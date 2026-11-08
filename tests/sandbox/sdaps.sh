#!/bin/bash
# The sdaps preset image (sandbox/sdaps/Dockerfile), checked in a live
# container as the session's own user.
#
#   ./tests/sandbox/sdaps.sh            # build the image if missing, check it
#   ./tests/sandbox/sdaps.sh --rebuild  # rebuild it first
#
# --rebuild is how an edit to sandbox/sdaps/Dockerfile reaches the check: a
# preset's image tag is its name (functions/environment.sh), so an existing
# image is reused however its Dockerfile has changed since.
#
# The image build already runs SDAPS's own end-to-end test, as root, on a
# writable filesystem. This checks what that cannot: the image as a session
# sees it, read-only, run by an unprivileged user with the template's
# environment and the sandbox's mounts. One questionnaire with code128
# questionnaire IDs goes through the whole workflow, every optional
# dependency on the path: setup tex (pdflatex, TeX Live's sdaps class),
# stamp, add --convert (Poppler through PyGObject, OpenCV), recognize (the C
# extension, zbarimg), CSV and feather export (pandas, pyarrow), both
# reports (reportlab, pdflatex) and annotate (Poppler, Pango).
#
# Two halves in one file. On the host it makes a throwaway project and runs
# itself with --probe through `sandbox.sh script` (functions/agents.sh binds
# tests/ read-only at the same path), the launch path an agent gets. A first
# launch only builds the image, its output shown, so the build's own
# warnings are not mistaken for the checked run's. Then, as in
# tests/git-escape/run.sh, the checked run's stderr is captured and must
# hold no warning (WARN). --probe holds the assertions; run by hand, it
# checks whatever sdaps is on PATH.
#
# Exit: 0 all passed, 1 an assertion failed, 99 the suite could not run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/report.sh
source "$SCRIPT_DIR/../lib/report.sh"

SDAPS_PYTHON=/opt/sdaps/bin/python

# --- container half --------------------------------------------------------

# The questionnaire: upstream's test document class options
# (test/data/tex/questionnaire_with_ids.tex in the SDAPS tarball), with one
# question of each kind recognize evaluates.
write_questionnaire() {
    cat >"$1" <<'EOF'
\documentclass[pdf, print_questionnaire_id, sdaps_style=code128, globalid=SDAPS, english, stamp, pagemark]{sdapsclassic}
\usepackage[utf8]{inputenc}
\usepackage{babel}
\author{sandbox-engine}
\title{sdaps image check}
\begin{document}
  \begin{questionnaire}
    \section{Questions}
    \singlemark{How well does the image work?}{well}{badly}
    \begin{choicequestion}[cols=3]{Pick any}
      \choiceitem{one}
      \choiceitem{two}
      \choiceitem{three}
    \end{choicequestion}
    \textbox{2cm}{Comments}
  \end{questionnaire}
\end{document}
EOF
}

# step chain|leaf ID TEXT CMD...: one workflow assertion. CMD's output goes
# to $LOG and is shown under a FAIL. A failed chain step leaves no project
# state for the steps after it, so they are reported as not run instead of
# failing on its leftovers; a leaf builds on the chain and nothing builds on
# it.
BROKEN=""
step() {
    local kind="$1" id="$2" text="$3"
    shift 3
    if [[ -n "$BROKEN" ]]; then
        bad "$id" "not run, $BROKEN failed: $text"
        return 1
    fi
    if "$@" >"$LOG" 2>&1; then
        ok "$id" "$text"
        return 0
    fi
    bad "$id" "$text"
    sed 's/^/  | /' "$LOG"
    [[ "$kind" == chain ]] && BROKEN="$id"
    return 1
}

# has_file PATH: PATH is a non-empty file, said in the step's log if not.
# shellcheck disable=SC2317  # called from the e_* steps, which step() runs indirectly
has_file() {
    [[ -s "$1" ]] && return 0
    echo "missing or empty: $1"
    return 1
}

# The workflow's steps, each a command plus a check of what it produced,
# run by step() through "$@" (hence the SC2317 directives).
# setup tex compiles in batchmode, so a LaTeX error is in its log only.
# shellcheck disable=SC2317
e_setup() {
    sdaps setup tex "$P" "$WORK/questionnaire.tex" && has_file "$P/questionnaire.pdf" && return 0
    [[ -f "$P/questionnaire.log" ]] && tail -n 40 "$P/questionnaire.log"
    return 1
}
# shellcheck disable=SC2317
e_stamp() {
    printf 'Hello\n12345\n' >"$WORK/ids"
    sdaps stamp "$P" -f "$WORK/ids" -o "$P/stamped.pdf" && has_file "$P/stamped.pdf"
}
# The recognized questionnaire IDs, read back from the barcodes on the
# converted scan, are the ones stamped: not merely that recognize exited 0.
# shellcheck disable=SC2317
e_csv() {
    local got
    sdaps export csv "$P" -o "$P/data.csv" || return 1
    got="$(tail -n +2 "$P/data.csv" | cut -d, -f1 | LC_ALL=C sort | tr '\n' ' ')"
    [[ "$got" == "12345 Hello " ]] && return 0
    echo "questionnaire_id column: want '12345 Hello ', got '$got'"
    return 1
}
# shellcheck disable=SC2317
e_feather() {
    local rows
    sdaps export feather "$P" -o "$P/data.feather" || return 1
    rows="$("$SDAPS_PYTHON" -c 'import sys, pandas; print(len(pandas.read_feather(sys.argv[1])))' "$P/data.feather")" || return 1
    [[ "$rows" == 2 ]] && return 0
    echo "feather rows: want 2, got '$rows'"
    return 1
}
# shellcheck disable=SC2317
e_report_reportlab() {
    sdaps report reportlab "$P" -o "$P/report-reportlab.pdf" && has_file "$P/report-reportlab.pdf"
}
# shellcheck disable=SC2317
e_report_tex() {
    sdaps report tex "$P" -o "$P/report-tex.pdf" && has_file "$P/report-tex.pdf"
}
# shellcheck disable=SC2317
e_annotate() {
    sdaps annotate "$P" && has_file "$P/annotated_questionnaire.pdf"
}

probe() {
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/sdaps-probe.XXXXXX")" || { echo "PREFLIGHT: mktemp failed" >&2; exit 99; }
    # shellcheck disable=SC2317  # invoked by the EXIT trap below
    cleanup() { rm -rf "$WORK"; }
    trap cleanup EXIT
    LOG="$WORK/step.log"
    P="$WORK/project"
    echo "=== sdaps image check, $(id -un) in $(cat /etc/sandbox-engine-build-id 2>/dev/null || echo 'no sandbox image')"

    # V1: the interpreter docs/usage.md names for scripts importing sdaps.
    local version
    if version="$("$SDAPS_PYTHON" -c 'import sdaps; print(sdaps.__version__)' 2>"$LOG")"; then
        ok V1 "$SDAPS_PYTHON imports sdaps $version"
    else
        bad V1 "$SDAPS_PYTHON cannot import sdaps"
        sed 's/^/  | /' "$LOG"
    fi

    # V2: the image is read-only at run time, so a module without bytecode
    # is recompiled on every start, printing its SyntaxWarnings each time.
    if "$SDAPS_PYTHON" - >"$LOG" 2>&1 <<'EOF'
import importlib.util, pathlib, sdaps, sys
root = pathlib.Path(sdaps.__file__).parent
missing = [str(p) for p in sorted(root.rglob("*.py"))
           if not pathlib.Path(importlib.util.cache_from_source(str(p))).is_file()]
print("\n".join(missing))
sys.exit(1 if missing else 0)
EOF
    then
        ok V2 "every sdaps module has precompiled bytecode"
    else
        bad V2 "sdaps modules without precompiled bytecode (or the check could not run):"
        sed 's/^/  | /' "$LOG"
    fi

    # U1: the image's uv-managed CPython serves the sdaps venv only. uv's
    # own managed-Python directory stays a writable one, so a project can
    # still install the interpreter it asks for (docs/usage.md).
    local uvdir
    if uvdir="$(uv python dir 2>"$LOG")" && mkdir -p "$uvdir" 2>>"$LOG" && [[ -w "$uvdir" ]]; then
        ok U1 "uv's managed-Python directory is writable: $uvdir"
    else
        bad U1 "uv's managed-Python directory is not writable: ${uvdir:-unknown}"
        sed 's/^/  | /' "$LOG"
    fi

    write_questionnaire "$WORK/questionnaire.tex"
    step chain E1 "setup tex compiles the questionnaire" e_setup
    step chain E2 "stamp prints two questionnaires with code128 IDs" e_stamp
    step chain E3 "add --convert imports the stamped PDF as a scan" \
        sdaps add "$P" --convert "$P/stamped.pdf"
    step chain E4 "recognize evaluates the scan" sdaps recognize "$P"
    step leaf E5 "export csv: the recognized IDs are the stamped ones" e_csv
    step leaf E6 "export feather writes data pandas reads back" e_feather
    step leaf E7 "report reportlab writes a PDF" e_report_reportlab
    step leaf E8 "report tex writes a PDF" e_report_tex
    step leaf E9 "annotate overlays the recognized positions on the questionnaire" e_annotate

    report_summary
}

# --- host half -------------------------------------------------------------

# launch ARG...: ./sandbox.sh ARG... with no controlling terminal, so no
# /dev/tty prompt can block it; Ctrl-C, TERM and a closed terminal are
# forwarded to its process group (tests/git-escape/run.sh explains both).
# Sets rc to its exit status.
launch() {
    local pid
    setsid -w "$REPO_ROOT/sandbox.sh" "$@" </dev/null &
    pid=$!
    # shellcheck disable=SC2064  # $pid is meant to expand now
    trap "kill -TERM -- -$pid 2>/dev/null || true" INT TERM HUP
    while :; do
        wait "$pid" && rc=0 || rc=$?
        kill -0 "$pid" 2>/dev/null || break
    done
    trap - INT TERM HUP
}

host() {
    local rebuild=()
    case "${1:-}" in
        "") ;;
        --rebuild) rebuild=(--rebuild) ;;
        *) echo "usage: $0 [--rebuild]" >&2; exit 99 ;;
    esac
    command -v apptainer >/dev/null 2>&1 || { echo "PREFLIGHT: no apptainer binary" >&2; exit 99; }
    command -v setsid >/dev/null 2>&1 || { echo "PREFLIGHT: no setsid binary" >&2; exit 99; }

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/sdaps-image.XXXXXX")" || { echo "PREFLIGHT: mktemp failed" >&2; exit 99; }
    # shellcheck disable=SC2317  # invoked by the EXIT trap below
    cleanup() { rm -rf "$WORK"; }
    trap cleanup EXIT

    # The project the session runs in. A committed README only: the probe
    # works under /tmp, and the environment comes from --environment.
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    local fixture="$WORK/project"
    mkdir -p "$fixture"
    { git init --quiet "$fixture" \
        && printf 'sdaps image fixture\n' >"$fixture/README" \
        && git -C "$fixture" add README \
        && git -C "$fixture" -c user.name=probe -c user.email=probe@invalid \
            commit --quiet -m "fixture base"; } \
        || { echo "PREFLIGHT: could not create the fixture project" >&2; exit 99; }

    # --no-update-check: whether omp, the image's agent in script mode, is
    # current is not this suite's question, and its notice would only add
    # noise.
    local -a common=(--environment preset=sdaps --no-update-check --ignore-warnings)

    echo "=== sdaps image: building it if missing${rebuild[*]:+ (rebuild requested)}"
    launch "${common[@]}" ${rebuild[@]+"${rebuild[@]}"} script --project-dir "$fixture" true
    if [[ "$rc" -ne 0 ]]; then
        echo "PREFLIGHT: the sdaps image could not be built or started (sandbox.sh exit $rc)" >&2
        exit 99
    fi

    echo "=== sdaps image: checking it, project dir $fixture"
    local stderr_log="$WORK/sandbox.stderr"
    launch "${common[@]}" script --project-dir "$fixture" "$SCRIPT_DIR/sdaps.sh" --probe 2>"$stderr_log"
    # The only warning allowed: an earlier, killed sandbox run's directory
    # being reaped, which depends on state outside this suite.
    if check_warnings WARN "$stderr_log" \
        -- '^reaping orphaned run directory: .* \(owner pid [0-9]+ is gone\)$'; then
        if [[ "$rc" -ne 0 ]]; then
            echo "sandbox.sh exited $rc; its stderr:"
            sed 's/^/  | /' "$stderr_log"
        fi
    else
        rc=1
    fi
    exit "$rc"
}

if [[ "${1:-}" == --probe ]]; then
    probe
    exit $?
fi
host "$@"
