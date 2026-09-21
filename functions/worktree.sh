#!/bin/bash
# --worktree <branch>: run the agent in a throwaway git worktree checked
# out on agent/<branch>, review the result on the host TTY after the
# container has exited, and commit it there -- never inside the container.
# See docs/worktree-mode.md for why (a linked worktree's writable gitdir
# is write access to the MAIN repository's entire history, not just the
# branch checked out here) and for what stays masked. In short: the
# worktree's checkout is bound read-write; every gitdir (the worktree's
# own, its per-worktree metadata under <main>/.git/worktrees/<name>/, and
# <main>/.git itself) stays read-only like any other gitdir
# (functions/git-mask.sh), so the agent cannot commit at all -- the human
# commits here, after review. Nothing is pushed: no forge credential and
# no remote URL enters the container for this feature; an approved run
# prints the `git push` command for the human to run themselves.
#
# Globals published for sandbox.sh / functions/agents.sh:
#   WORKTREE_BRANCH        the --worktree argument, verbatim (never invented)
#   WORKTREE_REF           "agent/$WORKTREE_BRANCH"
#   WORKTREE_REPO_ROOT     the main repository's top level (== PROJECT_DIR)
#   WORKTREE_DIR           $HOME/.agent/worktrees/<project-key>/<branch>
#   WORKTREE_PROJECT_MODE  ro|rw|deny -- how the main checkout is exposed
#                          (see worktree_confirm_readonly_project)
#   WORKTREE_MSG_HOST      host path of the agent's commit-message file
#   WORKTREE_REJECT_ACTION keep|discard|rerun, set by the reject menu
#   WORKTREE_DIFF_STATE_HASH
#                          hash of the diff state, recorded by
#                          worktree_build_diff_state and re-checked
#                          immediately before the commit, so an approval
#                          can only land the tree it saw
#   WORKTREE_PREREVIEW_STATE_LOG
#                          host path of the persistent state-render log:
#                          every worktree_render_state() pass (the initial
#                          render and the pre-commit recheck alike) is
#                          appended here, timestamped, so a mismatch can
#                          be diffed after the fact from outside

# The file the agent fills in with its own proposed commit message. Mounted
# read-write at $HOME/<this> inside the container; read back on the host
# after the container exits. Outside the worktree on purpose: a message
# file inside the checkout would be swept into the very commit it
# describes.
WORKTREE_MSG_NAME='.sandbox-commit-message'

# Display caps. The diff state is rendered once and used by both the
# approval gate and the sandboxed message generator, so the human and the
# model that proposes a message see the same change. These bound only what
# is SHOWN; the state file itself is never truncated, because it is the
# record of what the approval covers.
WORKTREE_GATE_DIFF_LINES=400
WORKTREE_PROMPT_DIFF_LINES=1200

# worktree_fail MSG [DETAIL...]: refuse the run with a single-owner error
# message. Every refusal in this file is a "do not guess" refusal: the
# alternative is acting on an ambiguous repository state with destructive
# git commands.
worktree_fail() {
    local msg="$1" detail
    shift
    echo "error: --worktree: $msg" >&2
    for detail in "$@"; do
        echo "       $detail" >&2
    done
    exit 1
}

# worktree_validate_branch BRANCH: the worktree's on-disk path is derived
# from BRANCH and BRANCH is interpolated into host-side git command lines,
# so it is validated before either happens.
#
# `git check-ref-format` is the authority on ref syntax and is used as
# such, but it is not sufficient on its own: measured, it ACCEPTS a leading
# "-" ("refs/heads/agent/-lead" passes), which would then be read as an
# option by the git commands below. It also accepts "/" separators, which
# are fine as nested directories but must not be able to contain "." or
# ".." components that would walk out of $HOME/.agent/worktrees.
worktree_validate_branch() {
    local branch="$1" comp
    local -a comps=()
    if [[ -z "$branch" ]]; then
        worktree_fail "--worktree needs a branch name"
    fi
    case "$branch" in
        -*)
            worktree_fail "branch name '$branch' starts with '-'" \
                "git check-ref-format accepts that, but the host-side git commands this" \
                "feature runs would read it as an option."
            ;;
        /* | */*/ | */)
            worktree_fail "branch name '$branch' has a leading or trailing '/'"
            ;;
    esac
    IFS='/' read -r -a comps <<<"$branch"
    for comp in ${comps[@]+"${comps[@]}"}; do
        if [[ "$comp" == "." || "$comp" == ".." ]]; then
            worktree_fail "branch name '$branch' contains a '$comp' path component" \
                "the worktree's on-disk path is derived from the branch name, so that" \
                "would resolve outside \$HOME/.agent/worktrees."
        fi
    done
    if ! git check-ref-format "refs/heads/agent/$branch" 2>/dev/null; then
        worktree_fail "'agent/$branch' is not a valid git branch name" \
            "(git check-ref-format refused it)"
    fi
}

# worktree_preflight: validate the flag and the repository, and derive
# every path this feature uses. Runs before the image build and before any
# container starts, so a repository that cannot support the flow is
# refused in the first second rather than after a full agent session.
worktree_preflight() {
    local top raw common key
    if ! command -v git >/dev/null 2>&1; then
        worktree_fail "no git binary on the host" \
            "the branch, worktree, review and commit steps all run host-side."
    fi
    worktree_validate_branch "$WORKTREE_BRANCH"

    top="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [[ -z "$top" ]]; then
        worktree_fail "$PROJECT_DIR is not a git repository"
    fi
    if [[ "$top" != "$PROJECT_DIR" ]]; then
        worktree_fail "the project dir is not the repository root" \
            "repository root is $top" \
            "re-run with --project-dir $top"
    fi

    # Refuse a project dir that is itself a linked worktree or uses an
    # external gitdir: the new worktree's metadata would live under a
    # <main>/.git that is not inside the bound tree, so the mask could not
    # cover it without --allow-external-gitdir and the container would see
    # an unmasked path to the real history.
    raw="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null)" || raw=""
    common=""
    if [[ -n "$raw" ]]; then
        [[ "$raw" == /* ]] || raw="$PROJECT_DIR/$raw"
        common="$(readlink -f "$raw" 2>/dev/null)" || common=""
    fi
    if [[ "$common" != "$PROJECT_DIR/.git" ]]; then
        worktree_fail "$PROJECT_DIR is not a main checkout" \
            "its shared git dir is ${common:-unresolvable}, not $PROJECT_DIR/.git" \
            "--worktree must run against the main checkout: the new worktree's metadata" \
            "lives under <main>/.git/worktrees/ and has to sit inside the masked tree."
    fi

    # A commit identity is needed by the host-side commit at the very end.
    # Checking it now turns "you ran an agent for an hour and cannot commit
    # the result" into a one-line refusal before anything starts.
    if ! git -C "$PROJECT_DIR" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
        worktree_fail "this host has no git commit identity configured" \
            "the approved commit is made here, on the host, with your own identity:" \
            "  git config --global user.name  'Your Name'" \
            "  git config --global user.email 'you@example.com'"
    fi

    # <project> is the checkout's basename plus a short digest of its
    # absolute path. The basename alone (as originally sketched) collides
    # across two checkouts sharing a directory name, but in different full,
    # paths, e.g. /path/to/project1 and /path/also-to/project1. The collision
    # is silent and dangerous: it looks exactly like a legitimate resume, so
    # one repository's agent would reattach the other's worktree and the
    # approved commit would land on the wrong project's branch.
    # The 8-character sha-hash uniquely identifies the full path.
    key="$(basename "$top")-$(printf '%s' "$top" | sha256sum | cut -c1-8)"
    WORKTREE_REPO_ROOT="$top"
    WORKTREE_REF="agent/$WORKTREE_BRANCH"
    WORKTREE_DIR="$HOME/.agent/worktrees/$key/$WORKTREE_BRANCH"
    # Lock lives beside the per-project directory, never inside the
    # worktree: the worktree is bound into the container, its parent is
    # not, so the agent can neither read nor forge this. Keyed by a digest
    # of the branch name so "feat/x" and "feat-x" cannot share a lock.
    WORKTREE_LOCK="$HOME/.agent/worktrees/$key/.lock-$(printf '%s' "$WORKTREE_BRANCH" | sha256sum | cut -c1-12)"
    # Persistent log of rendered pre-review tree state: appended on every
    # pass (initial render, pre-commit recheck) so a hash mismatch can be
    # diffed after the fact. Lives beside the worktree, never inside it --
    # the parent is not bound into the container, so the agent can neither
    # read nor forge this log, and it survives a kept/rejected worktree.
    WORKTREE_PREREVIEW_STATE_LOG="$HOME/.agent/worktrees/$key/.state-render.log"
    WORKTREE_PROJECT_MODE=ro
    WORKTREE_MSG_HOST=""
}

# worktree_confirm_readonly_project: worktree mode changes this sandbox's
# containment posture in one visible way -- the main checkout's working
# tree stops being writable, or stops being reachable at all -- so it is
# confirmed interactively, every run, on /dev/tty. Same channel and same
# reasoning as bind_scope_check() (functions/binds.sh): stdin is the
# agent's own input stream, so a confirmation read from stdin could be
# answered by the thing being confined. Read-only is the default and the
# safe answer.
#
# Three postures, recorded in WORKTREE_PROJECT_MODE:
#   ro   (default) -- the main checkout's working tree is bound read-only.
#   rw   -- the main checkout's working tree is bound read-write, as a
#           deliberate per-run keystroke, never a flag and never
#           unattended.
#   deny -- the main checkout's working tree is not bound at all. This
#           does not hide the repository's history -- every .git stays
#           read-only-masked in all three cases regardless of this
#           choice (docs/worktree-mode.md has the full reasoning); "deny"
#           withholds only the main checkout's untracked/ignored content
#           (notes, .env, build output) that a worktree does not carry.
worktree_confirm_readonly_project() {
    local reply
    # -r alone is not a reliable predictor: /dev/tty exists and is
    # world-readable even with no controlling terminal, where opening it
    # fails with ENXIO. Folding the printf into the if's condition (not a
    # statement in its body) is what keeps that failure from tripping the
    # caller's `set -e`.
    if [[ -r /dev/tty ]]; then
        if printf '%s\n' \
            "" \
            "--worktree $WORKTREE_BRANCH" \
            "  worktree (read-write): $WORKTREE_DIR" \
            "  branch:                $WORKTREE_REF" \
            "  main checkout:         $PROJECT_DIR  -> READ-ONLY" \
            "" \
            "The agent works only in the worktree. The main checkout is mounted read-only" \
            "so nothing it does can modify your working files; every .git stays read-only" \
            "in every case, so it cannot rewrite history no matter which option you choose." \
            "" 2>/dev/null >/dev/tty; then
            if printf 'Mount %s [r]ead-only, read-[w]rite, or [d]eny access to it entirely? ' \
                "$PROJECT_DIR" 2>/dev/null >/dev/tty; then
                read -r reply </dev/tty 2>/dev/null || reply=""
                case "$reply" in
                    [wW]*)
                        WORKTREE_PROJECT_MODE=rw
                        echo "info: main checkout $PROJECT_DIR mounted READ-WRITE by explicit confirmation; edits" >&2
                        echo "      it makes there are outside the worktree and will NOT appear in the approval" >&2
                        echo "      diff or reach $WORKTREE_REF." >&2
                        return 0
                        ;;
                    [yYrR]*)
                        # shellcheck disable=SC2034  # WORKTREE_PROJECT_MODE is read by sandbox.sh when it builds BINDS, and by generate_limitations_file (functions/agents.sh)
                        WORKTREE_PROJECT_MODE=ro
                        return 0
                        ;;
                    [nNdD]*)
                        # shellcheck disable=SC2034  # see above
                        WORKTREE_PROJECT_MODE=deny
                        echo "info: main checkout $PROJECT_DIR NOT mounted by explicit denial; the agent sees only" >&2
                        echo "      the worktree plus $PROJECT_DIR/.git (needed for git itself). untracked/ignored" >&2
                        echo "      files that exist only in the main checkout (notes, .env, build output) are not" >&2
                        echo "      reachable this session." >&2
                        return 0
                        ;;
                esac
            fi
        fi
    fi
    worktree_fail "the read-only mount of $PROJECT_DIR was not confirmed" \
        "worktree mode needs a terminal: it confirms this mount before the run and" \
        "requires an explicit approval on /dev/tty before it commits anything." \
        "there is no unattended path, by design."
}

# worktree_ref_checkout_path: the worktree path that currently has
# refs/heads/$WORKTREE_REF checked out, empty when no worktree does.
worktree_ref_checkout_path() {
    local line path=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) path="${line#worktree }" ;;
            "branch refs/heads/$WORKTREE_REF")
                printf '%s\n' "$path"
                return 0
                ;;
        esac
    done < <(git -C "$WORKTREE_REPO_ROOT" worktree list --porcelain 2>/dev/null)
    return 0
}

# worktree_lock_acquire: guard one worktree against a second concurrent
# run -- git's own worktree-creation check cannot see a second run that
# RESUMES an existing worktree, which is exactly what a crashed prior run
# leaves behind. See docs/worktree-mode.md ("Concurrency") for why
# agent/<branch>'s existence and `git worktree lock` cannot substitute
# for this.
#
# mkdir is the atomic primitive (it fails if the directory exists); the
# owner pid inside distinguishes a live run from one that was SIGKILLed,
# the same technique and the same acknowledged PID-reuse caveat as
# reap_orphaned_run_dirs() (functions/run-dir.sh). The owner HOST is
# recorded next to it because `kill -0` is meaningless across machines:
# $HOME can be a network mount, in which case two hosts share this lock
# path, and a foreign-host lock is therefore never taken over
# automatically.
#
# Releasing is registered here, on success, rather than wired into any
# other module's teardown: the hook exists exactly when the lock does.
worktree_lock_acquire() {
    local pid host this_host
    this_host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    mkdir -p "$(dirname "$WORKTREE_LOCK")"
    if mkdir "$WORKTREE_LOCK" 2>/dev/null; then
        echo "$$" >"$WORKTREE_LOCK/pid"
        echo "$this_host" >"$WORKTREE_LOCK/host"
        WORKTREE_LOCK_HELD=1
        register_cleanup_hook worktree_lock_release
        return 0
    fi
    pid="$(cat "$WORKTREE_LOCK/pid" 2>/dev/null)" || pid=""
    host="$(cat "$WORKTREE_LOCK/host" 2>/dev/null)" || host=""
    if [[ -n "$host" && "$host" != "$this_host" ]]; then
        worktree_fail "this worktree is locked by a run on another host: $host (pid ${pid:-unknown})" \
            "worktree: $WORKTREE_DIR" \
            "$HOME is shared between hosts, so whether that run is still alive cannot be" \
            "checked from here. Wait for it, or -- only if you know it is dead -- remove:" \
            "  rm -rf $WORKTREE_LOCK"
    fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        worktree_fail "another sandbox run (pid $pid) is already using this worktree" \
            "worktree: $WORKTREE_DIR" \
            "wait for that run to finish, or use a different --worktree branch."
    fi
    echo "worktree: taking over a stale lock (owner pid ${pid:-unknown} is gone)" >&2
    echo "$$" >"$WORKTREE_LOCK/pid"
    echo "$this_host" >"$WORKTREE_LOCK/host"
    WORKTREE_LOCK_HELD=1
    register_cleanup_hook worktree_lock_release
}

# worktree_lock_release: registered as a cleanup hook (functions/cleanup.sh)
# by worktree_lock_acquire() above and run on EXIT, so it is written
# defensively -- the hook may also be invoked directly, and may run after
# an earlier release.
worktree_lock_release() {
    if [[ "${WORKTREE_LOCK_HELD:-0}" -eq 1 && -n "${WORKTREE_LOCK:-}" && -d "$WORKTREE_LOCK" ]]; then
        rm -rf "$WORKTREE_LOCK"
        WORKTREE_LOCK_HELD=0
    fi
}

# worktree_prepare: the branch-collision policy, evaluated before the
# container runs.
#
#   1. worktree directory and branch both exist and the branch is checked
#      out at exactly that directory -> RESUME. A previous run crashed
#      before review; reattach instead of recreating.
#   2. the branch exists but is not checked out at that directory (landed
#      earlier and cleaned up, moved by hand, checked out elsewhere) ->
#      REFUSE, naming the ref's commit and location. Which case it is
#      cannot be told apart from here and guessing wrong loses work.
#   3. the directory exists but the branch does not -> REFUSE, same
#      reasoning.
#   4. neither exists -> CREATE.
#
# The lock is taken FIRST, before the state below is sampled: sampling and
# then locking leaves a window in which another sandbox run creates or
# removes the worktree, and this run would then act on a state that no
# longer holds. The destructive step (`git worktree add -b`) is
# additionally atomic on git's side, so the worst case was a confusing
# error rather than damage -- but a lock taken after the read it is
# supposed to protect is not a lock.
worktree_prepare() {
    local ref_exists=0 dir_exists=0 checked_out sha where
    worktree_lock_acquire
    if git -C "$WORKTREE_REPO_ROOT" show-ref --verify --quiet "refs/heads/$WORKTREE_REF"; then
        ref_exists=1
    fi
    if [[ -d "$WORKTREE_DIR" ]]; then
        dir_exists=1
    fi
    checked_out="$(worktree_ref_checkout_path)"

    if [[ "$ref_exists" -eq 1 && "$dir_exists" -eq 1 && "$checked_out" == "$WORKTREE_DIR" ]]; then
        if ! git -C "$WORKTREE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
            worktree_fail "$WORKTREE_DIR is registered for $WORKTREE_REF but is not a usable worktree" \
                "repair or remove it yourself:" \
                "  git -C $WORKTREE_REPO_ROOT worktree remove --force $WORKTREE_DIR"
        fi
        echo "worktree: resuming $WORKTREE_REF in $WORKTREE_DIR (left by an earlier run)" >&2
        return 0
    fi

    if [[ "$ref_exists" -eq 1 ]]; then
        sha="$(git -C "$WORKTREE_REPO_ROOT" rev-parse --short "refs/heads/$WORKTREE_REF" 2>/dev/null)" || sha="unknown"
        where="not checked out in any worktree"
        [[ -n "$checked_out" ]] && where="checked out at $checked_out"
        worktree_fail "branch $WORKTREE_REF already exists (at $sha, $where)" \
            "expected worktree: $WORKTREE_DIR ($([[ "$dir_exists" -eq 1 ]] && echo present || echo missing))" \
            "that is either a landed run whose worktree was cleaned up, a worktree moved" \
            "by hand, or a stale ref -- not guessing which. Pick a different --worktree" \
            "branch, or remove the ref yourself:" \
            "  git -C $WORKTREE_REPO_ROOT branch -D $WORKTREE_REF"
    fi

    if [[ "$dir_exists" -eq 1 ]]; then
        worktree_fail "$WORKTREE_DIR exists but branch $WORKTREE_REF does not" \
            "leftover directory from a discarded run, or something else entirely --" \
            "not guessing. Inspect it and remove it yourself:" \
            "  rm -rf $WORKTREE_DIR"
    fi

    mkdir -p "$(dirname "$WORKTREE_DIR")"
    # git's own exclusivity check lives here: if HEAD's branch, or
    # agent/<branch>, is already checked out elsewhere, this refuses rather
    # than racing.
    if ! git -C "$WORKTREE_REPO_ROOT" worktree add -b "$WORKTREE_REF" "$WORKTREE_DIR" HEAD; then
        worktree_fail "git worktree add refused to create $WORKTREE_DIR" \
            "nothing was created and no branch was moved."
    fi
    echo "worktree: created $WORKTREE_DIR on $WORKTREE_REF from HEAD" >&2
}

# worktree_message_template: the agreed commit-message shape. One copy,
# used by both the instructions the agent reads and the fallback prompt,
# so the two cannot drift apart (same anti-drift reasoning as
# tests/git-escape/fixtures.sh).
worktree_message_template() {
    cat <<'EOF'
<Title>

Issue:
<...>

Solution:
<...>
EOF
}

# worktree_render_state OUT LABEL: the ONE place that computes the
# committable state of the worktree. What it renders -- the porcelain
# status, the tracked diff against HEAD, and the per-file diff of every
# untracked, non-ignored path -- is by definition everything a commit from
# this worktree would capture, because `git add -A` stages exactly that
# set. Both consumers are derived from the SAME bytes this function
# produces, never from a second, independently written computation over
# the same tree: worktree_build_diff_state records it as the baseline the
# approval covers, and worktree_current_state_hash hashes a fresh render
# before the commit to decide whether the tree still matches. One renderer
# means approval and commit can never disagree about what the state is.
#
# LABEL names the caller's purpose ("initial", "recheck"); it goes into the
# persistent log header so several appends can be told apart afterwards.
#
# Invariants this function owns, both load-bearing for the security
# posture above:
#
# - Nothing can be committed that the diff state did not render. The
#   rendered set is the set `git add -A` will stage, with no cap on the
#   number of untracked files and no truncation of the file, because a
#   review that silently stops short is a review of a different change
#   than the one that lands.
# - -z on ls-files and core.quotePath=false on status are load-bearing,
#   not cosmetic: by default git C-quotes any path holding a non-ASCII or
#   control byte, quotes included, and that quoted string names no file --
#   so the per-file diff failed while the header still printed, and a
#   reviewer saw a filename and concluded the file was empty.
#
# Deliberately does NOT stage anything first. `git add -A -N` would make
# one `git diff HEAD` cover untracked files too, but it writes to the
# MAIN repository's shared object store (measured: docs/worktree-mode.md,
# "Commit path"). Untracked files are diffed with --no-index instead,
# which never opens the object database for writing, so a rejected run
# leaves the main repository's objects and index untouched.
#
# `git diff --no-index` exits 1 when its two inputs differ, which is the
# normal case here -- every untracked file differs from /dev/null -- so
# only a status above 1 is a failure. That failure is fatal rather than
# swallowed: a file that cannot be rendered must never reach a commit the
# human believes they reviewed.
#
# Every completed render is appended, timestamped and labelled, to
# WORKTREE_PREREVIEW_STATE_LOG ($HOME/.agent/worktrees/<key>/.state-render.log,
# outside the worktree and never bound into the container). This is the
# debugging record for the initial/recheck hashes: when worktree_commit
# reports a mismatch, the "initial" and "recheck" blocks in this log are
# the two states that were compared, diffable after the fact from outside
# the sandbox. The log is host-only (unbound path), append-only, and
# grows by one block per render -- a handful of kilobytes per run.
worktree_render_state() {
    local out="$1" label="$2" list="${RUN_DIR:?RUN_DIR must exist before state is rendered}/render-untracked.z"
    local f qf rc
    # The untracked list is captured before the block below rather than
    # streamed into it from a process substitution: a substitution's exit
    # status is unreachable, so a failing `ls-files` would look exactly
    # like "there are no untracked files" -- and `git add -A` would then
    # commit every one of them unreviewed.
    if ! git -C "$WORKTREE_DIR" ls-files --others --exclude-standard -z >"$list"; then
        worktree_fail "cannot list the untracked files in $WORKTREE_DIR" \
            "the worktree remains intact and nothing was committed."
    fi
    {
        echo "# status"
        # Every input below is a hard failure, never a swallowed error.
        # The commit stages whatever is in the tree; the review is the
        # only thing standing between that and the human, so a review
        # that is quietly missing a section is worse than no review at
        # all.
        if ! git -C "$WORKTREE_DIR" -c core.quotePath=false status --porcelain; then
            worktree_fail "cannot read the status of $WORKTREE_DIR" \
                "the worktree remains intact and nothing was committed."
        fi
        echo
        echo "# diff of tracked files against HEAD"
        if ! git -C "$WORKTREE_DIR" diff HEAD; then
            worktree_fail "cannot diff $WORKTREE_DIR against HEAD" \
                "the worktree remains intact and nothing was committed."
        fi
        while IFS= read -r -d '' f; do
            # %q rather than the raw name: with -z the path arrives
            # verbatim, and one containing a newline would otherwise
            # forge further header lines inside the text the human reads.
            printf -v qf '%q' "$f"
            echo
            echo "# new file: $qf"
            rc=0
            git -C "$WORKTREE_DIR" diff --no-index -- /dev/null "$f" || rc=$?
            # --no-index reports 1 for "they differ", which is the whole
            # point of the call; anything above that is a real failure.
            if [[ "$rc" -gt 1 ]]; then
                worktree_fail "cannot render $qf in $WORKTREE_DIR (git diff exited $rc)" \
                    "the worktree is intact and nothing was committed." \
                    "a change is offered for approval only when every part of it can be shown."
            fi
        done <"$list"
    } >"$out"
    if [[ -n "${WORKTREE_PREREVIEW_STATE_LOG:-}" ]]; then
        {
            echo "==== $(date '+%Y-%m-%dT%H:%M:%S%z') pid=$$ label=$label ===="
            cat -- "$out"
            echo
        } >>"$WORKTREE_PREREVIEW_STATE_LOG"
    fi
}

# worktree_sanitize_display: stdin -> stdout, minus the control bytes a
# terminal acts on rather than prints.
#
# The commit message and the diff body are agent-authored bytes on their
# way to the human's terminal, and a terminal executes what it is sent:
# "\e[2J\e[H" clears the screen and homes the cursor, so agent content can
# end by repainting the display with a short, innocent-looking summary and
# a counterfeit "[y/N]" prompt -- the human then approves a change they
# never saw. File content and the message file are the two channels.
# Filenames are not one: git C-quotes every path holding a control or
# non-ASCII byte before printing it.
#
# `cat -v` would do this too and is deliberately not used: it renders every
# byte >= 0x80 as "M-" noise, which turns any UTF-8 diff into garbage. A
# byte-oriented tr (LC_ALL=C) cannot touch a multibyte sequence, because
# every one of its bytes is >= 0x80 and no range below reaches there. The
# ranges delete 000-010 and 013-037 plus 177 (DEL), so exactly 011 (tab)
# and 012 (newline) survive.
#
# 015 (CR) is deleted with the rest, which costs nothing and closes a real
# hole. A lone CR returns the cursor to column 0, so the remainder of the
# line overprints what was already drawn: a diff body of
# "+ os.system(...)\r+ # harmless comment" is displayed as the comment
# alone. Hiding one line is the whole attack -- it does not need to repaint
# the screen. Nothing is lost on ordinary content either, since this
# filters the DISPLAY, not the file: a CRLF line still ends at its LF.
worktree_sanitize_display() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# worktree_current_state_hash: hash a FRESH render of the state, using the
# same worktree_render_state bytes the approval covers -- so the
# comparison in worktree_commit is between two outputs of one function,
# never between what was reviewed and a separately written hash computation.
worktree_current_state_hash() {
    local tmp="${RUN_DIR:?RUN_DIR must exist before state is rendered}/recheck-state"
    worktree_render_state "$tmp" "recheck"
    sha256sum -- "$tmp" | cut -d' ' -f1
}

# worktree_build_diff_state OUT: render the pending change once via
# worktree_render_state, then hash THOSE EXACT BYTES. The hash is taken
# over the file the human is shown, not over a second computation, so the
# approval answers "is this still the tree behind THIS file?".
worktree_build_diff_state() {
    local out="$1"
    worktree_render_state "$out" "initial"
    chmod 600 "$out"
    WORKTREE_DIFF_STATE_HASH="$(sha256sum -- "$out" | cut -d' ' -f1)"
}

# worktree_has_changes: anything at all for a commit to capture, ignoring
# .gitignore'd content (which never enters the commit).
worktree_has_changes() {
    local st
    st="$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)" || st=""
    [[ -n "$st" ]]
}

# worktree_generate_message OUT STATE: ask the agent to describe
# the change it just made, for the case where it left its own
# commit-message file empty. STATE is a summarized diff state of the
# repo -- worktree_render_state's output (porcelain status, tracked
# diff against HEAD, new-file diffs) -- what the model reads to write
# the message; the human review happens later, at the approval gate.
#
# This function owns only WHAT to ask. How to ask it without handing
# agent-authored text to an unsandboxed process is commit_msg_generate()'s
# job (functions/commit-message.sh): the agent runs again inside the same
# image, with its own tools switched off, its credentials present, and
# neither the project checkout nor the worktree mounted -- so nothing the
# previous agent wrote can be auto-loaded as instructions, and nothing it
# writes here can reach the host except the text a human then approves.
worktree_generate_message() {
    local out="$1" state="$2" prompt
    prompt="$(printf '%s\n' \
        "Write a git commit message for the change below." \
        "Reply with the message only -- no preamble, no code fences, no commentary." \
        "Use exactly this shape, and add an \"Additional Notes:\" block only if something" \
        "genuinely does not fit under Issue or Solution:" \
        "" \
        "$(worktree_message_template)" \
        "" \
        "The change:" \
        "")"
    prompt="$prompt
$(head -n "$WORKTREE_PROMPT_DIFF_LINES" "$state")"
    commit_msg_generate "$out" "$prompt"
}

# worktree_placeholder_message OUT: last resort, so a run whose message
# generation failed still reaches the approval gate (where the human sees
# the real diff regardless) instead of dying with the work unreviewed.
worktree_placeholder_message() {
    local out="$1"
    {
        echo "Agent changes on $WORKTREE_REF"
        echo
        echo "Issue:"
        echo "<not described: the agent left $WORKTREE_MSG_NAME empty and the"
        echo "sandboxed message generation was unavailable or failed>"
        echo
        echo "Solution:"
        echo "<see the diff>"
        echo
        echo "Files touched:"
        git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | sed 's/^/  /'
    } >"$out"
    chmod 600 "$out"
}

# worktree_resolve_message OUT STATE: agent-written file if it has
# content, sandboxed generation if not. STATE is the summarized diff
# state of the repo (worktree_render_state's output) handed to the
# generator when one is needed. Sets WORKTREE_MSG_SOURCE, which the
# approval gate shows the human -- "who wrote this message" is part of what
# is being approved.
worktree_resolve_message() {
    local out="$1" state="$2" src="${WORKTREE_MSG_HOST:-}"
    if [[ -n "$src" && -f "$src" ]] && grep -q '[^[:space:]]' "$src" 2>/dev/null; then
        cp "$src" "$out"
        chmod 600 "$out"
        WORKTREE_MSG_SOURCE="written by the agent"
        return 0
    fi
    echo "worktree: the agent left ~/$WORKTREE_MSG_NAME empty; generating a message in the sandbox" >&2
    if worktree_generate_message "$out" "$state"; then
        WORKTREE_MSG_SOURCE="generated in the sandbox (the agent left the file empty)"
        return 0
    fi
    worktree_placeholder_message "$out"
    WORKTREE_MSG_SOURCE="placeholder (agent file empty, generation failed)"
}

# worktree_approval_gate MSG STATE: mandatory. No flag, no environment
# variable and no answer other than an explicit "y" commits anything, and
# there is no unattended path at all -- a missing TTY refuses.
#
# The diff state goes to stderr so a logged run keeps the audit trail of
# what was approved; the question itself is asked on /dev/tty, because
# stdin belongs to the agent.
worktree_approval_gate() {
    local msg="$1" state="$2" total reply
    total="$(wc -l <"$state" | tr -d '[:space:]')"
    {
        echo
        echo "======================================================================"
        echo "  REVIEW: $WORKTREE_REF"
        echo "  worktree:     $WORKTREE_DIR"
        echo "  commits into: $WORKTREE_REPO_ROOT"
        echo "======================================================================"
        echo
        echo "--- proposed commit message [$WORKTREE_MSG_SOURCE] ---"
        worktree_sanitize_display <"$msg"
        echo
        echo "--- change ($total lines) ---"
        head -n "$WORKTREE_GATE_DIFF_LINES" "$state" | worktree_sanitize_display
        if [[ "$total" -gt "$WORKTREE_GATE_DIFF_LINES" ]]; then
            echo
            echo "... truncated. Full change:"
            echo "    git -C $WORKTREE_DIR status"
            echo "    git -C $WORKTREE_DIR diff HEAD"
        fi
        echo
        echo "$WORKTREE_REF is unreviewed by default: nothing has checked this diff but you."
        echo "Accepting commits it under your own git identity and makes you the owner of"
        echo "the correctness of whatever is merged out of this branch. Nothing is pushed."
        echo
    } >&2
    if [[ -r /dev/tty ]]; then
        if printf 'Commit this onto %s in %s? [y/N] ' "$WORKTREE_REF" "$WORKTREE_REPO_ROOT" 2>/dev/null >/dev/tty; then
            read -r reply </dev/tty 2>/dev/null || reply=""
            case "$reply" in
                [yY]*) return 0 ;;
                *) return 1 ;;
            esac
        fi
    fi
    worktree_fail "no terminal available to approve the commit" \
        "the worktree is intact at $WORKTREE_DIR and nothing was committed." \
        "worktree mode has no unattended approval path, by design."
}

# worktree_reject_menu: a rejected review is the human's decision, so the
# human also decides what happens to the work -- it is never silently
# deleted, and it is never silently kept either. Sets
# WORKTREE_REJECT_ACTION.
worktree_reject_menu() {
    local reply
    # shellcheck disable=SC2034  # WORKTREE_REJECT_ACTION is read by sandbox.sh's post-review case after this returns
    WORKTREE_REJECT_ACTION="keep"
    {
        echo
        echo "Not committed. The worktree is intact at:"
        echo "    $WORKTREE_DIR"
        echo
        echo "  k  keep it as it is, and exit (default) -- re-run the same --worktree"
        echo "     $WORKTREE_BRANCH later to pick it up again"
        echo "  r  re-run the agent in this same worktree now, then review again"
        echo "  d  discard it: remove the worktree and delete $WORKTREE_REF"
        echo
    } >&2
    if [[ -r /dev/tty ]]; then
        if printf 'Choose [k/r/d] ' 2>/dev/null >/dev/tty; then
            read -r reply </dev/tty 2>/dev/null || reply=""
            # shellcheck disable=SC2034  # see above: read by sandbox.sh after this returns
            case "$reply" in
                [rR]*) WORKTREE_REJECT_ACTION="rerun" ;;
                [dD]*) WORKTREE_REJECT_ACTION="discard" ;;
                *) WORKTREE_REJECT_ACTION="keep" ;;
            esac
        fi
    fi
}

# worktree_commit MSG: stage everything not ignored and commit it, on the
# host, with the host's own identity -- the human approved it and owns it.
#
# Returns 0 when the commit landed, 2 when the human asked for the state
# render and the message to be rebuilt (the tree moved under the review),
# and 1 when nothing was committed for any other reason. sandbox.sh treats every
# non-zero alike -- not committed, fall through to the reject menu -- so
# the distinction is informational, and both non-zero values are safe.
#
worktree_commit() {
    local msg="$1" now reply
    # The approval was given for one specific tree, so that tree is
    # re-hashed here rather than assumed to have stayed put.
    now="$(worktree_current_state_hash)"
    if [[ "$now" != "${WORKTREE_DIFF_STATE_HASH:-}" ]]; then
        {
            echo
            echo "worktree: $WORKTREE_DIR changed after the reviewed state was rendered."
            echo "          reviewed: ${WORKTREE_DIFF_STATE_HASH:-<none recorded>}"
            echo "          now:      $now"
            echo "          the approval you gave covers the earlier state, not this one."
            echo
            echo "  r  re-render the state, rebuild the message, then ask again"
            echo "  c  commit the current message and the current tree anyway"
            echo "  anything else: commit nothing (default)"
            echo
        } >&2
        reply=""
        if [[ -r /dev/tty ]]; then
            if printf 'Choose [r/c/N] ' 2>/dev/null >/dev/tty; then
                read -r reply </dev/tty 2>/dev/null || reply=""
            fi
        fi
        case "$reply" in
            [rR]*) return 2 ;;
            [cC]*) ;;
            *)
                echo "worktree: nothing committed; the worktree is intact at $WORKTREE_DIR" >&2
                return 1
                ;;
        esac
    fi
    if ! git -C "$WORKTREE_DIR" add -A; then
        worktree_fail "git add failed in $WORKTREE_DIR; nothing was committed"
    fi
    if git -C "$WORKTREE_DIR" diff --cached --quiet; then
        echo "worktree: nothing staged after git add -A; not committing" >&2
        return 1
    fi
    if ! git -C "$WORKTREE_DIR" commit -q -F "$msg"; then
        worktree_fail "git commit failed in $WORKTREE_DIR" \
            "the worktree is intact; nothing was committed."
    fi
}

# worktree_print_next_steps: pushing is the human's action, always. Name
# the exact command rather than describing it.
worktree_print_next_steps() {
    local remote=""
    if git -C "$WORKTREE_REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
        remote="origin"
    else
        remote="$(git -C "$WORKTREE_REPO_ROOT" remote 2>/dev/null | head -n1)"
    fi
    {
        echo
        echo "$WORKTREE_REF is a local branch in $WORKTREE_REPO_ROOT. Nothing was pushed."
        echo "    git -C $WORKTREE_REPO_ROOT log -p $WORKTREE_REF"
        if [[ -n "$remote" ]]; then
            echo "    git -C $WORKTREE_REPO_ROOT push $remote $WORKTREE_REF"
        else
            echo "    (this repository has no remote configured)"
        fi
        echo
    } >&2
}

# worktree_after_commit: the post-commit safety check. Everything not
# ignored is in the commit by construction (git add -A above), so what can
# still be in the worktree is .gitignore'd content -- reproducible by
# definition, but not this script's to delete unasked. Anything NOT ignored
# surviving a commit is an anomaly, so that case refuses removal outright
# rather than asking.
worktree_after_commit() {
    local sha leftovers ignored count size reply
    sha="$(git -C "$WORKTREE_DIR" rev-parse --short HEAD 2>/dev/null)" || sha="?"
    echo "worktree: committed $sha onto $WORKTREE_REF in $WORKTREE_REPO_ROOT" >&2

    leftovers="$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)" || leftovers=""
    if [[ -n "$leftovers" ]]; then
        {
            echo "worktree: NOT removing $WORKTREE_DIR -- uncommitted content survived the commit:"
            printf '%s\n' "$leftovers" | sed 's/^/    /'
        } >&2
        worktree_print_next_steps
        return 0
    fi

    ignored="$(git -C "$WORKTREE_DIR" status --porcelain --ignored 2>/dev/null | sed -n 's/^!! //p')" || ignored=""
    if [[ -n "$ignored" ]]; then
        count="$(printf '%s\n' "$ignored" | wc -l | tr -d '[:space:]')"
        size="$(du -sh "$WORKTREE_DIR" 2>/dev/null | cut -f1)"
        reply=""
        {
            echo
            echo "The commit is in. $WORKTREE_DIR still holds $count ignored entr(y|ies) (${size:-size unknown} total):"
            printf '%s\n' "$ignored" | head -n 20 | sed 's/^/    /'
            echo
        } >&2
        if [[ -r /dev/tty ]]; then
            if printf 'Remove the worktree and that ignored content? [y/N] ' 2>/dev/null >/dev/tty; then
                read -r reply </dev/tty 2>/dev/null || reply=""
            fi
        fi
        case "$reply" in
            [yY]*)
                if ! git -C "$WORKTREE_REPO_ROOT" worktree remove --force "$WORKTREE_DIR"; then
                    echo "worktree: could not remove $WORKTREE_DIR; it is left in place" >&2
                    worktree_print_next_steps
                    return 0
                fi
                ;;
            *)
                echo "worktree: keeping $WORKTREE_DIR" >&2
                worktree_print_next_steps
                return 0
                ;;
        esac
    else
        if ! git -C "$WORKTREE_REPO_ROOT" worktree remove "$WORKTREE_DIR"; then
            echo "worktree: could not remove $WORKTREE_DIR; it is left in place" >&2
            worktree_print_next_steps
            return 0
        fi
    fi
    git -C "$WORKTREE_REPO_ROOT" worktree prune
    echo "worktree: removed $WORKTREE_DIR ($WORKTREE_REF kept)" >&2
    worktree_print_next_steps
}

# worktree_discard: the human rejected the work AND asked for it to go
# away. The worktree is removed outright, but the branch is deleted with
# `git branch -d`, not -D: -d is git's own "this would lose commits" check,
# and it is the difference between discarding an unreviewed session and
# silently deleting a commit an earlier accepted round already landed on
# this branch. If -d refuses, the ref is kept and the human is told exactly
# what to run.
worktree_discard() {
    if ! git -C "$WORKTREE_REPO_ROOT" worktree remove --force "$WORKTREE_DIR" 2>/dev/null; then
        rm -rf "$WORKTREE_DIR"
    fi
    git -C "$WORKTREE_REPO_ROOT" worktree prune
    if git -C "$WORKTREE_REPO_ROOT" branch -d "$WORKTREE_REF" >/dev/null 2>&1; then
        echo "worktree: discarded $WORKTREE_DIR and deleted $WORKTREE_REF" >&2
        return 0
    fi
    {
        echo "worktree: discarded $WORKTREE_DIR, but KEPT branch $WORKTREE_REF:"
        echo "          it carries commits that are not merged anywhere else, so deleting it"
        echo "          would lose them. Delete it yourself if that is what you want:"
        echo "            git -C $WORKTREE_REPO_ROOT branch -D $WORKTREE_REF"
    } >&2
}

# worktree_report_keep / worktree_report_crash: the two paths that end a
# run with the worktree deliberately left intact.
worktree_report_keep() {
    {
        echo
        echo "worktree kept: $WORKTREE_DIR (branch $WORKTREE_REF, nothing committed)"
        echo "    inspect: git -C $WORKTREE_DIR status"
        echo "    resume:  re-run with --worktree $WORKTREE_BRANCH"
        echo "    drop:    git -C $WORKTREE_REPO_ROOT worktree remove --force $WORKTREE_DIR &&"
        echo "             git -C $WORKTREE_REPO_ROOT branch -D $WORKTREE_REF"
        echo
    } >&2
}

# A run that never reached the gate is never discarded and never
# auto-committed: it is left exactly as the container left it, for
# inspection, and a later --worktree run on the same branch resumes it.
worktree_report_crash() {
    local rc="$1"
    {
        echo
        echo "worktree: the container exited $rc -- the approval gate was NOT reached."
        echo "          $WORKTREE_DIR is left intact and nothing was committed."
        echo "    inspect: git -C $WORKTREE_DIR status"
        echo "    resume:  re-run with --worktree $WORKTREE_BRANCH"
        echo
    } >&2
}
