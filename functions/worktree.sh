#!/bin/bash
# --worktree <branch>: run the agent in a throwaway git worktree checked
# out on agent/<branch>, review the result on the host TTY after the
# container has exited, and commit it there -- never inside the container.
#
# WHY THE COMMIT IS HOST-SIDE. A linked worktree shares nearly all of the
# main repository's git directory: the object database
# (<main>/.git/objects), the ref namespace (refs/heads/*, packed-refs) and
# config are a single shared copy; only HEAD, index, ORIG_HEAD, logs/HEAD
# and config.worktree are per-worktree, under <main>/.git/worktrees/<name>/
# (git-worktree(1)). Measured directly against git 2.39.5: a commit made
# inside a worktree lands on the MAIN repository's refs/heads/<branch> and
# writes its objects into <main>/.git/objects, readable from the main
# checkout afterwards. A writable worktree gitdir therefore *is* write
# access to the main repository's history -- `git update-ref`, `branch -f`
# and `push --force` issued from a worktree reach every branch in the main
# repo, not just the worktree's own.
#
# So worktree mode binds the worktree's *checkout* read-write (the agent
# edits files) while all three gitdir paths stay read-only-masked exactly
# like every other gitdir (functions/git-mask.sh): <worktree>/.git (the
# "gitdir:" pointer file -- masked as a file, so the agent cannot repoint
# it either), <main>/.git/worktrees/<name>/, and <main>/.git itself. The
# agent cannot commit at all; the human commits here, after review.
#
# WHAT THIS DELIBERATELY DOES NOT DO: push. No forge credential and no real
# remote URL enters the container for this feature, and nothing in this
# file contacts a remote. An approved run commits onto agent/<branch> in
# the main repository and prints the exact `git push` command for the human
# to run themselves.
#
# Globals published for sandbox.sh / functions/agents.sh:
#   WORKTREE_BRANCH      the --worktree argument, verbatim (never invented)
#   WORKTREE_REF         "agent/$WORKTREE_BRANCH"
#   WORKTREE_REPO_ROOT   the main repository's top level (== PROJECT_DIR)
#   WORKTREE_DIR         $HOME/.agent/worktrees/<project-key>/<branch>
#   WORKTREE_PROJECT_RO  1 when the main checkout is mounted read-only
#   WORKTREE_MSG_HOST    host path of the agent's commit-message file
#   WORKTREE_REJECT_ACTION  keep|discard|rerun, set by the reject menu

# The file the agent fills in with its own proposed commit message. Mounted
# read-write at $HOME/<this> inside the container; read back on the host
# after the container exits. Outside the worktree on purpose: a message
# file inside the checkout would be swept into the very commit it
# describes.
WORKTREE_MSG_NAME='.sandbox-commit-message'

# Display/prompt caps. The review text is built once and reused by both the
# approval gate and the sandboxed message fallback, so the two can never
# disagree about what was reviewed.
WORKTREE_REVIEW_MAX_LINES=5000
WORKTREE_GATE_DIFF_LINES=400
WORKTREE_PROMPT_DIFF_LINES=1200
WORKTREE_UNTRACKED_MAX=50

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
    WORKTREE_PROJECT_RO=1
    WORKTREE_MSG_HOST=""
}

# worktree_confirm_readonly_project: worktree mode changes this sandbox's
# containment posture in exactly one visible way -- the main checkout stops
# being writable -- so it is confirmed interactively, every run, on
# /dev/tty. Same channel and same reasoning as bind_scope_check()
# (functions/binds.sh): stdin is the agent's own input stream, so a
# confirmation read from stdin could be answered by the thing being
# confined. Read-only is the default and the safe answer; making the main
# checkout writable exists only as a deliberate per-run keystroke, never as
# a flag and never unattended. Note that "w" relaxes the *working tree*
# only -- every .git stays read-only-masked in both cases, so neither
# answer lets the agent rewrite history.
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
            "in either case, so it cannot rewrite history either way." \
            "" 2>/dev/null >/dev/tty; then
            if printf 'Also mount %s read-only? [y/N] (or "w" to let the agent write the main checkout too) ' \
                "$PROJECT_DIR" 2>/dev/null >/dev/tty; then
                read -r reply </dev/tty 2>/dev/null || reply=""
                case "$reply" in
                    [wW]*)
                        WORKTREE_PROJECT_RO=0
                        echo "warning: main checkout $PROJECT_DIR mounted READ-WRITE by explicit confirmation;" >&2
                        echo "         edits it makes there are outside the worktree and will NOT appear in" >&2
                        echo "         the approval diff or reach $WORKTREE_REF." >&2
                        return 0
                        ;;
                    [yY]*)
                        # shellcheck disable=SC2034  # WORKTREE_PROJECT_RO is read by sandbox.sh when it builds BINDS, and by generate_limitations_file (functions/agents.sh)
                        WORKTREE_PROJECT_RO=1
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
# run. git's own "'<branch>' is already checked out at '<path>'" check is
# the exclusivity mechanism for worktree *creation* and still applies
# below, but it cannot see a second run that RESUMES an existing worktree
# -- and resume is exactly what a crashed prior run leaves behind. Without
# this, two agents would share one checkout and one index.
#
# Why not use the existence of agent/<branch> as the lock: a ref is the
# run's OUTPUT and outlives it (an approved run keeps the branch and
# removes the worktree), so it cannot express "a run is happening right
# now" -- it is true for a live run, a crashed run and a landed one alike.
# The one case a ref does cover, creation, is already covered atomically by
# `git worktree add -b`. `git worktree lock` is not this either: measured,
# it only blocks `worktree remove`/`prune`/`move`, and a locked worktree
# stays fully writable and committable by any process.
#
# mkdir is the atomic primitive (it fails if the directory exists); the
# owner pid inside distinguishes a live run from one that was SIGKILLed,
# the same technique and the same acknowledged PID-reuse caveat as
# reap_orphaned_run_dirs() (functions/run-dir.sh). The owner HOST is
# recorded next to it because `kill -0` is meaningless across machines:
# $HOME can be a network mount, in which case two hosts share this lock
# path and the worktree it guards, and pid 4711 being alive here says
# nothing about the run on the other host. A foreign-host lock is
# therefore never taken over automatically.
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

# worktree_build_review OUT: the exact content of the pending change,
# written once and then used for BOTH the approval gate's display and the
# fallback generator's prompt -- so the human and the model that
# proposes a message are looking at the same thing.
#
# Deliberately does NOT stage anything first. `git add -A -N` would make
# one `git diff HEAD` cover untracked files too, but measured it writes a
# loose object (the empty-blob placeholder) into the MAIN repository's
# shared object store. Nothing about merely reviewing a change should touch
# the main repository, so untracked files are diffed with --no-index
# instead, which never opens the object database for writing. A rejected
# run therefore leaves the main repository's objects and index untouched.
worktree_build_review() {
    local out="$1" f n=0
    {
        echo "# status"
        git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null
        echo
        echo "# diff of tracked files against HEAD"
        git -C "$WORKTREE_DIR" diff HEAD 2>/dev/null
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            n=$((n + 1))
            if [[ "$n" -gt "$WORKTREE_UNTRACKED_MAX" ]]; then
                echo "# ... further untracked files omitted from this review text"
                break
            fi
            echo
            echo "# new file: $f"
            git -C "$WORKTREE_DIR" diff --no-index -- /dev/null "$f" 2>/dev/null || true
        done < <(git -C "$WORKTREE_DIR" ls-files --others --exclude-standard 2>/dev/null)
    } | head -n "$WORKTREE_REVIEW_MAX_LINES" >"$out"
    chmod 600 "$out"
}

# worktree_has_changes: anything at all for a commit to capture, ignoring
# .gitignore'd content (which never enters the commit).
worktree_has_changes() {
    local st
    st="$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)" || st=""
    [[ -n "$st" ]]
}

# worktree_generate_commit_message OUT REVIEW: ask the agent to describe
# the change it just made, for the case where it left its own
# commit-message file empty.
#
# This function owns only WHAT to ask. How to ask it without handing
# agent-authored text to an unsandboxed process is commit_msg_generate()'s
# job (functions/commit-message.sh): the agent runs again inside the same
# image, with its own tools switched off, its credentials present, and
# neither the project checkout nor the worktree mounted -- so nothing the
# previous agent wrote can be auto-loaded as instructions, and nothing it
# writes here can reach the host except the text a human then approves.
worktree_generate_commit_message() {
    local out="$1" review="$2" prompt
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
$(head -n "$WORKTREE_PROMPT_DIFF_LINES" "$review")"
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

# worktree_resolve_commit_message OUT REVIEW: agent-written file if it has
# content, sandboxed generation if not. Sets WORKTREE_MSG_SOURCE, which the
# approval gate shows the human -- "who wrote this message" is part of what
# is being approved.
worktree_resolve_commit_message() {
    local out="$1" review="$2" src="${WORKTREE_MSG_HOST:-}"
    if [[ -n "$src" && -f "$src" ]] && grep -q '[^[:space:]]' "$src" 2>/dev/null; then
        cp "$src" "$out"
        chmod 600 "$out"
        WORKTREE_MSG_SOURCE="written by the agent"
        return 0
    fi
    echo "worktree: the agent left ~/$WORKTREE_MSG_NAME empty; generating a message in the sandbox" >&2
    if worktree_generate_commit_message "$out" "$review"; then
        WORKTREE_MSG_SOURCE="generated in the sandbox (the agent left the file empty)"
        return 0
    fi
    worktree_placeholder_message "$out"
    WORKTREE_MSG_SOURCE="placeholder (agent file empty, generation failed)"
}

# worktree_approval_gate MSG REVIEW: mandatory. No flag, no environment
# variable and no answer other than an explicit "y" commits anything, and
# there is no unattended path at all -- a missing TTY refuses.
#
# The review text goes to stderr so a logged run keeps the audit trail of
# what was approved; the question itself is asked on /dev/tty, because
# stdin belongs to the agent.
worktree_approval_gate() {
    local msg="$1" review="$2" total reply
    total="$(wc -l <"$review" | tr -d '[:space:]')"
    {
        echo
        echo "======================================================================"
        echo "  REVIEW: $WORKTREE_REF"
        echo "  worktree:     $WORKTREE_DIR"
        echo "  commits into: $WORKTREE_REPO_ROOT"
        echo "======================================================================"
        echo
        echo "--- proposed commit message [$WORKTREE_MSG_SOURCE] ---"
        cat "$msg"
        echo
        echo "--- change ($total lines) ---"
        head -n "$WORKTREE_GATE_DIFF_LINES" "$review"
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
worktree_commit() {
    local msg="$1"
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
