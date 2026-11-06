#!/bin/bash
# Host-side, apptainer-free verification of --worktree mode's behaviour
# (functions/worktree.sh). Same standard as the git-escape suites: it
# calls the REAL functions against REAL git fixtures and inspects their
# real output, rather than reasoning about the code.
#
# What this proves without a container:
#   - branch names and --start-point values are validated, and a new
#     agent/<branch> starts from HEAD or the pinned start point;
#   - the branch-collision policy resolves to resume / refuse / create as
#     specified, and the per-worktree lock refuses a second concurrent run,
#     takes over a crashed one, refuses one held from another host, and
#     releases through a registered teardown hook rather than through a
#     call wired into unrelated cleanup code;
#   - rendering a diff state writes nothing into the main repository;
#   - the host-side commit lands on agent/<branch> in the main repository;
#   - discarding never silently deletes a branch carrying real commits;
#   - the agent's commit-message file survives a resumed run, is never
#     inherited by a new worktree, refuses to be a symlink, is labelled at
#     the gate when a session left it unchanged, and goes away once the
#     commit lands or the worktree is discarded;
#   - the commit-message fallback is generated INSIDE the sandbox, with
#     the agent's own tools disabled and with neither the project checkout
#     nor the worktree mounted (it is fed an agent-authored diff, so both
#     are security properties, not details), and the per-agent model and
#     flag-propagation rules hold.
#
# That the writable worktree does not reopen a path to the main
# repository's history is tests/git-escape/worktree_mask_check.sh.
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

# shellcheck source=tests/lib/report.sh
source "$SCRIPT_DIR/../lib/report.sh"
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
# shellcheck source=functions/cleanup.sh
source "$REPO_ROOT/functions/cleanup.sh"
# shellcheck source=functions/worktree.sh
source "$REPO_ROOT/functions/worktree.sh"
# shellcheck source=functions/commit-message.sh
source "$REPO_ROOT/functions/commit-message.sh"

RUN_DIR="$W/run"
mkdir -p "$RUN_DIR" || fail_setup "mkdir RUN_DIR"
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
    # shellcheck disable=SC2034  # read by worktree_preflight (functions/worktree.sh); subshell-local on purpose
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
# A message left by an earlier worktree on this branch name (landed and
# cleaned up by hand) must not be offered as the new worktree's message.
mkdir -p "$(dirname "$WORKTREE_MSG_HOST")"
printf 'Stale title\n' > "$WORKTREE_MSG_HOST"
worktree_prepare >/dev/null 2>&1 || bad W3 "worktree_prepare failed to create the worktree"
[[ -d "$WORKTREE_DIR" ]] \
    && git -C "$W/main" show-ref --verify --quiet "refs/heads/$WORKTREE_REF" \
    && ok W3 "create: worktree and branch $WORKTREE_REF both exist" \
    || bad W3 "create left no worktree/branch"
[[ -f "$WORKTREE_DIR/tracked.txt" && ! -e "$WORKTREE_DIR/ignored" ]] \
    && ok W3b "the worktree is a checkout of HEAD (tracked content present)" \
    || bad W3b "the worktree does not look like a HEAD checkout"
[[ -f "$WORKTREE_MSG_HOST" && ! -L "$WORKTREE_MSG_HOST" && ! -s "$WORKTREE_MSG_HOST" \
    && "$(stat -c %a "$WORKTREE_MSG_HOST")" == 600 ]] \
    && ok W3c "create: the message file starts empty and private; a stale one is not inherited" \
    || bad W3c "create left the message file missing, non-empty or not 0600: $WORKTREE_MSG_HOST"

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
printf 'Earlier title\n\nIssue:\ne\n\nSolution:\ne\n' > "$WORKTREE_MSG_HOST"
resume_out="$(worktree_prepare 2>&1)"; resume_rc=$?
[[ "$resume_rc" -eq 0 && "$resume_out" == *resuming* ]] \
    && ok W6 "resume: an existing worktree+branch pair is reattached, not recreated" \
    || bad W6 "resume failed (rc=$resume_rc): $resume_out"
worktree_lock_release
grep -q 'Earlier title' "$WORKTREE_MSG_HOST" \
    && ok W6b "resume: the earlier session's commit message is kept for the resumed one" \
    || bad W6b "resume lost the earlier session's commit message"

# --- W6c: a symlinked message file is refused, never followed ------------
# It is bound read-write into the container and a bind follows a symlinked
# source, so a link here would hand the agent the file it points at.
# "reset" is the destructive variant: following the link would also empty
# the target.
mv "$WORKTREE_MSG_HOST" "$W/msg.saved"
printf 'host file\n' > "$W/victim"
chmod 644 "$W/victim"
ln -s "$W/victim" "$WORKTREE_MSG_HOST"
w6c_out="$( (worktree_message_file_ensure reset) 2>&1 )"; w6c_rc=$?
[[ "$w6c_rc" -ne 0 && "$w6c_out" == *"not a regular file"* \
    && "$(cat "$W/victim")" == "host file" && "$(stat -c %a "$W/victim")" == 644 ]] \
    && ok W6c "a symlinked message file refuses the run and its target is untouched" \
    || bad W6c "a symlinked message file was followed or accepted (rc=$w6c_rc): $w6c_out"
rm -f "$WORKTREE_MSG_HOST"
mv "$W/msg.saved" "$WORKTREE_MSG_HOST"

WT_GITDIR="$(git -C "$WORKTREE_DIR" rev-parse --absolute-git-dir 2>/dev/null)"
MAIN_GITDIR="$W/main/.git"

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

# --- W9b: a carried-over message is used, and labelled when unchanged ----
# The file outlives sessions, so the gate must say when the message is an
# earlier session's that the session under review never touched.
worktree_message_snapshot
worktree_resolve_message "$W/msg.final" "$W/diff_state.txt" >/dev/null 2>&1
[[ "$WORKTREE_MSG_SOURCE" == *"earlier session"* ]] && grep -q 'Agent title' "$W/msg.final" \
    && ok W9b "a message no session revised is still used, labelled as an earlier session's" \
    || bad W9b "carried-over message mishandled: source='$WORKTREE_MSG_SOURCE'"
printf 'Revised title\n\nIssue:\nx\n\nSolution:\ny\n' > "$WORKTREE_MSG_HOST"
worktree_resolve_message "$W/msg.final" "$W/diff_state.txt" >/dev/null 2>&1
[[ "$WORKTREE_MSG_SOURCE" == "written by the agent" ]] && grep -q 'Revised title' "$W/msg.final" \
    && ok W9c "a message the session revised is labelled as written by the agent" \
    || bad W9c "revised message mislabelled: source='$WORKTREE_MSG_SOURCE'"

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
printf 'Test commit\n' > "$WORKTREE_MSG_HOST"
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
[[ ! -e "$WORKTREE_MSG_HOST" ]] \
    && ok W12f "a landed commit deletes the spent message file" \
    || bad W12f "the committed message is still offered to the next session: $WORKTREE_MSG_HOST"

# --- W13: discard refuses to drop a branch carrying real commits ---------
printf 'Rejected title\n' > "$WORKTREE_MSG_HOST"
worktree_discard >/dev/null 2>&1
[[ ! -d "$WORKTREE_DIR" ]] \
    && ok W13 "discard removed the worktree" \
    || bad W13 "discard left the worktree behind"
git -C "$W/main" show-ref --verify --quiet "refs/heads/$WORKTREE_REF" \
    && ok W13b "discard KEPT a branch holding unmerged commits instead of deleting it" \
    || bad W13b "discard deleted a branch carrying commits -- silent data loss"
[[ ! -e "$WORKTREE_MSG_HOST" ]] \
    && ok W13c "discard deletes the message file along with the worktree" \
    || bad W13c "discard left the message file behind: $WORKTREE_MSG_HOST"

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

# --- W16: --start-point --------------------------------------------------
# git's <start-point>: a new agent/<branch> starts from the given commit
# instead of HEAD; the commit is pinned in preflight; an existing branch
# is never moved; anything that is not a commit refuses the run.
# "side" is a commit the main checkout is NOT on (empty tree, so a HEAD
# checkout and a side checkout are told apart by tracked.txt), made with
# plumbing so the main checkout's HEAD and working tree stay put.
w16_tree="$(git -C "$W/main" mktree </dev/null)"
w16_side="$(git -C "$W/main" commit-tree "$w16_tree" -p HEAD -m side)" \
    || fail_setup "commit-tree side"
git -C "$W/main" update-ref refs/heads/side "$w16_side" || fail_setup "update-ref side"
git -C "$W/main" tag -a -m annotated vside side || fail_setup "tag vside"
w16_head="$(git -C "$W/main" rev-parse HEAD)"

# shellcheck disable=SC2034  # WORKTREE_* are read by functions/worktree.sh
WORKTREE_BRANCH="sp"
# shellcheck disable=SC2034
WORKTREE_START_POINT="side"
# shellcheck disable=SC2034
WORKTREE_START_POINT_SET=1
worktree_preflight >/dev/null 2>&1 || bad W16 "preflight refused a valid --start-point"
WORKTREE_LOCK_HELD=0
worktree_prepare >/dev/null 2>&1 || bad W16 "worktree_prepare failed with a start point"
[[ "$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null)" == "$w16_side" \
    && ! -e "$WORKTREE_DIR/tracked.txt" \
    && "$(git -C "$W/main" rev-parse HEAD)" == "$w16_head" ]] \
    && ok W16 "create: agent/sp starts at the start point; the main checkout's HEAD is untouched" \
    || bad W16 "agent/sp did not start at 'side' (or the main HEAD moved)"
worktree_lock_release

# The existing branch is never moved: the flag refuses both the early
# preflight check and the authoritative one under the lock; without it,
# the same worktree resumes.
( worktree_preflight ) >/dev/null 2>&1 \
    && bad W16b "preflight accepted --start-point for an existing branch" \
    || ok W16b "refuse (preflight): --start-point with an existing agent/<branch>"
WORKTREE_LOCK_HELD=0
( worktree_prepare ) >/dev/null 2>&1 \
    && bad W16c "worktree_prepare accepted --start-point for an existing branch" \
    || ok W16c "refuse (under the lock): --start-point with an existing agent/<branch>"
# The refused subshell took the lock under this shell's pid and exited
# without the EXIT trap a real run releases it through.
rm -rf "$WORKTREE_LOCK"
worktree_lock_release
[[ "$(git -C "$W/main" rev-parse refs/heads/agent/sp)" == "$w16_side" ]] \
    && ok W16d "the refused runs left agent/sp where it was" \
    || bad W16d "a refused --start-point run moved agent/sp"
# shellcheck disable=SC2034
WORKTREE_START_POINT_SET=0
WORKTREE_START_POINT=""
worktree_preflight >/dev/null 2>&1
WORKTREE_LOCK_HELD=0
w16e_out="$(worktree_prepare 2>&1)"
[[ "$w16e_out" == *resuming* ]] \
    && ok W16e "without --start-point the same worktree resumes" \
    || bad W16e "resume without --start-point failed: $w16e_out"
worktree_lock_release

# Pinned: a ref that moves between preflight and creation (the image build
# sits there) does not change where the branch starts.
WORKTREE_BRANCH="sp2"
WORKTREE_START_POINT="side"
WORKTREE_START_POINT_SET=1
worktree_preflight >/dev/null 2>&1 || bad W16f "preflight refused 'side'"
git -C "$W/main" update-ref refs/heads/side "$w16_head"
# shellcheck disable=SC2034  # read by worktree_lock_acquire/release (functions/worktree.sh)
WORKTREE_LOCK_HELD=0
worktree_prepare >/dev/null 2>&1 || bad W16f "worktree_prepare failed for sp2"
[[ "$(git -C "$W/main" rev-parse refs/heads/agent/sp2 2>/dev/null)" == "$w16_side" ]] \
    && ok W16f "the start point is pinned in preflight; moving the ref later changes nothing" \
    || bad W16f "agent/sp2 followed the moved ref instead of the pinned commit"
worktree_lock_release
git -C "$W/main" update-ref refs/heads/side "$w16_side"

# Accepted values peel to a commit; everything else refuses.
WORKTREE_BRANCH="sp3"
WORKTREE_START_POINT="vside"
worktree_preflight >/dev/null 2>&1
[[ "$WORKTREE_START_SHA" == "$w16_side" ]] \
    && ok W16g "an annotated tag is peeled to its commit" \
    || bad W16g "vside resolved to '$WORKTREE_START_SHA', not $w16_side"
w16h_fail=0
for evil in "" "-side" "--exec=x" "--help" "no-such-ref" "HEAD^{tree}" "side:tracked.txt"; do
    ( WORKTREE_START_POINT="$evil"; worktree_preflight ) >/dev/null 2>&1 \
        && { w16h_fail=1; echo "  ..ACCEPTED start point: '$evil'"; }
done
[[ "$w16h_fail" -eq 0 ]] \
    && ok W16h "empty, '-'-leading, unknown and non-commit start points refuse the run" \
    || bad W16h "an invalid start point was accepted (see lines above)"

# argv: valid only with --worktree.
# shellcheck source=functions/argv.sh
source "$REPO_ROOT/functions/argv.sh"
( parse_argv --start-point side omp ) >/dev/null 2>&1 \
    && bad W16i "--start-point without --worktree was accepted" \
    || ok W16i "--start-point without --worktree refuses the run"
w16j="$( parse_argv --worktree x --start-point=side omp; echo "$WORKTREE_BRANCH|$WORKTREE_START_POINT|$WORKTREE_START_POINT_SET|${ARGS[*]-}" )"
[[ "$w16j" == "x|side|1|" ]] \
    && ok W16j "--worktree x --start-point=side parses into the start point, not the agent's argv" \
    || bad W16j "unexpected parse: $w16j"

report_summary
