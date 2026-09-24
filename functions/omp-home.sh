#!/bin/bash
# omp's ~/.omp inside the sandbox: a per-run directory.
#
# omp keeps state and configuration side by side. ~/.omp/agent holds its
# sqlite databases next to config.yml, models.yml, mcp.json, lsp.json,
# extensions/, hooks/, rules/, SYSTEM.md and more, and omp loads code or
# standing instructions from every one of those. ~/.omp itself holds the
# extracted native addons (reused whenever the file size matches), the hub
# broker's socket and collab's bearer tokens (run/), logs and caches. Any
# of it shared read-write with the host is a way out of the sandbox: into
# the next unsandboxed omp, or straight to a host-side process.
#
# So the host's ~/.omp is never bound as a directory. The container gets
# $RUN_DIR/omp in its place, with host paths bound into it one at a time:
#
#   natives            symlink to the image's read-only copy, extracted at
#                      build time (sandbox/agent/Dockerfile.template)
#   logs/              per project, kept on the host in ~/.agent/omp-logs/
#   run/ security/ cache/                    empty, per run
#   install-id gpu_cache.json                copies
#   sandbox-overlay.yml                      read-only settings overlay
#                      (PI_CONFIG_FILES) that forces secret redaction on
#   agent/             per run:
#     config.yml       a plain copy, so omp's rename-based save works; the
#                      session's own changes to it stay in the run
#     agent.db (-wal, -shm), blobs/, sessions/<this checkout>/
#                      the host's own, read-write: credentials and sessions
#     history.db       symlink into a per-project database in
#                      ~/.agent/omp-history/
#     every other host entry                 read-only
#     .env secret-placeholder.key models.db terminal-sessions/ cache/
#                      not bound: absent, or fresh per run
#
# Anything the session creates under a new name lands in $RUN_DIR and goes
# with it.
#
# sqlite: the three agent.db files are bound by name, and created empty on
# the host when absent. sqlite ignores the unlink that fails on a bound
# file at close, and keeps its data. history.db is reached through a
# symlink, which sqlite resolves, so its -wal/-shm live beside the real
# file in the bound directory. Residual: a host omp that closes its last
# agent.db connection in the moment between container start and the
# sandbox's own open deletes the -wal/-shm the sandbox has just bound; a
# host omp opened after that writes a second WAL for the same database.
#
# The sandbox mounts omp's default profile only; anything that makes omp
# read and write other paths than this layout is refused before the
# container starts (omp_home_refuse_overrides).

# OMP_IMAGE_NATIVES: where the image keeps omp's native addons, extracted at
# build time (sandbox/agent/Dockerfile.template).
OMP_IMAGE_NATIVES=/usr/local/omp/natives

# omp_home_require_natives: the per-run home links natives to the image's
# build-time copy. An omp image built before that extraction existed has
# no such copy, and image names do not change with the template, so an
# old image is reused as it is; omp would then fail on the dangling link
# inside the container, with an error that names neither the cause nor
# the remedy. Asked once per run, after the image is built. Only a
# definite "not in the image" refuses: an image that could not be asked
# fails at launch on its own, with the backend's own error.
omp_home_require_natives() {
    local rc=0
    backend_image_has_path "$OMP_IMAGE_NATIVES" || rc=$?
    [[ "$rc" -eq 1 ]] || return 0
    echo "error: the omp image $SANDBOX_IMAGE predates the build-time extraction of" >&2
    echo "       omp's native addons ($OMP_IMAGE_NATIVES is missing). Re-run once with --rebuild." >&2
    exit 1
}

# omp_home_project_key: "<basename>-<8 hex>" of the checkout, the same key
# --worktree uses under ~/.agent/worktrees, so both modes share one history
# and one log folder per project.
omp_home_project_key() {
    local top="${WORKTREE_REPO_ROOT:-$PROJECT_DIR}"
    printf '%s-%s' "$(basename "$top")" "$(printf '%s' "$top" | sha256sum | cut -c1-8)"
}

# omp_session_bucket DIR: the folder omp files DIR's sessions under.
# omp buckets by canonical working directory: "-<relative>" under $HOME,
# "-tmp-<relative>" under the temp root, "--<absolute>--" otherwise, with
# "/" replaced by "-".
omp_session_bucket() {
    local dir home tmp rel
    dir="$(readlink -f -- "$1")" || return 1
    home="$(readlink -f -- "$HOME")" || return 1
    tmp="$(readlink -f -- "${TMPDIR:-/tmp}")" || tmp=/tmp
    if [[ "$dir" == "$home"/* ]]; then
        rel="${dir#"$home"/}"
        printf -- '-%s' "${rel//\//-}"
    elif [[ "$dir" == "$tmp"/* ]]; then
        rel="${dir#"$tmp"/}"
        printf -- '-tmp-%s' "${rel//\//-}"
    else
        rel="${dir#/}"
        printf -- '--%s--' "${rel//\//-}"
    fi
}

# omp_home_mountpoint REL KIND: create REL (under the per-run home) as the
# mount point for a nested bind, so apptainer never has to create one.
omp_home_mountpoint() {
    local p="$OMP_HOME_DIR/$1"
    if [[ "$2" == dir ]]; then
        mkdir -p -- "$p"
    else
        mkdir -p -- "${p%/*}" && : >"$p"
    fi
}

# omp_home_bind_shared PATH KIND: the host's own PATH (under ~/.omp),
# read-write at the same path inside the per-run home.
omp_home_bind_shared() {
    omp_home_mountpoint "${1#"$HOME"/.omp/}" "$2" || return 1
    bind_state_rw "$1" "$2"
}

# omp_home_bind_private SRC DST: a sandbox-engine-owned host directory SRC,
# read-write at DST inside the per-run home. No host omp ever reads SRC.
omp_home_bind_private() {
    mkdir -p -- "$1" || return 1
    chmod 700 -- "$1"
    omp_home_mountpoint "${2#"$HOME"/.omp/}" dir || return 1
    BINDS+=(-B "$1:$2")
}

# omp_home_prepare: build $RUN_DIR/omp and append its binds to BINDS.
# Sets OMP_HOME_DIR, OMP_CONFIG_NAME.
omp_home_prepare() {
    local real="$HOME/.omp" agent name p kind key host_config="" forwarded
    ensure_run_dir
    OMP_HOME_DIR="$RUN_DIR/omp"
    agent="$OMP_HOME_DIR/agent"
    mkdir -p -- "$agent" "$OMP_HOME_DIR/run" "$OMP_HOME_DIR/security" "$OMP_HOME_DIR/cache" || return 1
    ln -s "$OMP_IMAGE_NATIVES" "$OMP_HOME_DIR/natives" || return 1
    for name in install-id gpu_cache.json; do
        if [[ -f "$real/$name" ]]; then
            cp -- "$real/$name" "$OMP_HOME_DIR/$name" || return 1
        fi
    done
    BINDS+=(-B "$OMP_HOME_DIR:$real")

    key="$(omp_home_project_key)"
    omp_home_bind_private "$HOME/.agent/omp-logs/$key" "$real/logs" || return 1
    omp_home_bind_private "$HOME/.agent/omp-history/$key" "$real/agent/.sandbox-history" || return 1
    ln -s .sandbox-history/history.db "$agent/history.db" || return 1

    # config.yml (or an existing config.yaml): a plain per-run copy. With
    # no host file, an empty mapping -- a missing one would send omp
    # looking for legacy settings to migrate, and an empty document is not
    # a mapping.
    OMP_CONFIG_NAME=config.yml
    for name in config.yml config.yaml; do
        if [[ -f "$real/agent/$name" ]]; then
            OMP_CONFIG_NAME="$name"
            host_config="$real/agent/$name"
            break
        fi
    done
    if [[ -n "$host_config" ]]; then
        cp -- "$host_config" "$agent/$OMP_CONFIG_NAME" || return 1
    else
        printf '{}\n' >"$agent/$OMP_CONFIG_NAME" || return 1
    fi
    chmod 600 -- "$agent/$OMP_CONFIG_NAME"
    if [[ -f "$real/agent/last-changelog-version" ]]; then
        cp -- "$real/agent/last-changelog-version" "$agent/" || return 1
    fi

    # Secret redaction forced on through an overlay: overlays outrank the
    # global config, omp never writes them back, and this one is bound
    # read-only so the session cannot switch it off for later processes.
    # It matters however a credential reaches the container: omp's own
    # bash tool does not scrub environment variables, so without it a
    # host-supplied key the agent prints (`env`) reaches the model
    # verbatim. The obfuscator redacts only provider-visible text; the real
    # value still reaches the actual API call.
    printf 'secrets:\n  enabled: true\n' >"$RUN_DIR/omp-overlay.yml" || return 1
    chmod 600 -- "$RUN_DIR/omp-overlay.yml"
    omp_home_mountpoint sandbox-overlay.yml file || return 1
    BINDS+=(-B "$RUN_DIR/omp-overlay.yml:$real/sandbox-overlay.yml:ro")
    # Only a value forwarded into the container matters here: the host's
    # own PI_CONFIG_FILES never crosses --cleanenv, but a forwarded one
    # would be replaced below without a word.
    if forwarded="$(backend_forwarded_env PI_CONFIG_FILES)" && [[ -n "$forwarded" ]]; then
        log_warn "PI_CONFIG_FILES ($forwarded) is not passed through to omp: the sandbox sets" \
            "its own read-only overlay, and your overlay files are not mounted."
    fi
    backend_forward_env PI_CONFIG_FILES "$real/sandbox-overlay.yml"

    omp_home_bind_shared "$real/agent/agent.db" file || return 1
    omp_home_bind_shared "$real/agent/agent.db-wal" file || return 1
    omp_home_bind_shared "$real/agent/agent.db-shm" file || return 1
    omp_home_bind_shared "$real/agent/blobs" dir || return 1
    name="$(omp_session_bucket "${WORKTREE_DIR:-$PROJECT_DIR}")" || return 1
    omp_home_bind_shared "$real/agent/sessions/$name" dir || return 1

    # Every other entry of the host's agent directory, read-only: whatever
    # omp loads from there is visible and unchangeable, including names a
    # later omp version adds. Excluded: the state handled above, the
    # copies, credentials and keys, and omp's other databases and caches,
    # which start fresh. AGENTS.md gets the sandbox notice overlay instead
    # (bind_augmented_instructions); its mount point is made here.
    : >"$agent/AGENTS.md"
    while IFS= read -r -d '' p; do
        name="${p##*/}"
        case "$name" in
            agent.db | agent.db-wal | agent.db-shm | blobs | sessions | \
                config.yml | config.yaml | last-changelog-version | AGENTS.md | \
                .env | secret-placeholder.key | terminal-sessions | cache | .sandbox-history | \
                *.db | *.db-wal | *.db-shm | *.db-journal | *.tmp)
                continue
                ;;
        esac
        # A dangling link has nothing to bind; apptainer would refuse it.
        [[ -e "$p" ]] || continue
        case "$name" in
            models.yml | models.yaml) scan_omp_api_keys "$p" ;;
        esac
        kind="file"
        if [[ -d "$p" ]]; then
            kind=dir
        fi
        omp_home_mountpoint "agent/$name" "$kind" || return 1
        bind_ro "$p"
    done < <(find "$real/agent" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# omp_home_refuse_overrides: a named profile, or a variable that moves
# omp's directories, makes omp read and write paths this layout does not
# build. Refuse rather than guess. "default", empty or whitespace is the
# default profile; OMP_PROFILE wins over PI_PROFILE whenever it is defined.
#
# The variables are checked as the CONTAINER will see them
# (backend_forwarded_env, functions/apptainer.sh): every exec cleans the
# environment, so a host variable of the same name does not reach omp at
# all, and refusing on it would block a run it cannot affect. A host-only
# profile variable is named once, so its silent absence in the sandbox is
# not a surprise.
omp_home_refuse_overrides() {
    local a prev="" var val
    local -a profiles=()
    for a in ${ARGS[@]+"${ARGS[@]}"}; do
        if [[ "$prev" == "--profile" ]]; then
            profiles+=("$a")
        fi
        if [[ "$a" == --profile=* ]]; then
            profiles+=("${a#--profile=}")
        fi
        prev="$a"
    done
    if val="$(backend_forwarded_env OMP_PROFILE)"; then
        profiles+=("$val")
    elif val="$(backend_forwarded_env PI_PROFILE)"; then
        profiles+=("$val")
    fi
    for var in OMP_PROFILE PI_PROFILE; do
        if [[ -n "${!var:-}" ]] && ! backend_forwarded_env "$var" >/dev/null; then
            log_info "$var is set on the host but does not reach the sandbox;" \
                "sandboxed omp uses the default profile"
        fi
    done
    for a in ${profiles[@]+"${profiles[@]}"}; do
        a="${a//[[:space:]]/}"
        if [[ -z "$a" || "$a" == default ]]; then
            continue
        fi
        echo "error: omp profile '$a' is selected; sandboxed omp runs support only the default" >&2
        echo "       profile (~/.omp/profiles is not mounted). Drop --profile/OMP_PROFILE/PI_PROFILE." >&2
        exit 1
    done
    for var in PI_CODING_AGENT_DIR PI_CONFIG_DIR PI_CODING_AGENT_SESSION_DIR; do
        if val="$(backend_forwarded_env "$var")" && [[ -n "$val" ]]; then
            echo "error: $var is forwarded into the sandbox; it moves omp's directories outside" >&2
            echo "       the layout the sandbox builds for it. Stop forwarding it for sandboxed omp runs." >&2
            exit 1
        fi
    done
}
