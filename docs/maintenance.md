# Recurring maintenance

Last verified: 2026-09-24.

Subject: the checks whose omission is silent. None of the items below fails
loudly when it is skipped — the sandbox keeps starting, the suite keeps passing,
and the property being maintained is simply gone. Each entry names its trigger,
why it goes stale, the procedure, and the condition that decides pass or fail.
The detail stays on the subject's own page; this page holds the schedule and the
pointer.

Most of these checks exist because the sandbox contains a moving target: the
agent CLIs ship continuously, and every one of them reads configuration and
credentials from paths this repository enumerates by hand.

## Triggers

| trigger | run |
| --- | --- |
| an agent CLI version changes in `sandbox/agent/Dockerfile.template` | config surfaces, key-syntax scans, `$HOME` surfaces, image installers |
| a new agent is onboarded | config surfaces, key-syntax scans, `$HOME` surfaces, image installers |
| any change to `sandbox.sh` or `functions/*.sh` | standing verification |
| quarterly, with no other trigger | config surfaces, image installers, page dates |

## Config surfaces the agent CLIs load

**Why it goes stale.** `config/mask.toml` (loaded by
`project_config_mask_load()`, `functions/binds.sh`) discovers nothing: it is a
literal table. A CLI that starts reading a new instruction file, rule directory
or settings path gains an unmasked surface, and nothing reports it — the new
path is simply writable by every run and loads on the next start.

**Procedure and pass condition.** The four-step review is in
[`project-config-masking.md`](project-config-masking.md), "Maintenance". Pass:
the set difference in both directions is empty, or every residual has a
recorded reason on that page.

## API-key syntax in the credential scans

**Why it goes stale.** `scan_omp_api_keys()` and `scan_opencode_api_keys()`
(`functions/agents.sh`) refuse to launch when a mounted config file carries a
literal credential, and forward the named environment variable when it carries a
reference instead. Both recognise the syntax by regex — `apiKey: VALUE` in YAML,
`"apiKey": "{env:VAR}"` in JSON, with `!cmd` and `{file:...}` treated as already
indirected. A renamed key, a new nesting, or a new reference form upstream is not
a parse error: the line stops matching, the scan finds nothing, and a live
credential is mounted into every run with no warning. The failure direction is
open.

**Procedure.** After a CLI upgrade, re-read that tool's documentation for how a
provider credential is spelled in its config file, and compare against the two
regexes. Then exercise both directions per agent: a config carrying a literal
key must refuse the launch, and a config carrying a reference must start with the
variable forwarded.

**Pass condition.** A literal key still aborts the run with the "sets apiKey to a
literal value" error, for each supported agent, on that agent's current config
syntax.

## The `$HOME` agent surfaces

**Why it goes stale.** `configure_agent()` (`functions/agents.sh`) binds each
agent's writable state under `$HOME` path by path (`bind_state_rw()`), its
config read-only where the host has it (`bind_ro()`), and nothing else; omp's
`~/.omp` is a per-run directory whose unlisted entries are bound read-only
(`functions/omp-home.sh`). A path upstream adds is therefore unbound by default,
which fails safe for containment but not for function: a new state file the CLI
must persist is silently lost. The silent containment risk is inside the paths
that ARE bound read-write from the host as whole directories — claude's
`~/.claude/projects`, `shell-snapshots`, `todos`, `statsig`, `file-history`
and `ide` — where a new config file, executable or server
registry the CLI starts keeping there is writable by every run and read by the
next unsandboxed one. The sandbox-owned per-project directories under
`~/.agent/` (`omp-history`, `omp-logs`, `opencode-share`, `opencode-cache`) are
read by no host CLI, so they do not carry that risk. The per-agent comment
blocks in `configure_agent()` are the enumeration to keep current, each
writable path with its reason.

**Procedure.** For each supported agent, list the paths the new version reads
and writes under `$HOME`, and reconcile against that agent's branch: new config
and instruction paths get a read-only bind; new state paths are bound writable
only when the run genuinely needs them to persist; anything new inside a
read-write directory that the CLI loads as configuration, executes, or uses to
reach another process gets a read-only bind, a per-run directory, or is left
unbound.

**Pass condition.** Every path the CLI reads as configuration or loads as
instructions under `$HOME` is named in the branch; every writable path is named
in its comment with a reason; nothing inside a read-write directory is loaded
as configuration, executed, or used to reach a host process.

## Agent image installers

**Why it goes stale.** `sandbox/agent/Dockerfile.template` installs the three
agents from upstream endpoints, not from pinned artifacts: an npm package for
claude on a NodeSource LTS repository, a piped install script for opencode with
a `sed` rewrite of its `INSTALL_DIR`, and a piped install script for omp. `D` —
the opencode endpoint has already moved once (2026-09-15): `opencode.ai/install.sh`
returns 404, `opencode.ai/v2/install` is the installer, and `opencode.ai/install`
redirects to a moving `dev`-branch file, not something to pin a build to. The
`sed` rewrites the script's `INSTALL_DIR=$HOME/.opencode/bin`; a renamed variable
makes it a silent no-op. A moved installer, a renamed install directory, or a
script that changes what it writes can produce an image that builds and ships
without a working agent.

**Procedure.** Rebuild each agent image and run the agent's own version command
inside it. The `test -x /usr/local/opencode/bin/opencode` guard in the opencode
stage exists for exactly this and must stay: a piped installer that fails
silently still exits 0.

**Pass condition.** Each image builds, and each agent reports a version from
inside its container.

## Standing verification

**Why it goes stale.** The mask assertions are kernel refusals, and a suite of
refusals cannot tell a working control from a broken fixture.

**Procedure.** On every change to `sandbox.sh` or `functions/*.sh`: `bash -n` on
each changed script, then `shellcheck sandbox.sh functions/*.sh` in one
invocation so `source` targets resolve, and
`shellcheck -S warning tests/git-escape/*.sh`. Then the suite:

```
./tests/git-escape/worktree_check.sh
./tests/git-escape/run.sh
./tests/git-escape/run.sh --negative
```

`worktree_check.sh` runs on the host alone; `run.sh` needs `apptainer`.

**Pass condition.** `worktree_check.sh` reports no failure; `run.sh` and its
negative run give the result recorded in [`git-breakout.md`](git-breakout.md),
"Standing verification". A negative run that stops failing means the suite can
no longer fail at all.

## Page dates and evidence labels

**Why it goes stale.** Every page here carries a "last verified" date and labels
each claim `M` (measured, output quoted) or `D` (derived, not exercised). The
labels decay faster than the claims: an `M` re-stated after a rewrite, without
the measurement being re-run, is a `D` wearing an `M`.

**Procedure.** Quarterly, per page: run its Reproduction section, confirm the
quoted output still matches, and move the header date. Where a measurement can no
longer be produced — no host with `apptainer`, an upstream endpoint gone — the
claim is demoted to `D` with the reason, never carried forward as `M`.

**Pass condition.** No page carries a date older than the review interval, and no
`M` on any page lacks output that was reproduced within it.
