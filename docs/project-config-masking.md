# Project config masking: what reads each path, and what the session sees

Last verified: 2026-09-23 (the `config.yml` form: 2026-09-24).

Subject: every path a supported agent CLI — or the host tooling that shares the
checkout with it — reads as configuration; the classification those paths are
graded against; the rule that decides what a sandboxed session sees at each of
them (`mask_project_agent_config()`, `functions/binds.sh`, over the table in
`config/mask.toml`); the host-side gate on `sandbox.yml`; and where a config file
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
| **A — pre-container** | `sandbox.yml` | the sandbox itself: `parse_project_sandbox_config` (`functions/project-sandbox-config.sh`) runs host-side, before `EXEC_ARGV` starts any container | the launching run's own binds, base image and environment | yes |
| **B — host execution, no agent in the loop** | `.envrc`, `.vscode/tasks.json`, `.vscode/launch.json`, `.devcontainer/devcontainer.json`, `.pre-commit-config.yaml` | direnv on `cd`; VS Code on folder open (`runOptions.runOn: folderOpen`) and on debug (`preLaunchTask`, `postDebugTask`); `initializeCommand` on the **host** before any container is built; the commit path, for pre-commit | a process, run as the human, unprompted | no |
| **C — host execution at agent-CLI startup** | `mcp.json`, `.mcp.json`, `.claude/mcp.json`, `.claude/.mcp.json`, `.omp/mcp.json`, `.omp/.mcp.json`, `.cursor/mcp.json`, `.windsurf/mcp_config.json`, `.vscode/mcp.json`, `.codex/config.toml`, `.gemini/settings.json`, `opencode.json`, `opencode.jsonc`, `.claude/settings.json`, `.claude/settings.local.json`, `.omp/config.yml`, `.omp/settings.json`, `.claude/hooks`, `.claude/plugins`, `.opencode/plugin`, `.opencode/plugins`, `.opencode/tool`, `.opencode/tools` | the agent CLI, at startup, before the model is consulted | a process (an MCP server `command`, `hooks`, `apiKeyHelper`, `statusLine`, `lsp.*.command`, `formatter.*.command`) or code loaded in-process (plugins, tools) | no |
| **D — instruction text** | `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, `.github/copilot-instructions.md`, `.claude/agents`, `.claude/commands`, `.claude/skills`, `.claude/rules`, `.claude/output-styles`, `.opencode/agent`, `.opencode/agents`, `.opencode/command`, `.opencode/commands`, `.opencode/mode`, `.opencode/modes`, `.opencode/skill`, `.opencode/skills`, and the sixteen paths under "Instruction surfaces beyond the root files" below | the agent CLI, into the system prompt: at startup for a path at or above the launch directory, and — under claude — on first read of a file in a subdirectory holding one | text; it takes effect only if the model acts on it | yes |

`D` — every trigger above is from the respective tool's own documentation. None
of them prompts.

The four classes partition the `config/mask.toml` table exactly, with one
residual: `.opencode/theme` and `.opencode/themes` are masked for uniformity
with the rest of `.opencode/`, and are neither executed nor read into the
context. `M` — the table holds 64 entries; see Reproduction. `D` — the
assignment of each entry to a class: 1 class A, 5 class B, 23 class C and 33
class D, plus the 2 residual.

The ordering is not a severity ranking of individual files. It is the order in
which the containment loses leverage: class A is decided before any container
exists, class B never involves the sandbox at all, and classes C and D are the
only two a mask on this run's own binds can affect.

## Where in the tree each read reaches

The class says who reads a path and when. It does not say **where the path has
to sit** for that read to happen, and the three supported agent CLIs disagree.
Every row is `D`, from the respective tool's current documentation.

| reader | project instruction and rule files it loads | where it looks | reaches below the launch directory |
| --- | --- | --- | --- |
| claude | `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`; `AGENTS.md` and `.claude/AGENTS.md` only under the conditions below | the launch directory and every directory above it, at launch | **yes** — a subdirectory's `CLAUDE.md`, `CLAUDE.local.md` or `AGENTS.md` is injected when the Read tool opens any file in that subdirectory |
| claude | `.claude/rules/**/*.md` | recursively under `.claude/rules/` | **yes** — rules without `paths:` frontmatter load at launch, path-scoped rules load when a matching file is read |
| omp | `AGENTS.md`, `CLAUDE.md`, `.omp/AGENTS.md`, `.claude/CLAUDE.md`, `.gemini/GEMINI.md`, `.github/copilot-instructions.md` | the launch directory and its ancestors to the repository root; one surviving file per depth, highest-priority provider wins that depth | no — a deeper file is not injected, but its **path** is listed in a `<dir-context>` block that tells the session to read it before editing there |
| omp | `.omp/RULES.md` | the nearest non-empty `.omp/` walking from the launch directory toward the repository root | no — but its body is always-apply: carried in the system prompt on *every* request, not just the first |
| omp | `.omp/rules/*`, `.cursor/rules/*`, `.windsurf/rules/*`, `.clinerules`, `.agent/rules/*`, `.agents/rules/*`, `.github/instructions/**/*.instructions.md` | config directories of the launch directory; `.clinerules` and `.agent*/` walk up; `.github/instructions/` is read recursively | selection is by `globs`/`applyTo`, not by depth; `applyTo: '**'` makes a rule always-apply |
| opencode | `AGENTS.md`, else `CLAUDE.md` | the launch directory and its ancestors, **first match wins** | no — unless `opencode.json` `instructions` names deeper files, a field that accepts globs (`packages/*/AGENTS.md`) and remote `https://` URLs fetched at startup |

**Depth is agent-dependent, and under claude it is not optional.** The same
`sub/AGENTS.md` is inert under opencode, a pointer under omp, and injected
instruction text under claude as soon as the session reads any file in `sub/` —
subject to the `AGENTS.md` conditions below, where a `sub/CLAUDE.md` or
`sub/CLAUDE.local.md` is injected on read unconditionally. Claude Code's
strictest project-instructions setting, `managed-only`, still loads a
subdirectory's `CLAUDE.md` and `.claude/rules/` files on read.

**Claude's `AGENTS.md` handling is conditional, and a mask cannot depend on the
condition.** Reading `AGENTS.md` directly requires Claude Code v2.1.277 or
later, is implemented as the built-in `agents-md` plugin, and is off in any
session that cannot fetch feature flags — Amazon Bedrock and other third-party
providers, telemetry disabled, the first session after an install or upgrade —
or where `disableAllHooks`, `allowManagedHooksOnly`, or a disabled `agents-md`
plugin applies. `D`. Where it is off, `AGENTS.md` still reaches the system
prompt through a `CLAUDE.md` holding `@AGENTS.md` (expanded inline at launch)
or a `CLAUDE.md` symlinked to it; and omp and opencode read it as their primary
project instruction file regardless. A perimeter that tracked the condition
would have to be recomputed per host, per version and per provider, and would
fail open on every one it guessed wrong.

**None of this is a read the model chose to make.** Each of these paths enters
the context as system-authored instruction — in the opening system prompt, or
injected onto a tool result — with no call in the transcript attributable to the
model's own judgement. That is the property that separates a config path from
an ordinary readable file such as a `README.md`, which enters as tool output
the model is free to weigh or ignore, and only when the model asked for it. The
mask is a perimeter over **automatic instruction injection**, not over what a
session is able to read.

### Instruction surfaces beyond the root files

`D` — each of these sixteen paths is read into the system prompt by at least one
supported agent, and each is a table entry; the rows record what reads it and
why it earns a place, which is what an audit of the perimeter checks against.

| path | read by | why it matters |
| --- | --- | --- |
| `.omp/RULES.md` | omp | always-apply — the body rides the system prompt on *every* request, not just the first |
| `.omp/AGENTS.md` | omp | native provider, priority 100: shadows every other context file at that depth |
| `.omp/rules/*.{md,mdc}` | omp | project rules; `alwaysApply: true` is injected verbatim |
| `.claude/CLAUDE.md` | claude, omp | a documented project-instructions location, equal to `./CLAUDE.md` |
| `.claude/AGENTS.md` | claude | loaded with `AGENTS.md`; distinct from the masked `.claude/agents` directory on a case-sensitive filesystem |
| `CLAUDE.local.md` | claude | loads at launch alongside `CLAUDE.md` |
| `.gemini/GEMINI.md` | omp | gemini provider's project context file; the table carries `.gemini/settings.json` too |
| `.github/instructions/**/*.instructions.md` | omp | read recursively; `applyTo: '**'` makes the rule always-apply |
| `.cursor/rules/*.{mdc,md}` | omp | the current Cursor convention; the table also carries the legacy `.cursorrules` |
| `.windsurf/rules/*.md`, `.windsurfrules` | omp | the table also carries `.windsurf/mcp_config.json` |
| `.clinerules` (file or directory) | omp | the nearest one walking up from the launch directory |
| `.agent/AGENTS.md`, `.agents/AGENTS.md` | omp | agents provider, walked up to the repository root |
| `.agent/rules/*`, `.agents/rules/*` | omp | same walk, same always-apply semantics as any other rule source |

A rule directory is carried as a directory entry (`- dir: .omp/rules`), which
covers every file under it without the table having to enumerate extensions.

A root `GEMINI.md` is *not* on the table: no supported agent reads it — Gemini
CLI does, and `.gemini/settings.json` is on the table only because omp's
cross-tool MCP discovery reads that file.

### The mask reaches the whole tree, not just the root

`D` — `config/mask.toml` is root-relative by design, because every supported
agent launches with its cwd at the checkout root and none of them walks *above*
it. But the always-loaded instruction files are read at any depth, so a
root-only mask would leave `sub/AGENTS.md` writable and loadable. The mask
therefore runs a second, tree-wide sweep (`config_deep_instruction_paths()`) for
the basenames on the table's `[anywhere]` list — `AGENTS.md`, `CLAUDE.md`,
`CLAUDE.local.md`, `.cursorrules` and `.envrc` — at every depth, and applies the
identical committed/clean rule to each match: a committed, clean `sub/AGENTS.md`
is a read-only copy of its committed content, an uncommitted one is hidden.
Root-level paths the table already covered are not bound twice, and neither is
a match inside a table directory (`.claude/agents/AGENTS.md`): that directory's
entry already decides its whole content.

Gitignored matches are included. An ignore rule is a statement about what git
tracks, not about what an agent CLI loads, so it must not be a place to hide an
instruction file. The matching is handed to git as `:(glob)**/<name>`
pathspecs rather than looped over in shell, so including ignored files costs a
single tree walk in C rather than a shell loop over every path in
`node_modules/`.

The startup block is fed from the same pass, so a deep uncommitted instruction
file is named at launch.

### `@` imports move class-D content off the mask list

Class D is "diff = payload" only for an instruction file that contains no
imports. Both claude and omp expand an `@path` token inside an instruction file
inline before injection, resolving it relative to the importing file and
recursing — four hops for claude, five for omp. `D`.

So a committed, masked, human-reviewed `AGENTS.md` holding `@docs/notes.md`
loads `docs/notes.md` into the system prompt at launch, and `docs/notes.md` is an
ordinary source file: not on the table, writable by every run. It is the class-D
form of the indirection below — the reviewed diff is the reference, not the
referent — and it means the payload of a class-D path is bounded by its imports,
not by its own diff.

## What indirection costs

Classes B and C are the classes where a review of the committed file is not a
review of what runs. The concrete shape, `D`:

- `mcp.json` naming `{"command": "node", "args": ["tools/helper.js"]}` commits a
  reference. `tools/helper.js` is an ordinary source file: not on the mask table
  (`config/mask.toml`), writable by every sandboxed run, and read by the agent
  CLI on the human's next bare-host start in that checkout.
- `.claude/settings.json` `hooks`, `apiKeyHelper` and `statusLine` are command
  strings with the same property.
- `.pre-commit-config.yaml` names a repository and revision that the commit path
  fetches and executes; the fetched content is not in the checkout at all.
- `.devcontainer/devcontainer.json` `initializeCommand` is a host command line.

The consequence for the convention is bounded and worth stating directly:
masking a class-B or class-C path read-only removes the agent's ability to
change *which* referent is named. It does not remove its ability to change the
referent, when the referent is a path in the same checkout.

## The class-C perimeter does not bound what becomes context

An MCP server returns text to its client at connect time — the `initialize`
response's `instructions` field, plus every tool name, description and input
schema — and that text is read into the model's context before the session's
first prompt. `D`, from the MCP specification.

Nothing constrains where the server sources that text. A server that reads a
file in the checkout turns that file into class-D content without the file
appearing on the mask list and without any masked path changing. The mask list
is therefore a perimeter over *config paths*, not a perimeter over *what becomes
instructions*, and no masking polarity changes that.

## What crosses the container barrier

Transport decides whether a class-C definition is reachable from inside a
sandboxed run. `D`:

| transport | inside the container |
| --- | --- |
| stdio | the client spawns the named `command` inside the container. The image ships a fixed toolchain (`sandbox/agent/Dockerfile.template`), so a definition naming a host path has nothing to spawn and the server fails to start, like any other missing binary; a command that exists in the image, or a host binary mounted read-only by a `sandbox.yml` `binds:` entry, runs contained. |
| `http` / `sse` | the client opens a network connection. The agent image ships curl and ca-certificates with open network egress, and the read-only `.git` mask does not restrict egress (`git-breakout.md`), so a remote endpoint is reachable. |

MCP credentials: opencode's `~/.local/share/opencode/mcp-auth.json` and claude's
`~/.claude/.credentials.json` are bound read-write, so what the agent stores
there survives the run. claude's `~/.claude.json` is a per-run copy that is
never written back (below), so nothing claude keeps in that file persists.

Current handling of on-disk MCP config by the three agent branches in
`configure_agent()` (`functions/agents.sh`), `D`:

| agent | project- and user-scope MCP config from disk | mechanism |
| --- | --- | --- |
| claude | loaded | `RUN_CMD=(claude "${ARGS[@]}")`; the run's own argv passes through untouched |
| omp | loaded | `RUN_CMD=(omp "${ARGS[@]}")` |
| opencode | loaded | `RUN_CMD=(opencode "${ARGS[@]}")`; `mcp.*.command` is read from the visible `opencode.json` |

Each source has its own gate, which is why no CLI-level switch is forced:

| source | gate |
| --- | --- |
| project-scope files (`.mcp.json`, `mcp.json`, `.claude/settings.json`, `opencode.json`, `.omp/mcp.json`, …) | the convention below: visible only when committed and clean, as a read-only copy — a change lands only through a commit, i.e. a human review pass |
| claude's user- and local-scope servers (`~/.claude.json`) | the per-run copy: loaded from the host's file, and nothing the session writes there reaches a later run |
| the other global definitions (`~/.claude/settings.json`, `~/.claude/mcp.json`/`.mcp.json`, `~/.omp/agent/mcp.json`/`.mcp.json`, `~/.config/opencode/opencode.json`) | read-only, human-authored outside any repo the agent can reach |

claude used to get `--strict-mcp-config` appended unconditionally, with the
run's own `--mcp-config` values folded into a single occurrence. The flag only
stopped the sandboxed session from *loading* definitions; it did nothing about a
definition the session wrote into `~/.claude.json` being live on the human's
next bare-host start, which the per-run copy now prevents. omp's named profiles
(`~/.omp/profiles/`) are not supported in the sandbox: a run that selects one
refuses to start.

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

**One exception: `sandbox.yml`** (`D` —
`require_trusted_project_sandbox_config()`). The sandbox parses it on the host
before every launch, so an agent-authored copy would shape the *next run's own
containment* and no container mask can intercept that read — the read happens
outside every container. The gate therefore sits on the read itself, in
`parse_project_sandbox_config()` (`functions/project-sandbox-config.sh`), one
layer earlier than the rest of the convention: a `sandbox.yml` that is not
tracked in HEAD and identical to it is **refused outright**, before a single key
is parsed. The refusal names what the uncommitted version would change about
the run, setting by setting ("mounts the host path X into every sandbox
READ-WRITE", "changes the sandbox base image to the Y preset") rather than
dumping the file, and committing it is how you accept it. Comment-only and
blank-line-only edits are ignored, so re-flowing a comment cannot trip the
fence. A symlink at that path is refused too: git vouches for the link while
the parser reads its target, which is a different file and may be untracked.
On the table itself `sandbox.yml` is an ordinary row, masked exactly like every
other entry.

**The agents' global config under `$HOME` follows the same shape, with a
different anchor** (`D` — `configure_agent()`, `functions/agents.sh`;
`bind_ro()`, `bind_state_rw()`, `functions/binds.sh`). It has no repository, so
committed-vs-uncommitted cannot be evaluated against it; the anchor is that the
human put it in their own `$HOME`, outside any repo the agent can reach. So
global config is mounted read-only and readable, and nothing else of the
agent's directory is bound:

| global path | session sees |
| --- | --- |
| present config | the real content, read-only |
| absent config | nothing bound at all |
| absent config inside a read-write state directory (opencode's `~/.local/share/opencode/bin`) | created empty on the host, then read-only — left unbound it would be creatable through the parent; a dangling symlink there refuses the run |
| opencode's `~/.local/state/opencode` (its server registry, `service.json`: pid, port, password) | a fresh per-run directory, never the host's — the host's would hand the session a host server's password (`docs/parallelization.md`) |
| writable state (session databases, caches, credentials the agent refreshes) | read-write, one path at a time; a missing JSON state file is created as `{}` |
| `.env` | never mounted, not even read-only — announced on the terminal instead |

`D` — the launch line (`--containall --no-mount home,…`, `functions/apptainer.sh`)
leaves `$HOME` absent inside the container except where a bind scaffolds it,
so a path nothing binds cannot reach the host. Per apptainer's documented
behaviour, a write in-session lands as follows; not measured with this launch
line:

| path under `$HOME` | in-container write |
| --- | --- |
| bound read-write | lands, persists on the host — the deliberate set |
| bound read-only | refused, `EROFS` |
| unbound, beside a bind (scaffolded) | not on the host: refused, or lost with the container |
| unbound, nothing scaffolds it | refused, `ENOENT` |

**claude's `~/.claude.json` is a per-run copy that is never written back**
(`D` — `claude_json_prepare()`, `claude_json_report()`,
`functions/claude-json.sh`). The file mixes state claude rewrites constantly
with what a later unsandboxed `claude` spawns and trusts. `D` — per Claude
Code's MCP documentation (`code.claude.com/docs/en/mcp`): user-scope MCP
servers are its top-level `mcpServers`; a local-scope server is stored "in
`~/.claude.json` under that project's path"; `projects["<path>"].hasTrustDialogAccepted`
set to `true` trusts a folder without a dialog; and the per-project
enabled/disabled server lists are recorded there too. Any merge-back would
let a session plant a command line or a trust decision for the next bare-host
run, so there is none: the session works on its copy, and when it exits the
report names the top-level keys it changed and keeps its version at
`~/.agent/claude.json.last-session` (mode 0600, one file, overwritten by the
next run that changes it; a symlink there is not followed), outside every
checkout, with the `diff` command to compare it. Cost: nothing the session
changes in that file — an accepted trust dialog, onboarding and tip counters —
carries over to the next run.

**omp's `~/.omp` is a per-run directory** (`D` — `functions/omp-home.sh`),
because omp keeps state and configuration in the same directories.
`~/.omp/agent` holds its sqlite databases next to `config.yml`, `models.yml`,
`lsp.json`, `extensions/`, `hooks/`, `rules/`, `SYSTEM.md` and more — omp loads
code or standing instructions from each of those — and `~/.omp` itself holds
the extracted native addons (reused when the file size matches, with no hash
check), the hub broker's socket and collab's bearer tokens (`run/`), logs and
caches. Any of that bound read-write would reach the next unsandboxed omp, or a
process running on the host. So the host's `~/.omp` is never bound as a
directory: the container gets a per-run directory in its place, with the
host's paths bound into it one by one:

| inside the sandbox | what it is |
| --- | --- |
| `~/.omp/natives` | the image's own read-only copy, extracted at build time |
| `~/.omp/logs` | per project, kept on the host in `~/.agent/omp-logs/` |
| `~/.omp/run`, `security`, `cache` | empty, per run |
| `~/.omp/agent/config.yml` | a plain per-run copy; at exit, `modelRoles` and `cycleOrder` merge back, the rest is reported |
| `~/.omp/agent/agent.db` (`-wal`, `-shm`), `blobs/`, `sessions/<this checkout>/` | the host's own, read-write — credentials and this checkout's sessions |
| `~/.omp/agent/history.db` | a per-project database in `~/.agent/omp-history/` |
| every other entry of the host's `~/.omp/agent` | read-only, including names a later omp version adds |
| `.env`, `secret-placeholder.key`, `models.db`, `terminal-sessions/` | not bound: absent, or fresh per run; a host `.env` is announced as withheld |

Secret redaction is forced on by a read-only settings overlay passed through
`PI_CONFIG_FILES`; omp never writes overlay values into `config.yml`. The
settings merge-back takes a key only when the session changed it, the value is
plain model ids in the shape omp writes, and the host file still holds its
launch value for that key — a change made on the host during the run wins and
is reported. Anything the session created under a new name is discarded with
the run and listed at exit. The residual: a host omp that closes its last
`agent.db` connection in the moment between container start and the sandbox's
own open removes the `-wal`/`-shm` files the sandbox has just bound, and a host
omp opened after that writes a second WAL for the same database.

**The merge-back reads one spelling of `config.yml`: the one omp writes**
(`omp_config_standard()`, `functions/omp-home.sh`). A line scanner and a YAML
parser agree on which top-level keys a file has only when no construct can
span lines or hide a key, so every file the merge touches — the session's copy,
the launch copy, the host file, and the rewrite before it replaces the host
file — must be in this form. A session copy outside it merges nothing and lists
nothing; a host file outside it is never written. Either case names the first
line outside the form. The form:

- `{}` as the only line (the empty mapping), or
- every column-0 line is `KEY:` or `KEY: VALUE`, `KEY` made of `A-Z a-z 0-9 _ -`
  and not starting with a digit or `-`, each `KEY` once;
- every other line is indented by a multiple of two spaces, then any number of
  `- ` item markers, then `KEY:`, `KEY: VALUE` or a bare `VALUE`, `KEY` plain or
  double-quoted;
- a `VALUE` is a complete double-quoted string; a plain scalar (no leading YAML
  indicator except `-`, `?` or `:` before a non-space, no `: ` or ` #` inside,
  no leading or trailing space, no trailing `:`); or `[]`/`{}`, only as a whole
  item and never after `KEY: `.

Outside the form, among others: blank lines, comments, tabs and other control
characters, `---`/`...`/`%` lines, quoted, flow or `?` top-level keys,
`KEY:VALUE` without the space (a plain scalar to YAML, not a key), anchors,
aliases, tags, single quotes, block scalars, flow collections other than
`[]`/`{}`, and a string left open across lines.

`M` — omp 18.2.9 saves settings through `Bun.YAML.stringify(settings, null, 2)`
with `/: +$/gm` replaced by `:` (`packages/utils/src/yaml-config.ts`, read from
the omp binary). Run through omp's own Bun on 2026-09-24, it writes an empty
list or mapping as the key followed by an indented `[]`/`{}`, double-quotes
keys and strings that need it, writes a multi-line string as one quoted line,
and in no shape tried emitted a comment, a blank line or a block scalar. The
output below is in the form (`omp_config_standard` accepts it):

```
$ BUN_BE_BUN=1 omp -e 'const s=o=>Bun.YAML.stringify(o,null,2).replace(/: +$/gm,":");
    console.log(s({cycleOrder:[],modelRoles:{},a:{b:[],"n":null,"we ird":1},q:"x: y",m:"a\nb",
    h:"#x",ids:["anthropic/claude-haiku-4-5:low"]}))'
cycleOrder:
  []
modelRoles:
  {}
a:
  b:
    []
  "n": null
  we ird: 1
q: "x: y"
m: "a\nb"
h: "#x"
ids:
  - anthropic/claude-haiku-4-5:low
```

The same writer puts `"n"` or `we ird` at column 0 when such a key is
top-level; the form does not admit that, so the merge refuses such a file.

`M` — the merge-side behaviour, `bash tests/git-escape/worktree_check.sh`: a
quoted top-level key or `KEY:VALUE` in the session copy, or a comment in the
host file, merges nothing; omp's emptied `cycleOrder` merges:

```
ok   O12    a session copy or host file outside omp's written form merges nothing, and says so
ok   O13    an emptied cycleOrder, in the form omp writes it, merges back
```

Only omp's default profile is mounted: a run that selects a named profile
(`--profile`, or `OMP_PROFILE`/`PI_PROFILE` forwarded into the container) or
forwards a variable that moves omp's directories refuses to start. An omp image
built before the native addons were extracted at build time has no read-only
copy for `~/.omp/natives` to point at, and image names do not change with the
template; the run checks the image once at startup and asks for a single
`--rebuild` rather than letting omp fail on a dangling link.

## The mask table

`D` — `config/mask.toml` is the perimeter: nothing discovers config paths, so a
path that is not on the table is not masked. It is TOML in `pyproject.toml`
layout. Each `[project.GROUP]` table holds a `files` array, a `dirs` array, or
both, of paths relative to the checkout root; a `dirs` entry covers everything
beneath it, and the group name only files rows under the comment that names
their vector. `[anywhere]` holds a `names` array of basenames matched at every
depth (see "The mask reaches the whole tree"). The loader,
`project_config_mask_load()`, parses it line by line, without a TOML library,
and accepts only a strict subset — comments, blank lines, those headers and
keys, one `"VALUE",` per line at four-space indent, `]` — and refuses the run on
anything else: a missing file, a repeated table or key, an unknown key or
table, an empty table or array, an inline array, single quotes, a trailing
comment, a path or name listed twice, an absolute path, a `.` or `..`
component, a `/` in a basename — because a row that silently dropped out would
look exactly like a mask that works. Every accepted value is a TOML basic
string that needs no escape, so the file reads the same to any TOML parser.
The table is located relative to `functions/binds.sh`, never through the
environment.

`M` — the loader's arrays equal what Python's `tomllib` reads from the file
(same 64 paths with the same kinds, same 5 names, same order):

```
python3 -c 'import sys, tomllib
d = tomllib.load(open("config/mask.toml", "rb"))
for t in d["project"].values():
    for k in ("files", "dirs"):
        for v in t.get(k, []): print("P", k[:-1], v)
for v in d["anywhere"]["names"]: print("A", v)' >/tmp/py.out
bash -c 'source functions/log.sh; source functions/agents.sh; source functions/binds.sh
project_config_mask_load
for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
    printf "P %s %s\n" "${PROJECT_CONFIG_MASK_KIND[i]}" "${PROJECT_CONFIG_MASK_PATH[i]}"
done
printf "A %s\n" "${PROJECT_CONFIG_MASK_ANYWHERE[@]}"' | cmp - /tmp/py.out && echo equal
```

prints `equal`.

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

`D` — in worktree mode each such file gets its own decision in the approval
gate, with its content shown, sanitized: **add** it to the commit, **exclude**
it (the default: leave it in the worktree and decide later — the file stays
uncommitted, and the worktree is then not removed after the commit, because
`worktree_after_commit()` removes only a worktree with nothing left over), or
**delete** it before the commit. The ordering in `worktree_commit()`
(`functions/worktree.sh`) is: the pre-commit tree-hash recheck runs **first**,
against the state the review rendered; the recorded per-file decisions are
applied after it, because they are decisions *about* that tree rather than new
content. Deleted files are removed before staging, then `git add -A` stages
everything, then the excluded files are unstaged with `git rm --cached`. The
commit therefore carries only what the human added — but the staging step has
already written those blobs into the main repository's shared object store, so
"excluded" means "not in the commit", not "never written".

Three properties of that gate are load-bearing:

- **The file's type is checked before it is read.** The agent chooses the
  path's type as well as its name. A FIFO would block the gate forever on
  `open(2)` — after the diff is displayed and before the commit prompt — and a
  symlink would display its *target's* content while `git add -A` stages the
  link, so the human would approve bytes that are not the bytes committed.
  Anything that is not a readable regular file is named by type, read not at
  all, and offered only exclude-or-delete, never "add".
- **Excluded paths are unstaged as literal pathspecs.** `--pathspec-file-nul`
  changes the separator; it does not make entries literal, and pathspec
  wildcards stay live — an entry `sub/*.md` unstages every sibling `.md` the
  pattern matches (`M` — test M12 in `tests/git-escape/worktree_check.sh`).
  Since the agent picks these filenames, a name that is also a glob would
  silently drop reviewed, approved work from the commit. Each path is written
  `:(top,literal)<path>`, and `--ignore-unmatch` is not used: after
  `git add -A` every excluded path must be staged, so a pathspec matching nothing
  means the tree moved and the run refuses.
- **The candidate list fails closed.** It is written to a caller-named file
  whose exit status is checked, never streamed out of a process substitution,
  because a failing git read inside `< <(...)` is invisible — the caller sees
  an empty list, and an empty list is indistinguishable from "the agent created
  nothing". The gate would then be skipped entirely and `git add -A` would
  sweep every plant into the commit unreviewed.

The gate's candidate sweep (`config_shaped_untracked()`) matches a `files` path
exactly, anything inside a `dirs` directory, and every `[anywhere]` name at any
depth. It is deliberately over-inclusive: a false positive costs
one keystroke; a false negative is a plant that loads on the human's next
bare-host session. The sweep lists `git ls-files --others` **without**
`--exclude-standard`, so an ignore rule cannot hide a plant, and the matching is
handed to git as pathspecs rather than looped over in shell, so including ignored
files costs one tree walk in C even on a checkout carrying `node_modules/`.

A gitignored candidate is marked as such and offered only exclude-or-delete:
`git add -A` never stages it, so there is nothing to add or unstage. A round
whose only product is gitignored still reaches the gate: `git status
--porcelain` excludes ignored files, so `worktree_has_changes()` also counts a
config-shaped untracked path — and a failure to list them — as a change,
rather than reporting "no changes" and skipping the per-file decisions.

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

## The patch channel

Masking committed config read-only means a legitimate request — "add this MCP
server", "record this convention in `AGENTS.md`" — has no way to land. Refusing
it silently would push the agent toward working around the mask.

`D` — so the agent is given one writable, named, reported channel
(`resolve_patch_dir()`, `report_agent_patches()`, `functions/agents.sh`): a
**gitignored directory inside the checkout**, chosen by the top-level `patches:`
key in `sandbox.yml` and resolved relative to the project directory (default
`.agent/patches`). Each run gets its own timestamped subdirectory, created on
the host before the container starts. It needs no bind of its own — it is an
ordinary part of the checkout the agent already has read-write.

Gitignored is a requirement, not a preference: it is what keeps an
agent-authored diff out of your own commit and out of the approval gate's
staged set. If the configured path is not ignored — or the key is absent and
the default is not ignored either — the channel is simply **off** for that run:
no directory is created, the agent is told it has nowhere to drop a patch, and
one line says so. The same holds for an absolute path, and for one that resolves
outside the checkout through a symlink; that check runs before anything is
created. Nothing is refused and nothing falls back somewhere less safe; the
channel is a convenience, not a containment control.

The agent is told, in its limitations file, that a read-only path is read-only
by design, and that a unified diff written to `<patches-dir>/<stamp>/<name>.patch`
is how to propose a change to **any** path the run mounted read-only — not only
committed config.

After the container exits, `report_agent_patches()` scans that exact directory
and prints, per patch, the command that would apply it:

```
sandbox: the sandboxed agent left 1 proposed patch(es) for
  paths this run mounted read-only:
  /home/you/proj/.agent/patches/20260921-101500-12345/mcp.patch
    git -C /home/you/proj apply /home/you/proj/.agent/patches/20260921-101500-12345/mcp.patch
sandbox: those patches were written by the sandboxed agent. Nothing has
  been applied -- reading each one before applying it is your job.
```

Nothing is copied and nothing is deleted. The files are already in their final
location inside your own project directory: a copy-out step would only create a
second place to look, and deleting from a directory you own after merely
reporting it is the "the sandbox removed files from my checkout" behaviour this
design rules out. Old per-run directories are yours to keep or clean up.

Nothing is applied automatically: a patch that the host applies without a human
reading it is the write access that was just taken away, restored by a longer
route. Paths are printed through `printf %q`, so a name carrying shell
metacharacters or terminal escapes is inert in the line the human copies, and
only regular files are reported — a symlink planted in the directory is not.

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

`M` — prints `64`.

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
