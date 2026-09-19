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
# shellcheck source=tests/git-escape/fixtures.sh
source "$SCRIPT_DIR/fixtures.sh"
NEGATIVE=0
[[ "${1:-}" == "--negative" ]] && NEGATIVE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-escape.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

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
# Project-level credentialed origin -- the A7-A9 sanitizer-coverage
# assertions in probe.sh check that this never reaches the agent, same as
# the already-covered A1-A6 kernel-refusal assertions check writes never
# do. Distinct from A3/A4's own "probe" remote (a transient -c override,
# never persisted to config) so neither interferes with the other.
git -C "$FIXTURE" remote add origin "https://$SECRET_PROJECT/proj.git"

# Submodule, with its own distinct credentialed origin -- proves the
# sanitizer is not accidentally scoped to the project's top-level .git
# only. The bare source must have a real commit before `submodule add`
# clones it, or git reports "cloned an empty repository" and leaves no
# gitdir for the submodule to have its own config in.
git init --quiet --bare "$WORK/subsrc.git"
git clone --quiet "$WORK/subsrc.git" "$WORK/subtmp"
echo x > "$WORK/subtmp/x"
git -C "$WORK/subtmp" -c user.name=probe -c user.email=probe@invalid add x
git -C "$WORK/subtmp" -c user.name=probe -c user.email=probe@invalid commit --quiet -m subinit
git -C "$WORK/subtmp" push --quiet origin HEAD:master
rm -rf "$WORK/subtmp"
git -C "$FIXTURE" -c protocol.file.allow=always submodule add --quiet "$WORK/subsrc.git" sub
git -C "$FIXTURE" add sub .gitmodules
git -C "$FIXTURE" -c user.name=probe -c user.email=probe@invalid commit --quiet -m "add submodule"
git -C "$FIXTURE/sub" remote set-url origin "https://$SECRET_SUBMODULE/sub.git"

# Worktree, checked out OUTSIDE the project tree -- the layout --worktree
# mode uses (worktrees live under $HOME/.agent/worktrees/..., never under
# the project dir). It carries two distinct jobs in this suite:
#
#   - its own credentialed config.worktree, which exposed a real gap: a
#     worktree's config.worktree previously rode along unsanitized on its
#     parent .git's blanket read-only mount whenever the worktree's own
#     checkout wasn't independently discoverable (fixed in
#     sanitize_gitdir_metadata(), functions/git-mask.sh);
#   - and, bound READ-WRITE below, it is the --worktree writable checkout
#     A10/A11 assert cannot reach the main repository's history. That bind
#     is what makes it a real test of worktree mode rather than of a
#     read-only bystander: the worktree's files must be writable while its
#     .git pointer file, its metadata dir, and the main .git must not be.
git -C "$FIXTURE" worktree add --quiet -b agentwt "$WORK/wt"
git -C "$WORK/wt" config extensions.worktreeConfig true
git -C "$WORK/wt" config --worktree remote.fork.url \
    "https://$SECRET_WORKTREE/fork.git"

# A second repository standing in for a read-write extra bind
# (sandbox.yml binds:/--bind) -- proves the sanitizer covers every
# read-write extra bind mask_git_readonly() walks, not just the project
# dir. Only exercised in plain mode, where sandbox.sh can actually mount
# it; --negative runs probe.sh directly on the host with no apptainer
# involved at all, so its own filesystem access needs no bind.
EXTRA="$WORK/extra"
mkdir -p "$EXTRA"
git init --quiet "$EXTRA"
printf 'extra fixture\n' > "$EXTRA/e"
git -C "$EXTRA" add e
git -C "$EXTRA" -c user.name=probe -c user.email=probe@invalid commit --quiet -m einit
git -C "$EXTRA" remote add origin "https://$SECRET_EXTRA/extra.git"

if [[ "$NEGATIVE" -eq 1 ]]; then
    echo "=== negative control: probe on the host, no mask, failures expected"
    set +e
    SCRATCH="$WORK/scratch" "$SCRIPT_DIR/probe.sh" "$FIXTURE" "$EXTRA" "$WORK/wt"
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
"$REPO_ROOT/sandbox.sh" --bind "$EXTRA:rw" --bind "$WORK/wt:rw" script \
    --project-dir "$FIXTURE" "$SCRIPT_DIR/probe.sh" "$FIXTURE" "$EXTRA" "$WORK/wt"
