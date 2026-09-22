#!/bin/bash
# Verbosity helpers. VERBOSE is set by parse_argv: 0 = quiet (only the
# existing warnings/notes), 1 = -v, 2 = -vv. Everything goes to stderr
# so stdout stays the agent's.
VERBOSE=0
log_info()  { [[ "$VERBOSE" -ge 1 ]] && printf '%s\n' "sandbox: $*" >&2; return 0; }
log_debug() { [[ "$VERBOSE" -ge 2 ]] && printf '%s\n' "sandbox[debug]: $*" >&2; return 0; }

# SANDBOX_WARNINGS: every warning this run emitted, in order. Retained as
# well as printed, because the gate below re-prints them: by the time the
# agent starts, a full-screen TUI has taken the terminal and repainted
# over everything above it, so a warning that was only printed when it
# happened is a warning nobody read.
SANDBOX_WARNINGS=()

# log_warn MESSAGE...: the single warning channel. Every host-side
# condition that is worth interrupting a human for goes through here --
# not through a bare `echo ... >&2` -- so that "did this run warn about
# anything?" has one answer instead of being scattered across a dozen
# files. Fatal errors do not belong here: they exit, and an exit needs no
# gate.
#
# Each argument is one line, printed with the same "sandbox: " prefix the
# rest of this file uses for the first line and indented for the rest.
log_warn() {
    local first="${1:-}" rest
    shift || true
    printf '%s\n' "sandbox: $first" >&2
    SANDBOX_WARNINGS+=("$first")
    for rest in "$@"; do
        printf '  %s\n' "$rest" >&2
        SANDBOX_WARNINGS+=("  $rest")
    done
    return 0
}

# confirm_warnings: the gate. Called once, immediately before the first
# container starts, after every check that can warn has run.
#
# Silent when the run produced no warnings -- the common path is
# unchanged. Otherwise it re-prints what was warned about and waits, so
# the human reads it while the terminal still belongs to them rather than
# after a TUI has scrolled it away.
#
# With a TTY: any interaction continues. No specific key, because the
# point is that a human is present and has looked, not that they typed
# the right letter.
#
# With no TTY (CI, </dev/null, a script harness): there is nobody to
# confirm, so the run REFUSES unless --ignore-warnings was passed. That
# matches --allow-external-binds/--allow-external-gitdir: intent is stated
# on the command line, never inferred from the environment.
confirm_warnings() {
    local line reply
    [[ ${#SANDBOX_WARNINGS[@]} -gt 0 ]] || return 0
    {
        echo
        echo "sandbox: this run produced ${#SANDBOX_WARNINGS[@]} warning line(s):"
        for line in "${SANDBOX_WARNINGS[@]}"; do
            printf '    %s\n' "$line"
        done
        echo
    } >&2
    if [[ -r /dev/tty ]] && printf '%s' \
        "sandbox: waiting for user to confirm they read the warnings above (continue with any input) ... " \
        2>/dev/null >/dev/tty; then
        # The value is deliberately discarded: any interaction continues.
        # shellcheck disable=SC2034  # read purely to block until the human responds
        read -r reply </dev/tty 2>/dev/null || true
        printf '\n' 2>/dev/null >/dev/tty
        return 0
    fi
    if [[ "${IGNORE_WARNINGS:-0}" -eq 1 ]]; then
        printf '%s\n' "sandbox: no terminal to confirm on; --ignore-warnings was passed, continuing." >&2
        return 0
    fi
    {
        echo "sandbox: refusing to start -- this run warned about the above and there is"
        echo "         no terminal to confirm on. Re-run with --ignore-warnings to proceed"
        echo "         anyway, having read them."
    } >&2
    exit 1
}

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
