#!/bin/bash
# git-escape probe -- runs INSIDE the agent container, launched via the
# generic `./sandbox.sh script` run mode (see tests/git-escape/run.sh for
# the host driver).
#
# Asserts the one control that holds under every git architecture: every
# .git reachable from the agent is bind-mounted read-only, so a git binary
# the agent supplies itself still cannot rewrite history. A5 fetches that
# binary, which is why it runs first.
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
set -uo pipefail

REPO="${1:-$PWD}"
SCRATCH="${SCRATCH:-/dev/shm/git-escape}"
GIT="$SCRATCH/root/usr/bin/git"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SUITE="${SUITE:-bookworm}"
PINNED_GIT="${PINNED_GIT:-2.39.5-0+deb12u3}"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "PREFLIGHT: no such repo: ${1:-$PWD}" >&2; exit 99; }
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export PATH="$SCRATCH/root/usr/lib/git-core:$PATH"
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@invalid

PASS=0 FAIL=0
ok()   { printf 'ok   %-6s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL %-6s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
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
a1_fail=0
while read -r gd; do
    [[ -n "$gd" ]] || continue
    err="$(touch "$gd/ESCAPE_PROBE" 2>&1)"; rc=$?
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
