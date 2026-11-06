#!/bin/bash
# git-escape probe -- runs INSIDE the agent container, launched via the
# generic `./sandbox.sh script` run mode (see tests/git-escape/run.sh for
# the host driver).
#
# Asserts the one control that holds under every git architecture: every
# .git reachable from the agent is bind-mounted read-only, so no git binary
# -- the one the image ships, or one the agent fetches itself -- can rewrite
# history. A5 vendors its own pinned git, independent of the image's own,
# so this suite proves the mask rather than just exercising whatever git the
# image happens to ship. Runs first because everything below needs a binary.
#
# Two rules keep this suite honest, both learned by getting them wrong:
#
#   1. Never pipe a command whose exit code is asserted. `cmd | head`
#      reports head's status, which is 0 essentially always.
#   2. A kernel refusal cannot tell a working control from a broken
#      fixture -- git touches .git/FETCH_HEAD before it contacts a remote,
#      so `fetch` against a *nonexistent* remote also fails with EROFS.
#      Preconditions are therefore checked separately and exit 99 rather
#      than reporting a pass.
#
# Exit: 0 all passed, 1 an assertion failed, 99 the suite could not run.
#
# `cmd && ok ... || bad ...` is used throughout for lightweight pass/fail
# reporting; ok()/bad() (below) are plain printf+counter calls that cannot
# themselves fail, so the "C also runs if A succeeds but B fails" hazard
# SC2015 warns about does not apply here.
# shellcheck disable=SC2015
set -uo pipefail

REPO="${1:-$PWD}"
EXTRA_REPO="${2:-}"
# The --worktree writable checkout. Optional: passed by run.sh in
# plain and negative mode alike, absent when probe.sh is invoked by hand.
WT_REPO="${3:-}"
SCRATCH="${SCRATCH:-/dev/shm/git-escape}"
GIT="$SCRATCH/root/usr/bin/git"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SUITE="${SUITE:-bookworm}"
PINNED_GIT="${PINNED_GIT:-2.39.5-0+deb12u3}"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "PREFLIGHT: no such repo: ${1:-$PWD}" >&2; exit 99; }
if [[ -n "$EXTRA_REPO" ]]; then
    EXTRA_REPO="$(cd "$EXTRA_REPO" 2>/dev/null && pwd)" || { echo "PREFLIGHT: no such extra-bind repo: $2" >&2; exit 99; }
fi
# shellcheck source=tests/git-escape/fixtures.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures.sh"
# shellcheck source=tests/lib/report.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/report.sh"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export PATH="$SCRATCH/root/usr/lib/git-core:$PATH"
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@invalid

# EXPECT_FAIL: the assertion IDs this run must fail, space-separated, read
# into report.sh's EXPECTED_FAIL. Set only by run.sh --negative, which runs
# this probe on the host; inside the container --containall drops the host
# environment, so a normal run always expects every assertion to pass.
read -r -a EXPECTED_FAIL <<< "${EXPECT_FAIL:-}"
chk()  { if [[ "$3" == "$4" ]]; then ok "$1" "$2"; else bad "$1" "$2 (want '$4', got '$3')"; fi; }

# --- A5: the agent acquires its own git ----------------------------------
# This is not setup, it is the threat the mask exists for: the image ships
# no git, so an attacker's first move is to fetch one. Done first because
# everything below needs that binary. /dev/shm, not /tmp: --writable-tmpfs
# is a 64 MiB tmpfs shared by / and /tmp, too small for the package.
acquire_git() {
    local deb="$SCRATCH/git.deb" url idx
    mkdir -p "$SCRATCH/root" || return 1
    [[ -x "$GIT" ]] && return 0
    url="$MIRROR/pool/main/g/git/git_${PINNED_GIT}_amd64.deb"
    if ! curl -fsS --max-time 60 -o "$deb" "$url"; then
        # Pin goes stale on every security update; resolve from the index.
        idx="$SCRATCH/Packages.gz"
        curl -fsS --max-time 120 -o "$idx" \
            "$MIRROR/dists/$SUITE/main/binary-amd64/Packages.gz" || return 1
        url="$MIRROR/$(python3 -c "
import gzip,re,sys
d=gzip.open(sys.argv[1],'rt',errors='replace').read()
for b in d.split('\n\n'):
    if re.search(r'^Package: git$',b,re.M):
        print(re.search(r'^Filename: (.+)$',b,re.M).group(1)); break
" "$idx")" || return 1
        rm -f "$idx"
        curl -fsS --max-time 60 -o "$deb" "$url" || return 1
    fi
    dpkg-deb --fsys-tarfile "$deb" \
        | tar -x -C "$SCRATCH/root" ./usr/bin/git ./usr/lib/git-core 2>/dev/null
    rm -f "$deb"
    [[ -x "$GIT" ]]
}

if acquire_git; then
    ok A5 "agent fetched its own git ($("$GIT" --version 2>/dev/null))"
else
    bad A5 "could not fetch a git binary -- egress closed or mirror moved"
    echo "A5 is the acquisition path; without it nothing below can run." >&2
    exit 99
fi
cd "$REPO" || { echo "PREFLIGHT: repo under test not found: $REPO" >&2; exit 99; }

# Preflight. Every assertion below reads a non-zero exit as proof of a kernel
# refusal, so a git that cannot start would make the whole suite "pass".
if ! "$GIT" --version >/dev/null 2>&1; then
    echo "PREFLIGHT: $GIT does not run -- acquire it first" >&2; exit 99
fi
if ! "$GIT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "PREFLIGHT: $REPO is not a git repository" >&2; exit 99
fi

# --- A1: every write into .git is refused by the kernel -------------------
# A ".git" match is a DIRECTORY for the top-level repo and a submodule's
# real gitdir, but a FILE (a "gitdir: <path>" pointer) for a submodule's
# or worktree's own checkout -- `find -name .git` matches both. Writing
# INTO a file as if it were a directory ("$gd/ESCAPE_PROBE") always fails
# with ENOTDIR ("Not a directory"), never EROFS, regardless of any mask,
# so that check would prove nothing for a file-type match; it has to
# attempt writing the file itself instead.
a1_fail=0
while read -r gd; do
    [[ -n "$gd" ]] || continue
    if [[ -d "$gd" ]]; then
        err="$(touch "$gd/ESCAPE_PROBE" 2>&1)"; rc=$?
    else
        err="$( { : >> "$gd"; } 2>&1 )"; rc=$?
    fi
    [[ $rc -ne 0 && "$err" == *"Read-only file system"* ]] || { a1_fail=1; echo "  ..$gd rc=$rc err=$err"; }
done < <(find . -name .git -maxdepth 4 -printf '%p\n' 2>/dev/null)
chk A1 "writes into every .git refused (EROFS)" "$a1_fail" 0

# --- A2: commit fails at lock creation, no partial state ------------------
head_before="$("$GIT" rev-parse HEAD 2>/dev/null)"
objs_before="$(find .git/objects -type f 2>/dev/null | wc -l)"
out="$("$GIT" commit --allow-empty -m probe 2>&1)"; rc=$?
head_after="$("$GIT" rev-parse HEAD 2>/dev/null)"
objs_after="$(find .git/objects -type f 2>/dev/null | wc -l)"
[[ $rc -ne 0 ]] && ok A2a "commit exit=$rc (non-zero)" || bad A2a "commit SUCCEEDED"
chk A2b "commit left HEAD unmoved"      "$head_after" "$head_before"
chk A2c "commit created no loose object" "$objs_after" "$objs_before"

# --- fixture: a writable remote carrying a commit we do not have ----------
# Verified before use. A4 asserts that a kernel refusal stops a fetch; a
# missing remote produces a refusal too (.git/FETCH_HEAD is on the masked
# mount), so an unchecked fixture makes A4 pass while testing nothing.
BARE="$SCRATCH/remote.git"; WORK="$SCRATCH/work"
rm -rf "$BARE" "$WORK"
"$GIT" clone --quiet --bare "$REPO" "$BARE"  >/dev/null 2>&1
"$GIT" clone --quiet "$BARE" "$WORK"         >/dev/null 2>&1
( cd "$WORK" && "$GIT" commit --quiet --allow-empty -m upstream-commit && "$GIT" push --quiet origin HEAD ) >/dev/null 2>&1
UPSTREAM="$( cd "$WORK" && "$GIT" rev-parse HEAD 2>/dev/null )"

fixture_bad=""
[[ -d "$BARE" ]] || fixture_bad="bare remote not created"
[[ -n "$UPSTREAM" ]] || fixture_bad="upstream commit not created"
[[ -z "$fixture_bad" ]] && { "$GIT" --git-dir="$BARE" cat-file -t "$UPSTREAM" >/dev/null 2>&1 \
    || fixture_bad="upstream commit $UPSTREAM absent from the bare remote"; }
[[ -z "$fixture_bad" ]] && { "$GIT" cat-file -t "$UPSTREAM" >/dev/null 2>&1 \
    && fixture_bad="upstream commit $UPSTREAM is ALREADY in the repo under test"; }
if [[ -n "$fixture_bad" ]]; then
    printf 'FIXTURE BROKEN: %s\n' "$fixture_bad" >&2
    printf 'A3/A4 cannot be evaluated; refusing to report them as passes.\n' >&2
    exit 99
fi
ok FIX "fixture: remote has $UPSTREAM, repo under test does not"

R=(-c "remote.probe.url=$BARE" -c "remote.probe.fetch=+refs/heads/*:refs/remotes/probe/*")
# --- A3: push SUCCEEDS; the local tracking ref stays stale ----------------
# Both refs below must name what this fixture actually touches. An earlier
# version watched refs/remotes/probe/master while pushing escape-$$ and
# fetching into probe/*, so it passed against an unmasked repo too.
BR="escape-$$"
head_now="$("$GIT" rev-parse HEAD 2>/dev/null)"
out="$("$GIT" "${R[@]}" push probe "HEAD:refs/heads/$BR" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok A3a "push exit=0 (remote accepted the objects)" || bad A3a "push exit=$rc: $out"
land="$("$GIT" --git-dir="$BARE" rev-parse "refs/heads/$BR" 2>/dev/null)"
chk A3b "objects really landed on the remote" "$land" "$head_now"
"$GIT" rev-parse --verify --quiet "refs/remotes/probe/$BR" >/dev/null 2>&1 \
  && bad A3c "tracking ref refs/remotes/probe/$BR was written" \
  || ok A3c "tracking ref refs/remotes/probe/$BR absent (refs/remotes stale)"
[[ "$out" == *"update_ref failed"* ]] && ok A3d "push reported the refused tracking update" \
  || bad A3d "no 'update_ref failed' in push output: $out"

# --- A4: fetch fails, and nothing from upstream lands --------------------
ref_before="$("$GIT" rev-parse refs/remotes/probe/master 2>/dev/null || echo none)"
out="$("$GIT" "${R[@]}" fetch probe 2>&1)"; rc=$?
ref_after="$("$GIT" rev-parse refs/remotes/probe/master 2>/dev/null || echo none)"
[[ $rc -ne 0 ]] && ok A4a "fetch exit=$rc (non-zero)" || bad A4a "fetch SUCCEEDED: $out"
[[ "$out" == *"Read-only file system"* ]] && ok A4b "fetch refused by the kernel" \
  || bad A4b "fetch failed for another reason: $out"
chk A4c "refs/remotes/probe/master unmoved" "$ref_after" "$ref_before"
"$GIT" cat-file -t "$UPSTREAM" >/dev/null 2>&1 \
  && bad A4d "upstream object $UPSTREAM entered the object store" \
  || ok A4d "upstream object absent from object store"

# --- A6: path aliasing cannot reach a writable project .git --------------
a6_fail=0
for probe_cmd in \
    "$GIT --git-dir=$REPO/.git commit --allow-empty -m alias" \
    "$GIT -C $REPO commit --allow-empty -m alias" \
    "env GIT_DIR=$REPO/.git GIT_WORK_TREE=$REPO $GIT commit --allow-empty -m alias"; do
    $probe_cmd >/dev/null 2>&1 && { a6_fail=1; echo "  ..SUCCEEDED: $probe_cmd"; }
done
chk A6 "--git-dir/-C/GIT_DIR aliasing still refused" "$a6_fail" 0

# --- A7: no fixture credential reachable anywhere bound into the sandbox --
# not just the project's own top-level .git. Recursive grep across every
# bound path this probe was told about (the project tree, plus the
# extra-bind fixture when run.sh passed one), not just known gitdirs, so a
# credential that escapes through a path this suite does not specifically
# enumerate (a nested worktree's metadata directory, an unexpected copy,
# ...) still gets caught. Covers the project's own origin, the submodule's
# origin (nested inside $REPO), and the worktree's config.worktree (also
# nested inside $REPO/.git/worktrees/, per mask_git_readonly()'s own
# recursive read-only mount of the whole .git tree) in one pass.
a7_fail=0
for secret in "$SECRET_PROJECT" "$SECRET_SUBMODULE" "$SECRET_WORKTREE" "$SECRET_EXTRA"; do
    grep -rq -- "$secret" "$REPO" 2>/dev/null && { a7_fail=1; echo "  ..LEAK in project tree: $secret"; }
    [[ -n "$EXTRA_REPO" ]] && grep -rq -- "$secret" "$EXTRA_REPO" 2>/dev/null \
        && { a7_fail=1; echo "  ..LEAK in extra bind: $secret"; }
done
chk A7 "no fixture credential reachable anywhere bound into the sandbox" "$a7_fail" 0

# --- A8: the redaction actually ran (positive evidence) -- an empty or
# missing config would also "pass" A7 without the sanitizer having done
# anything, the same false-positive risk A1-A6's own preflight checks
# guard against for kernel refusals (see the file header).
a8_seen=0
grep -q "REDACTED-BY-SANDBOX" "$REPO/.git/config" 2>/dev/null && a8_seen=$((a8_seen + 1))
a8_want=1
if [[ -n "$EXTRA_REPO" ]]; then
    grep -q "REDACTED-BY-SANDBOX" "$EXTRA_REPO/.git/config" 2>/dev/null && a8_seen=$((a8_seen + 1))
    a8_want=2
fi
chk A8 "sanitizer placeholder present in every masked config checked" "$a8_seen" "$a8_want"

# --- A9: no host global git config is reachable at all -- guards against a
# future change silently binding one in, which would bypass this
# sanitizer entirely regardless of how correct it is.
a9_fail=0
for p in "$HOME/.gitconfig" "$HOME/.git-credentials"; do
    [[ -e "$p" ]] && { a9_fail=1; echo "  ..UNEXPECTED: $p is reachable inside the sandbox"; }
done
chk A9 "no host ~/.gitconfig or ~/.git-credentials reachable" "$a9_fail" 0

# --worktree writable checkout must not reopen a path to the main
# repository's history
# =======================================================================
# A linked worktree shares the main repository's object database and ref
# namespace outright; only HEAD/index/logs/HEAD/config.worktree are its
# own. So "the worktree is read-write" and "the main repository's history
# is read-only" are only compatible because three separate paths are
# masked: the worktree's own ".git" pointer file, the
# <main>/.git/worktrees/<name>/ directory it names, and <main>/.git.
if [[ -n "$WT_REPO" ]]; then
    WT_REPO="$(cd "$WT_REPO" 2>/dev/null && pwd)" || { echo "PREFLIGHT: no such worktree: $3" >&2; exit 99; }
    WT_GITDIR="$("$GIT" -C "$WT_REPO" rev-parse --absolute-git-dir 2>/dev/null)"
    if [[ -z "$WT_GITDIR" || ! -f "$WT_REPO/.git" ]]; then
        echo "PREFLIGHT: $WT_REPO is not a linked worktree (no .git file / no gitdir)" >&2
        exit 99
    fi

    # A10a is positive evidence, and it comes first for the same reason the
    # fixture checks above do: without it, every refusal below would also
    # "pass" if the worktree simply were not mounted at all.
    if ( : > "$WT_REPO/ESCAPE_PROBE_WT" ) 2>/dev/null; then
        rm -f "$WT_REPO/ESCAPE_PROBE_WT"
        ok A10a "the worktree checkout is genuinely writable (so A10b+ mean something)"
    else
        bad A10a "the worktree checkout is NOT writable -- A10b/A11 below prove nothing"
    fi

    ( : >> "$WT_REPO/.git" ) 2>/dev/null \
        && bad A10b "the worktree's .git pointer file is writable -- its gitdir can be repointed" \
        || ok A10b "the worktree's .git pointer file is read-only"

    ( : > "$WT_GITDIR/ESCAPE_PROBE" ) 2>/dev/null \
        && bad A10c "the worktree's metadata dir $WT_GITDIR is writable" \
        || ok A10c "the worktree's metadata dir is read-only"

    # A11a: the agent cannot commit from inside its own worktree. The whole
    # design depends on this -- the commit is a host-side, post-exit,
    # human-approved step, and a worktree commit would write objects and
    # move a branch in the MAIN repository.
    wt_head_before="$("$GIT" -C "$WT_REPO" rev-parse HEAD 2>/dev/null)"
    out="$("$GIT" -C "$WT_REPO" commit --allow-empty -m wt-escape 2>&1)"; rc=$?
    wt_head_after="$("$GIT" -C "$WT_REPO" rev-parse HEAD 2>/dev/null)"
    [[ $rc -ne 0 ]] && ok A11a "commit from the worktree exit=$rc (non-zero)" \
                    || bad A11a "commit from the worktree SUCCEEDED: $out"
    chk A11b "the worktree's branch did not move" "$wt_head_after" "$wt_head_before"

    # A11c is the escalation that matters most: a worktree shares the main
    # repository's ENTIRE ref namespace, so a writable worktree gitdir
    # would let the agent rewrite branches it was never given a checkout
    # of -- master included.
    main_br="$("$GIT" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    main_before="$("$GIT" -C "$REPO" rev-parse "refs/heads/$main_br" 2>/dev/null)"
    out="$("$GIT" -C "$WT_REPO" update-ref "refs/heads/$main_br" "$wt_head_before" 2>&1)"; rc=$?
    main_after="$("$GIT" -C "$REPO" rev-parse "refs/heads/$main_br" 2>/dev/null)"
    [[ $rc -ne 0 ]] && ok A11c "update-ref against the main repo's $main_br exit=$rc (non-zero)" \
                    || bad A11c "update-ref rewrote the main repo's $main_br from the worktree: $out"
    chk A11d "the main repo's $main_br is unmoved" "$main_after" "$main_before"

    # A11e: no new, unmasked writable gitdir can be minted from here.
    out="$("$GIT" -C "$WT_REPO" worktree add "$SCRATCH/escape-wt" -b escape-$$ 2>&1)"; rc=$?
    [[ $rc -ne 0 ]] && ok A11e "worktree add from the worktree exit=$rc (non-zero)" \
                    || bad A11e "worktree add minted a fresh writable gitdir: $out"
else
    echo "note: no worktree path passed as \$3 -- A10/A11 not exercised" >&2
fi

report_summary
