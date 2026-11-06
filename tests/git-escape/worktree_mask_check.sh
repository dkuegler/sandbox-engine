#!/bin/bash
# Host-side, apptainer-free verification that --worktree mode does not
# reopen a path to rewriting the main repository's history: the worktree
# root mask_git_readonly() walks (functions/git-mask.sh) and the refusal
# of a project dir whose gitdir lies outside it (worktree_preflight,
# functions/worktree.sh). The rest of --worktree mode's behaviour is
# tests/worktree/worktree_check.sh.
#
# Same standard as sanitize_check.sh: it calls the REAL functions against
# REAL git fixtures and inspects their real output. What it cannot prove,
# and what needs apptainer (run.sh/probe.sh): that the kernel actually
# refuses writes through those read-only binds from inside a live
# container.
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

W="$(mktemp -d "${TMPDIR:-/tmp}/git-escape-worktree-mask.XXXXXX")"
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

# --- fixture --------------------------------------------------------------
git init -q "$W/main" || fail_setup "init main"
printf 'tracked\n' > "$W/main/tracked.txt"
git -C "$W/main" add tracked.txt
git -C "$W/main" commit -q -m base || fail_setup "commit into main"

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

RUN_DIR="$W/run"
mkdir -p "$RUN_DIR" || fail_setup "mkdir RUN_DIR"
# Read by mask_git_readonly() (functions/git-mask.sh), sourced above; a use
# reached through `source` is invisible here without -x.
# shellcheck disable=SC2034
ALLOW_EXTERNAL_GITDIR=0
# shellcheck disable=SC2034  # read by log_debug (functions/log.sh)
VERBOSE=0

PROJECT_DIR="$W/main"
# shellcheck disable=SC2034  # read by functions/worktree.sh
WORKTREE_BRANCH="demo"

worktree_preflight || fail_setup "worktree_preflight refused the main fixture"
worktree_prepare >/dev/null 2>&1 || fail_setup "worktree_prepare could not create the worktree"
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

# --- W15: a non-main checkout is refused outright ------------------------
# A linked worktree's <main>/.git lives outside the project dir, so its
# history could not be masked from inside the container.
(
    # shellcheck disable=SC2030,SC2034  # both are read by worktree_preflight (functions/worktree.sh); subshell-local on purpose
    PROJECT_DIR="$WORKTREE_DIR"
    # shellcheck disable=SC2034
    WORKTREE_BRANCH="nested"
    worktree_preflight
) >/dev/null 2>&1 \
    && bad W15 "--worktree accepted a project dir whose git dir is outside it" \
    || ok W15 "refuse: --worktree only runs against a main checkout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
