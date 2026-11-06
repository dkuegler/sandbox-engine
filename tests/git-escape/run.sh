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
# shellcheck source=tests/lib/report.sh
source "$SCRIPT_DIR/../lib/report.sh"

# Warnings this script prints on purpose:
#   - git, while building the fixture: the bare submodule source is still
#     empty when it is cloned (it is filled through that clone, below).
#   - sandbox.sh (plain mode only), once per bind outside the project dir:
#     both are requested on purpose, see the --allow-external-binds note
#     at the launch below.
#   - sandbox.sh, only when an earlier sandbox run died before cleaning up:
#     it reaps that run's directory, and the warning gate then reports the
#     count and continues because of --ignore-warnings (functions/run-dir.sh,
#     functions/log.sh).
EMPTY_CLONE_WARNING="warning: You appear to have cloned an empty repository."
if [[ "$NEGATIVE" -eq 1 ]]; then
    expect_warnings "$EMPTY_CLONE_WARNING"
else
    expect_warnings "$EMPTY_CLONE_WARNING" \
        "warning: bind (--bind) '<work>/extra' is outside the project dir <work>/repo
  (allowed by --allow-external-binds, mounted read-write)" \
        "warning: bind (--bind) '<work>/wt' is outside the project dir <work>/repo
  (allowed by --allow-external-binds, mounted read-write)" \
        -- \
        "sandbox: reaping orphaned run directory: <run-dir> (owner pid <pid> is gone)
sandbox: this run produced <n> warning line(s):
    reaping orphaned run directory: <run-dir> (owner pid <pid> is gone)
sandbox: no terminal to confirm on; --ignore-warnings was passed, continuing."
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-escape.XXXXXX")"
# shellcheck disable=SC2317  # invoked by the EXIT trap below
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
# image instead of triggering a fresh build for a default ENV_TAG. It is
# COMMITTED in the fixture, not just copied in: sandbox.yml configures the
# run before any container exists, so an uncommitted one is refused
# outright (functions/project-sandbox-config.sh) and the suite would never
# launch.
if [[ -f "$REPO_ROOT/sandbox.yml" ]]; then
    cp "$REPO_ROOT/sandbox.yml" "$FIXTURE/sandbox.yml"
    git -C "$FIXTURE" add sandbox.yml
fi
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
    # Exactly what a host with no mask must fail: every mask assertion.
    # The rest hold either way and are not mask assertions: A5 (the
    # probe acquires its own git), FIX (the fixture check), A3a/A3b (push
    # succeeds and its objects land on the remote) and A10a (the worktree
    # checkout is writable). probe.sh compares this list with what
    # actually failed and exits 0 only when the two are identical, so an
    # assertion that stops being able to fail is caught by name.
    NEGATIVE_EXPECT_FAIL="A1 A2a A2b A2c A3c A3d A4a A4b A4c A4d A6 A7 A8 A9"
    NEGATIVE_EXPECT_FAIL+=" A10b A10c A11a A11b A11c A11d A11e"
    # A9 fails only when a ~/.gitconfig or ~/.git-credentials is
    # reachable. On the host that would depend on the caller's own home
    # directory, so the probe gets a throwaway HOME that has both.
    NEG_HOME="$WORK/home"
    mkdir -p "$NEG_HOME"
    : > "$NEG_HOME/.gitconfig"
    : > "$NEG_HOME/.git-credentials"
    echo "=== negative control: probe on the host, no mask, failures expected"
    set +e
    HOME="$NEG_HOME" EXPECT_FAIL="$NEGATIVE_EXPECT_FAIL" SCRATCH="$WORK/scratch" \
        "$SCRIPT_DIR/probe.sh" "$FIXTURE" "$EXTRA" "$WORK/wt"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        echo "PASS: without the mask, exactly the expected assertions fail"
        exit 0
    fi
    echo "BROKEN: probe exit $rc" >&2
    [[ $rc -eq 1 ]] && echo "  the failures differ from the expected list; see MISMATCH above" >&2
    [[ $rc -eq 99 ]] && echo "  the suite could not run; fix the preflight failure above" >&2
    exit 1
fi

echo "=== git-escape suite, project dir $FIXTURE"
# --ignore-warnings and --allow-external-binds are both deliberate, not
# incidental: this harness drives sandbox.sh unattended, and each gate
# would otherwise stop to ask a question nothing here can answer.
# --allow-external-binds clears bind_scope_check's prompt for $EXTRA and
# $WORK/wt (both deliberately outside $FIXTURE, functions/binds.sh) and
# keeps both binds read-write as requested (":rw"), not downgraded to
# read-only the way an interactive "r" reply would -- part of what this
# suite proves is that the `.git` mask holds even under a read-write
# extra bind, so downgrading it would weaken that assertion.
#
# --ignore-warnings only covers a run with no terminal to confirm on
# (confirm_warnings, functions/log.sh): with one attached, the warning
# gate still waits for a human, by design. So sandbox.sh runs in a new
# session (setsid) with no controlling terminal, where opening /dev/tty
# fails and every /dev/tty prompt takes its documented unattended path --
# the same whether this suite runs in CI or from a human's terminal. The
# warning text and the external-bind notice still print to stderr; the
# assertions decide pass or fail.
#
# A new session is also outside the terminal's foreground process group,
# so Ctrl-C no longer reaches sandbox.sh on its own. Run in the
# background of this non-interactive script, setsid is not a process
# group leader and so execs in place: $! is sandbox.sh and its process
# group id. The trap forwards Ctrl-C, TERM and a closed terminal to that
# whole group as SIGTERM -- not SIGINT, which bash sets to ignored in a
# background job and its children, so a forwarded INT would be dropped.
# SIGTERM still runs sandbox.sh's EXIT trap, so it cleans up as it would
# for an interactive Ctrl-C.
setsid -w "$REPO_ROOT/sandbox.sh" --bind "$EXTRA:rw" --bind "$WORK/wt:rw" \
    --ignore-warnings --allow-external-binds script \
    --project-dir "$FIXTURE" "$SCRIPT_DIR/probe.sh" "$FIXTURE" "$EXTRA" "$WORK/wt" \
    </dev/null &
sandbox_pid=$!
trap 'kill -TERM -- "-$sandbox_pid" 2>/dev/null || true' INT TERM HUP
rc=0
# `wait` returns early (>128) when a trapped signal arrives; keep waiting
# until sandbox.sh itself has exited so cleanup runs after it, not under it.
while :; do
    wait "$sandbox_pid" && rc=0 || rc=$?
    kill -0 "$sandbox_pid" 2>/dev/null || break
done
trap - INT TERM HUP
exit "$rc"
