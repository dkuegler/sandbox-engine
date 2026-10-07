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
#   WORKTREE_MSG_HOST      host path of the agent's commit-message file,
#                          kept beside the worktree across sessions until a
#                          commit lands or the worktree is discarded
#   WORKTREE_MSG_START_HASH
#                          hash of that file as the current agent session
#                          started (worktree_message_snapshot), so the gate
#                          can name a message this session left unchanged
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
    local top raw common key bkey
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
    bkey="$(printf '%s' "$WORKTREE_BRANCH" | sha256sum | cut -c1-12)"
    WORKTREE_LOCK="$HOME/.agent/worktrees/$key/.lock-$bkey"
    # Persistent log of rendered pre-review tree state: appended on every
    # pass (initial render, pre-commit recheck) so a hash mismatch can be
    # diffed after the fact. Lives beside the worktree, never inside it --
    # the parent is not bound into the container, so the agent can neither
    # read nor forge this log, and it survives a kept/rejected worktree.
    WORKTREE_PREREVIEW_STATE_LOG="$HOME/.agent/worktrees/$key/.state-render.log"
    WORKTREE_PROJECT_MODE=ro
    # The agent's proposed commit message belongs to the worktree, not to
    # one run: a re-run from the reject menu, or a later run resuming a
    # kept or crashed worktree, starts from what the earlier session wrote.
    # Beside the worktree like the lock, keyed the same way; only this one
    # file is bound into the container (configure_agent, functions/agents.sh),
    # never its directory. No ref component may start with ".", so no
    # branch's worktree directory can take this name.
    WORKTREE_MSG_HOST="$HOME/.agent/worktrees/$key/.commit-message-$bkey"
    WORKTREE_MSG_START_HASH=""
    # Agent-created config candidates are decided per file at the approval
    # gate; these are the outcome arrays, defined from the start so
    # worktree_commit is behavior-identical when it is reached without a
    # gate pass (tests, crash resume).
    WORKTREE_CONFIG_EXCLUDE=()
    WORKTREE_CONFIG_DELETE=()
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
#           (scratch, .env, build output) that a worktree does not carry.
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
            "  main checkout:         $PROJECT_DIR" \
            "" \
            "The agent works only in the worktree. The main checkout is mounted read-only" \
            "so nothing it does can modify your working files; every .git stays read-only" \
            "in every case, so it cannot rewrite history no matter which option you choose." \
            "" \
            "[n] does not hide the repository. It leaves the main checkout's WORKING TREE" \
            "unmounted, while $PROJECT_DIR/.git -- and every nested repository's .git --" \
            "stays mounted read-only exactly as in the other two options, so the full" \
            "tracked history stays readable. What [n] withholds is the untracked and" \
            "ignored content that exists only in the main checkout (scratch, .env, build" \
            "output) and that a worktree does not carry." \
            "" 2>/dev/null >/dev/tty; then
            if printf 'Mount the %s (main) working tree [r]ead-only, read-[w]rite, or do [n]ot mount it? ' \
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
                        echo "info: main checkout $PROJECT_DIR working tree NOT mounted by explicit denial;" >&2
                        echo "      the agent sees the worktree plus $PROJECT_DIR/.git, read-only (git itself" >&2
                        echo "      needs it), so tracked history stays readable. untracked/ignored files that" >&2
                        echo "      exist only in the main checkout (scratch, .env, build output) are not" >&2
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

# worktree_message_file_ensure [reset]: make WORKTREE_MSG_HOST a private
# regular file, creating it if absent and emptying it on "reset". It is
# bound read-write into the container, and a bind follows a symlinked
# source to its target, so a link here would hand the agent write access
# to whatever it names: anything but a regular file refuses the run rather
# than being followed, replaced or guessed about. Its directory is never
# bound, so nothing inside the container can plant one; this is the guard
# against everything outside it. Runs again right before the bind, because
# the image build sits between worktree_prepare and configure_agent.
worktree_message_file_ensure() {
    local f="${WORKTREE_MSG_HOST:?worktree_preflight sets WORKTREE_MSG_HOST}"
    # -L first: -f follows a link and would accept a link to a regular file.
    if [[ -L "$f" ]] || { [[ -e "$f" ]] && [[ ! -f "$f" ]]; }; then
        worktree_fail "$f is not a regular file" \
            "it holds the agent's proposed commit message and is bound read-write into" \
            "the container, so a link or special file there is never followed." \
            "Inspect it and remove it yourself; the next run creates a fresh one."
    fi
    if [[ "${1:-}" == reset || ! -e "$f" ]]; then
        (umask 077 && : >"$f") || worktree_fail "could not create $f"
    fi
    chmod 600 "$f" || worktree_fail "could not make $f private"
}

# worktree_message_file_remove: the message file's lifecycle ends with the
# worktree's work -- a landed commit or a discard. Never fails its caller:
# by then the commit has landed or the worktree is gone, so a leftover is
# reported rather than fatal. rm on a link removes the link, never its
# target.
worktree_message_file_remove() {
    local f="${WORKTREE_MSG_HOST:-}"
    [[ -n "$f" ]] || return 0
    rm -f -- "$f" 2>/dev/null \
        || echo "worktree: could not remove the spent commit message $f; remove it yourself" >&2
    return 0
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
#
# The agent's commit-message file follows the same policy: RESUME keeps
# it, so the resumed session starts from the message the earlier one
# wrote; CREATE empties it, because anything left there belonged to an
# earlier worktree on this branch name, whose work is no longer here.
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
        worktree_message_file_ensure
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
    worktree_message_file_ensure reset
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
        if ! git -C "$WORKTREE_DIR" -c core.quotePath=false status --porcelain -uall; then
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

# worktree_has_changes: anything at all this round produced that the human
# should be shown.
#
# `git status --porcelain` alone is not that set: it excludes gitignored
# files, so a round whose only product is a gitignored `.envrc` or
# `.claude/hooks/x.sh` would report "no changes", skip the approval gate
# entirely, and therefore skip the per-file config decisions the gate
# exists to make. Nothing would be committed in that case -- ignored files
# are not staged -- but the human would never be told the files are there,
# which is the part that matters for a config plant. So a config-shaped
# untracked path counts as a change even when git would ignore it, and so
# does a failure to list them: the gate then runs and refuses on the same
# failure, loudly, instead of this check quietly skipping it.
worktree_has_changes() {
    local st cand="${RUN_DIR:-}/has-changes-candidates.z"
    st="$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)" || st=""
    [[ -n "$st" ]] && return 0
    [[ -n "${RUN_DIR:-}" ]] || return 0
    config_shaped_untracked "$WORKTREE_DIR" "$cand" || return 0
    [[ -s "$cand" ]]
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
        "Use exactly this shape, and add an \"Additional scratch:\" block only if something" \
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

# worktree_message_snapshot: hash the agent's message file as an agent
# session starts. The file outlives sessions, so "written by the agent" no
# longer tells the human whether the message was written for the change
# under review; worktree_resolve_message compares against this hash to
# name a message this session left untouched. An unreadable file records
# no hash, which only ever drops that note, never adds it.
worktree_message_snapshot() {
    WORKTREE_MSG_START_HASH="$(sha256sum -- "${WORKTREE_MSG_HOST:-}" 2>/dev/null | cut -d' ' -f1)" \
        || WORKTREE_MSG_START_HASH=""
}

# worktree_resolve_message OUT STATE: agent-written file if it has
# content, sandboxed generation if not. STATE is the summarized diff
# state of the repo (worktree_render_state's output) handed to the
# generator when one is needed. Sets WORKTREE_MSG_SOURCE, which the
# approval gate shows the human -- "who wrote this message" is part of what
# is being approved, and so is "when": a message whose bytes match
# worktree_message_snapshot's hash was carried over from an earlier
# session and may not describe what that session added.
worktree_resolve_message() {
    local out="$1" state="$2" src="${WORKTREE_MSG_HOST:-}"
    if [[ -n "$src" && -f "$src" ]] && grep -q '[^[:space:]]' "$src" 2>/dev/null; then
        cp "$src" "$out"
        chmod 600 "$out"
        if [[ -n "${WORKTREE_MSG_START_HASH:-}" \
            && "$(sha256sum -- "$out" | cut -d' ' -f1)" == "$WORKTREE_MSG_START_HASH" ]]; then
            WORKTREE_MSG_SOURCE="written by the agent in an earlier session, unchanged in this one"
        else
            WORKTREE_MSG_SOURCE="written by the agent"
        fi
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

# worktree_use_color: color only when the review is going to a terminal and
# the user has not opted out (https://no-color.org). A logged run (stderr
# redirected to a file) keeps plain text, so the audit trail has no escapes.
# Colors are applied strictly AFTER sanitize_agent_display: that filter
# strips ESC, so agent-authored text can never smuggle in its own sequences.
worktree_use_color() {
    [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]
}

# worktree_colorize_state: stdin -> stdout, the rendered state
# (worktree_render_state's format) with color. Status letters, "# ..."
# section headers, and diff headers/hunks/added/removed lines each get a
# color; nothing is added or dropped, so the text is the same modulo escapes.
# File-content lines are told from diff headers by tracking whether a hunk
# has started: inside a hunk a removed line "-- x" is content, not a header.
worktree_colorize_state() {
    if ! worktree_use_color; then
        cat
        return
    fi
    awk '
    BEGIN {
        E = sprintf("%c", 27)
        R = E "[0m"; B = E "[1m"; RED = E "[31m"; GRN = E "[32m"
        YEL = E "[33m"; MAG = E "[35m"; CYN = E "[36m"
        sec = ""; hunk = 0
    }
    /^# status$/                { sec = "status"; hunk = 0; print B CYN $0 R; next }
    /^# diff of tracked files/  { sec = "diff";   hunk = 0; print B CYN $0 R; next }
    /^# new file: /             { sec = "diff";   hunk = 0; print B CYN $0 R; next }
    sec == "status" {
        if ($0 == "") { sec = ""; print; next }
        x = substr($0, 1, 1); y = substr($0, 2, 1)
        if (x == "?" || y == "?")      c = MAG
        else if (x == "D" || y == "D") c = RED
        else if (x == "A")             c = GRN
        else                           c = YEL
        print c $0 R; next
    }
    sec == "diff" {
        if ($0 ~ /^diff --git /) { hunk = 0; print B $0 R; next }
        if (!hunk) {
            if ($0 ~ /^@@/) { hunk = 1; print CYN $0 R; next }
            print B $0 R; next
        }
        if ($0 ~ /^@@/)      { print CYN $0 R; next }
        if ($0 ~ /^\+/)      { print GRN $0 R; next }
        if ($0 ~ /^-/)       { print RED $0 R; next }
        print; next
    }
    { print }
    '
}

# worktree_print_change_summary: the last thing shown before the commit
# question -- every path the commit would carry, one line each, with its
# FULL path. `-uall` is what makes that true: git's default collapses an
# untracked directory into "dir/", which names no file and hides what is in
# it. Gitignored paths are not listed: `git add -A` never stages them, so
# they are not a difference the commit makes (status omits them by default).
#
# -z, captured to a file with the status checked, for the same reasons as
# worktree_render_state: C-quoted paths name no file, and a failed read
# must not look like "no changes".
worktree_print_change_summary() {
    local list="${RUN_DIR:?RUN_DIR must exist before the summary is rendered}/summary-status.z"
    local rec x y path orig label c qp n=0
    local R="" B="" RED="" GRN="" YEL="" MAG="" CYN=""
    if worktree_use_color; then
        R=$'\033[0m' B=$'\033[1m' RED=$'\033[31m' GRN=$'\033[32m'
        YEL=$'\033[33m' MAG=$'\033[35m' CYN=$'\033[36m'
    fi
    if ! git -C "$WORKTREE_DIR" -c core.quotePath=false status --porcelain -z -uall >"$list"; then
        worktree_fail "cannot list the changed files in $WORKTREE_DIR" \
            "the worktree is intact and nothing was committed."
    fi
    {
        echo
        printf '%s--- files this commit would contain (gitignored paths excluded) ---%s\n' "$B$CYN" "$R"
        while IFS= read -r -d '' rec; do
            x="${rec:0:1}" y="${rec:1:1}" path="${rec:3}" orig=""
            # A rename/copy record is followed by one more field: the old path.
            if [[ "$x" == [RC] || "$y" == [RC] ]]; then
                IFS= read -r -d '' orig || break
            fi
            if [[ "$x" == "?" ]]; then
                label="new     " c="$MAG"
            elif [[ "$x" == D || "$y" == D ]]; then
                label="deleted " c="$RED"
            elif [[ "$x" == A ]]; then
                label="added   " c="$GRN"
            elif [[ "$x" == R || "$y" == R ]]; then
                label="renamed " c="$CYN"
            else
                label="modified" c="$YEL"
            fi
            printf -v qp '%q' "$path"
            if [[ -n "$orig" ]]; then
                printf -v orig '%q' "$orig"
                qp="$orig -> $qp"
            fi
            printf '  %s%s  %s%s\n' "$c" "$label" "$qp" "$R"
            n=$((n + 1))
        done <"$list"
        if [[ "$n" -eq 0 ]]; then
            echo "  (none: only config-shaped or gitignored paths, decided above)"
        else
            printf '  %s%d file(s)%s\n' "$B" "$n" "$R"
        fi
        echo
    } >&2
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
        sanitize_agent_display <"$msg"
        echo
        echo "--- change ($total lines) ---"
        head -n "$WORKTREE_GATE_DIFF_LINES" "$state" | sanitize_agent_display | worktree_colorize_state
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
    # Agent-created config candidates: untracked paths that are
    # config-shaped (mask-entry paths, content of mask-entry directories,
    # or "[anywhere]" names at any depth). The commit must not sweep
    # them in -- each one is shown and decided individually, and only an
    # explicit "add" stages it. Every decision's default is "exclude":
    # left uncommitted in the worktree, which then survives the commit
    # (worktree_after_commit removes only a worktree with nothing left
    # over). "delete" removes the file before the commit.
    WORKTREE_CONFIG_EXCLUDE=()
    WORKTREE_CONFIG_DELETE=()
    local -a candidates=()
    # Captured to a file, with the status checked, rather than streamed
    # from a process substitution: inside "< <(...)" a failed git read
    # would be indistinguishable from "the agent created nothing", so the
    # per-file block below would be skipped and `git add -A` would sweep
    # every plant into the commit unreviewed.
    local candlist="${RUN_DIR:?RUN_DIR must exist before the gate runs}/cfg-candidates.z"
    if ! config_shaped_untracked "$WORKTREE_DIR" "$candlist"; then
        worktree_fail "cannot enumerate the agent-created config paths in $WORKTREE_DIR" \
            "the worktree is intact and nothing was committed." \
            "a change is offered for approval only when every part of it can be shown."
    fi
    while IFS= read -r -d '' f; do candidates+=("$f"); done <"$candlist"
    if [[ ${#candidates[@]} -gt 0 ]]; then
        local f rel reply2 ftype stageable
        local ignf="$RUN_DIR/cfg-candidates-ignored" ign_rc=0
        printf '%s\0' "${candidates[@]}" \
            | git -C "$WORKTREE_DIR" check-ignore -z --stdin >"$ignf" 2>/dev/null || ign_rc=$?
        # check-ignore exits 0 when it ignores something and 1 when it
        # ignores nothing; only a real failure (above 1) refuses.
        if [[ "$ign_rc" -gt 1 ]]; then
            worktree_fail "git check-ignore failed while classifying agent-created config paths" \
                "the worktree is intact at $WORKTREE_DIR and nothing was committed."
        fi
        declare -A is_ignored=()
        while IFS= read -r -d '' f; do is_ignored["$f"]=1; done <"$ignf"
        {
            echo
            echo "--- agent-created config files: shown individually, committed only on an explicit yes ---"
            echo
        } >&2
        for f in "${candidates[@]}"; do
            rel="${f#"$WORKTREE_DIR"/}"
            # The agent chose this path's TYPE as well as its name. Ask
            # what it is before reading it: a fifo would block this gate
            # forever on open(2), after the diff was shown and before the
            # commit prompt, and a symlink would display its TARGET's
            # content while `git add -A` stages the LINK -- so the human
            # would approve bytes that are not the bytes committed. The
            # agent chose the mode too: an unreadable file cannot be
            # shown either.
            ftype="$(config_display_type "$f")"
            if [[ -z "$ftype" && ! -r "$f" ]]; then
                ftype="regular file, not readable"
            fi
            {
                printf '  config-shaped untracked path: %q\n' "$rel"
                if [[ -n "${is_ignored[$f]+x}" ]]; then
                    echo "  (gitignored: never staged by git add -A either way)"
                fi
                if [[ -n "$ftype" ]]; then
                    echo "  type: $ftype"
                    echo "  content: not shown -- only a readable regular file is read here."
                else
                    echo "  content:"
                    sanitize_agent_display <"$f" | head -n 60
                    if [[ "$(wc -l <"$f" | tr -d '[:space:]')" -gt 60 ]]; then
                        printf '%s\n' "  ... (truncated; the full file is on disk)"
                    fi
                fi
            } >&2
            # "add" is offered only for a regular, not-ignored file whose
            # content was actually displayed above. For anything else the
            # choice is exclude or delete: committing content nobody could
            # be shown is the thing this whole block exists to prevent, and
            # an ignored file is never staged anyway.
            #
            # "exclude" is RECORDED only for a path `git add -A` can
            # actually stage, because that record becomes a pathspec which
            # must match afterwards. Measured: `git add -A` silently skips a
            # fifo, socket or device node, but DOES stage a symlink (mode
            # 120000). Recording an unstageable path would make the unstage
            # step fail "pathspec did not match", which the commit step
            # reads as "the tree moved under the review" -- turning an
            # agent-created fifo into a refusal of the human's own commit.
            # A gitignored path needs no record either: `git add -A` never
            # stages one.
            stageable=0
            if [[ -z "${is_ignored[$f]+x}" ]] && [[ -f "$f" || -L "$f" ]]; then
                stageable=1
            fi
            if [[ -n "${is_ignored[$f]+x}" || -n "$ftype" ]]; then
                if printf '  decide: e[x]clude: leave it in the worktree, decide later / [d]elete it [x] ' 2>/dev/null >/dev/tty; then
                    read -r reply2 </dev/tty 2>/dev/null || reply2=""
                    case "$reply2" in
                        [dD]*) WORKTREE_CONFIG_DELETE+=("$f") ;;
                        *)
                            if [[ "$stageable" -eq 1 ]]; then
                                WORKTREE_CONFIG_EXCLUDE+=("$f")
                            fi
                            ;;
                    esac
                elif [[ "$stageable" -eq 1 ]]; then
                    # No terminal: hold back anything the commit could
                    # otherwise sweep in.
                    WORKTREE_CONFIG_EXCLUDE+=("$f")
                fi
                continue
            fi
            if printf '  decide: [a]dd to the commit / e[x]clude: leave it in the worktree, decide later / [d]elete it [x] ' 2>/dev/null >/dev/tty; then
                read -r reply2 </dev/tty 2>/dev/null || reply2=""
                case "$reply2" in
                    [aA]*) : ;;
                    [dD]*) WORKTREE_CONFIG_DELETE+=("$f") ;;
                    *) WORKTREE_CONFIG_EXCLUDE+=("$f") ;;
                esac
            else
                # No terminal: the safe default is not committing it.
                WORKTREE_CONFIG_EXCLUDE+=("$f")
            fi
        done
    fi
    worktree_print_change_summary
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
    # The recorded per-file decisions about agent-created config paths are
    # applied AFTER the recheck above: the approval binds the tree the
    # review rendered, and these edits are decisions ABOUT that tree, not
    # new content. Deleted files leave the tree before staging; the
    # excluded ones are unstaged right after, so "git add -A" still
    # stages exactly the reviewed tree while the commit carries only what
    # the human added.
    local f
    for f in ${WORKTREE_CONFIG_DELETE[@]+"${WORKTREE_CONFIG_DELETE[@]}"}; do
        # -L first: deleting a symlink unlinks the LINK, never whatever
        # it points at, which may be any host file the user can read.
        if [[ -L "$f" ]]; then
            rm -f -- "$f"
        elif [[ -d "$f" ]]; then
            rm -rf -- "$f"
        else
            rm -f -- "$f"
        fi
    done
    if ! git -C "$WORKTREE_DIR" add -A; then
        worktree_fail "git add failed in $WORKTREE_DIR; nothing was committed"
    fi
    if [[ ${#WORKTREE_CONFIG_EXCLUDE[@]} -gt 0 ]]; then
        # Each excluded path is written as an explicitly LITERAL,
        # root-relative pathspec. --pathspec-file-nul only changes the
        # separator and disables C-quoting; it does NOT make the entries
        # literal, and pathspec wildcards stay live -- measured: an entry
        # "sub/*.md" unstages every sibling .md the pattern matches. The
        # agent picks these filenames, so a name that is also a glob would
        # silently drop reviewed, approved work from the commit.
        # ":(top,literal)" matches exactly the one path and nothing else.
        if ! {
            for f in "${WORKTREE_CONFIG_EXCLUDE[@]}"; do
                printf ':(top,literal)%s\0' "${f#"$WORKTREE_DIR"/}"
            done
        } >"${RUN_DIR:?}/cfg-exclude.z"; then
            worktree_fail "could not record the excluded config file list" \
                "the worktree is intact; nothing was committed."
        fi
        # No --ignore-unmatch: after `git add -A` every excluded path must
        # be staged, so a pathspec matching nothing means the tree moved
        # under the review. That is exactly the condition to refuse on,
        # not to hide.
        if ! git -C "$WORKTREE_DIR" rm -q --cached \
            --pathspec-from-file="$RUN_DIR/cfg-exclude.z" --pathspec-file-nul; then
            worktree_fail "could not unstage the config files you chose to exclude" \
                "an excluded path that is no longer staged means $WORKTREE_DIR changed" \
                "after the review was rendered; the worktree is intact and nothing was committed."
        fi
    fi
    if git -C "$WORKTREE_DIR" diff --cached --quiet; then
        echo "worktree: nothing staged after git add -A (and after unstaging the excluded config files); not committing" >&2
        return 1
    fi
    if ! git -C "$WORKTREE_DIR" commit -q -F "$msg"; then
        worktree_fail "git commit failed in $WORKTREE_DIR" \
            "the worktree is intact; nothing was committed."
    fi
    # The message has landed. A later session on this worktree (kept for
    # its ignored leftovers) starts from an empty file, not from this one.
    worktree_message_file_remove
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
# ignored is in the commit by construction (git add -A above), so anything
# NOT ignored surviving a commit is an anomaly: that case refuses removal
# outright. Gitignored content is reproducible by definition and is not
# reported or asked about; it is removed with the worktree.
worktree_after_commit() {
    local sha leftovers
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

    # Gitignored content (e.g. a notes/ directory holding the patch channel's
    # run directory) is not part of the commit and not worth a question:
    # --force removes it along with the worktree.
    if ! git -C "$WORKTREE_REPO_ROOT" worktree remove --force "$WORKTREE_DIR"; then
        echo "worktree: could not remove $WORKTREE_DIR; it is left in place" >&2
        worktree_print_next_steps
        return 0
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
    worktree_message_file_remove
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
        echo "             git -C $WORKTREE_REPO_ROOT branch -D $WORKTREE_REF &&"
        echo "             rm -f $WORKTREE_MSG_HOST"
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
