#!/bin/bash
# Host driver for the git-escape regression suite.
#
#   ./tests/git-escape/run.sh            # assert the mask holds
#   ./tests/git-escape/run.sh --negative # assert the suite can fail
#
# Runs against a throwaway repository, never the caller's checkout: the
# probe writes ESCAPE_PROBE markers into every .git it finds, and if the
# mask ever regresses those writes land for real.
#
# --negative is the meta-test. It runs the same probe on the host, where
# no mask exists, and requires it to FAIL. A suite that cannot fail proves
# nothing, and two assertions in the first draft passed in both worlds
# because they watched refs the fixture never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NEGATIVE=0
[[ "${1:-}" == "--negative" ]] && NEGATIVE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-escape.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Throwaway repository under test. `origin` is set here, on the host,
# because .git is read-only by the time the probe runs -- the probe cannot
# add a remote, it can only use -c overrides.
FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE"
git init --quiet "$FIXTURE"
# Inherit this repo's environment so the probe reuses an already-built
# image instead of triggering a fresh build for a default ENV_TAG.
[[ -f "$REPO_ROOT/sandbox.yml" ]] && cp "$REPO_ROOT/sandbox.yml" "$FIXTURE/sandbox.yml"
printf 'probe fixture\n' > "$FIXTURE/README"
git -C "$FIXTURE" add README
git -C "$FIXTURE" \
    -c user.name=probe -c user.email=probe@invalid \
    commit --quiet -m "fixture base"

if [[ "$NEGATIVE" -eq 1 ]]; then
    echo "=== negative control: probe on the host, no mask, failures expected"
    set +e
    SCRATCH="$WORK/scratch" "$SCRIPT_DIR/probe.sh" "$FIXTURE"
    rc=$?
    set -e
    if [[ $rc -eq 1 ]]; then
        echo "PASS: the suite fails when the mask is absent (exit $rc)"
        exit 0
    fi
    echo "BROKEN: expected exit 1 (assertions failed), got $rc" >&2
    [[ $rc -eq 0 ]] && echo "  every assertion passed without a mask -- they assert nothing" >&2
    [[ $rc -eq 99 ]] && echo "  the suite could not run; fix the preflight failure above" >&2
    exit 1
fi

echo "=== git-escape suite, project dir $FIXTURE"
"$REPO_ROOT/sandbox.sh" script --project-dir "$FIXTURE" "$SCRIPT_DIR/probe.sh" "$FIXTURE"
