#!/bin/bash
# Git MCP sidecar lifecycle: starts sandbox/gitmcp.sif (the container that
# owns git access) before the agent runs, exposes it over a Unix domain
# socket shared with the agent container, masks every .git in the project
# tree read-only in the agent container, and stops the sidecar on exit.
#
# Populates (when a .git is present): RUN_DIR, GIT_SIDECAR_NAME,
# GIT_MCP_SOCKET, and appends the read-only .git binds to BINDS.
#
# Unix socket, not loopback HTTP: an `apptainer instance` shares the
# host's network namespace unless started with --net, which needs root
# privileges we don't have. A TCP listener on 127.0.0.1 is therefore
# reachable by every local process regardless of any bearer token. A
# socket file mode 0600 inside a 0700 RUN_DIR makes the kernel's own
# connect()-time permission check the access control instead, and avoids
# a secret needing to be minted, plumbed through APPTAINERENV_*, and
# written into a config file at all.

# cleanup is registered as the EXIT trap by sandbox.sh *before* anything
# else runs, so every variable it touches is referenced defensively.
cleanup() {
    if [[ -n "${GIT_SIDECAR_NAME:-}" ]]; then
        apptainer instance stop "$GIT_SIDECAR_NAME" >/dev/null 2>&1 || true
    fi
    # Ephemeral bind points created inside the user's project dir.
    if [[ -n "${OMP_MCP_PLACEHOLDER:-}" && -f "$OMP_MCP_PLACEHOLDER" ]]; then
        rm -f "$OMP_MCP_PLACEHOLDER"
    fi
    if [[ -n "${OMP_MCP_DIR_CREATED:-}" && -d "$OMP_MCP_DIR_CREATED" ]]; then
        rmdir "$OMP_MCP_DIR_CREATED" 2>/dev/null || true
    fi
    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
        rm -rf "$RUN_DIR"
    fi
}

# dump_sidecar_logs NAME: best-effort dump of the instance's stdout/stderr
# on a readiness failure. There is no `apptainer instance logs` command
# (the "instance" group is only list/run/start/stats/stop -- an earlier
# version of this script called it anyway and always failed with a usage
# error). Since Apptainer 1.1 `instance list --logs` prints the on-disk
# log paths instead; parse and cat those.
dump_sidecar_logs() {
    local name="$1" listing errlog outlog
    listing="$(apptainer instance list --logs "$name" 2>/dev/null || true)"
    errlog="$(printf '%s\n' "$listing" | command grep -oE '/\S+\.err' | head -n1)"
    outlog="$(printf '%s\n' "$listing" | command grep -oE '/\S+\.out' | head -n1)"
    if [[ -n "$errlog" && -f "$errlog" ]]; then
        echo "--- sidecar stderr ($errlog) ---" >&2
        cat "$errlog" >&2
    fi
    if [[ -n "$outlog" && -f "$outlog" ]]; then
        echo "--- sidecar stdout ($outlog) ---" >&2
        cat "$outlog" >&2
    fi
    if [[ -z "$errlog$outlog" ]]; then
        echo "note: could not locate sidecar log files via 'apptainer instance list --logs $name'" >&2
        [[ -n "$listing" ]] && printf '%s\n' "$listing" >&2
    fi
}

# resolve_git_dir PATH: echoes the real git directory for a .git entry.
# In a worktree or submodule checkout .git is a FILE containing
# "gitdir: <path>" (possibly relative), and that target holds the actual
# refs/objects, so it must be masked too.
resolve_git_dir() {
    local entry="$1" target base
    if [[ -d "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi
    [[ -f "$entry" ]] || return 0
    target="$(sed -n 's/^gitdir:[[:space:]]*//p' "$entry" | head -n1)"
    [[ -n "$target" ]] || return 0
    if [[ "$target" != /* ]]; then
        base="$(dirname "$entry")"
        target="$base/$target"
    fi
    target="$(readlink -f "$target" 2>/dev/null || true)"
    [[ -n "$target" && -e "$target" ]] && printf '%s\n' "$target"
}

# git_dir_visible PATH ROOTS...: true if PATH is at or under any of the
# given roots -- i.e. already visible in the container without needing
# its own extra bind. Shared by mask_git_readonly's containment check
# and its caller so both agree on what "inside the sandbox" means.
git_dir_visible() {
    local p="$1" root
    shift
    for root in "$@"; do
        [[ "$p" == "$root" || "$p" == "$root"/* ]] && return 0
    done
    return 1
}

# mask_git_readonly: appends a read-only bind for every .git under the
# project tree and every read-write extra bind (top level, submodules,
# nested repositories) plus the real git directory each one points at.
#
# apptainer sorts mount points by destination depth, shallowest first
# (PointList.Less/Sort in internal/pkg/util/fs/mount/mount_linux.go), so
# the shallow read-write project-dir/extra-bind mounts land before these
# deeper read-only binds and the kernel then enforces the boundary
# regardless of what tries to write .git inside the container. A
# read-only extra bind needs no mask of its own (the kernel already
# refuses the write), and a source inside the project dir is already
# covered by the project-dir walk.
#
# This walks each root once per run (`find` cannot know where a .git
# might be without looking), which is the dominant cost of every
# invocation on a large tree and grows with the number of read-write
# extra binds (sandbox.yml binds:/--bind) sandbox.sh covers. The elapsed
# time is reported per root so that cost is visible instead of silent.
#
# Caching the result across runs was considered and rejected: this is
# the sole enforcement point for a security boundary (F8), and a cache
# with any TTL creates a window where a `.git` created *by the agent
# itself* between runs -- e.g. after `apt install git && git init`,
# exactly the capability this mask exists to contain now that the agent
# image ships no git binary -- would not be masked on the next run until
# the cache expired. Any invalidation cheap enough to be worth doing
# (mtime of the project root, of RUN_DIR, ...) does not detect a new
# nested repository several directories down, so it would not actually
# be safe, only appear to be. There is no way to know "nothing changed"
# without a walk at least as expensive as the one being avoided.
mask_git_readonly() {
    local entry real root start_ts end_ts elapsed j
    local -a masked=()
    local -a roots=("$PROJECT_DIR")
    local -a extra_srcs=(${EXTRA_BIND_SRCS[@]+"${EXTRA_BIND_SRCS[@]}"})
    local -a extra_ro=(${EXTRA_BIND_RO[@]+"${EXTRA_BIND_RO[@]}"})
    for ((j = 0; j < ${#extra_srcs[@]}; j++)); do
        [[ "${extra_ro[$j]}" -eq 1 ]] && continue
        [[ "${extra_srcs[$j]}" == "$PROJECT_DIR" || "${extra_srcs[$j]}" == "$PROJECT_DIR"/* ]] && continue
        roots+=("${extra_srcs[$j]}")
    done

    for root in "${roots[@]}"; do
        start_ts="$(date +%s.%N)"
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            BINDS+=(-B "$entry:$entry:ro")
            masked+=("$entry")
            real="$(resolve_git_dir "$entry")"
            # A gitdir outside every bound tree is not covered by any
            # read-write bind, so only mask it when it is actually
            # visible in the container -- or explicitly opted into.
            if [[ -n "$real" && "$real" != "$entry" ]] && git_dir_visible "$real" "${roots[@]}"; then
                BINDS+=(-B "$real:$real:ro")
                masked+=("$real")
            elif [[ -n "$real" && "$real" != "$entry" ]]; then
                if [[ "${ALLOW_EXTERNAL_GITDIR:-0}" -eq 1 ]]; then
                    BINDS+=(-B "$real:$real:ro")
                    masked+=("$real")
                    echo "note: mounting external git dir $real read-only (--allow-external-gitdir)" >&2
                else
                    echo "note: git dir $real lies outside the bound trees and is not mounted into the sandbox; pass --allow-external-gitdir to mount it read-only" >&2
                fi
            fi
        done < <(find "$root" -mindepth 1 -name .git -prune -print 2>/dev/null)
        end_ts="$(date +%s.%N)"
        elapsed="$(awk -v a="$start_ts" -v b="$end_ts" 'BEGIN { printf "%.3f", b - a }')"
        echo "git: scanned $root for .git entries in ${elapsed}s" >&2
        log_debug "find root: $root (${elapsed}s)"
    done

    # shellcheck disable=SC2034  # GIT_MASK_COUNT is read by sandbox.sh's post-configure_agent summary log
    GIT_MASK_COUNT=${#masked[@]}
    if [[ ${#masked[@]} -gt 0 ]]; then
        echo "git: masking ${#masked[@]} path(s) read-only in the sandbox: ${masked[*]}" >&2
    fi
}

# start_git_sidecar: masks .git read-only unconditionally, then (only if
# the project root is itself a repository) starts the MCP sidecar.
# Leaves GIT_MCP_SOCKET empty when there is no sidecar.
start_git_sidecar() {
    RUN_DIR=""
    GIT_SIDECAR_NAME=""
    GIT_MCP_SOCKET=""

    mask_git_readonly

    # .git is a directory in a normal clone and a file in a worktree or
    # submodule checkout; both are repositories the sidecar can serve.
    [[ -e "$PROJECT_DIR/.git" ]] || return 0

    RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-engine.XXXXXX")"
    chmod 700 "$RUN_DIR"
    # mktemp's XXXXXX suffix is what makes RUN_DIR unique per run; $$ is
    # not (PIDs are reused, and two concurrent invocations of this script
    # can share one). apptainer instance names are global per user, so a
    # collision both fails `instance run` for the second run and makes
    # this script's cleanup() stop the *other* run's sidecar.
    GIT_SIDECAR_NAME="git-sidecar-${RUN_DIR##*.}"
    GIT_MCP_SOCKET="$RUN_DIR/gitmcp.sock"
    log_info "git sidecar: name=$GIT_SIDECAR_NAME socket=$GIT_MCP_SOCKET"

    # git's own global-config search order, minus the system file: an
    # explicit GIT_CONFIG_GLOBAL wins, then XDG, then the classic
    # dotfile. Only the host's *global* config is ever considered here --
    # nothing project- or system-scoped.
    local GIT_HOST_CONFIG="" c
    for c in "${GIT_CONFIG_GLOBAL:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config" "$HOME/.gitconfig"; do
        if [[ -n "$c" && -f "$c" ]]; then GIT_HOST_CONFIG="$c"; break; fi
    done

    # `instance start` runs the SIF's %startscript, which a plain
    # Dockerfile build (apptainer's dockerfile:/buildkit: bootstrap) has
    # no way to define -- only ENTRYPOINT/CMD, which apptainer maps to
    # %runscript. `instance run` is the counterpart that executes
    # %runscript, with these trailing arguments passed to it. Using
    # `start` here silently produced an instance with nothing listening
    # (readiness always timed out).
    #
    # RUN_DIR is bound into the sidecar too so the socket it creates
    # lands on the same host path the agent container mounts below.
    #
    # The repository is bound READ-ONLY into the sidecar as well: every
    # tool this server exposes is read-only, so nothing in the sidecar
    # needs write access either. Exposing a mutating tool later means
    # flipping this bind back to rw for that tool's sake, deliberately.
    #
    # The host's global git config, if any, is bound read-only at a
    # fixed in-container path (never the host path itself, which stays
    # out of both the sidecar's argv and the config's own view) and the
    # server is told where to find it with --gitconfig. include.path/
    # includeIf targets inside that file point at host paths that are
    # not mounted; git silently ignores a missing include (git-config(5)),
    # so this only degrades to "the included settings are absent", never
    # an error. Omitted entirely when the host has no global config, so
    # the sidecar keeps today's no-identity behaviour.
    local -a git_instance_binds=(-B "$PROJECT_DIR:$PROJECT_DIR:ro" -B "$RUN_DIR")
    local -a git_server_args=(--repository "$PROJECT_DIR" --socket "$GIT_MCP_SOCKET")
    if [[ -n "$GIT_HOST_CONFIG" ]]; then
        git_instance_binds+=(-B "$GIT_HOST_CONFIG:/run/gitconfig:ro")
        git_server_args+=(--gitconfig /run/gitconfig)
    fi

    log_argv "apptainer instance run argv" \
        apptainer instance run --containall --writable-tmpfs \
        "${git_instance_binds[@]}" "$GITMCP_SIF" "$GIT_SIDECAR_NAME" "${git_server_args[@]}"

    apptainer instance run \
        --containall --writable-tmpfs \
        "${git_instance_binds[@]}" \
        "$GITMCP_SIF" \
        "$GIT_SIDECAR_NAME" \
        "${git_server_args[@]}"

    # Wait for the sidecar to create and bind its socket before handing
    # the agent an MCP config that points at it.
    local ready=0 _i
    for _i in $(seq 1 50); do
        if [[ -S "$GIT_MCP_SOCKET" ]]; then
            ready=1
            break
        fi
        sleep 0.2
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "git MCP sidecar did not create $GIT_MCP_SOCKET within 10s" >&2
        dump_sidecar_logs "$GIT_SIDECAR_NAME"
        exit 1
    fi
}
