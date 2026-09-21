# Commit-message generation: where it runs, on what model, with which flags

Last verified: 2026-09-21 (omp v18.2.5). `M` = measured, output quoted. `D` =
derived from source or documentation, not exercised.

Subject: how `sandbox.sh --worktree <branch>` obtains a commit message when the
agent left its own message file empty, implemented in
`functions/commit-message.sh`. The message the agent writes itself needs none of
this; this page is only about the fallback.

## The load-bearing fact

**The text handed to the generator is a diff the sandboxed agent just wrote.**
It is attacker-controlled input in the exact threat model this tool exists for,
so generation does not run on the host. It runs through `apptainer exec` against
the same image the agent ran in, and the only thing crossing back to the host is
the generated text on stdout — which the approval gate then shows the human
verbatim, next to the diff it claims to describe.

## The generator's container is smaller than the agent's

It gets the agent's config and credentials and nothing else. Specifically it
does **not** get the project checkout or the worktree.

Reason: every supported agent auto-loads instruction files (`CLAUDE.md`,
`AGENTS.md`), rules and skills from its working directory. Mounting the tree the
previous agent just wrote would let that agent choose the generator's own
instructions. Instead the container's cwd is a directory created for this run
alone, holding nothing, and the diff arrives as one inert argv string.

That directory is created **through the `/tmp` bind, not beside it**. The
generator's scratch directory on the host is bound *at* `/tmp` in the
container, so the container path `/tmp/commit-msg-cwd` is the host path
`<scratch>/commit-msg-cwd` — the `/tmp` prefix has to be stripped before the
`mkdir`:

```
mkdir -p "$scratch${COMMIT_MSG_CWD#/tmp}"
```

`D` — creating `"$scratch$COMMIT_MSG_CWD"` instead puts the directory at
`/tmp/tmp/commit-msg-cwd` inside the container. The `--cwd` the generator is
given then names a path that does not exist, which is either a failed run
falling into the placeholder path or a run whose working directory nobody
chose. Pure path arithmetic, invisible from either side alone.

It contains no instruction file for any agent to discover because the scratch
directory is created fresh for this generation and nothing else writes into
it. The coding agent's `/tmp` is a different directory, `rm -rf`'d and
recreated, so the agent cannot pre-seed the generator's filesystem.

The bind set is not re-listed in `functions/commit-message.sh`. `configure_agent`
(`functions/agents.sh`) records `AGENT_CONFIG_BIND_START` at the point where the
run's project/worktree/extra/`.git`-mask binds are already in place, and
`sandbox.sh` slices everything appended after it into `AGENT_CONFIG_BINDS`. A
per-agent config bind added later is therefore carried automatically rather than
having to be remembered in two places.

## Tools are disabled as well, inside that container

Containment stops the generator reaching the host; it does not stop it acting
inside a container that holds live credentials and has open network egress. With
tools enabled, a prompt injection in the diff could read the mounted auth files
and post them outward. Both layers together leave one surviving worst case: a
misleading commit message, shown to a human for approval.

| agent | how execution is disabled | note |
| --- | --- | --- |
| omp | `--no-tools --no-lsp --no-extensions --no-skills --no-rules --no-session --no-title` | `--no-tools`/`--no-lsp` remove the execution surface; the discovery switches stop on-disk files loading as instructions |
| claude | `--bare --tools "" --strict-mcp-config` | `D` — `--bare` skips hooks, skills, commands, subagents, plugins, MCP and `CLAUDE.md`, but documents that Bash/read/edit remain, so `--tools ""` is what actually removes them |
| opencode | `OPENCODE_CONFIG_CONTENT={"permission":"deny"}` | `D` — opencode has no `--no-tools` flag; tool availability is configuration, not argv. When a `commit` agent is selected the deny is repeated at agent scope (below) |

`D` — opencode's config schema types `permission` as a union whose first branch
is a bare action string, so `"deny"` denies **every** tool, including tools added
upstream later. An enumerated `tools: {}` map would silently start allowing
those:

```
$ curl -s https://opencode.ai/config.json \
    | jq -c '.["$defs"].PermissionConfig.anyOf[0], .["$defs"].PermissionActionConfig'
{"$ref":"#/$defs/PermissionActionConfig"}
{"type":"string","enum":["ask","allow","deny"]}
```

The variable is delivered `APPTAINERENV_`-prefixed rather than through `--env`,
so its value never appears in a world-readable `/proc/<pid>/cmdline` — the same
reasoning as `require_host_env()` (`functions/agents.sh`). It is exported inside
a subshell: the reject menu's "re-run the agent" path launches the real agent
from the same shell, and an inherited `permission: "deny"` would silently
cripple it.

When the generator selects opencode's `commit` agent, the inline config it is
given is instead:

```json
{"permission":"deny","agent":{"commit":{"permission":"deny","tools":{"*":false}}}}
```

opencode merges config sources rather than replacing them, and an agent's own
settings override the global ones — so a `commit` agent carrying
`permission: {bash: allow}`, or the deprecated-but-still-valid
`tools: {bash: true}` (documented as equivalent to `{"*": "allow"}`), would hand
tools back to the one run that must not have them. Inline config is the
highest-precedence user-writable source, so both spellings are denied again at
agent scope. The agent key is injected **only** when that agent was selected:
adding it otherwise would invent an agent with no `description`, which
opencode's schema rejects.

`M` — both shapes are legal where they are placed, so neither silently
invalidates the config:

```
$ curl -s https://opencode.ai/config.json -o /tmp/oc.json
$ python3 -c "import json;d=json.load(open('/tmp/oc.json'))['\$defs'];\
print(d['PermissionConfig']['anyOf'][0], d['PermissionActionConfig']['enum'], \
d['AgentConfig']['properties']['tools'])"
{'$ref': '#/$defs/PermissionActionConfig'} ['ask', 'allow', 'deny']
{'type': 'object', 'additionalProperties': {'type': 'boolean'},
 'description': "@deprecated Use 'permission' field instead"}
```

`D` — opencode ships no built-in agent named `commit` (its built-ins are
`build`, `plan`, `general`, `explore`, `scout`, and the hidden `compaction`,
`title` and `summary`). `--agent commit` therefore resolves only to an agent the
user defined, and the presence check means nothing is passed when they did not.
A user-defined `commit` agent written for host use may carry a prompt telling it
to stage and commit; with every tool denied and no repository in the container
it cannot, and a refusal reaching stdout fails into the placeholder path.

## Model selection

| agent | default choice | mechanism | when unconfigured |
| --- | --- | --- | --- |
| omp | `modelRoles.commit` | `--model commit` — omp resolves the role itself | no `--model`; omp's default model |
| claude | `haiku` | `--model haiku`, a built-in alias | not possible; no configuration needed |
| opencode | a `commit` agent | `--agent commit` — opencode resolves the agent's model itself | `small_model` via `--model <value>`, else no `--model` |

`--commit-model MODEL` overrides all three. It is the only way to name a model
for an agent whose configuration offers none, and it never inherits the coding
run's `--model`: that model was chosen to write code, not to summarize a diff.

`M` — omp's `commit` is two different things and only one of them is used here.
`modelRoles.commit` is a **model role** (built-in roles: `default`, `smol`,
`slow`, `vision`, `plan`, `commit`, `tiny`, `task`, `advisor`); `omp commit` is
a **CLI command** that generates a message, updates changelogs and commits:

```
$ omp commit --help
Generate a commit message and update changelogs

FLAGS
      --push             Push after committing
      --dry-run          Preview without committing
      --no-changelog     Skip changelog updates
      --legacy           Use legacy deterministic pipeline
  -c, --context=<value>  Additional context for the model
  -m, --model=<value>    Override model selection
```

`M` — `omp commit` does not hand git to the model. It drives narrow structured
tools and applies the result from code, so the model never chooses a command:

```
$ cd /tmp/dryrun && omp commit --dry-run --no-changelog
● Discovering context files...
  └─ ~/.omp/agent/AGENTS.md
● Starting commit agent...
  GitOverview
  GitFileDiff       files: calc.py
  ProposeCommit     type: feat  scope: calc  summary: add mul and sub functions
● agent finished (5 messages, 4 tools)

Generated commit message:
feat(calc): added multiplication and subtraction functions
```

`M` — the read-only `.git` mask contains that code path too, and `--dry-run`
does not need to write at all:

```
$ chmod -R a-w .git && omp commit --dry-run --no-changelog ; echo $?
Generated commit message: feat(calc): added multiply and subtract functions
0
$ omp commit --no-changelog ; echo $?
✗ Commit failed:
    git write-tree: Could not create named temp file in '/tmp/dryrun/.git/objects'
1
$ git log --oneline | head -1
bba49ca init
```

So a writable `.git` is never required to obtain a message: the command that
produces one succeeds against the mask, and the command that would write is
stopped by it. Making `.git` writable for a commit session would buy only the
commit itself, at the cost of the guarantee in `git-breakout.md` — which is
stated as kernel-level and unconditional, explicitly *not* resting on a wrapper,
an allow-list, or the absence of a git binary. It would also make `.git/hooks/`
and `.git/config` (`core.hooksPath`) writable, and those execute on the host at
the human's next git operation.

`D` — the command is still not the mechanism used here, for a reason the flag
list makes structural: it derives its input from the repository it runs in
(nothing feeds it a diff), so it needs the project or worktree mounted, and it
has no switch to disable the context-file discovery shown above. In a mounted
worktree that discovery would load the agent-authored instruction files this
feature exists to keep out. `omp -p` has those switches (`--no-rules`,
`--no-skills`, `--no-extensions`); `omp commit` does not. What is passed instead
is only the role name, with the prompt supplied here and every tool off.

`--push` is consequently unreachable from this path, and it is excluded by
construction rather than by filtering: `commit_msg_passthrough()` is an
allow-list, so a flag has to be named there to survive. Note that blocking the
flag would not be containment in any case — `git-breakout.md` measures `push`
**succeeding** through the read-only mask, because a push writes to the remote
and not to local `.git`. What contains it is the remote-URL and credential
redaction applied to every `.git` the container can read.

`M` — omp resolves **role names** through `--model`, so passing the role rather
than a scraped model id is what makes a profile or config overlay that redefines
the role take effect. The reply's own model signature identifies the model that
answered:

```
$ omp -p --mode json --no-tools --no-session --no-title --model commit "Reply with exactly: OK"
...,"thinkingSignature":"...MDIZY2xhdWRlLWhhaWt1LTQtNS0yMDI1MTAwMTgA..."
# base64 of the signature contains "claude-haiku-4-5-20251001";
# modelRoles.commit is anthropic/claude-haiku-4-5:low
```

`M` — an unresolvable `--model` value is refused outright rather than silently
falling back to the default model:

```
$ omp -p --no-tools --no-session --model zzzznonexistentmodel "Reply with exactly: OK"
Set an API key environment variable:
  ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, etc.
```

That refusal is why the omp path checks whether `modelRoles.commit` exists
before naming it. The check is a **presence** check only — never a value
extraction — so the resolution itself stays omp's job. With `--profile P` in
play it reads that profile's own `config.yml` and not the base one, because
`--profile` is documented as an isolated profile for auth, sessions, settings
and caches.

`D` — opencode has no model-**role** concept, but it does have named **agents**,
and an agent carries its own `model`. A `commit` agent is therefore the
opencode-native spelling of "the model this task uses", and `--agent commit`
leaves the model resolution to opencode exactly as the omp path leaves role
resolution to omp.

Define it either way opencode supports:

```json title="~/.config/opencode/opencode.json"
{
  "agent": {
    "commit": {
      "description": "Commit-message generation",
      "model": "opencode/big-pickle"
    }
  }
}
```

```markdown title="~/.config/opencode/agents/commit.md"
---
description: Commit-message generation
model: opencode/big-pickle
---
Summarize the diff.
```

`D` — both directory spellings are checked (`agents/` is opencode's current
layout, `agent/` the backwards-compatible one; opencode loads both), as are
`opencode.json` and `opencode.jsonc`. Like the omp check this is a **presence**
check only — the model id behind the name is never read here. The scan tracks
brace depth rather than matching the name textually, so a `"commit"` key inside
a prompt string, a `command` block or another agent's `permission` map is not a
definition.

`D` — no model id is hard-coded in this path. Provider catalogs change; OpenCode
Zen's free entries are documented as limited-time, and a pinned id that is
withdrawn fails every subsequent generation. The id always comes from live
config resolution.

`D` — a non-schema key (e.g. `"commit_model"`) is not usable: opencode validates
its config against a strict schema that rejects unknown keys, so the key would
invalidate the user's own opencode config, not only this generator's view of it.
The agent block carries the same information inside the schema.

`D` — the model is not discovered at generation time (e.g. `opencode models`
interpolated into `--model` by a `bash -c` wrapper). The generator is exec'd as
a fixed argv with no shell in the container; a wrapper would assemble a shell
command line across three quoting layers in the one run whose input is
attacker-authored.

`small_model` remains the fallback when no `commit` agent exists. It is an
official field but the wrong one semantically: opencode consults it only for its
own hardcoded lightweight tasks (title and summary generation), never for
`opencode run`. There is consequently nothing to delegate, so its value is read
and named on the command line. Global config only, for both mechanisms: project
config is not read, because the project is deliberately not mounted.

## Flag propagation from the run's own argv

Generation is a different task from the coding run with a smaller mandate, so
the run's trailing argv is not forwarded wholesale. A flag is propagated only if
it changes **which configuration and credentials resolve**.

Propagated:

| flag | agent | why it must be |
| --- | --- | --- |
| `--profile` | omp | selects an isolated profile for auth *and* settings; without it the commit role resolves against the wrong profile, and may not be authenticated at all |
| `--config` | omp | a `config.yml` overlay can define `modelRoles.commit`, which is exactly "the commit model, changed on the command line". Repeatable; every occurrence is kept |
| `--settings`, `--setting-sources` | claude | select which settings files apply, including the env and credential-helper entries that decide how the run authenticates |

Not propagated:

| flag | agent | why not |
| --- | --- | --- |
| `--model` | all | selects the coding model; the commit model is chosen separately, above |
| `--smol`, `--slow`, `--plan` | omp | override other roles, never `commit` |
| `--api-key` | omp | would place a live credential in an argv; authentication already reaches the container through the environment |
| `--thinking`, `--service-tier` | omp | tune a coding turn; a one-paragraph summary needs neither |
| `--add-dir` | omp, claude | grants filesystem scope — the generator is supposed to have none |
| `--hook`, `-e`/`--extension`, `--plugin-dir`, `--plugin-url` | omp, claude | load executable code, which is the thing being switched off |
| `--mcp-config` | claude | names command lines to spawn; `--strict-mcp-config` with no config leaves none |
| `--system-prompt`, `--append-system-prompt`, `--agent`, `--agents` | omp, claude | replace or redirect the persona; the requested message shape depends on the default one. The opencode `--agent commit` above is not this flag travelling: it is a fixed name resolved against global config, never a value taken from the run's argv |
| `-c`/`--continue`, `-r`/`--resume`, `--session-dir` | omp, claude | session continuity; generation is stateless and sessions are disabled |
| `--mode`, `--output-format`, `--json-schema` | omp, claude | change stdout's shape, which is read verbatim as the message |
| `--cwd` | omp | set by this feature to the empty scratch directory |
| `--auto-approve`, `--approval-mode`, `--permission-mode`, `--dangerously-skip-permissions` | omp, claude | capability flags |
| — | opencode | no config-selection flag exists; opencode selects config through `OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` environment variables, not argv |

## Failure is never fatal

Any failure — no agent CLI for this run mode, no image, a non-zero exit, an
empty answer, a timeout of `COMMIT_MSG_TIMEOUT` seconds — falls through to a
placeholder message naming the files touched. Generation is a convenience; the
human still reviews the real diff either way, and a wedged generator must not be
able to block that.

## What is verified, and what is not

`M` — the omp path end to end: role resolution, refusal of unknown models, and
every structural property below.

`D` — the claude and opencode argv shapes come from vendor documentation. They
have not been executed: neither binary, nor its configuration, is reachable from
the environment this was written in.

## Reproduction

```
./tests/git-escape/worktree_check.sh
```

Assertions `W10`–`W10l` cover: generation goes through `apptainer exec` against
the run's image; neither the worktree nor the project is among its binds; the
agent's own config binds are; the execution switches are present; the omp role
is named rather than a model id; an absent role yields no `--model` instead of a
failing run; `--commit-model` overrides; profile/config propagate while the
coding model and approval flags do not; claude's and opencode's hardening is
applied; and the opencode override does not leak into the calling shell.

Each of those was confirmed to be load-bearing by mutating
`functions/commit-message.sh` one property at a time — mounting the worktree,
dropping `--no-tools`, ignoring `--commit-model`, dropping propagation, dropping
claude's `--bare`/`--tools`, dropping opencode's denial, and exporting the
opencode override outside the subshell. Each mutation failed exactly its own
assertion and no other.
