#!/bin/bash
# Owns the process's single EXIT trap and the teardown callbacks registered
# against it. Nothing here knows what any of those callbacks release --
# that is the point: a module that creates host-side state registers its own
# release function when it creates the state, so this file (and every other
# module) stays independent of it.
#
# Sourced FIRST by sandbox.sh, before any module that registers at source
# time and before `trap cleanup EXIT`.

# Registered teardown callbacks, in registration order. Read only by
# cleanup().
CLEANUP_HOOKS=()

# register_cleanup_hook FN: run FN on exit. Idempotent, so a caller that can
# run twice (a retried acquire, a re-entered lifecycle step) does not stack
# duplicate teardowns.
#
# The name is resolved at EXIT, not here, so registration order and function
# definition order are independent.
register_cleanup_hook() {
    local fn="$1" existing
    for existing in ${CLEANUP_HOOKS[@]+"${CLEANUP_HOOKS[@]}"}; do
        [[ "$existing" == "$fn" ]] && return 0
    done
    CLEANUP_HOOKS+=("$fn")
}

# cleanup: the EXIT trap, registered by sandbox.sh before anything can
# create state.
#
# Hooks run in REVERSE registration order (last acquired, first released --
# atexit(3)/defer semantics), because registration order is acquisition
# order and a later hook may depend on state an earlier one owns.
#
# Every hook is called defensively: a hook whose function is not defined
# (module never sourced) is skipped, and a hook that fails cannot stop the
# ones behind it. A teardown path that aborts halfway leaks exactly the
# state this trap exists to remove.
cleanup() {
    local status=$? i fn
    for (( i = ${#CLEANUP_HOOKS[@]} - 1; i >= 0; i-- )); do
        fn="${CLEANUP_HOOKS[$i]}"
        declare -F "$fn" >/dev/null 2>&1 || continue
        "$fn" || true
    done
    return "$status"
}
