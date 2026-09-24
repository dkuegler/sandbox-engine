#!/bin/bash
# Owns the lifecycle of the per-run scratch directory (RUN_DIR): its
# teardown callback, and reaping any copy leaked by a prior run that was
# SIGKILLed before that callback could fire. RUN_DIR itself is not
# git-specific -- functions/agents.sh's ensure_run_dir() creates it on
# demand for every agent's per-run copies (omp's per-run home among them), and
# sandbox.sh's own EXEC_ARGV construction uses it unconditionally (every
# agent, including `script`) for the /tmp bind that replaces
# --writable-tmpfs's 64 MiB ceiling.
#
# This file knows about RUN_DIR and nothing else. Other host-side state
# with its own lifetime (the --worktree lock, functions/worktree.sh)
# registers its own release with register_cleanup_hook()
# (functions/cleanup.sh); it is deliberately not called from here.

# remove_run_dir: registered below as a cleanup hook, so it runs on EXIT
# whether or not this run ever created a RUN_DIR -- hence the defensive
# guard rather than an assumption that ensure_run_dir() ran.
remove_run_dir() {
    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
        rm -rf "$RUN_DIR"
    fi
}

# Registered at source time: RUN_DIR is created lazily from several call
# sites (functions/agents.sh, functions/git-mask.sh, sandbox.sh), and a
# teardown that is only registered on one of those paths is a teardown that
# one day does not run. Requires functions/cleanup.sh to be sourced first,
# which sandbox.sh does.
register_cleanup_hook remove_run_dir

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
            log_warn "reaping orphaned run directory: $dir (owner pid $pid is gone)"
            rm -rf "$dir"
        fi
    done
}
