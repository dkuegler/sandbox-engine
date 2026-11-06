#!/bin/bash
# Host-side, apptainer-free verification of the credential/URL sanitizer
# (sanitize_git_config/redact_urls/sanitize_gitdir_metadata/mask_git_readonly,
# functions/git-mask.sh). This is NOT a replacement for the full
# tests/git-escape/ probe -- it cannot prove the read-only *bind* actually
# lands (that needs a real apptainer container, see run.sh) -- but it calls
# the real sanitizer functions against real fixtures and inspects their real
# output, so it proves the thing the mask/bind cannot: whether the sanitized
# copy that gets bound over each gitdir's config/config.worktree/FETCH_HEAD/
# logs/HEAD is actually free of the credentials the real file carries.
#
# Builds the same four fixtures as run.sh/probe.sh (fixtures.sh, same
# directory) so a leak this catches and a leak the full container-based
# probe catches are the same claim, verified two ways.
#
# Exit: 0 all passed, 1 an assertion failed, 99 the suite could not run.
#
# `cmd && ok ... || bad ...` is used throughout for lightweight pass/fail
# reporting, same convention as probe.sh; ok()/bad() are plain printf+counter
# calls that cannot themselves fail, so the "C also runs if A succeeds but B
# fails" hazard SC2015 warns about does not apply here.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/git-escape/fixtures.sh
source "$SCRIPT_DIR/fixtures.sh"

# shellcheck source=tests/lib/report.sh
source "$SCRIPT_DIR/../lib/report.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/git-escape-sanitize.XXXXXX")"
# shellcheck disable=SC2317  # invoked indirectly via `trap cleanup EXIT`, not a direct call
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@invalid

fail_setup() { echo "PREFLIGHT: $*" >&2; exit 99; }

# The bare submodule source is still empty when it is cloned (it is filled
# through that clone), so git says so; the clone itself succeeds.
expect_warnings "warning: You appear to have cloned an empty repository."

# --- fixture: submodule source (populated before use, see run.sh's own
# comment on this same false-empty-clone trap) --------------------------
mkdir -p "$W/subsrc.git" || fail_setup "mkdir subsrc.git"
git init -q --bare "$W/subsrc.git" || fail_setup "init bare subsrc.git"
git clone -q "$W/subsrc.git" "$W/subtmp" || fail_setup "clone subsrc.git"
echo x > "$W/subtmp/x"
git -C "$W/subtmp" add x
git -C "$W/subtmp" commit -q -m subinit || fail_setup "commit into subtmp"
git -C "$W/subtmp" push -q origin HEAD:master || fail_setup "push subtmp -> subsrc.git"
rm -rf "$W/subtmp"

# --- fixture: main project, credentialed origin -------------------------
git init -q "$W/main" || fail_setup "init main"
echo hi > "$W/main/f"
git -C "$W/main" add f
git -C "$W/main" commit -q -m init || fail_setup "commit into main"
git -C "$W/main" remote add origin "https://$SECRET_PROJECT/proj.git"

# --- fixture: submodule, distinct credentialed origin --------------------
git -C "$W/main" -c protocol.file.allow=always submodule add -q "$W/subsrc.git" sub \
    || fail_setup "submodule add"
git -C "$W/main" add sub .gitmodules
git -C "$W/main" commit -q -m "add submodule" || fail_setup "commit submodule"
git -C "$W/main/sub" remote set-url origin "https://$SECRET_SUBMODULE/sub.git" \
    || fail_setup "set submodule origin"

# --- fixture: worktree, distinct credentialed remote in config.worktree --
git -C "$W/main" worktree add -q -b agentwt "$W/wt" || fail_setup "worktree add"
git -C "$W/wt" config extensions.worktreeConfig true
git -C "$W/wt" config --worktree remote.fork.url "https://$SECRET_WORKTREE/fork.git"

# --- fixture: a second repo standing in for a read-write extra bind -----
mkdir -p "$W/extra" || fail_setup "mkdir extra"
git init -q "$W/extra" || fail_setup "init extra"
echo e > "$W/extra/e"
git -C "$W/extra" add e
git -C "$W/extra" commit -q -m einit || fail_setup "commit into extra"
git -C "$W/extra" remote add origin "https://$SECRET_EXTRA/extra.git"

# Preflight: every secret must actually be present in the raw fixture, or
# an assertion that finds nothing proves nothing.
for secret in "$SECRET_PROJECT" "$SECRET_SUBMODULE" "$SECRET_WORKTREE" "$SECRET_EXTRA"; do
    grep -rq -- "$secret" "$W" 2>/dev/null \
        || fail_setup "fixture secret '$secret' not found anywhere under $W -- fixture is broken"
done

# --- exercise the real sanitizer ------------------------------------------
# shellcheck source=functions/log.sh
source "$REPO_ROOT/functions/log.sh"
# shellcheck source=functions/agents.sh
source "$REPO_ROOT/functions/agents.sh"
# shellcheck source=functions/git-mask.sh
source "$REPO_ROOT/functions/git-mask.sh"

# These four are read by mask_git_readonly() (functions/git-mask.sh), sourced
# above -- shellcheck does not follow the source without -x, so it cannot see
# that use.
# shellcheck disable=SC2034
PROJECT_DIR="$W/main"
# shellcheck disable=SC2034
EXTRA_BIND_SRCS=("$W/extra")
# shellcheck disable=SC2034
EXTRA_BIND_RO=(0)
# shellcheck disable=SC2034
ALLOW_EXTERNAL_GITDIR=0
BINDS=()
mask_git_readonly >/dev/null

[[ "${GIT_MASK_COUNT:-0}" -ge 3 ]] \
    && ok SETUP "mask_git_readonly masked $GIT_MASK_COUNT gitdir(s) (project, submodule, extra-bind)" \
    || bad SETUP "mask_git_readonly masked only $GIT_MASK_COUNT gitdir(s), expected >= 3"

# --- collect every sanitized overlay mask_git_readonly actually produced -
# BINDS is "-B" markers interleaved with "SRC:DST:OPTS" strings; the
# sanitized ones are exactly the "$RUN_DIR/gitsan-*" sources
# sanitize_gitdir_metadata() writes (functions/git-mask.sh).
declare -a SANITIZED_FILES=()
prev=""
for tok in "${BINDS[@]}"; do
    if [[ "$prev" == "-B" && "$tok" == "$RUN_DIR"/gitsan-*:* ]]; then
        SANITIZED_FILES+=("${tok%%:*}")
    fi
    prev="$tok"
done

[[ "${#SANITIZED_FILES[@]}" -ge 1 ]] \
    && ok SETUP "${#SANITIZED_FILES[@]} sanitized overlay file(s) generated" \
    || bad SETUP "no sanitized overlay files were generated at all"

# --- A7: no credential/URL survives in any sanitized overlay --------------
leak_found=0
for f in "${SANITIZED_FILES[@]}"; do
    for secret in "$SECRET_PROJECT" "$SECRET_SUBMODULE" "$SECRET_WORKTREE" "$SECRET_EXTRA"; do
        if grep -q -- "$secret" "$f" 2>/dev/null; then
            echo "  ..LEAK: $secret found in sanitized file $f" >&2
            leak_found=1
        fi
    done
done
[[ "$leak_found" -eq 0 ]] \
    && ok A7 "no fixture credential survives in any sanitized overlay file" \
    || bad A7 "at least one fixture credential survived sanitization (see LEAK lines above)"

# --- A8: each gitdir's sanitized config actually contains the redaction
# placeholder -- an empty/missing file would also "pass" A7 without the
# sanitizer having done anything, per this suite's own standing lesson
# that a kernel refusal (or here, a no-op) cannot be told apart from a
# working control without checking for positive evidence too.
placeholder_seen=0
for f in "${SANITIZED_FILES[@]}"; do
    grep -q "REDACTED-BY-SANDBOX" "$f" 2>/dev/null && placeholder_seen=$((placeholder_seen + 1))
done
[[ "$placeholder_seen" -ge 3 ]] \
    && ok A8 "$placeholder_seen sanitized file(s) show the REDACTED-BY-SANDBOX placeholder (project/submodule/worktree all actually rewritten, not just empty)" \
    || bad A8 "only $placeholder_seen sanitized file(s) show the placeholder, expected >= 3"

# --- A9: the *raw* files (not the overlay) still carry the secret -- this
# is not a bug, it documents the known, stated boundary (read-only mask
# hides writes, not the file's own content outside the 4 sanitized names)
# and doubles as proof this suite is not vacuously matching an
# already-empty file.
raw_has_secret=0
[[ -f "$W/main/.git/config" ]] && grep -q -- "$SECRET_PROJECT" "$W/main/.git/config" && raw_has_secret=$((raw_has_secret + 1))
subgitdir="$(git -C "$W/main/sub" rev-parse --absolute-git-dir 2>/dev/null)"
[[ -n "$subgitdir" && -f "$subgitdir/config" ]] && grep -q -- "$SECRET_SUBMODULE" "$subgitdir/config" && raw_has_secret=$((raw_has_secret + 1))
[[ -f "$W/main/.git/worktrees/wt/config.worktree" ]] && grep -q -- "$SECRET_WORKTREE" "$W/main/.git/worktrees/wt/config.worktree" && raw_has_secret=$((raw_has_secret + 1))
[[ -f "$W/extra/.git/config" ]] && grep -q -- "$SECRET_EXTRA" "$W/extra/.git/config" && raw_has_secret=$((raw_has_secret + 1))
[[ "$raw_has_secret" -eq 4 ]] \
    && ok A9 "all 4 raw (unsanitized) fixture files still carry their secret -- fixture is real, not a no-op" \
    || bad A9 "only $raw_has_secret/4 raw fixture files carry their secret"

# --- A10: absence of any host global git config bind (grepped from source,
# not assumed) -- guards against a future change silently binding one in.
if grep -rInE '\-B[[:space:]]+.*(\.gitconfig|\.git-credentials)' "$REPO_ROOT/functions" >/dev/null 2>&1; then
    bad A10 "functions/*.sh binds a host ~/.gitconfig or ~/.git-credentials path -- that would bypass this sanitizer entirely"
else
    ok A10 "no functions/*.sh bind references a host ~/.gitconfig or ~/.git-credentials path"
fi

# --- A11: worktree metadata reachable only via the parent .git's blanket
# mount (worktree checkout directory outside every walked root -- exactly
# what --worktree mode does: worktrees live under $HOME/.agent/worktrees/...,
# never under $PROJECT_DIR). mask_git_readonly() only calls
# sanitize_gitdir_metadata() on a gitdir it finds directly (named
# literally ".git") or resolves *from* one; a per-worktree metadata
# directory (.git/worktrees/<name>/) is neither -- it is a plain
# subdirectory nested inside an already-masked .git, so its
# config.worktree/logs/HEAD ride along on the parent's blanket read-only
# bind, in full, unredacted, whenever that worktree's own checkout .git
# file is not itself inside a walked root.
wt_metadata="$W/main/.git/worktrees/wt/config.worktree"
blanket_bind=0
overridden=0
for tok in "${BINDS[@]}"; do
    [[ "$tok" == "$W/main/.git:$W/main/.git:ro" ]] && blanket_bind=1
    [[ "$tok" == *":$wt_metadata:ro" ]] && overridden=1
done
if [[ "$blanket_bind" -eq 1 && "$overridden" -eq 0 ]]; then
    bad A11 "worktree config.worktree ($wt_metadata) is exposed raw via the parent .git's blanket read-only mount -- mask_git_readonly() never sanitizes a registered worktree's own metadata directory unless that worktree's checkout .git file happens to be independently discovered inside a walked root"
else
    ok A11 "worktree config.worktree is either overridden by its own sanitized bind, or the parent .git is not blanket-mounted"
fi

report_summary
