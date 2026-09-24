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
#     config.yml       a plain copy, so omp's rename-based save works; at
#                      exit modelRoles and cycleOrder merge back
#                      (omp_config_merge), everything else is reported
#     agent.db (-wal, -shm), blobs/, sessions/<this checkout>/
#                      the host's own, read-write: credentials and sessions
#     history.db       symlink into a per-project database in
#                      ~/.agent/omp-history/
#     every other host entry                 read-only
#     .env secret-placeholder.key models.db terminal-sessions/ cache/
#                      not bound: absent, or fresh per run
#
# Anything the session creates under a new name lands in $RUN_DIR and goes
# with it; omp_home_report_created names it at exit.
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

    key="$(project_state_key)"
    omp_home_bind_private "$HOME/.agent/omp-logs/$key" "$real/logs" || return 1
    omp_home_bind_private "$HOME/.agent/omp-history/$key" "$real/agent/.sandbox-history" || return 1
    ln -s .sandbox-history/history.db "$agent/history.db" || return 1

    # config.yml (or an existing config.yaml): a plain per-run copy, the
    # launch state kept beside it for omp_config_merge. With no host file,
    # an empty mapping -- a missing one would send omp looking for legacy
    # settings to migrate, and an empty document is not a mapping.
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
    cp -- "$agent/$OMP_CONFIG_NAME" "$RUN_DIR/omp-config.orig" || return 1
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

    (cd "$OMP_HOME_DIR" && find . -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort) \
        >"$RUN_DIR/omp-home.manifest" || return 1
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

# --- after the container exits ------------------------------------------

# The standard form. omp writes config.yml with Bun's YAML.stringify at
# two-space indent, trailing spaces after a colon stripped; the merge
# reads that form and nothing else, because a line scanner and a YAML
# parser agree on what the top-level keys are only when no construct can
# span lines or hide a key. omp_config_standard FILE accepts exactly:
#   - "{}" as the only line (the empty mapping), or lines of which
#   - every column-0 line is "KEY:" or "KEY: VALUE", KEY an identifier
#     (A-Z a-z 0-9 _ -, not starting with a digit or "-"), each KEY once;
#   - every other line is indented by a multiple of two spaces, then any
#     number of "- " item markers, then "KEY:", "KEY: VALUE" or VALUE,
#     KEY plain or double-quoted;
#   - a VALUE is a complete double-quoted string, a plain scalar (no
#     leading YAML indicator except "-", "?" or ":" before a non-space, no
#     ": " or " #" inside, no leading/trailing space, no trailing ":"),
#     or -- only as a whole item, never after "KEY: " -- "[]" or "{}".
# Rejected, among others: blank lines, comments, tabs, control
# characters, document markers, quoted/flow/complex top-level keys,
# "KEY:VALUE" without the space, anchors, aliases, tags, single quotes,
# block scalars, flow collections other than "[]"/"{}", a string left
# open across lines. On rejection prints "line N: TEXT" and fails.
omp_config_standard() {
    awk '
        BEGIN { IND = "-?:,[]{}#&*!|>\047\"%@`" }
        function quotedok(s) { return s ~ /^"([^"\\]|\\.)*"$/ }
        function plainok(s,   c) {
            if (s == "" || s ~ /^ / || s ~ / $/ || s ~ /:$/) return 0
            if (index(s, ": ") || index(s, " #")) return 0
            c = substr(s, 1, 1)
            if (index(IND, c) && !(index("-?:", c) && length(s) > 1 && substr(s, 2, 1) != " ")) return 0
            return 1
        }
        function valueok(s, bare) {
            if (substr(s, 1, 1) == "\"") return quotedok(s)
            if (s == "[]" || s == "{}") return bare
            return plainok(s)
        }
        function fail() { printf "line %d: %s\n", NR, $0; bad = 1; exit }
        NR == 1 && $0 == "{}" { empty = 1; next }
        empty || $0 == "" || /[[:cntrl:]]/ { fail() }
        {
            match($0, /^ */); n = RLENGTH; rest = substr($0, n + 1)
            if (n % 2) fail()
            if (n == 0) {
                if (rest !~ /^[A-Za-z_][A-Za-z0-9_-]*:( |$)/) fail()
                key = rest; sub(/:.*/, "", key)
                if (key in seen) fail()
                seen[key] = 1
                v = substr(rest, length(key) + 3)
                if (length(rest) > length(key) + 1 && !valueok(v, 0)) fail()
                next
            }
            while (substr(rest, 1, 2) == "- ") rest = substr(rest, 3)
            if (substr(rest, 1, 1) == "\"") {
                if (!match(rest, /^"([^"\\]|\\.)*"/)) fail()
                after = substr(rest, RLENGTH + 1)
                if (after == "" || after == ":") next
                if (substr(after, 1, 2) != ": " || !valueok(substr(after, 3), 0)) fail()
                next
            }
            p = index(rest, ": ")
            if (p) {
                if (!plainok(substr(rest, 1, p - 1)) || !valueok(substr(rest, p + 2), 0)) fail()
                next
            }
            if (rest ~ /:$/) {
                if (!plainok(substr(rest, 1, length(rest) - 1))) fail()
                next
            }
            if (!valueok(rest, 1)) fail()
        }
        END {
            if (bad) exit 1
            if (NR == 0) { print "the file is empty"; exit 1 }
        }
    ' "$1"
}

# The helpers below read files omp_config_standard has accepted: a
# top-level block is its column-0 key line and every indented line after
# it, and no key occurs twice.

# omp_config_keys FILE: FILE's top-level keys, sorted.
omp_config_keys() {
    grep -o -E '^[A-Za-z_][A-Za-z0-9_-]*:' "$1" 2>/dev/null | sed 's/:$//' | LC_ALL=C sort
}

# omp_config_block FILE KEY: KEY's top-level block in FILE; empty when KEY
# is absent.
omp_config_block() {
    [[ -f "$1" ]] || return 0
    awk -v key="$2" '
        /^[^ ]/ { if (inblk) exit; if ($0 ~ "^" key ":( |$)") inblk = 1 }
        inblk { print }
    ' "$1"
}

# omp_config_with_block FILE KEY BLOCKFILE: FILE on stdout with KEY's
# top-level block replaced by BLOCKFILE, appended when FILE has none; the
# empty mapping "{}" is replaced by the block alone.
omp_config_with_block() {
    awk -v key="$2" -v blockfile="$3" '
        BEGIN { while ((getline l < blockfile) > 0) blk[++bn] = l }
        function emit(   i) { for (i = 1; i <= bn; i++) print blk[i]; done = 1 }
        NR == 1 && $0 == "{}" { next }
        /^[^ ]/ {
            inblk = 0
            if (!done && $0 ~ "^" key ":( |$)") { emit(); inblk = 1; next }
        }
        inblk { next }
        { print }
        END { if (!done) emit() }
    ' "$1"
}

# omp_config_block_mergeable KEY BLOCK: BLOCK is exactly the shape omp
# writes for KEY -- "modelRoles:" with "  <role>: <model>" lines, or
# "cycleOrder:" with "  - <model>" lines, or the empty form, "  {}" or
# "  []" alone on the line after the key -- and every value is a plain
# model id. Anything else is not merged.
omp_config_block_mergeable() {
    local key="$1" line first=1 items=0 empty
    local id='[A-Za-z0-9][A-Za-z0-9._/:@+-]*'
    case "$key" in
        modelRoles) empty="  {}" ;;
        cycleOrder) empty="  []" ;;
        *) return 1 ;;
    esac
    while IFS= read -r line; do
        if [[ "$first" -eq 1 ]]; then
            first=0
            [[ "$line" == "$key:" ]] || return 1
            continue
        fi
        [[ "$items" -ge 0 ]] || return 1
        if [[ "$items" -eq 0 && "$line" == "$empty" ]]; then
            items=-1
            continue
        fi
        case "$key" in
            modelRoles) [[ "$line" =~ ^\ \ [A-Za-z0-9_-]+:\ ${id}$ ]] || return 1 ;;
            cycleOrder) [[ "$line" =~ ^\ \ -\ ${id}$ ]] || return 1 ;;
        esac
        items=$((items + 1))
    done <<<"$2"
    [[ "$first" -eq 0 && "$items" -ne 0 ]]
}

# omp_config_others_equal OLD NEW KEY: every top-level block except KEY's
# is identical in OLD and NEW.
omp_config_others_equal() {
    local k a b
    while IFS= read -r k; do
        [[ "$k" == "$3" ]] && continue
        a="$(omp_config_block "$1" "$k")"
        b="$(omp_config_block "$2" "$k")"
        [[ "$a" == "$b" ]] || return 1
    done < <({ omp_config_keys "$1"; omp_config_keys "$2"; } | LC_ALL=C sort -u)
}

# omp_config_merge: of everything the session saved to its config copy,
# only modelRoles and cycleOrder reach the host's real file, and only when
# the session changed the key, the new value passes
# omp_config_block_mergeable, and the real file still holds what it held
# at launch for that key -- a change made on the host meanwhile wins and
# is reported. Other changed keys are reported, never merged. Every file
# involved -- the session's copy, the launch copy, the host file and the
# rewrite -- must be in the standard form (omp_config_standard); a copy
# that is not is neither merged nor listed, and a host file that is not
# is never written. A killed run never gets here, so it merges nothing.
omp_config_merge() {
    local copy orig real key s_orig s_now h_now tmp block newf bad real_bad=""
    local -a merged=() skipped=() others=()
    [[ -n "${OMP_HOME_DIR:-}" && -f "$RUN_DIR/omp-config.orig" ]] || return 0
    copy="$OMP_HOME_DIR/agent/$OMP_CONFIG_NAME"
    orig="$RUN_DIR/omp-config.orig"
    real="$HOME/.omp/agent/$OMP_CONFIG_NAME"
    block="$RUN_DIR/omp-config.block"
    newf="$RUN_DIR/omp-config.new"
    if [[ ! -f "$copy" || -L "$copy" ]]; then
        printf '%s\n' "sandbox: the omp session left no regular $OMP_CONFIG_NAME; nothing was merged back." >&2
        return 0
    fi
    if ! bad="$(omp_config_standard "$copy")"; then
        {
            printf '%s\n' "sandbox: the omp session's $OMP_CONFIG_NAME is not in the form omp writes, so"
            printf '%s\n' "  nothing was merged back and its changes are not listed. The first line"
            printf '%s\n' "  outside that form:"
            printf '    %s\n' "$bad"
        } | sanitize_agent_display >&2 || true
        return 0
    fi
    if ! bad="$(omp_config_standard "$orig")"; then
        {
            printf '%s\n' "sandbox: $real was not in the form omp writes at launch, so nothing was"
            printf '%s\n' "  merged back and the session's changes are not listed. The first line"
            printf '%s\n' "  outside that form:"
            printf '    %s\n' "$bad"
        } | sanitize_agent_display >&2 || true
        return 0
    fi
    if [[ -f "$real" && ! -L "$real" ]] && ! bad="$(omp_config_standard "$real")"; then
        real_bad="$bad"
    fi
    while IFS= read -r key; do
        s_orig="$(omp_config_block "$orig" "$key")"
        s_now="$(omp_config_block "$copy" "$key")"
        if [[ "$s_orig" == "$s_now" ]]; then
            continue
        fi
        if [[ "$key" != modelRoles && "$key" != cycleOrder ]]; then
            others+=("$key")
            continue
        fi
        if ! omp_config_block_mergeable "$key" "$s_now"; then
            skipped+=("$key: not the plain model-id shape omp writes")
            continue
        fi
        if [[ -L "$real" || ! -f "$real" ]]; then
            skipped+=("$key: $real is missing or a symlink")
            continue
        fi
        if [[ -n "$real_bad" ]]; then
            skipped+=("$key: $real is not in the form omp writes ($real_bad)")
            continue
        fi
        h_now="$(omp_config_block "$real" "$key")"
        if [[ "$h_now" != "$s_orig" ]]; then
            skipped+=("$key: changed on the host during the run; the host's value stays")
            continue
        fi
        printf '%s\n' "$s_now" >"$block"
        if ! omp_config_with_block "$real" "$key" "$block" >"$newf" \
            || ! omp_config_standard "$newf" >/dev/null \
            || [[ "$(omp_config_block "$newf" "$key")" != "$s_now" ]] \
            || ! omp_config_others_equal "$real" "$newf" "$key"; then
            skipped+=("$key: the rewrite would have touched more than this key")
            continue
        fi
        # Written beside the real file and renamed over it, so a reader
        # never sees half a file; cp -p first carries its mode over.
        if ! tmp="$(mktemp "${real%/*}/.sandbox-config.XXXXXX")"; then
            skipped+=("$key: could not write beside $real")
            continue
        fi
        if ! { cp -p -- "$real" "$tmp" && cat -- "$newf" >"$tmp" && mv -f -- "$tmp" "$real"; }; then
            rm -f -- "$tmp"
            skipped+=("$key: could not replace $real")
            continue
        fi
        # A worktree re-run starts from what was just merged.
        if omp_config_with_block "$orig" "$key" "$block" >"$orig.next"; then
            mv -f -- "$orig.next" "$orig"
        fi
        merged+=("$key")
    done < <({ omp_config_keys "$orig"; omp_config_keys "$copy"; } | LC_ALL=C sort -u)

    if [[ ${#merged[@]} -gt 0 ]]; then
        printf '%s\n' "sandbox: omp settings merged back into $real: ${merged[*]}" >&2
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        {
            printf '%s\n' "sandbox: omp settings the session changed but NOT merged into $real:"
            printf '    %s\n' "${skipped[@]}"
        } | sanitize_agent_display >&2 || true
    fi
    if [[ ${#others[@]} -gt 0 ]]; then
        {
            printf '%s\n' "sandbox: the omp session also changed these settings; only modelRoles and"
            printf '%s\n' "  cycleOrder are ever merged back, so they stay in the run. Its values:"
            for key in "${others[@]}"; do
                omp_config_block "$copy" "$key" | sed 's/^/    /' || true
            done
            printf '%s\n' "  Apply any you want by hand, e.g. with 'omp config set'."
        } | sanitize_agent_display >&2 || true
    fi
    return 0
}

# omp_home_report_created: name what the session created under ~/.omp at
# a path that did not exist at launch. It is already gone with $RUN_DIR;
# under agent/ it would have been loaded by the next unsandboxed omp, so
# the human should know it was attempted. omp's own per-run state is not
# listed: its databases, terminal sessions, caches, the placeholder key and
# wt/ (the worktrees omp creates for isolated tasks).
omp_home_report_created() {
    local rel
    local -a created=()
    [[ -n "${OMP_HOME_DIR:-}" && -f "$RUN_DIR/omp-home.manifest" ]] || return 0
    while IFS= read -r rel; do
        case "$rel" in
            ./run/* | ./logs/* | ./security/* | ./cache/* | ./natives/*) continue ;;
        esac
        case "${rel##*/}" in
            *.db | *.db-wal | *.db-shm | *.db-journal | *.tmp | \
                terminal-sessions | cache | secret-placeholder.key | wt) continue ;;
        esac
        created+=("$HOME/.omp/${rel#./}")
    done < <(cd "$OMP_HOME_DIR" && find . -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort \
        | LC_ALL=C comm -13 "$RUN_DIR/omp-home.manifest" -)
    [[ ${#created[@]} -gt 0 ]] || return 0
    {
        printf '%s\n' "sandbox: the omp session created these under ~/.omp; they were discarded with"
        printf '%s\n' "  the run (anything under ~/.omp/agent would have loaded in your next omp):"
        printf '    %s\n' "${created[@]}"
    } | sanitize_agent_display >&2 || true
    return 0
}

# omp_home_finish: the post-exit half, run after every container exit
# (each round in worktree mode). A no-op for every other agent.
omp_home_finish() {
    [[ -n "${OMP_HOME_DIR:-}" ]] || return 0
    omp_config_merge
    omp_home_report_created
    return 0
}
