#!/bin/bash
# omp's ~/.omp inside the sandbox.
#
# The sandbox mounts omp's default profile only; anything that makes omp
# read and write other paths than that layout is refused before the
# container starts (omp_home_refuse_overrides).

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
