# Project config masking: what reads each path, and what the session sees

Last verified: 2026-09-23.

Subject: every path a supported agent CLI — or the host tooling that shares the
checkout with it — reads as configuration; the classification those paths are
graded against; the rule that decides what a sandboxed session sees at each of
them (`mask_project_agent_config()`, `functions/binds.sh`, over the table in
`config/mask.yml`); the host-side gate on `sandbox.yml`; and where a config file
the agent creates surfaces. `M` = measured, output quoted. `D` = derived from
source or documentation, not exercised.

## The load-bearing fact

**Some files in a checkout are not data — they are code that the human's own
machine runs, unprompted, outside any container, or instructions the next
session loads before its first prompt.** The sandbox contains what the agent
does *during* the run. It does not contain what the human's editor, shell or
agent CLI does with the checkout *after* the run, and every one of those reads
configuration out of the project without asking.

An agent that can write those files does not need to escape the sandbox. It only
has to wait.

## Two axes: who reads it, and whether the diff is the payload

**Where the read happens.** A read performed outside the container cannot be
intercepted by any bind, in either orientation. Four readers exist, in
decreasing order of what a mask can do about them:

| reader | when | a container mask can intercept it |
| --- | --- | --- |
| the sandbox itself | host-side, before any container exists | never |
| non-agent host tooling (editor, direnv, git) | whenever the human touches the checkout | never |
| the agent CLI, before the model runs | every CLI startup, host or container | only for the container's own run |
| the agent CLI, into the model's context | every CLI startup, host or container | only for the container's own run |

**Whether the diff is the payload.** For some config the file's content is
everything the file does: reading the diff is reading the whole behaviour. For
the rest the file is a *pointer* — it names a command, a script path, a
repository and revision, or a URL — and the thing named is not in the diff, and
is generally not on the mask list at all. A human reviewing such a diff has
reviewed the reference, not the referent.

## The four classes

| class | entries | reader, and what triggers the read | what the read produces | diff = payload |
| --- | --- | --- | --- | --- |
| **A — pre-container** | `sandbox.yml` | the sandbox itself: `parse_sandbox_yml` (`functions/sandbox_yml.sh`) runs host-side, before `EXEC_ARGV` starts any container | the launching run's own binds, base image and environment | yes |
| **B — host execution, no agent in the loop** | `.envrc`, `.vscode/tasks.json`, `.vscode/launch.json`, `.devcontainer/devcontainer.json`, `.pre-commit-config.yaml` | direnv on `cd`; VS Code on folder open (`runOptions.runOn: folderOpen`) and on debug (`preLaunchTask`, `postDebugTask`); `initializeCommand` on the **host** before any container is built; the commit path, for pre-commit | a process, run as the human, unprompted | no |
| **C — host execution at agent-CLI startup** | `mcp.json`, `.mcp.json`, `.claude/mcp.json`, `.claude/.mcp.json`, `.omp/mcp.json`, `.omp/.mcp.json`, `.cursor/mcp.json`, `.windsurf/mcp_config.json`, `.vscode/mcp.json`, `.codex/config.toml`, `.gemini/settings.json`, `opencode.json`, `opencode.jsonc`, `.claude/settings.json`, `.claude/settings.local.json`, `.omp/config.yml`, `.omp/settings.json`, `.claude/hooks`, `.claude/plugins`, `.opencode/plugin`, `.opencode/plugins`, `.opencode/tool`, `.opencode/tools` | the agent CLI, at startup, before the model is consulted | a process (an MCP server `command`, `hooks`, `apiKeyHelper`, `statusLine`, `lsp.*.command`, `formatter.*.command`) or code loaded in-process (plugins, tools) | no |
| **D — instruction text** | `.claude/agents`, `.claude/commands`, `.claude/skills`, `.claude/rules`, `.claude/output-styles`, `.opencode/agent`, `.opencode/agents`, `.opencode/command`, `.opencode/commands`, `.opencode/mode`, `.opencode/modes`, `.opencode/skill`, `.opencode/skills` | the agent CLI, into the system prompt, at startup | text; it takes effect only if the model acts on it | yes |

`D` — every trigger above is from the respective tool's own documentation. None
of them prompts.

The four classes partition the `config/mask.yml` table exactly, with one
residual: `.opencode/theme` and `.opencode/themes` are masked for uniformity
with the rest of `.opencode/`, and are neither executed nor read into the
context. `M` — the table holds 44 entries; see Reproduction. `D` — the
assignment of each entry to a class: 1 class A, 5 class B, 23 class C and 13
class D, plus the 2 residual.

The ordering is not a severity ranking of individual files. It is the order in
which the containment loses leverage: class A is decided before any container
exists, class B never involves the sandbox at all, and classes C and D are the
only two a mask on this run's own binds can affect.

## The convention: the session sees what the branch commits

The mask list is fixed; the decision is not. For every path on the list, per
bound checkout:

**visible to the session ⇔ tracked in that checkout's HEAD tree AND identical
to it in the working tree.**

The committed tree is the trust anchor, and it is safe for exactly one reason:
only the user commits. Commits are the human's act, so committed config is
config the human has already seen and chosen. Everything else in the checkout
is uncommitted state — the user's local drafts, local secrets, or something an
earlier agent left behind — and the session is blind to it.

`D` — the predicate is computed host-side from the checkout's own plumbing
(`git ls-tree -r HEAD`, `git diff HEAD --quiet`) by `config_path_state()`; the
agent holds no writable `.git` anywhere (all gitdirs are masked read-only), so
it cannot influence the decision, and a git read that fails for any reason other
than "no repository" or "no commit yet" refuses the run rather than reading as an
empty result. A directory that is not a git checkout at all degrades, not
refuses: nothing is committed anywhere, so every on-disk list path is
uncommitted and hidden.

The states per path, and what the container sees (`D` — `config_mask_one()`;
the Reproduction below measures the first three):

| state | container sees | host effect |
| --- | --- | --- |
| committed & clean | a fresh per-run **copy** of the committed content, read-only | none |
| uncommitted (untracked, or tracked with local drift) | an empty placeholder — or the HEAD copy, so the session sees the branch's config, not the local deltas | none |
| absent on disk | **not bound at all** | none |
| a symlink, on disk or in HEAD | nothing: the run is refused | none |

**Committed paths are read-only.** An agent write there would persist
uncommitted on the host and run outside the sandbox later. The copy is not a
self-bind (`-B p:p:ro` mounts the host inode), because a read-only bind on a
shared filesystem is defeatable by a hardlink alias — `ln p alias` needs only
write access to the alias's parent directory, and a write through the alias
mutates the committed file on the host. The copy is a different inode: every
alias the agent can create hits the copy, and the checkout stays untouched.

**Uncommitted paths are hidden.** The session cannot read the user's local
config and cannot write the path. An untracked path hides behind an empty
placeholder; a tracked path with local drift hides behind the committed copy, so
the session sees the branch's config and never the local deltas or the local
secrets they may hold. Over an *existing* destination this materializes nothing
on the host.

**Absent paths are not bound.** Existence is not the gate; the commit is. There
is nothing to hide at a path that does not exist, and binding one would make
apptainer materialize an empty placeholder in the checkout — empty files that
land in `git status`, get swept into commits, and turn "no config" into "a
zero-byte config that is a parse error" on the human's next bare-host run.

**Symlinks are refused.** A bind is resolved to wherever a link points, not to
the path it names: as a bind source a link sends the mount to some other host
file, and as a destination it moves the mask off the path the agent CLI reads.
A config path must therefore be a regular file or a directory, in the working
tree and in HEAD. A link *inside* a masked directory is unaffected — it is
copied from HEAD and only ever resolved inside the container.

**One exception: `sandbox.yml`** (`D` — `require_trusted_sandbox_yml()`). The
sandbox parses it on the host before every launch, so an agent-authored copy
would shape the *next run's own containment* and no container mask can
intercept that read — the read happens outside every container. The gate
therefore sits on the read itself, in `parse_sandbox_yml()`
(`functions/sandbox_yml.sh`), one layer earlier than the rest of the convention:
a `sandbox.yml` that is not tracked in HEAD and identical to it is **refused
outright**, before a single key is parsed. The refusal names what the
uncommitted version would change about the run, setting by setting ("mounts the
host path X into every sandbox READ-WRITE", "changes the sandbox base image to
the Y preset") rather than dumping the file, and committing it is how you
accept it. Comment-only and blank-line-only edits are ignored, so re-flowing a
comment cannot trip the fence. A symlink at that path is refused too: git
vouches for the link while the parser reads its target, which is a different
file and may be untracked. On the table itself `sandbox.yml` is an ordinary
row, masked exactly like every other entry.

## The mask table

`D` — `config/mask.yml` is the perimeter: nothing discovers config paths, so a path
that is not on the table is not masked. Each entry is `- file: PATH` or
`- dir: PATH` under the `project:` key, relative to the checkout root; a `dir`
entry covers everything beneath it. The loader, `project_config_mask_load()`,
accepts only that strict subset of YAML and refuses the run on anything else —
a missing or empty file, an unknown key, quoting, a trailing comment, an
absolute path or a `..` component — because a row that silently dropped out
would look exactly like a mask that works. The table is located relative to
`functions/binds.sh`, never through the environment.

## Where an agent-created config file can go

A file the agent creates at an absent config path:

1. does not load in the current session — config is read at CLI startup;
2. is invisible to every later sandboxed run — it is uncommitted, so the
   convention hides it next run;
3. reaches the host checkout or the worktree branch only through a human act.

`D` — in normal mode there is no approval gate, so the review is the exit report:
`report_created_config_paths()` names every list path that was absent at launch
and exists now, lists directory contents, and prints file content through the
same terminal-escape sanitizer the worktree review uses. A path that is not a
regular file — a FIFO, a symlink, a device — is named by type and never read,
since reading it would block the report or print another file's bytes under its
name. Nothing is deleted and nothing is committed automatically. The same report
runs after every round in worktree mode when the main checkout is mounted
read-write, because the approval gate reviews only the worktree.

In worktree mode, a file created inside the worktree is part of the approval
gate's review like any other untracked file, and reaches the branch only if the
human approves the commit.

## The startup block

Every run states the partition before the agent starts (`D` —
`report_config_masking()`):

```
sandbox: agent-config masking (the session sees a known config path's committed content only):
  read-only, committed (the human authored it at some commit):
    <paths>
  hidden, not committed (the session sees nothing at these paths):
    <paths>
  not present at launch, not bound (the agent may create files there; anything it creates is surfaced when the run ends):
    <paths>
```

It doubles as the plant tripwire: a config file that appeared in a checkout
uninvited — a plant left by a crashed run — is uncommitted, so it shows up in
the hidden section by name, every run, until the human acts on it. That is also
the residual risk of the unbound-absent stance: a plant from a crashed run
persists untracked on the host, inert inside the sandbox, live for the human's
bare-host sessions, until the human removes it.

In worktree mode two checkouts are masked — the main one and the worktree — and
both appear in the block, each row tagged `[main]` or `[worktree]`, followed by
a line stating how the main checkout is mounted this run and so whether
anything can be created at its paths.

## Reproduction

The number of entries on the table, read through the loader itself (which
refuses an unusable table rather than returning an empty one):

```
cd <repo>
bash -c 'set -euo pipefail
source functions/log.sh; source functions/agents.sh; source functions/binds.sh
project_config_mask_load
echo "${#PROJECT_CONFIG_MASK_PATH[@]}"'
```

`M` — prints `44`.

The masked set itself is produced by calling the real function; nothing about it
needs a container. `/proj` below is a checkout with one path in each state: a
committed, clean `.claude/settings.json`; a committed `opencode.json` with an
uncommitted edit on top; a staged-but-uncommitted `.omp/config.yml`; an
untracked `mcp.json`; and no `sandbox.yml` at all.

```
cd <repo>
bash -c '
source functions/log.sh; source functions/agents.sh; source functions/binds.sh
RUN_DIR="$(mktemp -d)"; BINDS=(); RO_MASKED=()
mask_project_agent_config /proj
printf "%s\n" "${RO_MASKED[@]}" | sed "s|^/proj/||"
rm -rf "$RUN_DIR"'
```

`M` — prints:

```
.claude/settings.json (committed; read-only copy)
opencode.json (uncommitted changes; hidden, session sees the committed version)
.omp/config.yml (uncommitted; hidden)
mcp.json (uncommitted; hidden)
```

Three things to read out of that output. **No absent path appears at all** —
every other table path is absent in this fixture and therefore unbound,
including `sandbox.yml`. **Staging is not committing** — `.omp/config.yml` is in
the index and still reports `hidden`, since the predicate is HEAD membership,
not index membership. **The committed path's bind source is a copy under
`$RUN_DIR/cfgmask/`**, named by a hash rather than by the path; `M` — `cmp`
against the checkout file reports it byte-identical.

`M` — `git status --porcelain` in the fixture afterwards shows only the three
files the fixture itself created (`A  .omp/config.yml`, ` M opencode.json`,
`?? mcp.json`) and no placeholder litter anywhere. That absence is the
regression to watch: a mask that silently started binding absent destinations
again would put empty files into every run's checkout.

The convention's behaviour is exercised by the permanent suite (the `M`
assertions):

```
./tests/git-escape/worktree_check.sh
```
