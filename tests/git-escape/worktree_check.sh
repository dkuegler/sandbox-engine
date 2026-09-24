#!/bin/bash
# Host-side, apptainer-free verification of --worktree mode
# (functions/worktree.sh, plus the worktree root mask_git_readonly()
# gained in functions/git-mask.sh). Companion to sanitize_check.sh, same
# standard: it calls the REAL functions against REAL git fixtures and
# inspects their real output, rather than reasoning about the code.
#
# What this proves without a container:
#   - the writable worktree does not reopen a path to rewriting the main
#     repository's history: all three gitdir paths a worktree's history is
#     reachable through end up in BINDS read-only, and the negative
#     control shows that is NOT true without the worktree root, so the
#     assertion is load-bearing rather than passing for free;
#   - the branch-collision policy resolves to resume / refuse / create as
#     specified, and the per-worktree lock refuses a second concurrent run,
#     takes over a crashed one, refuses one held from another host, and
#     releases through a registered teardown hook rather than through a
#     call wired into unrelated cleanup code;
#   - rendering a diff state writes nothing into the main repository;
#   - the host-side commit lands on agent/<branch> in the main repository;
#   - discarding never silently deletes a branch carrying real commits;
#   - the commit-message fallback is generated INSIDE the sandbox, with
#     the agent's own tools disabled and with neither the project checkout
#     nor the worktree mounted (it is fed an agent-authored diff, so both
#     are security properties, not details), and the per-agent model and
#     flag-propagation rules hold.
#
# What it cannot prove, and what needs apptainer (see run.sh/probe.sh):
# that the kernel actually refuses writes through those read-only binds
# from inside a live container.
#
# Exit: 0 all passed, 1 an assertion failed, 99 the suite could not run.
#
# `cmd && ok ... || bad ...` is used throughout, same convention as
# probe.sh/sanitize_check.sh; ok()/bad() are plain printf+counter calls
# that cannot themselves fail, so SC2015's "C also runs if A succeeds but
# B fails" hazard does not apply.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0 FAIL=0
ok()  { printf 'ok   %-6s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %-6s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
fail_setup() { echo "PREFLIGHT: $*" >&2; exit 99; }

command -v git >/dev/null 2>&1 || fail_setup "no git binary"

W="$(mktemp -d "${TMPDIR:-/tmp}/git-escape-worktree.XXXXXX")"
# shellcheck disable=SC2317  # invoked indirectly via `trap cleanup_all EXIT`, not a direct call
cleanup_all() { rm -rf "$W"; }
trap cleanup_all EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@invalid

# HOME is redirected into the fixture for the whole run: worktree paths are
# derived from it, and this suite must never touch the real
# ~/.agent/worktrees.
HOME="$W/home"
mkdir -p "$HOME" || fail_setup "mkdir fake HOME"

# --- fixtures -------------------------------------------------------------
# main: the repository under test, with a tracked file, an ignored one and
# an untracked one -- the three states the review/commit path treats
# differently.
git init -q "$W/main" || fail_setup "init main"
printf 'IGNORED\n' > "$W/main/.gitignore"
printf 'tracked\n'  > "$W/main/tracked.txt"
git -C "$W/main" add .gitignore tracked.txt
git -C "$W/main" commit -q -m base || fail_setup "commit into main"

# twin: a DIFFERENT repository with the SAME basename, in a different
# parent directory. The whole point of the path key.
mkdir -p "$W/other" || fail_setup "mkdir other"
git init -q "$W/other/main" || fail_setup "init twin"
printf 'twin\n' > "$W/other/main/f"
git -C "$W/other/main" add f
git -C "$W/other/main" commit -q -m twin || fail_setup "commit into twin"

# --- load the real implementation ----------------------------------------
# shellcheck source=functions/log.sh
source "$REPO_ROOT/functions/log.sh"
# shellcheck source=functions/apptainer.sh
source "$REPO_ROOT/functions/apptainer.sh"
# shellcheck source=functions/agents.sh
source "$REPO_ROOT/functions/agents.sh"
# shellcheck source=functions/git-mask.sh
source "$REPO_ROOT/functions/git-mask.sh"
# shellcheck source=functions/cleanup.sh
source "$REPO_ROOT/functions/cleanup.sh"
# shellcheck source=functions/worktree.sh
source "$REPO_ROOT/functions/worktree.sh"
# shellcheck source=functions/commit-message.sh
source "$REPO_ROOT/functions/commit-message.sh"
# shellcheck source=functions/binds.sh
source "$REPO_ROOT/functions/binds.sh"
# shellcheck source=functions/omp-home.sh
source "$REPO_ROOT/functions/omp-home.sh"

RUN_DIR="$W/run"
mkdir -p "$RUN_DIR" || fail_setup "mkdir RUN_DIR"
# Read by mask_git_readonly() (functions/git-mask.sh), sourced above; a use
# reached through `source` is invisible here without -x.
# shellcheck disable=SC2034
ALLOW_EXTERNAL_GITDIR=0
# shellcheck disable=SC2034  # read by log_debug (functions/log.sh)
VERBOSE=0

PROJECT_DIR="$W/main"
WORKTREE_BRANCH="demo"

# --- W1: branch-name validation ------------------------------------------
# Each case runs in a subshell: worktree_validate_branch refuses by
# exiting, which is correct for a launcher and fatal for a test harness.
#
# "-lead" is the one that matters. Measured against git 2.39.5,
# `git check-ref-format refs/heads/agent/-lead` ACCEPTS it, so relying on
# git alone would let a branch name be read as an option by the host-side
# git commands this feature runs.
w1_fail=0
for good in demo feat/x release-1.2; do
    ( worktree_validate_branch "$good" ) >/dev/null 2>&1 \
        || { w1_fail=1; echo "  ..REJECTED a valid branch name: '$good'"; }
done
for evil in "-lead" "a..b" "a b" "tilde~" "" "/lead" "trail/" "x/../../etc"; do
    ( worktree_validate_branch "$evil" ) >/dev/null 2>&1 \
        && { w1_fail=1; echo "  ..ACCEPTED an invalid branch name: '$evil'"; }
done
[[ "$w1_fail" -eq 0 ]] \
    && ok W1 "branch validation accepts valid names and refuses '-'-leading/'..'/whitespace ones" \
    || bad W1 "branch validation is wrong (see lines above)"

# --- W2: worktree path key is per-checkout, not per-basename -------------
worktree_preflight || fail_setup "worktree_preflight refused the main fixture"
MAIN_WT_DIR="$WORKTREE_DIR"
MAIN_WT_REF="$WORKTREE_REF"
(
    PROJECT_DIR="$W/other/main"
    worktree_preflight
    printf '%s\n' "$WORKTREE_DIR"
) >"$W/twin_dir" 2>/dev/null
TWIN_WT_DIR="$(cat "$W/twin_dir" 2>/dev/null)"
[[ -n "$TWIN_WT_DIR" && "$TWIN_WT_DIR" != "$MAIN_WT_DIR" ]] \
    && ok W2 "two checkouts named 'main' get distinct worktree paths" \
    || bad W2 "basename collision: both checkouts map to '$MAIN_WT_DIR'"
[[ "$MAIN_WT_REF" == "agent/demo" ]] \
    && ok W2b "branch is the flag's own argument, prefixed once: $MAIN_WT_REF" \
    || bad W2b "unexpected ref '$MAIN_WT_REF'"

# --- W3: create ----------------------------------------------------------
worktree_prepare >/dev/null 2>&1 || bad W3 "worktree_prepare failed to create the worktree"
[[ -d "$WORKTREE_DIR" ]] \
    && git -C "$W/main" show-ref --verify --quiet "refs/heads/$WORKTREE_REF" \
    && ok W3 "create: worktree and branch $WORKTREE_REF both exist" \
    || bad W3 "create left no worktree/branch"
[[ -f "$WORKTREE_DIR/tracked.txt" && ! -e "$WORKTREE_DIR/ignored" ]] \
    && ok W3b "the worktree is a checkout of HEAD (tracked content present)" \
    || bad W3b "the worktree does not look like a HEAD checkout"

# --- W4: a second concurrent run is refused while the first holds the lock
# This is the gap git's own exclusivity check does not cover: it guards
# worktree *creation*, and a resumed run creates nothing.
( worktree_lock_acquire ) >/dev/null 2>&1 \
    && bad W4 "a second run acquired the lock while this one holds it" \
    || ok W4 "a concurrent run is refused while the lock owner is alive"

# --- W4b: the lock releases through a registered teardown hook -----------
# The EXIT trap (cleanup(), functions/cleanup.sh) must not name this
# feature: taking the lock is what registers its release. Asserted on the
# registry and then on the effect, because a hook that is registered but
# never reached releases nothing.
w4b_registered=0
for w4b_hook in ${CLEANUP_HOOKS[@]+"${CLEANUP_HOOKS[@]}"}; do
    [[ "$w4b_hook" == "worktree_lock_release" ]] && w4b_registered=1
done
[[ "$w4b_registered" -eq 1 ]] \
    && ok W4b "acquiring the lock registered its own release on the EXIT trap" \
    || bad W4b "no release hook was registered: CLEANUP_HOOKS=(${CLEANUP_HOOKS[*]-})"
cleanup >/dev/null 2>&1
[[ ! -d "$WORKTREE_LOCK" ]] \
    && ok W4c "the generic EXIT trap released the lock without knowing what it is" \
    || bad W4c "cleanup() left the lock behind at $WORKTREE_LOCK"

# --- W5: a crashed run's stale lock is taken over, not treated as live ---
worktree_lock_release
mkdir -p "$WORKTREE_LOCK" 2>/dev/null
( exit 0 ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
echo "$DEAD_PID" > "$WORKTREE_LOCK/pid"
echo "${HOSTNAME:-$(uname -n)}" > "$WORKTREE_LOCK/host"
( worktree_lock_acquire ) >/dev/null 2>&1 \
    && ok W5 "a stale lock (owner pid gone) is taken over, so a crashed run can resume" \
    || bad W5 "a stale lock blocked a resume"
rm -rf "$WORKTREE_LOCK"

# --- W5b: a lock held from ANOTHER host is never taken over --------------
# $HOME can be a network mount, in which case two hosts share this lock
# path and the worktree it guards. The recorded pid is dead *here*, so a
# host-blind check would take the lock over and put two agents in one
# checkout; only the recorded host can refuse it.
WORKTREE_LOCK_HELD=0
mkdir -p "$WORKTREE_LOCK" 2>/dev/null
echo "$DEAD_PID" > "$WORKTREE_LOCK/pid"
echo "some-other-host.invalid" > "$WORKTREE_LOCK/host"
( worktree_lock_acquire ) >/dev/null 2>&1 \
    && bad W5b "a lock held by another host was taken over on a dead local pid" \
    || ok W5b "a foreign-host lock is refused even though its pid is dead here"
rm -rf "$WORKTREE_LOCK"

# --- W6: resume ----------------------------------------------------------
WORKTREE_LOCK_HELD=0
resume_out="$(worktree_prepare 2>&1)"; resume_rc=$?
[[ "$resume_rc" -eq 0 && "$resume_out" == *resuming* ]] \
    && ok W6 "resume: an existing worktree+branch pair is reattached, not recreated" \
    || bad W6 "resume failed (rc=$resume_rc): $resume_out"
worktree_lock_release

# --- W7: the security assertion ------------------------------------------
# Every path a worktree's history is reachable through must be masked
# read-only: the worktree's own "gitdir:" pointer FILE (unmasked, the agent
# could repoint it at a writable directory), the per-worktree metadata
# directory it names, and the main repository's .git itself -- which a
# linked worktree shares outright (one object store, one ref namespace).
WT_GITFILE="$WORKTREE_DIR/.git"
WT_GITDIR="$(git -C "$WORKTREE_DIR" rev-parse --absolute-git-dir 2>/dev/null)"
MAIN_GITDIR="$W/main/.git"

bind_is_ro() {
    local want="$1" tok
    for tok in ${BINDS[@]+"${BINDS[@]}"}; do
        [[ "$tok" == "$want:$want:ro" ]] && return 0
    done
    return 1
}

# shellcheck disable=SC2034  # read by mask_git_readonly() through `source`
EXTRA_BIND_SRCS=()
# shellcheck disable=SC2034  # read by mask_git_readonly() through `source`
EXTRA_BIND_RO=()
BINDS=()
mask_git_readonly >/dev/null 2>&1

w7_fail=0
for p in "$WT_GITFILE" "$WT_GITDIR" "$MAIN_GITDIR"; do
    bind_is_ro "$p" || { w7_fail=1; echo "  ..NOT masked read-only: $p"; }
done
[[ "$w7_fail" -eq 0 ]] \
    && ok W7 "worktree .git file, its metadata dir, and the main .git are all bound read-only" \
    || bad W7 "the writable worktree leaves a path to the main repository's history open"

[[ "$WT_GITDIR" == "$MAIN_GITDIR"/worktrees/* ]] \
    && ok W7b "the worktree's gitdir really is inside the main repository ($WT_GITDIR)" \
    || bad W7b "unexpected worktree gitdir layout: $WT_GITDIR"

# Negative control. Without the worktree root, the worktree's own .git is
# outside every walked tree and is NOT masked -- so W7 is testing the new
# root, not something that was true anyway. (The main .git stays masked
# either way: it is found by the project-dir walk.)
saved_wt="$WORKTREE_DIR"
WORKTREE_DIR=""
BINDS=()
mask_git_readonly >/dev/null 2>&1
bind_is_ro "$WT_GITFILE" \
    && bad W7c "negative control failed: $WT_GITFILE is masked even without the worktree root, so W7 proves nothing" \
    || ok W7c "negative control: without the worktree root that .git is unmasked, so W7 is load-bearing"
WORKTREE_DIR="$saved_wt"
BINDS=()
mask_git_readonly >/dev/null 2>&1

# --- W8: rendering a diff state writes nothing into the main repository --
# `git add -A -N` would make one `git diff HEAD` cover untracked files too,
# but measured it writes a loose object (the empty-blob placeholder) into
# the shared object store. Rendering the diff state must not touch the
# main repository at all, so it is rendered without staging anything.
printf 'edited\n' >> "$WORKTREE_DIR/tracked.txt"
printf 'brand new\n' > "$WORKTREE_DIR/added.txt"
printf 'build junk\n' > "$WORKTREE_DIR/IGNORED"
objs_before="$(find "$MAIN_GITDIR/objects" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
idx_before="$(md5sum "$WT_GITDIR/index" 2>/dev/null | cut -d' ' -f1)"
worktree_build_diff_state "$W/diff_state.txt"
objs_after="$(find "$MAIN_GITDIR/objects" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
idx_after="$(md5sum "$WT_GITDIR/index" 2>/dev/null | cut -d' ' -f1)"
[[ "$objs_before" == "$objs_after" ]] \
    && ok W8 "building the diff state wrote no object into the main repository ($objs_before)" \
    || bad W8 "the diff-state render wrote objects into the main repository ($objs_before -> $objs_after)"
[[ "$idx_before" == "$idx_after" ]] \
    && ok W8b "building the diff state left the worktree index untouched" \
    || bad W8b "the diff-state render modified the worktree index"

# The diff state still has to SHOW the untracked file, or the human approves a
# commit containing content they were never shown.
grep -q 'brand new' "$W/diff_state.txt" \
    && ok W8c "the diff state shows the content of untracked files" \
    || bad W8c "untracked file content is missing from the diff state"
grep -q 'build junk' "$W/diff_state.txt" \
    && bad W8d "the diff state shows .gitignore'd content that will not be committed" \
    || ok W8d "the diff state omits .gitignore'd content, matching what the commit will contain"

# --- W9: the agent's own message is used verbatim, fallback untouched ----
WORKTREE_MSG_HOST="$W/agent-msg"
printf 'Agent title\n\nIssue:\nx\n\nSolution:\ny\n' > "$WORKTREE_MSG_HOST"
# A generator that would be a hard failure if it ran at all.
mkdir -p "$W/bin"
printf '#!/bin/sh\necho GENERATOR-RAN\nexit 0\n' > "$W/bin/omp"
chmod +x "$W/bin/omp"
PATH="$W/bin:$PATH"
worktree_resolve_message "$W/msg.final" "$W/diff_state.txt" >/dev/null 2>&1
if grep -q 'Agent title' "$W/msg.final" && ! grep -q 'GENERATOR-RAN' "$W/msg.final"; then
    ok W9 "a non-empty agent message is used verbatim; the fallback never runs"
else
    bad W9 "agent-written message was not used verbatim"
fi

# --- W10: empty agent file -> generation INSIDE the sandbox --------------
# The diff handed to the generator is agent-authored text. Generating on
# the host would mean an agent-authored file steering an unsandboxed
# process, so what is asserted here is that the generator goes through
# apptainer at all, that it cannot see the tree the agent just wrote, and
# that it still gets the credentials it needs to answer.
: > "$WORKTREE_MSG_HOST"

# Stand-in apptainer: records the exact argv and environment it was handed,
# then answers the way a model would.
cat > "$W/bin/apptainer" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$W/appt-argv"
env > "$W/appt-env"
printf 'Generated title\n\nIssue:\ni\n'
STUB
chmod +x "$W/bin/apptainer"

SANDBOX_IMAGE="$W/agent.sif"
: > "$SANDBOX_IMAGE"
AGENT=omp
ARGS=()
COMMIT_MODEL=""
# shellcheck disable=SC2034  # read by backend_generator_argv (functions/apptainer.sh)
AGENT_CONFIG_BINDS=(-B "$HOME/.omp")
mkdir -p "$HOME/.omp/agent" "$HOME/.config/opencode"
printf 'modelRoles:\n  commit: anthropic/claude-haiku-4-5:low\n' \
    > "$HOME/.omp/agent/config.yml"
printf '{\n  "model": "anthropic/claude-sonnet-4-5",\n  "small_model": "anthropic/claude-haiku-4-5"\n}\n' \
    > "$HOME/.config/opencode/opencode.json"

# has_arg NEEDLE ARG...: exact-match membership, so a bind spec can never
# be confused with a substring of the prompt (which carries the diff).
has_arg() {
    local needle="$1" a
    shift
    for a in "$@"; do [[ "$a" == "$needle" ]] && return 0; done
    return 1
}
# has_path NEEDLE ARG...: true when any argument names NEEDLE as a path,
# bare or as part of a "src:dst[:opts]" bind spec.
has_path() {
    local needle="$1" a
    shift
    for a in "$@"; do
        [[ "$a" == "$needle" || "$a" == "$needle:"* ]] && return 0
    done
    return 1
}
# split_argv FILE: APPT_PRE = apptainer's own flags/binds, APPT_POST = the
# agent command line. Split at the image path, so the prompt (one argument
# carrying the whole diff) can never be mistaken for a flag.
split_argv() {
    local a seen=0
    APPT_PRE=() APPT_POST=() APPT_IMAGE=0
    while IFS= read -r a || [[ -n "$a" ]]; do
        if [[ "$seen" -eq 0 && "$a" == "$SANDBOX_IMAGE" ]]; then
            seen=1 APPT_IMAGE=1
            continue
        fi
        if [[ "$seen" -eq 0 ]]; then APPT_PRE+=("$a"); else APPT_POST+=("$a"); fi
    done < "$1"
}

rm -f "$W/appt-argv"
worktree_resolve_message "$W/msg.final" "$W/diff_state.txt" >/dev/null 2>&1
grep -q 'Generated title' "$W/msg.final" \
    && ok W10 "an empty agent file falls back to generated message" \
    || bad W10 "fallback did not produce a message"

split_argv "$W/appt-argv"
[[ "$APPT_IMAGE" -eq 1 ]] && has_arg exec ${APPT_PRE[@]+"${APPT_PRE[@]}"} \
    && ok W10b "generation runs via apptainer exec against this run's image" \
    || bad W10b "generation did not go through a container at all"

if has_path "$WORKTREE_DIR" ${APPT_PRE[@]+"${APPT_PRE[@]}"} \
    || has_path "$W/main" ${APPT_PRE[@]+"${APPT_PRE[@]}"}; then
    bad W10c "the generator mounts the checkout, so agent-authored instruction files auto-load"
else
    ok W10c "neither the worktree nor the project is mounted into the generator"
fi

has_path "$HOME/.omp" ${APPT_PRE[@]+"${APPT_PRE[@]}"} \
    && ok W10d "the agent's own config binds are carried, so it can authenticate" \
    || bad W10d "config binds missing: the generator could never reach a model"

w10_missing=""
for flag in -p --no-tools --no-lsp --no-extensions --no-skills --no-rules --no-session; do
    has_arg "$flag" ${APPT_POST[@]+"${APPT_POST[@]}"} || w10_missing="$w10_missing $flag"
done
[[ -z "$w10_missing" ]] \
    && ok W10e "the generator runs with every execution facility disabled" \
    || bad W10e "generator invoked WITHOUT:$w10_missing -- injected text could act inside the container"

# The model is named by ROLE, not resolved here: that is what makes an
# overlay or profile that redefines the role take effect.
has_arg commit ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && ok W10f "omp is asked for its own \"commit\" role rather than a scraped model id" \
    || bad W10f "the commit role was not used"

# An undefined role is a hard error in omp, so "no role configured" must
# fall back to the default model instead of failing every run.
mv "$HOME/.omp/agent/config.yml" "$HOME/.omp/agent/config.yml.off"
rm -f "$W/appt-argv"
commit_msg_generate "$W/msg.norole" "prompt" >/dev/null 2>&1
split_argv "$W/appt-argv"
has_arg --model ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && bad W10g "a commit role was named even though none is configured" \
    || ok W10g "no configured commit role -> no --model, so generation still runs"
mv "$HOME/.omp/agent/config.yml.off" "$HOME/.omp/agent/config.yml"

COMMIT_MODEL="vendor/tiny-1"
rm -f "$W/appt-argv"
commit_msg_generate "$W/msg.override" "prompt" >/dev/null 2>&1
split_argv "$W/appt-argv"
has_arg "vendor/tiny-1" ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && ok W10h "--commit-model overrides the agent's own role selection" \
    || bad W10h "--commit-model was ignored"
# shellcheck disable=SC2034  # read by commit_msg_model_args (functions/commit-message.sh)
COMMIT_MODEL=""

# Only flags that change WHICH configuration resolves may cross over. The
# coding run's own model and any capability-granting flag must not: the
# generator is a different task with a smaller mandate.
ARGS=(--profile work --config /tmp/overlay.yml --model opus --auto-approve "do the thing")
rm -f "$W/appt-argv"
commit_msg_generate "$W/msg.pass" "prompt" >/dev/null 2>&1
split_argv "$W/appt-argv"
if has_arg --profile ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && has_arg work ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && has_arg /tmp/overlay.yml ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && ! has_arg opus ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && ! has_arg --auto-approve ${APPT_POST[@]+"${APPT_POST[@]}"}; then
    ok W10i "profile/config propagate; the coding model and approval flags do not"
else
    bad W10i "flag propagation is wrong (leaked a capability flag, or dropped profile/config)"
fi
# shellcheck disable=SC2034  # read by commit_msg_passthrough (functions/commit-message.sh)
ARGS=()

# Claude Code: --bare is its documented minimal mode but deliberately keeps
# Bash/read/edit, so --tools "" is what actually removes the tools.
AGENT=claude
rm -f "$W/appt-argv"
commit_msg_generate "$W/msg.claude" "prompt" >/dev/null 2>&1
split_argv "$W/appt-argv"
if has_arg --bare ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && has_arg --tools ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && has_arg haiku ${APPT_POST[@]+"${APPT_POST[@]}"}; then
    ok W10j "claude runs --bare with its tools removed, on the haiku alias"
else
    bad W10j "claude was invoked without its documented minimal/no-tools flags"
fi

# opencode has no --no-tools flag at all: tool availability is config. A
# bare-string permission denies every tool, including ones added later.
AGENT=opencode
rm -f "$W/appt-argv" "$W/appt-env"
commit_msg_generate "$W/msg.opencode" "prompt" >/dev/null 2>&1
split_argv "$W/appt-argv"
if has_arg run ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && has_arg "anthropic/claude-haiku-4-5" ${APPT_POST[@]+"${APPT_POST[@]}"} \
    && grep -q 'APPTAINERENV_OPENCODE_CONFIG_CONTENT=.*"permission":"deny"' "$W/appt-env"; then
    ok W10k "opencode runs on its configured small_model with every tool denied"
else
    bad W10k "opencode was invoked without a denied-tool config or without small_model"
fi
# That override must not survive into the NEXT agent run: the reject menu's
# re-run path launches the real agent from this same shell, and an
# inherited permission:"deny" would silently cripple it. Read through
# printenv, because what matters is the EXPORTED environment a child
# process would receive, not merely this shell's variable.
printenv APPTAINERENV_OPENCODE_CONFIG_CONTENT >/dev/null 2>&1 \
    && bad W10l "APPTAINERENV_OPENCODE_CONFIG_CONTENT leaked; the next agent run would be crippled" \
    || ok W10l "the tool-denying override does not leak into the calling shell"
# shellcheck disable=SC2034  # read by the commit_msg_* functions (functions/commit-message.sh)
AGENT=omp

# --- W11: generator failure still reaches the gate -----------------------
printf '#!/bin/sh\nexit 3\n' > "$W/bin/apptainer"
chmod +x "$W/bin/apptainer"
worktree_resolve_message "$W/msg.final" "$W/diff_state.txt" >/dev/null 2>&1
if grep -q '[^[:space:]]' "$W/msg.final" && grep -q "$WORKTREE_REF" "$W/msg.final"; then
    ok W11 "a failed generator still yields a non-empty message, so the human still reviews"
else
    bad W11 "a failed generator left no message at all"
fi

# --- W12: the approved commit lands on agent/<branch> in the MAIN repo ---
printf 'Test commit\n\nIssue:\ni\n\nSolution:\ns\n' > "$W/msg.final"
before_sha="$(git -C "$W/main" rev-parse "refs/heads/$WORKTREE_REF" 2>/dev/null)"
worktree_commit "$W/msg.final" >/dev/null 2>&1
after_sha="$(git -C "$W/main" rev-parse "refs/heads/$WORKTREE_REF" 2>/dev/null)"
[[ -n "$after_sha" && "$after_sha" != "$before_sha" ]] \
    && ok W12 "the host-side commit moved $WORKTREE_REF in the main repository" \
    || bad W12 "the commit did not land on the branch"
git -C "$W/main" cat-file -t "$after_sha" >/dev/null 2>&1 \
    && ok W12b "its objects are in the main repository's own object store" \
    || bad W12b "the commit object is not readable from the main repository"
git -C "$W/main" show --stat --oneline "$after_sha" 2>/dev/null | grep -q 'added.txt' \
    && ok W12c "untracked files were included in the commit (git add -A)" \
    || bad W12c "untracked files were left out of the commit"
git -C "$W/main" show --stat --oneline "$after_sha" 2>/dev/null | grep -q 'IGNORED' \
    && bad W12d "gitignored content was committed" \
    || ok W12d "gitignored content stayed out of the commit"

# master must not have moved: the whole point is that the work lands on the
# throwaway branch and nowhere else.
master_ref="$(git -C "$W/main" symbolic-ref --short HEAD 2>/dev/null)"
master_now="$(git -C "$W/main" rev-parse "refs/heads/$master_ref" 2>/dev/null)"
[[ "$master_now" == "$before_sha" ]] \
    && ok W12e "the main branch $master_ref is untouched by the commit" \
    || bad W12e "the main branch moved"

# --- W13: discard refuses to drop a branch carrying real commits ---------
worktree_discard >/dev/null 2>&1
[[ ! -d "$WORKTREE_DIR" ]] \
    && ok W13 "discard removed the worktree" \
    || bad W13 "discard left the worktree behind"
git -C "$W/main" show-ref --verify --quiet "refs/heads/$WORKTREE_REF" \
    && ok W13b "discard KEPT a branch holding unmerged commits instead of deleting it" \
    || bad W13b "discard deleted a branch carrying commits -- silent data loss"

# --- W14: the refuse cases, which must never guess -----------------------
# branch present, worktree gone (a landed run, or one moved by hand).
git -C "$W/main" worktree prune
WORKTREE_LOCK_HELD=0
( worktree_prepare ) >/dev/null 2>&1 \
    && bad W14 "a branch with no matching worktree was silently reused" \
    || ok W14 "refuse: branch exists without its worktree"
worktree_lock_release

# worktree directory present, branch gone.
git -C "$W/main" branch -D "$WORKTREE_REF" >/dev/null 2>&1
mkdir -p "$WORKTREE_DIR"
# shellcheck disable=SC2034  # read by worktree_lock_acquire/release (functions/worktree.sh)
WORKTREE_LOCK_HELD=0
( worktree_prepare ) >/dev/null 2>&1 \
    && bad W14b "a leftover worktree directory with no branch was silently reused" \
    || ok W14b "refuse: worktree directory exists without its branch"
worktree_lock_release
rm -rf "$WORKTREE_DIR"

# --- W15: a non-main checkout is refused outright ------------------------
# A linked worktree's <main>/.git lives outside the project dir, so its
# history could not be masked from inside the container.
(
    # shellcheck disable=SC2030,SC2034  # both are read by worktree_preflight (functions/worktree.sh); subshell-local on purpose
    PROJECT_DIR="$MAIN_WT_DIR"
    # shellcheck disable=SC2034
    WORKTREE_BRANCH="nested"
    worktree_preflight
) >/dev/null 2>&1 \
    && bad W15 "--worktree accepted a project dir whose git dir is outside it" \
    || ok W15 "refuse: --worktree only runs against a main checkout"

# --- M: the project config mask -----------------------------------------
# The convention's whole contract is one rule -- visible <=> tracked in
# HEAD and identical to it -- plus "absent means unbound". Each assertion
# below fails on a plausible regression of that rule, and the ones marked
# so were written against a measured bug.
MASKREPO="$W/maskrepo"
mkdir -p "$MASKREPO/sub/deep" "$MASKREPO/vendor/pkg" "$MASKREPO/.omp" "$MASKREPO/.claude/agents"
git init --quiet "$MASKREPO"
printf 'vendor/\n' > "$MASKREPO/.gitignore"
printf 'committed root\n' > "$MASKREPO/AGENTS.md"
printf 'committed deep\n' > "$MASKREPO/sub/deep/AGENTS.md"
printf 'committed rules\n' > "$MASKREPO/.omp/RULES.md"
printf 'committed agent\n' > "$MASKREPO/.claude/agents/AGENTS.md"
printf 'x\n' > "$MASKREPO/f"
git -C "$MASKREPO" add .gitignore AGENTS.md sub/deep/AGENTS.md .omp/RULES.md .claude/agents/AGENTS.md f
git -C "$MASKREPO" commit --quiet -m "mask fixture"
printf 'committed root\nLOCAL DRIFT\n' > "$MASKREPO/AGENTS.md"
printf 'untracked plant\n' > "$MASKREPO/CLAUDE.md"
printf 'deep untracked plant\n' > "$MASKREPO/sub/CLAUDE.md"
printf 'ignored plant\n' > "$MASKREPO/vendor/pkg/AGENTS.md"

BINDS=() RO_MASKED=() CFG_MASK_STATE=() CFG_MASK_PATH=() CFG_MASK_OWNER=()
mask_project_agent_config "$MASKREPO"

mask_state_of() {
    local want="$1" i
    for i in "${!CFG_MASK_PATH[@]}"; do
        [[ "${CFG_MASK_PATH[i]}" == "$want" ]] && { printf '%s' "${CFG_MASK_STATE[i]}"; return 0; }
    done
    printf 'missing'
}
mask_src_of() {
    local want="$1" b
    for b in "${BINDS[@]}"; do
        [[ "$b" == "-B" ]] && continue
        [[ "$b" == *":$want:ro" ]] && { printf '%s' "${b%%:*}"; return 0; }
    done
    printf ''
}

[[ "$(mask_state_of "$MASKREPO/.omp/RULES.md")" == committed ]] \
    && ok M1 "committed & clean config is visible (read-only copy)" \
    || bad M1 "a committed, clean config path was not reported committed"
[[ "$(mask_state_of "$MASKREPO/CLAUDE.md")" == hidden ]] \
    && ok M2 "untracked config is hidden" \
    || bad M2 "an untracked config path was not hidden"
[[ "$(mask_state_of "$MASKREPO/AGENTS.md")" == hidden ]] \
    && ok M3 "tracked-but-modified config is hidden" \
    || bad M3 "a locally modified config path was not hidden"
# The regression the convention itself names as the one to watch.
[[ "$(mask_state_of "$MASKREPO/.claude/settings.json")" == unbound \
   && -z "$(mask_src_of "$MASKREPO/.claude/settings.json")" \
   && ! -e "$MASKREPO/.claude/settings.json" ]] \
    && ok M4 "absent config produces no bind and materialises nothing" \
    || bad M4 "an absent config path was bound, or materialised on disk"
# A committed copy must come from HEAD, never from the dirty working tree.
[[ "$(cat "$(mask_src_of "$MASKREPO/sub/deep/AGENTS.md")" 2>/dev/null)" == "committed deep" ]] \
    && ok M5 "the bound copy is HEAD's content" \
    || bad M5 "the bound copy did not match HEAD"
[[ "$(cat "$(mask_src_of "$MASKREPO/AGENTS.md")" 2>/dev/null)" == "committed root" ]] \
    && ok M6 "a dirty path shows HEAD's content, not the working tree's" \
    || bad M6 "local drift was visible through the mask"
# Tree-wide reach: the same rule at depth, and no hiding behind .gitignore.
[[ "$(mask_state_of "$MASKREPO/sub/deep/AGENTS.md")" == committed \
   && "$(mask_state_of "$MASKREPO/sub/CLAUDE.md")" == hidden ]] \
    && ok M7 "deep instruction files obey the same rule as root-level ones" \
    || bad M7 "a deep instruction file was masked differently from a root-level one"
[[ "$(mask_state_of "$MASKREPO/vendor/pkg/AGENTS.md")" == hidden ]] \
    && ok M8 "a gitignored instruction file is still masked" \
    || bad M8 "an ignore rule was a place to hide an instruction file"
# A deep match inside a table directory is decided by that directory's
# entry, not by a second bind nested in it.
[[ "$(mask_state_of "$MASKREPO/.claude/agents")" == committed \
   && "$(mask_state_of "$MASKREPO/.claude/agents/AGENTS.md")" == missing ]] \
    && ok M14 "a deep match inside a table directory is covered by that entry alone" \
    || bad M14 "a deep match inside a table directory got its own nested bind"
# One RO_MASKED element per masked path: a split append corrupts the
# agent's own limitations file and the read-only bind count.
[[ "$(printf '%s\n' "${RO_MASKED[@]}" | grep -c '^committed version)')" -eq 0 ]] \
    && ok M9 "each masked path is exactly one RO_MASKED element" \
    || bad M9 "a RO_MASKED entry was split across two array elements"
# Worktree mode masks two checkouts; both must survive in the report.
MASKWT="$W/maskwt"
cp -a "$MASKREPO" "$MASKWT"
mask_project_agent_config "$MASKWT"
main_rows=0 wt_rows=0
for _i in "${!CFG_MASK_OWNER[@]}"; do
    [[ "${CFG_MASK_OWNER[_i]}" == "$MASKREPO" ]] && main_rows=$((main_rows+1))
    [[ "${CFG_MASK_OWNER[_i]}" == "$MASKWT" ]] && wt_rows=$((wt_rows+1))
done
[[ "$main_rows" -gt 0 && "$wt_rows" -gt 0 ]] \
    && ok M10 "masking a second checkout keeps the first one's report rows" \
    || bad M10 "the second mask pass discarded the first checkout's partition"
# The gate's candidate list must propagate a failed git read, not return
# an empty list that reads as "the agent created nothing".
(
    # shellcheck disable=SC2317  # invoked indirectly, as the `git` shadow inside this subshell
    git() { [[ "$*" == *"ls-files --others"* ]] && return 1; command git "$@"; }
    config_shaped_untracked "$MASKREPO" "$W/cand-fail.z"
) >/dev/null 2>&1 \
    && bad M11 "a failed untracked-file read produced an empty candidate list" \
    || ok M11 "a failed candidate enumeration refuses instead of returning empty"
# Literal pathspecs: an excluded file whose NAME is a glob must not unstage its
# neighbours from a commit the human already approved.
GLOBREPO="$W/globrepo"
mkdir -p "$GLOBREPO/sub"
git init --quiet "$GLOBREPO"
printf 'b\n' > "$GLOBREPO/base"
git -C "$GLOBREPO" add base
git -C "$GLOBREPO" commit --quiet -m base
printf 'w\n' > "$GLOBREPO/sub/work.md"
printf 'o\n' > "$GLOBREPO/sub/other.md"
printf 'p\n' > "$GLOBREPO/sub/*.md"
git -C "$GLOBREPO" add -A
printf ':(top,literal)%s\0' 'sub/*.md' > "$W/exclude-glob.z"
git -C "$GLOBREPO" rm -q --cached --pathspec-from-file="$W/exclude-glob.z" --pathspec-file-nul
[[ "$(git -C "$GLOBREPO" diff --cached --name-only | sort | tr '\n' ' ')" == "sub/other.md sub/work.md " ]] \
    && ok M12 "a glob-named excluded file unstages only itself" \
    || bad M12 "a glob-named excluded file dropped reviewed work from the commit"
# A config path must not be a symlink, neither on disk nor as HEAD records
# it: the bind would follow the link to some other host file.
LINKREPO="$W/linkrepo"
mkdir -p "$LINKREPO/.claude"
git init --quiet "$LINKREPO"
printf 'target\n' > "$LINKREPO/real.json"
ln -s ../real.json "$LINKREPO/.claude/settings.json"
git -C "$LINKREPO" add -A
git -C "$LINKREPO" commit --quiet -m "linked config"
link_refused() { ( BINDS=() RO_MASKED=(); mask_project_agent_config "$LINKREPO" ) >/dev/null 2>&1 && return 1; return 0; }
m13=0
link_refused || m13=1
# The working tree replaced the link with a regular file: HEAD still has
# the link, and the committed copy would be one.
rm "$LINKREPO/.claude/settings.json"
printf 'plain\n' > "$LINKREPO/.claude/settings.json"
link_refused || m13=1
[[ "$m13" -eq 0 ]] \
    && ok M13 "a config path that is a symlink, on disk or in HEAD, refuses the run" \
    || bad M13 "a symlinked config path was bound"
# The mask table is the perimeter: a malformed table must refuse the run,
# never load with rows silently missing.
mask_table_refused() {
    printf '%b' "$1" >"$W/mask-variant.toml"
    (
        # shellcheck disable=SC2030,SC2034  # subshell-local on purpose; read by project_config_mask_load
        PROJECT_CONFIG_MASK_FILE="$W/mask-variant.toml" PROJECT_CONFIG_MASK_KIND=() \
            PROJECT_CONFIG_MASK_PATH=() PROJECT_CONFIG_MASK_ANYWHERE=()
        project_config_mask_load
    ) >/dev/null 2>&1 && return 1
    return 0
}
m15=0
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' && m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[project.b]\ndirs = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "../x",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = ["x.json"]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n' || m15=1
[[ "$m15" -eq 0 ]] \
    && ok M15 "a malformed mask table (duplicate, '..', inline array, unclosed, no [anywhere]) refuses; a valid one loads" \
    || bad M15 "the mask loader accepted a malformed table, or refused a valid one"
# The shipped table is TOML that any parser reads the same way: the
# loader's rows equal tomllib's (Python >= 3.11; skipped without it).
if python3 -c 'import tomllib' 2>/dev/null; then
    m16_py="$(python3 -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
for t in d["project"].values():
    for k in ("files", "dirs"):
        for v in t.get(k, []): print("P", k[:-1], v)
for v in d["anywhere"]["names"]: print("A", v)' "$PROJECT_CONFIG_MASK_FILE")"
    m16_sh="$(
        project_config_mask_load
        for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
            printf 'P %s %s\n' "${PROJECT_CONFIG_MASK_KIND[i]}" "${PROJECT_CONFIG_MASK_PATH[i]}"
        done
        printf 'A %s\n' "${PROJECT_CONFIG_MASK_ANYWHERE[@]}"
    )"
    [[ -n "$m16_sh" && "$m16_sh" == "$m16_py" ]] \
        && ok M16 "config/mask.toml loads to exactly what tomllib reads" \
        || bad M16 "the mask loader and tomllib disagree about config/mask.toml"
else
    printf 'skip %-6s %s\n' M16 "no python3 with tomllib (>= 3.11)"
fi

# --- B: the global surface's read-only binds (functions/binds.sh) --------
# An absent global config path must never become creatable on the host:
# unbound when nothing read-write covers it, created and bound read-only
# when something does.
G="$W/global"
mkdir -p "$G/rwparent"
# b_bound PATH: some bind in BINDS has PATH as its container destination.
b_bound() {
    local b dst
    for b in "${BINDS[@]}"; do
        [[ "$b" == -B ]] && continue
        dst="$b"
        [[ "$b" == *:* ]] && { dst="${b#*:}"; dst="${dst%%:*}"; }
        [[ "$dst" == "$1" ]] && return 0
    done
    return 1
}
BINDS=() RO_MASKED=()
bind_ro "$G/absent/settings.json"
[[ ${#BINDS[@]} -eq 0 && ! -e "$G/absent" ]] \
    && ok B1 "an absent config path with no read-write parent is not bound, and nothing is created" \
    || bad B1 "an absent config path was bound or materialized on the host"
BINDS=(-B "$G/rwparent") RO_MASKED=()
bind_ro "$G/rwparent/bin" dir
[[ -d "$G/rwparent/bin" && " ${BINDS[*]} " == *" $G/rwparent/bin:$G/rwparent/bin:ro "* ]] \
    && ok B2 "an absent path under a read-write bind is created on the host and bound read-only" \
    || bad B2 "an absent path under a read-write bind was left creatable"
ln -s "$G/nowhere" "$G/rwparent/link"
( BINDS=(-B "$G/rwparent"); bind_ro "$G/rwparent/link" ) >/dev/null 2>&1 \
    && bad B3 "a dangling symlink under a read-write bind was accepted" \
    || ok B3 "a dangling symlink under a read-write bind refuses the run"
BINDS=(-B "$G/rwparent") RO_MASKED=()
bind_augmented_instructions "$G/rwparent/AGENTS.md" 2>/dev/null
[[ ! -e "$G/rwparent/AGENTS.md" ]] && ! b_bound "$G/rwparent/AGENTS.md" \
    && ok B4 "the instruction overlay is skipped where a read-write bind covers an absent destination" \
    || bad B4 "the instruction overlay would materialize a file inside a read-write bind"
BINDS=() RO_MASKED=()
# opencode's state directory holds service.json (a server's pid, port and
# password); the host's copy must never be what the session sees.
b5_binds="$(
    # shellcheck disable=SC2030,SC2034  # subshell-local; read by configure_agent
    AGENT=opencode ARGS=() BINDS=() RO_MASKED=() EXTRA_BIND_SRCS=() EXTRA_BIND_RO=()
    mkdir -p "$HOME/.local/state/opencode"
    configure_agent >/dev/null 2>&1
    printf '%s\n' "${BINDS[@]}"
)"
if grep -qx -- "$RUN_DIR/opencode-state:$HOME/.local/state/opencode" <<<"$b5_binds" \
    && ! grep -q -- "^$HOME/.local/state/opencode" <<<"$b5_binds"; then
    ok B5 "opencode's state directory (service.json) is per run, never the host's"
else
    bad B5 "the session could read or write the host's opencode service.json"
fi

# --- O: omp's per-run ~/.omp (functions/omp-home.sh) ---------------------
# The host's ~/.omp holds code omp loads (native addons, extensions/,
# settings naming modules) and sockets to host-side processes (run/). What
# is asserted: none of that is bound writable, config is a plain per-run
# copy, only the state that must persist is shared, and the settings
# merge-back takes exactly the two keys it may and nothing it should not.
OMP="$HOME/.omp"
mkdir -p "$OMP/agent/extensions" "$OMP/agent/sessions/-elsewhere" "$OMP/agent/terminal-sessions" \
    "$OMP/natives/9.9.9" "$OMP/run/daemons/x" "$HOME/projects/p"
printf 'addon\n' >"$OMP/natives/9.9.9/pi_natives.node"
printf 'setupVersion: 1\nmodelRoles:\n  default: vendor/big\n  smol: vendor/small\ntheme:\n  dark: night\ncycleOrder:\n  - vendor/big\n  - vendor/small\n' \
    >"$OMP/agent/config.yml"
printf 'rule\n' >"$OMP/agent/RULES.md"
for f in .env secret-placeholder.key history.db models.db agent.db; do : >"$OMP/agent/$f"; done
BINDS=() RO_MASKED=()
omp_home_prepare || fail_setup "omp_home_prepare"
unset APPTAINERENV_PI_CONFIG_FILES
omp_bound() { local b; for b in "${BINDS[@]}"; do [[ "$b" == "$1" ]] && return 0; done; return 1; }
# A host path bound from: PATH (or anything below it) is some bind's source.
omp_bound_src_under() { local b; for b in "${BINDS[@]}"; do [[ "$b" == "$1"* ]] && return 0; done; return 1; }
# Matches PATH as a bind's source or its destination, or anything below it.
omp_bound_under() {
    local b dst
    for b in "${BINDS[@]}"; do
        dst="${b#*:}"; dst="${dst%%:*}"
        [[ "$b" == "$1"* || "$dst" == "$1"* ]] && return 0
    done
    return 1
}
# shellcheck disable=SC2031  # W15 changed PROJECT_DIR only inside its own subshell
O_BUCKET="$(omp_session_bucket "${WORKTREE_DIR:-$PROJECT_DIR}")"
O_KEY="$(omp_home_project_key)"

if omp_bound "$RUN_DIR/omp:$OMP" && [[ "$(readlink "$OMP_HOME_DIR/natives")" == /usr/local/omp/natives ]] \
    && ! omp_bound_src_under "$OMP/natives" && ! omp_bound_src_under "$OMP/run" \
    && ! omp_bound_src_under "$OMP/logs" && ! omp_bound_src_under "$OMP:"; then
    ok O1 "per-run ~/.omp: the host's natives, run/ and logs are not bound"
else
    bad O1 "a host ~/.omp path holding code or sockets is bound into the sandbox"
fi
if [[ -f "$OMP_HOME_DIR/agent/config.yml" && ! -L "$OMP_HOME_DIR/agent/config.yml" ]] \
    && cmp -s "$OMP_HOME_DIR/agent/config.yml" "$OMP/agent/config.yml" \
    && ! omp_bound_under "$OMP/agent/config.yml"; then
    ok O2 "config.yml is a plain per-run copy, so omp's rename-based save cannot hit EBUSY"
else
    bad O2 "config.yml is a bind (EBUSY on save) or not the host's content"
fi
if omp_bound "$OMP/agent/extensions:$OMP/agent/extensions:ro" && omp_bound "$OMP/agent/RULES.md:$OMP/agent/RULES.md:ro" \
    && omp_bound "$OMP/agent/agent.db" && omp_bound "$OMP/agent/sessions/$O_BUCKET" \
    && ! omp_bound_under "$OMP/agent/sessions/-elsewhere" && ! omp_bound_under "$OMP/agent/.env" \
    && ! omp_bound_under "$OMP/agent/secret-placeholder.key" && ! omp_bound_under "$OMP/agent/history.db" \
    && ! omp_bound_under "$OMP/agent/models.db" && ! omp_bound_under "$OMP/agent/terminal-sessions"; then
    ok O3 "host config read-only; agent.db and this checkout's sessions shared; .env, key, other state not bound"
else
    bad O3 "the agent directory's binds do not match the allowlist"
fi
if [[ "$(readlink "$OMP_HOME_DIR/agent/history.db")" == .sandbox-history/history.db ]] \
    && omp_bound "$HOME/.agent/omp-history/$O_KEY:$OMP/agent/.sandbox-history"; then
    ok O4 "history.db is this project's own database, not the host's"
else
    bad O4 "history.db does not resolve to the per-project database"
fi
if [[ "$(omp_session_bucket "$HOME/projects/p")" == -projects-p \
    && "$(omp_session_bucket /usr/share)" == --usr-share-- \
    && "$(omp_session_bucket "$W")" == "-tmp-${W#"$(readlink -f "${TMPDIR:-/tmp}")"/}" ]]; then
    ok O5 "session folders are named the way omp names them"
else
    bad O5 "omp_session_bucket disagrees with omp's scheme"
fi
# The session edits its copy; only modelRoles/cycleOrder may reach the host.
sed -i 's|default: vendor/big|default: vendor/other|; s|dark: night|dark: day|' "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
if grep -q '^  default: vendor/other$' "$OMP/agent/config.yml" && grep -q '^  dark: night$' "$OMP/agent/config.yml" \
    && [[ "$(omp_config_block "$OMP/agent/config.yml" cycleOrder)" == "$(printf 'cycleOrder:\n  - vendor/big\n  - vendor/small')" ]] \
    && grep -q 'dark: day' "$W/omp-merge.err"; then
    ok O7 "a modelRoles change merges back; a theme change is only reported"
else
    bad O7 "the merge-back took the wrong keys"
fi
sed -i 's|smol: vendor/small|smol: vendor/hostpick|' "$OMP/agent/config.yml"
sed -i 's|smol: vendor/small|smol: vendor/sessionpick|' "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  smol: vendor/hostpick$' "$OMP/agent/config.yml" && grep -q 'changed on the host' "$W/omp-merge.err" \
    && ok O8 "a change made on the host during the run wins, and is reported" \
    || bad O8 "the session overwrote a concurrent host change"
printf 'cycleOrder:\n  - vendor/big\n  - vendor/x; touch /tmp/pwn\n' >"$W/omp-bad.block"
omp_config_with_block "$OMP_HOME_DIR/agent/config.yml" cycleOrder "$W/omp-bad.block" >"$W/omp-bad.yml"
cp "$W/omp-bad.yml" "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  - vendor/small$' "$OMP/agent/config.yml" && ! grep -q 'pwn' "$OMP/agent/config.yml" \
    && ok O9 "a value that is not a plain model id is not merged" \
    || bad O9 "a non-model-id value reached the host config"
: >"$OMP_HOME_DIR/agent/SYSTEM.md"
: >"$OMP_HOME_DIR/agent/models.db-wal"
omp_home_report_created 2>"$W/omp-created.err"
grep -q 'agent/SYSTEM.md' "$W/omp-created.err" && ! grep -q 'models.db' "$W/omp-created.err" \
    && ok O10 "a config file created in-session is named at exit; omp's own state is not" \
    || bad O10 "the exit report missed a created config file, or listed omp's state"
# The merge reads only the form omp writes (omp_config_standard). Each
# case starts from a host file, a launch copy and a session copy set here.
o_std() { printf '%b' "$1" >"$OMP/agent/config.yml"; cp "$OMP/agent/config.yml" "$RUN_DIR/omp-config.orig"; }
O_HOST='modelRoles:\n  default: vendor/a\ncycleOrder:\n  - vendor/a\n'
o12=0
# A top-level key the line scanner cannot see: nothing merged, nothing listed.
o_std "$O_HOST"
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\n"theme": x\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" && grep -q 'not in the form omp writes' "$W/omp-merge.err" \
    && grep -q '"theme": x' "$W/omp-merge.err" || o12=1
# "KEY:VALUE" without the space is a plain scalar to YAML, not a key.
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\ntheme:x\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" && grep -q 'not in the form omp writes' "$W/omp-merge.err" || o12=1
# A host file outside the form is never written, however clean the session.
o_std "$O_HOST"
printf '# mine\n%b' "$O_HOST" >"$OMP/agent/config.yml"
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^# mine$' "$OMP/agent/config.yml" && grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" \
    && grep -q 'not in the form omp writes' "$W/omp-merge.err" || o12=1
[[ "$o12" -eq 0 ]] \
    && ok O12 "a session copy or host file outside omp's written form merges nothing, and says so" \
    || bad O12 "the merge read or wrote a config.yml that is not in the form omp writes"
# omp writes an emptied list as the key followed by an indented "[]".
o_std "$O_HOST"
printf 'modelRoles:\n  default: vendor/a\ncycleOrder:\n  []\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
[[ "$(omp_config_block "$OMP/agent/config.yml" cycleOrder)" == "$(printf 'cycleOrder:\n  []')" ]] \
    && ok O13 "an emptied cycleOrder, in the form omp writes it, merges back" \
    || bad O13 "omp's own empty-list form did not merge"
OMP_HOME_DIR=""
# The image-natives check: the stand-in apptainer runs the probe's own
# command on the host, which plays the image, so OMP_IMAGE_NATIVES decides
# whether the "image" has the directory.
cat > "$W/bin/apptainer" <<STUB
#!/bin/sh
while [ "\$#" -gt 0 ] && [ "\$1" != "$SANDBOX_IMAGE" ]; do shift; done
[ "\$#" -gt 0 ] || exit 255
shift
exec "\$@"
STUB
chmod +x "$W/bin/apptainer"
o11=0
# shellcheck disable=SC2034  # OMP_IMAGE_NATIVES is read by omp_home_require_natives (functions/omp-home.sh)
( OMP_IMAGE_NATIVES="$W/no-such-natives"; omp_home_require_natives ) >/dev/null 2>&1 && o11=1
( OMP_IMAGE_NATIVES="$W"; omp_home_require_natives ) >/dev/null 2>&1 || o11=1
printf '#!/bin/sh\nexit 255\n' > "$W/bin/apptainer"
# shellcheck disable=SC2034  # see above
( OMP_IMAGE_NATIVES="$W/no-such-natives"; omp_home_require_natives ) >/dev/null 2>&1 || o11=1
[[ "$o11" -eq 0 ]] \
    && ok O11 "an image without the build-time native addons refuses; one that has them, or cannot be asked, does not" \
    || bad O11 "the image-natives check refused wrongly, or let an old image through"

# o_refuses ARG...: omp_home_refuse_overrides with ARGS=(ARG...), in an
# environment holding only O_ENV of the variables it reads; true if it
# refused. The container sees only APPTAINERENV_-forwarded variables, so
# those are what must refuse -- and a host-only variable must not.
o_refuses() {
    (
        unset OMP_PROFILE PI_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR PI_CODING_AGENT_SESSION_DIR
        unset APPTAINERENV_OMP_PROFILE APPTAINERENV_PI_PROFILE APPTAINERENV_PI_CODING_AGENT_DIR \
            APPTAINERENV_PI_CONFIG_DIR APPTAINERENV_PI_CODING_AGENT_SESSION_DIR
        if [[ -n "${O_ENV:-}" ]]; then export "${O_ENV?}"; fi
        # shellcheck disable=SC2034  # ARGS and VERBOSE are read by omp_home_refuse_overrides and log_info
        ARGS=("$@") VERBOSE=0
        omp_home_refuse_overrides
    ) >/dev/null 2>&1 && return 1
    return 0
}
o_fail=0
o_refuses --profile work || o_fail=1
O_ENV=APPTAINERENV_OMP_PROFILE=work o_refuses || o_fail=1
O_ENV=APPTAINERENV_PI_CODING_AGENT_DIR=/x o_refuses || o_fail=1
o_refuses --profile=default && o_fail=1
O_ENV=APPTAINERENV_OMP_PROFILE=' default ' o_refuses && o_fail=1
O_ENV=OMP_PROFILE=work o_refuses && o_fail=1
O_ENV=PI_CODING_AGENT_DIR=/x o_refuses && o_fail=1
[[ "$o_fail" -eq 0 ]] \
    && ok O6 "a named profile or directory override that reaches the sandbox refuses; the default profile, and host-only variables, run" \
    || bad O6 "profile/override refusal is wrong"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
