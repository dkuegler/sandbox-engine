#!/bin/bash
# Shared pass/fail reporting for the shell test suites. Sourced, not run.
#
#   ok ID TEXT       record a passing assertion and print its line
#   bad ID TEXT      record a failing assertion and print its line
#   report_summary   print the expected and the tested result side by
#                    side; returns 0 exactly when they match
#   expect_warnings  announce, before a run, the warnings it will print
#                    on purpose (see below)
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

# expect_warnings LINE... [-- MAYBE_LINE...]: print, before the run, the
# warning lines it will print on purpose, so a reader of the log can tell
# an intended warning from a regression without reading the script. Each
# LINE is one warning, shown as it appears with its variable parts
# (temporary paths, pids, counts) as <placeholders>; the count is the
# number of LINEs. Lines after "--" depend on state outside the test (a
# leftover from an earlier run) and may or may not appear. This only
# documents: nothing checks the actual output against it, so the
# assertions alone still decide pass or fail.
expect_warnings() {
    local -a always=() maybe=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do always+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    maybe=("$@")
    echo "The following test expects ${#always[@]} WARNING(S):"
    echo "=== STDERR ==="
    [[ ${#always[@]} -gt 0 ]] && printf '%s\n' "${always[@]}"
    if [[ ${#maybe[@]} -gt 0 ]]; then
        echo "=== and possibly (depends on state outside this test) ==="
        printf '%s\n' "${maybe[@]}"
    fi
    echo "==="
}

# expect_failures: print, before the assertions run, the FAIL lines a
# negative control prints on purpose, one per EXPECTED_FAIL ID. Prints
# nothing when EXPECTED_FAIL is empty, so a normal run stays quiet and a
# FAIL there is never pre-announced. Unlike expect_warnings this is also
# checked: report_summary compares the IDs that actually failed against
# the same list.
expect_failures() {
    [[ ${#EXPECTED_FAIL[@]} -gt 0 ]] || return 0
    echo "The following test expects ${#EXPECTED_FAIL[@]} FAILURE(S):"
    echo "=== STDOUT ==="
    printf 'FAIL %s ...\n' "${EXPECTED_FAIL[@]}"
    echo "=== (indented lines after a FAIL are its details) ==="
}
