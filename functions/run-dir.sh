#!/bin/bash
# Owns the lifecycle of the per-run scratch directory (RUN_DIR): its EXIT-
# trap cleanup, and reaping any copy leaked by a prior run that was
# SIGKILLed before its own cleanup could fire. RUN_DIR itself is not
# git-specific -- functions/agents.sh's ensure_run_dir() creates it on
# demand for the omp branch's secrets redaction, independent of git, and
# sandbox.sh's own EXEC_ARGV construction uses it unconditionally (every
# agent, including `script`) for the /tmp bind that replaces
# --writable-tmpfs's 64 MiB ceiling.

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
