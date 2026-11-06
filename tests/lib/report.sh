#!/bin/bash
# Shared pass/fail reporting for the shell test suites. Sourced, not run.
#
#   ok ID TEXT       record a passing assertion and print its line
#   bad ID TEXT      record a failing assertion and print its line
#   report_summary   print the expected and the tested result side by
#                    side; returns 0 exactly when they match
#   check_warnings   assert that a captured stderr log holds exactly the
#                    expected warnings (see below)
#   expect_failures  announce, before a run, the assertions EXPECTED_FAIL
#                    says must fail (see below)
#
# ok()/bad() are plain printf+counter calls that cannot themselves fail,
# which is what lets every suite use `cmd && ok ... || bad ...` without
# SC2015's "C also runs if A succeeds but B fails" hazard.
#
# EXPECTED_FAIL: the assertion IDs this run is expected to fail, a shell
# array. Empty -- every normal run -- means every assertion is expected to
# pass. A negative control sets the exact list, so the run is judged on
# WHICH assertions failed, not on whether any did: an assertion that stops
# failing without a mask, or one that starts failing for an unrelated
# reason, is a mismatch either way. An array, not an environment
# variable, so no stray variable can turn a suite's failures into
# expected ones; only probe.sh sets it, from what run.sh --negative passes.

PASS=0 FAIL=0
PASSED_IDS=() FAILED_IDS=() EXPECTED_FAIL=()
ok()  { printf 'ok   %-6s %s\n' "$1" "$2"; PASS=$((PASS+1)); PASSED_IDS+=("$1"); }
bad() { printf 'FAIL %-6s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_IDS+=("$1"); }

# _report_line LABEL PASSED FAILED ID...: one "N passed, M failed" line,
# with the failing IDs appended when there are any.
_report_line() {
    local label="$1" passed="$2" failed="$3"
    shift 3
    if [[ $# -gt 0 ]]; then
        printf '%-9s %d passed, %d failed: %s\n' "$label" "$passed" "$failed" "$*"
    else
        printf '%-9s %d passed, %d failed\n' "$label" "$passed" "$failed"
    fi
}

report_summary() {
    local id total=$((PASS + FAIL)) rc=0
    local -a unexpected=() passed_instead=() not_run=()
    local -A is_expected=() is_failed=() is_passed=()
    for id in "${EXPECTED_FAIL[@]}"; do is_expected[$id]=1; done
    for id in "${PASSED_IDS[@]}"; do is_passed[$id]=1; done
    for id in "${FAILED_IDS[@]}"; do
        is_failed[$id]=1
        [[ -n "${is_expected[$id]+x}" ]] || unexpected+=("$id")
    done
    for id in "${EXPECTED_FAIL[@]}"; do
        if [[ -n "${is_failed[$id]+x}" ]]; then
            :
        elif [[ -n "${is_passed[$id]+x}" ]]; then
            passed_instead+=("$id")
        else
            not_run+=("$id")
        fi
    done

    echo
    _report_line expected: "$((total - ${#EXPECTED_FAIL[@]}))" "${#EXPECTED_FAIL[@]}" "${EXPECTED_FAIL[@]}"
    _report_line tested: "$PASS" "$FAIL" "${FAILED_IDS[@]}"
    if [[ ${#unexpected[@]} -gt 0 ]]; then
        echo "MISMATCH: failed, expected to pass: ${unexpected[*]}"
        rc=1
    fi
    if [[ ${#passed_instead[@]} -gt 0 ]]; then
        echo "MISMATCH: passed, expected to fail: ${passed_instead[*]}"
        rc=1
    fi
    if [[ ${#not_run[@]} -gt 0 ]]; then
        echo "MISMATCH: expected to fail, never ran: ${not_run[*]}"
        rc=1
    fi
    return "$rc"
}

# warning_lines LOG: the warnings in a captured stderr log, one per line.
# Two sources, which between them cover every warning path sandbox.sh
# has:
#   - a line starting "warning:"/"WARNING:"/"error:"/"ERROR:" -- git,
#     apptainer, and sandbox.sh's own direct prints (functions/binds.sh);
#     only that first line, not an indented continuation;
#   - each entry of the warning gate's re-printed list after "sandbox:
#     this run produced N warning line(s):" (confirm_warnings,
#     functions/log.sh), which is every log_warn of the run. The first
#     print of a log_warn is not matched, so each counts once.
warning_lines() {
    awk '
        /^(warning|WARNING|error|ERROR):/ { print; next }
        /^sandbox: this run produced [0-9]+ warning line\(s\):$/ { gate = 1; next }
        gate && /^    / { sub(/^    /, ""); print; next }
        { gate = 0 }
    ' "$1"
}

# check_warnings ID LOG REQUIRED_ERE... [-- OPTIONAL_ERE...]: one assertion
# that LOG's warnings (warning_lines) are exactly the expected ones. Each
# REQUIRED_ERE must match exactly one warning; an OPTIONAL_ERE may match
# any number, for warnings caused by state outside the test (a run directory
# an earlier, killed run left behind). Any warning neither matches is a
# failure, so a new warning breaks the suite instead of scrolling past.
# On failure the mismatches are printed as indented detail lines, then
# the whole log, since the warnings only make sense in context.
check_warnings() {
    local id="$1" log="$2" w re i matched
    shift 2
    local -a required=() optional=() warnings=() problems=() hits=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do required+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    optional=("$@")
    mapfile -t warnings < <(warning_lines "$log")
    for i in "${!required[@]}"; do hits[i]=0; done
    for w in ${warnings[@]+"${warnings[@]}"}; do
        matched=0
        for i in "${!required[@]}"; do
            if [[ "$w" =~ ${required[i]} ]]; then hits[i]=$((hits[i] + 1)); matched=1; break; fi
        done
        if [[ "$matched" -eq 0 ]]; then
            for re in ${optional[@]+"${optional[@]}"}; do
                if [[ "$w" =~ $re ]]; then matched=1; break; fi
            done
        fi
        [[ "$matched" -eq 1 ]] || problems+=("unexpected: $w")
    done
    for i in "${!required[@]}"; do
        [[ "${hits[i]}" -eq 1 ]] || problems+=("expected once, seen ${hits[i]}x: ${required[i]}")
    done
    if [[ ${#problems[@]} -eq 0 ]]; then
        ok "$id" "exactly the expected warnings (${#warnings[@]}: ${#required[@]} required, $((${#warnings[@]} - ${#required[@]})) optional)"
        return 0
    fi
    bad "$id" "the warnings differ from the expected ones"
    printf '  ..%s\n' "${problems[@]}"
    echo "  ..captured stderr:"
    sed 's/^/  | /' "$log"
    return 1
}

# expect_failures: print, before the assertions run, the FAIL lines a
# negative control prints on purpose, one per EXPECTED_FAIL ID. Prints
# nothing when EXPECTED_FAIL is empty, so a normal run stays quiet and a
# FAIL there is never pre-announced. The list is also enforced:
# report_summary compares the IDs that actually failed against it.
expect_failures() {
    [[ ${#EXPECTED_FAIL[@]} -gt 0 ]] || return 0
    echo "The following test expects ${#EXPECTED_FAIL[@]} FAILURE(S):"
    echo "=== STDOUT ==="
    printf 'FAIL %s ...\n' "${EXPECTED_FAIL[@]}"
    echo "=== (indented lines after a FAIL are its details) ==="
}
