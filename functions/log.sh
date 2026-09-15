#!/bin/bash
# Verbosity helpers. VERBOSE is set by parse_argv: 0 = quiet (only the
# existing warnings/notes), 1 = -v, 2 = -vv. Everything goes to stderr
# so stdout stays the agent's.
VERBOSE=0
log_info()  { [[ "$VERBOSE" -ge 1 ]] && printf '%s\n' "sandbox: $*" >&2; return 0; }
log_debug() { [[ "$VERBOSE" -ge 2 ]] && printf '%s\n' "sandbox[debug]: $*" >&2; return 0; }

# log_argv LABEL ARG...: -vv-only helper that %q-quotes an argv array onto
# one copy-pasteable line, e.g. `log_argv "apptainer exec argv" apptainer
# exec --containall ...`. Any token immediately following a literal "--env"
# has its VALUE redacted (only the KEY= prefix survives) since --env
# becomes APPTAINERENV_* inside the container and must never be dumped in
# full -- see the "Git access" note in sandbox.sh.
log_argv() {
    local label="$1"
    shift
    [[ "$VERBOSE" -ge 2 ]] || return 0
    local tok prev="" show rendered
    local -a parts=()
    for tok in "$@"; do
        show="$tok"
        if [[ "$prev" == "--env" && "$tok" == *=* ]]; then
            show="${tok%%=*}=<redacted>"
        fi
        parts+=("$show")
        prev="$tok"
    done
    printf -v rendered '%q ' "${parts[@]}"
    log_debug "$label: $rendered"
    return 0
}
