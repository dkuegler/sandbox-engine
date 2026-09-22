# Git breakout: what the sandbox enforces

Fact record. Each claim is **M** (measured, output quoted) or **D** (derived from
git source/docs or from code, not exercised). Never promote D to M without adding
the output. Last verified 2026-09-16.

## Guarantee

**An agent cannot rewrite or destroy local git history.** Enforced by a
kernel-level read-only bind of every `.git`, applied unconditionally in every
configuration — not by a wrapper, allow-list, or the absence of a git binary.

`mask_git_readonly()` (`functions/git-mask.sh:126-171`) binds read-only every
`.git` under the project tree and under every read-write extra bind — top level,
submodules, nested repos — plus the real gitdir a worktree/submodule `.git` *file*
points at (`resolve_git_dir()`, `:62-81`). Apptainer sorts mounts shallowest-first,
so these land after the read-write project bind. A gitdir outside every bound tree
is left unmounted (unreachable) unless `--allow-external-gitdir`. The walk is
uncached by design (`:115-125`): a `.git` the agent creates between runs must be
masked on the next one.

**M** — live agent container mount table:

```
/home/.../sandbox-engine       rw,nosuid,nodev  nfs4
/home/.../sandbox-engine/.git  ro,nosuid,nodev  nfs4
```

**Not guaranteed:** repository confidentiality (§3).

## Behaviour against a read-only `.git`

| operation | result | |
| --- | --- | --- |
| `log` `show` `blame` `grep` `rev-parse` `branch --list` `ls-remote` | works | D |
| `status`, `diff` | exit 0, no warning, `GIT_OPTIONAL_LOCKS=0` not needed | M |
| `add` `commit` `checkout` `merge` `rebase` `stash` `branch -d` `worktree add` `gc` | fail at lock creation, `Read-only file system` | D |
| `fetch` | `error: cannot open '.git/FETCH_HEAD': Read-only file system`, exit 255 | M |
| `fetch --no-write-fetch-head` | exit 128, fails at object store | M |
| `push` to writable remote | **succeeds**, remote updated, exit 0 | M |

### push succeeds

```
To /tmp/gitro/remote.git
   d9519ed..4f98b0c  master -> master
error: update_ref failed for ref 'refs/remotes/origin/master': cannot lock ref
  ...refs/remotes/origin/master.lock': Read-only file system
push exit=0
```

`transport_push()` updates the remote, then calls
`transport_update_tracking_ref()` (`transport.c:1606`) → `refs_update_ref(...,
UPDATE_REFS_MSG_ON_ERR)`, whose return value is **ignored**. So: the condition for
push is that the *remote* is writable; the local `.git` may be fully read-only;
`refs/remotes/*` is left stale with no way to re-sync (fetch cannot work).

Local history is unaffected — a push writes to the remote. A local-path remote
inside a bound tree has its own `.git` masked; outside, it is not mounted.

### `fetch --no-write-fetch-head` — no hole

An earlier run recorded exit 0, implying a write path through the mask. False
negative: nothing to fetch. Re-run against a remote with real new commits:

```
error: unable to create temporary file: Read-only file system
fatal: unpack-objects failed
exit=128
BEFORE: 89519355…   AFTER: 89519355…   (unchanged)
upstream HEAD 282416d3… -> git cat-file -t: could not get object info (128)
```

Fails at the object store, before any ref update. **Assert exit code, ref
position, and object presence — exit code alone reproduces the false negative.**

## Not contained

**Egress is unrestricted.** M, from inside a live agent container: DNS
`github.com` → `140.82.121.3`; `https://github.com` → 200; `https://pypi.org/simple/`
→ 200; raw TCP `github.com:22` from a python socket → `SSH-2.0-…` banner.

The raw-socket row is decisive: this is not "`curl` is installed"
(`sandbox/agent/Dockerfile.template:30-32`). Every preset ships python
(`functions/environment.sh:49-62`), so removing `curl` changes nothing. An agent
with arbitrary outbound TCP already has every channel `git push <url>` offers.
No apptainer-level fix exists without root (`--net` needs privileges).

**The agent can already run git — from the image or self-installed.** The
default image ships `git` directly (decided 2026-09-17); `environment.image`/
`environment.dockerfile` mode can still select a base with none. Either way the
mask does not care where the binary came from: a self-installed binary, a static
build, or a git library that never execs all hit the same read-only mount.

**A prior MCP sidecar/tool-allow-list design was retired, and was never in
the enforcement path anyway.** It would have been redundant against the
integrity threat (the kernel refuses writes) even had it worked, and it
never did: its `nc -U <socket>` transport was denied by the Canonical-shipped
enforce-mode profile `/etc/apparmor.d/nc.openbsd` with
`info="Failed name lookup - disconnected path"` — AppArmor mediates the
*peer's* path as stored at `bind()` in the binder's mount namespace, and the
sidecar bound inside its own apptainer namespace, so that path was
disconnected globally, confirmed against an unconfined host shell too (same
failure, no apptainer involved).

## Standing verification

`tests/git-escape/` asserts the mask on every change. `./tests/git-escape/run.sh`
builds a throwaway repository, runs `./sandbox.sh script tests/git-escape/probe.sh`
against it, and checks 15 assertions from inside a real agent container: 15/15
pass. `--negative` runs the same probe on the host with no mask and requires it
to fail: 11 of 15 fail. The 4 that pass in both are not mask assertions — the
agent acquiring a git binary, the fixture check, and `push` succeeding plus its
objects landing on the remote, all of which must hold either way.

Verified there and no longer open: mutating commands failing at lock creation with
no partial state (`HEAD` unmoved, no loose object); a **self-installed** git
subject to the same refusals as the git that now ships in the image — the probe
vendors its own pinned `git 2.39.5` from `deb.debian.org` into the container
with no root in about a second, independent of whatever the image itself
provides, confirming the mask does not care which git binary is used;
`--git-dir` / `-C` / `GIT_DIR` aliasing refused; `fetch` failing with the
upstream commit absent from the object store.

A suite of kernel-refusal assertions cannot distinguish a working control from a
broken fixture — git writes `.git/FETCH_HEAD` before it contacts any remote, so
`fetch` against a *nonexistent* remote fails with `EROFS` too. Preconditions are
therefore checked separately and exit 99 rather than reporting a pass, and
`--negative` exists to prove the assertions can fail at all. Both gates caught
real false positives while the suite was being written.

## Untested

Submodule / nested-repo / worktree-gitdir masking: the code walks for it, but the
harness fixture is a single-repo tree (`masking 1 path(s)`), so only a top-level
`.git` has been observed read-only. If a writable-worktree mode is added, that it
cannot rewrite main history.

## Reproduction

Needs a host with `git` **and** `apptainer`. Confined to `/tmp/gitro`, safe to
re-run.

```bash
cd /tmp && rm -rf gitro && mkdir -p gitro/ctx && cd gitro
printf 'FROM debian:bookworm-slim\nRUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates\n' > ctx/Dockerfile
apptainer build -F gitro.sif dockerfile:ctx
SIF=/tmp/gitro/gitro.sif
apptainer exec --containall --no-mount home "$SIF" git --version   # MUST print a version

git init -q repo && cd repo && git config user.email a@b && git config user.name a
echo one > f && git add f && git commit -qm one
git init -q --bare ../remote.git && git remote add origin /tmp/gitro/remote.git
git push -q origin master
cd /tmp/gitro && git clone -q remote.git up && cd up
git config user.email a@b && git config user.name a
echo upstream >> f && git commit -qam two && git push -q origin master
UP=$(git rev-parse HEAD); cd /tmp/gitro; R=/tmp/gitro/repo
run(){ apptainer exec --containall --no-mount home -B /tmp/gitro -B "$R/.git:$R/.git:ro" \
        "$SIF" sh -c "cd $R; $1"; }

echo "BEFORE: $(git --git-dir=$R/.git rev-parse refs/remotes/origin/master)"
run 'git fetch --no-write-fetch-head origin; echo "exit=$?"'
echo "AFTER:  $(git --git-dir=$R/.git rev-parse refs/remotes/origin/master)"
run "git cat-file -t $UP; echo objects_present=\$?"
run 'git push origin master; echo "push exit=$?"'
run 'GIT_OPTIONAL_LOCKS=0 git status; echo "status exit=$?"'
```

The recorded runs used `--no-home`, which apptainer documents as equivalent to
`--no-mount home` (**D**); the sandbox itself passes only `--no-mount`.

The `git --version` line is not optional: a container without git turns every
step into `git: not found` (exit 127), indistinguishable from a refused write if
you read only exit codes — this is how the `--no-write-fetch-head` false negative
above was produced. Never
`apt-get install` inside the `--containall` run; its overlay is read-only and the
install fails silently.
