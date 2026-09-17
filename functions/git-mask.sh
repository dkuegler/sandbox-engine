#!/bin/bash
# Read-only .git mask: the sole git-access control now that the agent image
# ships a real `git` binary directly (decided 2026-09-17: option
# A). Every .git under the project tree -- and under every read-write extra
# bind -- is bind-mounted read-only into the agent container, kernel-
# enforced, so it holds regardless of whether the git binary the agent uses
# came from the image or was fetched/installed by the agent itself.
#
# Also owns cleanup() for the per-run scratch directory (RUN_DIR), which is
# no longer git-specific: functions/agents.sh's ensure_run_dir() creates it
# on demand for the omp branch's secrets redaction, independent of git.
# cleanup is registered as the EXIT trap by sandbox.sh *before* anything
# else runs, so every variable it touches is referenced defensively.
cleanup() {
    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
        rm -rf "$RUN_DIR"
    fi
}

# reap_orphaned_run_dirs: on startup, before this run creates its own
# RUN_DIR, remove any leftover "$TMPDIR/sandbox-engine.*" directory whose
# owner process is gone. A directory leaks when a run is killed with
# SIGKILL before cleanup()'s EXIT trap can fire -- ensure_run_dir()
# (functions/agents.sh) writes the creating shell's PID into
# "<dir>/.owner_pid" for exactly this check. `kill -0 $pid` can in theory
# false-negative on PID reuse (a coincidentally-alive unrelated process
# now holds that PID) -- acceptable here: the cost of a false "still
# alive" is only that one small leaked directory survives one more scan,
# never data loss. A directory with no `.owner_pid` file at all (created
# by an older version of this script, or by something else entirely) is
# left alone rather than guessed at.
reap_orphaned_run_dirs() {
    local dir pid
    for dir in "${TMPDIR:-/tmp}"/sandbox-engine.*; do
        [[ -d "$dir" ]] || continue
        [[ -f "$dir/.owner_pid" ]] || continue
        pid="$(cat "$dir/.owner_pid" 2>/dev/null)"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "reaping orphaned run directory: $dir (owner pid $pid is gone)" >&2
            rm -rf "$dir"
        fi
    done
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
# itself* between runs -- e.g. after `git init` in a subdirectory, or a
# fresh `git clone`, both ordinary agent activity now that git ships in
# the image -- would not be masked on the next run until the cache
# expired. Any invalidation cheap enough to be worth doing (mtime of the
# project root, of RUN_DIR, ...) does not detect a new nested repository
# several directories down, so it would not actually be safe, only
# appear to be. There is no way to know "nothing changed" without a walk
# at least as expensive as the one being avoided.
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
            # entry is itself the gitdir (ordinary/nested repo case) --
            # sanitize it directly. A worktree/submodule .git is a file,
            # not a gitdir, so there is nothing under it to sanitize; its
            # target (real, below) is the actual gitdir in that case.
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
