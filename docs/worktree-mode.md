# Worktree mode: what a writable git worktree does and does not expose

Last verified: 2026-09-19 (git 2.39.5).

Subject: the containment boundary of `sandbox.sh --worktree <branch>`, which
binds a git worktree read-write into the sandbox while the repository's
history stays read-only. `M` = measured, output quoted. `D` = derived from
source or documentation, not exercised.

## The load-bearing fact

**A linked worktree shares the main repository's object database and ref
namespace. It is not an isolated copy.** Only `HEAD`, `index`, `ORIG_HEAD`,
`logs/HEAD` and `config.worktree` are per-worktree, under
`<main>/.git/worktrees/<name>/`; `objects/`, `refs/`, `packed-refs` and
`config` are one shared copy (`D`, git-worktree(1); `M`, below).

Consequence: **a writable worktree gitdir is write access to the main
repository's entire history**, including branches the worktree never checked
out.

`M` — a commit made inside a worktree lands on the main repository's own ref
and object store:

```
$ git -C main worktree add -b agent/demo ../wt HEAD
$ git -C wt commit -aqm "from worktree"
$ git -C main log --oneline agent/demo
020f47f from worktree
6fe337b base
$ git -C main cat-file -t "$(git -C wt rev-parse HEAD)"
commit
```

`M` — with no mask, `update-ref` issued from a worktree rewrites an unrelated
branch of the main repository. From the regression harness's negative control
(`tests/git-escape/run.sh --negative`), where no mask exists:

```
FAIL A11c   update-ref rewrote the main repo's master from the worktree:
FAIL A11d   the main repo's master is unmoved
            (want '1c312373e962364ab55d53edb771ff4bf6d2b89a',
              got 'b2e7a9195bd7d976d54fb8ca67eb6869c8a7f66b')
```

## What is bound, and what is masked

Worktree mode binds the worktree's **checkout** read-write and sets it as the
container's cwd. Three separate paths carry the history, and all three are
bind-mounted read-only by `mask_git_readonly()` (`functions/git-mask.sh`),
which walks the worktree as a root exactly as it walks any read-write bind:

| path | why it must be masked |
| --- | --- |
| `<worktree>/.git` | a **file** holding `gitdir: <path>`. Writable, it can be repointed at a directory that is not masked. Bound read-only over itself, so it cannot be rewritten or unlinked. |
| `<main>/.git/worktrees/<name>/` | the worktree's own `HEAD`/`index`/`config.worktree`. Resolved from the file above by `resolve_git_dir()`. |
| `<main>/.git` | the shared object store and ref namespace. Found by the ordinary project-dir walk. |

The main checkout itself is mounted **read-only**, confirmed interactively on
`/dev/tty` before the run. The worktree is the only writable checkout.

`M` — a worktree contains only files git tracks. A main checkout holding
`tracked.txt`, `sub/n.txt`, `.gitignore`, an untracked `untracked.txt` and an
ignored `ignored-artifact` produces a worktree holding only the three tracked
entries. This is why the main checkout is mounted at all: untracked and
ignored files (local scratch directories, `.env`, build output) exist only
there, and the agent is told so in its own instruction file
(`bind_augmented_instructions()`, `functions/agents.sh`).

`M` — git in a worktree needs no main working tree, only `<main>/.git`. With
every file in the main checkout deleted except `.git`, `status`, `log`,
`diff` and `commit` in the worktree all returned rc=0.

The confirmation offers read-only, read-write and deny/do not mount. **`deny`
does not hide the repository's history.** It skips the `$PROJECT_DIR` bind,
so the main *working tree* is not mounted and the untracked and ignored files
that live only there are out of reach — but `mask_git_readonly()`'s walk is
unconditional, so `$PROJECT_DIR/.git`, and every nested repository's `.git`,
are still bound read-only. Tracked content of every branch therefore stays
readable through the shared object store (`D` — the walk's roots do not depend
on the answer). The prompt says that, rather than "deny access to it
entirely": a human choosing `deny` to keep a secret out of the container gets
nothing from it if the secret was ever committed.

## Commit path

The container is never given a way to commit: every gitdir is read-only, so
`commit` fails at lock creation like any other history write. After the
container exits, on the host, `functions/worktree.sh` shows the change and a
commit message, requires an explicit `y` on `/dev/tty`, and only then runs
`git add -A` + `git commit` with the host's own identity. There is no flag,
environment variable or unattended path that skips the approval.

Nothing is pushed. No forge credential and no real remote URL enters the
container for this feature, and no host-side step here contacts a remote; an
approved run prints the `git push` command for the human to run.

**Reviewing does not touch the main repository.** `git add -A -N` would let
one `git diff HEAD` cover untracked files too, but it writes to the shared
object store:

`M` —
```
$ before=$(find .git/objects -type f | wc -l)   # 4
$ git add -A -N
$ after=$(find .git/objects -type f | wc -l)    # 5
```

One loose object (the empty-blob placeholder). The diff state therefore
renders untracked files with `git diff --no-index` instead, which never opens
the object database for writing, so a rejected run leaves the main
repository's objects and index byte-for-byte unchanged.

## Commit message file

The agent writes its proposed message to `$HOME/.sandbox-commit-message` inside
the container. That path is a single-file read-write bind of
`~/.agent/worktrees/<project>-<hash>/.commit-message-<branch digest>` on the
host, beside the lock: outside the worktree, so the message cannot be swept
into the commit it describes, and its directory is never bound, so the bind
reaches no other host file (`worktree_message_file_ensure()`,
`functions/worktree.sh`; the bind is in `configure_agent()`,
`functions/agents.sh`).

The file belongs to the worktree, not to one run (`M`, `worktree_check.sh`
W3c, W6b, W12f, W13c):

| event | message file |
| --- | --- |
| worktree created | emptied: anything there was left by an earlier worktree on that branch name |
| re-run from the reject menu, or resumed by a later `--worktree` run after keep or a crash | kept as the earlier session left it |
| commit lands | deleted |
| discard | deleted |

A carried-over message can be stale, so the agent is told the file may already
hold an earlier session's message and to revise it, and the review labels a
message whose bytes did not change during the session under review as
`written by the agent in an earlier session, unchanged in this one` (`M`, W9b,
W9c). The file's hash is taken as each session starts
(`worktree_message_snapshot()`).

**A symlink or any other non-regular file at the host path refuses the run.**
A bind follows a symlinked source to its target (`D`; same reasoning as
`project-config-masking.md`), so a link there would bind whatever it names
read-write into the container, and emptying it at creation would truncate that
target. Checked when the worktree is prepared and again immediately before the
bind, since the image build runs in between (`M`, W6c: refused, the target's
content and mode unchanged).

Carrying the message forward opens no new channel into the next session: that
session already reads everything the previous one left in the worktree (`D`).

## Branch names

`M` — `git check-ref-format` is not sufficient validation on its own. It
**accepts** a leading `-`:

```
  'good'       ACCEPT
  'feat/x'     ACCEPT
  'bad..name'  reject
  '-lead'      ACCEPT
  'sp ace'     reject
  'tilde~'     reject
  'end.lock'   reject
  ''           reject
  'a//b'       reject
```

`agent/-lead` would be read as an option by the host-side git commands the
feature runs, so a leading `-` is rejected separately, as are `.` and `..`
path components (the worktree's on-disk path is derived from the branch
name).

## Worktree path key

Worktrees live at `$HOME/.agent/worktrees/<basename>-<8-hex-digest>/<branch>`,
where the digest covers the checkout's absolute path. The basename alone
collides across two checkouts sharing a directory name, and the collision is
indistinguishable from a legitimate resume — one repository's agent would
reattach the other's worktree and the approved commit would land on the wrong
project's branch.

## Concurrency

Shared resource: one checkout and one index per worktree. Two runs in it
means two agents editing one tree.

**Creation is guarded by git itself, atomically.** `M` — eight concurrent
`git worktree add -b agent/race` against one repository, exactly one
winner; the rest: `fatal: a branch named 'agent/race' already exists`.
Ref creation is a compare-and-swap against "absent" — `M`,
`git update-ref refs/heads/x HEAD ""` a second time:
`cannot lock ref 'refs/heads/x': reference already exists`.

**Resume is not guarded by git, and cannot be.** A resumed run creates no
worktree and no ref, so no git-side check fires. The state a resume finds —
`agent/<branch>` plus its worktree, both present — is also the state a live
run, a crashed run and a landed run leave behind: `agent/<branch>` is the
run's output and outlives it (an approved run keeps the ref and removes the
worktree, `worktree_after_commit()`), so ref existence does not encode
whether a run is in progress (`D`).

**`git worktree lock` is not mutual exclusion.** It guards
`remove`/`prune`/`move`. `M` — inside a worktree locked with
`git worktree lock --reason probe`, a second process committed normally
(`08786bb commit made while LOCKED`); `git worktree remove` on it refused:
`fatal: cannot remove a locked working tree, lock reason: probe`.

**What enforces it:** a lock directory beside the per-project worktree
directory, never inside it, so the container can neither read nor forge it
(`worktree_lock_acquire()`, `functions/worktree.sh`). `mkdir` is the atomic
primitive; the directory records the owner's pid and host. Four outcomes:

| lock state | result |
| --- | --- |
| absent | acquired |
| owner pid alive, same host | refused, naming the pid |
| owner pid gone, same host | taken over — this is what makes crash-resume safe |
| owner host ≠ this host | refused, never taken over |

The host field is load-bearing when `$HOME` is a network mount: two
machines then share this lock path and the worktree it guards, and
`kill -0` on a pid number says nothing about a process on the other
machine. Same PID-reuse caveat as any pid-file scheme; a false "still
alive" costs a refused run, never data loss.

The lock is taken before the collision policy reads the repository state,
not after.

**`flock(2)` does not fit this program.** A bash-held descriptor is not
close-on-exec, and the lock holder launches a container, so the container
and anything the agent spawns inside it inherit the lock. `M` — owner takes
`flock -n 9`, forks a child, is `SIGKILL`ed:

```
owner SIGKILLed; child 11352 alive: yes
   new run REFUSED -- lock still held via the inherited fd
   after the child dies: ACQUIRED
```

**Release** is registered by `worktree_lock_acquire()` with
`register_cleanup_hook()` (`functions/cleanup.sh`) at the moment the lock is
taken, so the hook exists exactly when the lock does; the EXIT trap that
runs it names neither the lock nor this feature. The worktree itself is
never removed by that trap — a run killed before its review leaves the
checkout for inspection and for a later resumed run, and only the lock goes.

## Reproduction

```
./tests/git-escape/worktree_check.sh    # host-side, no apptainer needed
./tests/git-escape/run.sh --negative    # meta-test: assertions must FAIL
./tests/git-escape/run.sh               # full probe, needs apptainer
```

`worktree_check.sh` calls the real functions against real fixtures and
asserts the three masks are produced, plus a negative control showing the
worktree's `.git` is *not* masked without the worktree root — so the
assertion cannot pass for free. It also drives the lock through all four
of its outcomes (live owner refused, dead local owner taken over,
foreign-host owner refused, release reached through the registered hook).
`run.sh`'s A10/A11 assert the same boundary from inside a container.

The two facts above that the harness does not cover — `git worktree lock`
being advisory, and `flock`'s inherited descriptor — reproduce standalone:

```
# git worktree lock guards remove/prune/move, not use
id='-c user.name=probe -c user.email=probe@invalid'
git init -q main && git -C main $id commit -q --allow-empty -m base
git -C main worktree add -q -b agent/l ../wt-l HEAD
git -C main worktree lock ../wt-l --reason probe
( cd wt-l && date > f && git add f && git $id commit -qm "while LOCKED" ) # succeeds
git -C main worktree remove ../wt-l                                      # refuses

# an flock is inherited by children and outlives the owner's SIGKILL
printf '%s\n' '#!/bin/bash' 'exec 9>lock.file' 'flock -n 9 || exit 1' \
    'sleep 300 & echo $! > child.pid' 'sleep 0.3' 'kill -9 $$' > owner.sh
bash owner.sh; sleep 0.5
flock -n lock.file -c true && echo "released" || echo "still held by the child"
kill -9 "$(cat child.pid)"; sleep 0.3
flock -n lock.file -c true && echo "released once the child is gone"
```

## Status of the container-side half

`M` — the read-only binds are produced, verified host-side (49/49,
`worktree_check.sh`). `M` — the assertions can fail: the negative control
fails all seven worktree assertions with no mask. `D` — that the kernel
refuses writes through these particular binds from inside a live container
follows from the same bind mechanism measured for every other gitdir in
`git-breakout.md`, but has not been re-measured for the worktree paths
specifically; that needs an apptainer install.
