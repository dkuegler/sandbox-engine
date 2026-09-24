# Parallelization: how claude-code, omp, and opencode handle concurrent sessions

Fact record. Last verified 2026-09-17.

opencode wants a server process to attach to, because sessions and auth
supposedly live in a shared database that concurrent processes corrupt or
lock. This page determines what claude-code and omp do about the same
problem, whether opencode's server mode is usable from inside the sandbox
given `--containall` and the bind layout, and what `sandbox.sh` would have
to own to fix it.

**Method.** No `apptainer` binary is available in this environment, so the
sandbox itself could not be launched end-to-end. opencode 2.0.6 was installed
directly (`curl -fsSL https://opencode.ai/v2/install`, into a throwaway
`$HOME`) and driven with real `opencode run`/`opencode service`/`opencode
session` invocations — the same binary and CLI surface `sandbox/agent/
Dockerfile.template` installs, one version ahead of what that Dockerfile's
comment describes. The apptainer-specific claims below (PID-namespace
teardown, shared network namespace) rest on apptainer's own documented flag
semantics (cited) plus a direct kernel-level reproduction of the PID
namespace mechanism via `unshare --pid --fork`, not on running `sandbox.sh`
itself. omp's findings come from live inspection of a real `~/.omp` install
with a real concurrent worker process attached. claude-code's session-storage
model is sourced from its own docs and a public GitHub issue (cited); the
`claude` binary was not available to drive directly.

## What each agent actually does

| | storage | daemon/server | concurrency unit |
|---|---|---|---|
| **claude-code** | one JSONL file per session, under `~/.claude/projects/<project-hash>/<session-id>.jsonl`; no shared database | none — every `claude` invocation is a fully independent process | one file per session; safe by construction *between* projects, but Anthropic's own tracker has an open bug (anthropics/claude-code#26964) where two concurrent sessions in the **same** project directory cross-contaminate each other's JSONL — entries from one session land in the other's file |
| **omp** | `~/.omp/agent/{agent,history,models}.db` (+ `-wal`/`-shm`), SQLite in WAL mode, shared across every project | none — no `serve`/`daemon`/`service` subcommand exists (`omp --help` lists none); every `omp` invocation opens the databases directly | per-process, coordinated by SQLite's own WAL locking, not by omp |
| **opencode** | `~/.local/share/opencode/opencode.db` (+`-wal`/`-shm`), SQLite, shared across every project; scoped internally by `project`/`workspace`/`session_v2` tables | yes — `opencode serve --service`, auto-spawned by the first CLI invocation that doesn't find one already running, registered in `~/.local/state/opencode/service.json` **and** `~/.config/opencode/service.json` (a password-bearing pointer: pid, `http://127.0.0.1:<port>`, password) | one shared background process per machine (default); `--standalone` forces a private per-invocation server; `--server <url>` attaches to an explicit one |

The premise that motivated this investigation ("a shared database that
concurrent processes corrupt or lock") does not match either omp's or
opencode's actual design. Both use SQLite in WAL mode, which is explicitly
built for multiple concurrent readers plus one writer; neither showed
corruption in any test below (`PRAGMA integrity_check` returned `ok` for
opencode's db after repeated kill/respawn cycles, and for all three of omp's
live databases while a second concurrent omp process was attached). The
actual failure mode is architectural, not a database-locking bug, and it is
specific to opencode.

## Observed failure mode: opencode's server dies with the container that spawned it

opencode's server-mode design assumes the background service outlives any
one CLI invocation: the first `opencode run`/`opencode session list`/etc.
auto-spawns `opencode serve --service` as a detached child, and every later
invocation on the machine is supposed to find it via `service.json` and
reuse it. Measured directly:

- A clean invocation with no server running spawns one (`opencode serve
  --service`, its own pid, its own `setsid`-style detachment from the CLI's
  process group) and takes it from cold start to a served response in
  **9.4s** and, in a repeat run, **10.37s** (`time timeout 20 opencode run
  "hi from c"`) — dominated by `location services booted`, provider/model
  config loading, and file-watcher setup logged to
  `~/.local/share/opencode/log/opencode.log`.
- Two, then three, truly concurrent `opencode run` invocations against
  *different* project directories (`/dev/shm/oc-project-{a,b}` and
  `{d,e,f}`), sharing one `$HOME`, raced to spawn the server exactly once
  each time — never two competing daemons — and both/all projects got
  correct, separately-scoped responses (one for `oc-project-b`, naming its
  own directory, while sharing the same daemon and database as `a`).
  opencode's own spawn-locking held under real concurrency in every trial
  run here.
- Hard-killing the daemon (`pkill -9`) while leaving its stale
  `service.json` in place (pid and port now dead) does not wedge the next
  invocation: it detects the dead server and respawns transparently, paying
  the same ~9–10s cost again.

None of that is a bug — it is opencode behaving exactly as designed, one
persistent per-machine daemon, reused across invocations, self-healing if
killed. The actual problem is what `--containall` does to that design, and
it was confirmed two ways:

1. **Documented.** Apptainer's own docs
   (apptainer.org/docs/user/main/cli/apptainer_exec.html;
   apptainer.org/user-docs/2.5/appendix.html) state `--containall` = `
   --contain` (fresh, empty `/tmp` and `$HOME`) **plus `--ipc` plus `--pid`**
   — a new PID namespace for the exec'd command, distinct from the host's.
2. **Reproduced.** A new PID namespace kills every process inside it the
   instant its PID-1 process exits, including a process that has already
   detached itself (`setsid`) specifically to survive its parent — this is
   a kernel property of `CLONE_NEWPID`, not something a well-behaved daemon
   can opt out of. Verified directly with `unshare --user --pid
   --mount-proc --fork --map-root-user bash -c '...'`: a `setsid`-detached
   `sleep 60` visibly running as PID 3 inside the new namespace (confirmed
   via `ps -ef` from inside it) vanished completely the instant the
   namespace's PID-1 process returned — not because it exited on its own,
   but because the kernel tore down the whole namespace under it.

Put together: any `opencode serve --service` that the opencode branch of
`configure_agent()` (`functions/agents.sh`) auto-spawns via
`RUN_CMD=(opencode "${ARGS[@]}")` is a child of that one apptainer
`exec --containall` invocation's PID namespace, so it dies the instant that
invocation's process exits — every single time, regardless of how the
daemon tries to detach. Meanwhile `~/.local/state/opencode/service.json`
(`~/.local/state/opencode` is bound **read-write** by that same branch,
unscoped by project, identical for every `./sandbox.sh opencode ...`
invocation on the host) survives on the host after the container that wrote
it is gone. The net effect measured above — the "self-healing respawn" —
is not a convenience, it is *mandatory* on every single invocation: opencode
can never actually observe a live server it didn't just spawn itself in the
same container, so every run pays the full ~9–10s cold-start tax that
opencode's own design exists to amortize away.

That also creates a real cross-project hazard that follows directly from two
things already established above, without needing a nested apptainer test
to demonstrate the mechanism: apptainer instances share the host's network
namespace by default (unprivileged apptainer has no `--net` flag without
root, and this repo never passes one), and the shared, unscoped-by-project
bind above means every concurrent `./sandbox.sh opencode ...` invocation
reads and writes the *same* `service.json`. So if two invocations against
two *different* projects genuinely overlap in time, the second one to start
will find the first one's live `service.json` (a real, host-reachable
`127.0.0.1:<port>`, exactly as this repeatedly measured above for
same-project-directory races) and attach to it as a client rather than
spawning its own — meaning one container's opencode server ends up quietly
serving another, unrelated project's session. When the first container's
own agent turn finishes and its process exits, its PID namespace — and the
server living in it — dies, silently taking down the second project's
in-flight session with it. This half of the chain was not independently
reproduced end-to-end (that needs two real concurrent `sandbox.sh`
invocations sharing a real apptainer host), but it follows directly from two
independently-verified facts above (shared netns; shared, live,
per-machine-not-per-project `service.json`) plus the auto-attach behavior
already measured directly in the two/three-way same-host races.

## Is opencode's server mode "usable" inside the sandbox?

Reachable, yes — loopback is shared regardless of `--pid`/`--containall`
(PID and network namespaces are independent axes; apptainer shares the host
netns by default, since unprivileged apptainer's `--net` needs root, which
this repo never passes). *Persistent and reusable*, no — not as currently
wired, because the server always ends up a child of whichever single
`apptainer exec` invocation happened to spawn it, and that invocation's own
lifetime is exactly one `sandbox.sh` run.

## Recommendation

Run the opencode background service the same shape the git MCP sidecar used
to — as its own long-lived `apptainer instance`, started outside any
per-invocation `exec`, so its process tree is never inside the PID namespace
that a single agent run tears down on exit. (That sidecar itself was
deleted 2026-09-17 in favor of a real `git` binary in the agent image, see
`docs/git-breakout.md` — but the pattern it used for the git sidecar is
still the right one to reuse here.) Concretely:

- **One server per project**, not per user and not per run. Per-run is what
  happens today by accident and defeats the entire point of a persistent
  server (same ~9–10s tax, forever). Per-user (one daemon shared by every
  project on the host) is what the *unscoped* bind layout produces today,
  and it is exactly the mechanism behind the cross-project hazard above:
  one project's container lifecycle becomes a single point of failure for
  every other concurrently-running project's session. Per-project matches
  how opencode already partitions its own data internally (`project`,
  `project_directory`, `workspace` tables in the shared db).
- `sandbox.sh` would need to: (1) start-or-attach an `opencode serve`
  apptainer instance keyed by the project directory; (2) point the per-run
  agent container at it with opencode's own `--server <url>` flag (already
  a first-class CLI flag, no fork needed) instead of leaving
  `RUN_CMD=(opencode "${ARGS[@]}")` to auto-spawn one inside the ephemeral
  container; (3) forward the server's password (`service.json`'s
  `password` field) the same way `RUN_DIR`-scoped state is handed to the
  agent container today (`ensure_run_dir()`, `functions/agents.sh`); (4)
  reap orphaned per-project server instances on a later run, since a
  project can be abandoned or renamed and nothing else will ever stop that
  instance otherwise.
- claude-code needs none of this — its one-file-per-session model has no
  shared-daemon lifecycle to manage, and the existing bind layout (the
  claude branch of `configure_agent()`, `functions/agents.sh`) is already
  correct for it. Its own concurrency bug (cross-session JSONL
  contamination, anthropics/claude-code#26964) is upstream and orthogonal
  to sandboxing; nothing in this bind layout causes or fixes it.
- omp needs none of this either — no daemon exists to place anywhere, and
  its SQLite WAL databases already tolerate real concurrent processes.

These acceptance criteria are concrete enough to implement directly: a
per-project persistent `opencode serve` instance, wired the same way the
git sidecar already was, with a measurable before/after on invocation
latency.
