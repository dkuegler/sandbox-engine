# Using `sandbox.sh`

User reference for the launcher. It describes current behaviour and is updated
with it. The fact records listed at the end hold the evidence.

`sandbox.sh` runs a coding agent CLI (claude, opencode or omp) inside an
apptainer container. The project directory is mounted read-write and every
`.git` in it read-only, so the agent can edit files but cannot rewrite history.
The agent's own config comes from your `$HOME`, read-only except for the state
it has to write. Nothing else from the host is mounted unless you ask for it.

## Invocation

```
./sandbox.sh [options] <claude|opencode|omp> [agent-args...]
```

The project directory defaults to the current directory. sandbox-engine's
options are recognised anywhere on the command line, and everything else is
passed to the agent unchanged. `-h`/`--help` and `-v`/`-vv` are the exceptions:
before the agent name they belong to `sandbox.sh`, after it to the agent.

| option | effect |
| --- | --- |
| `--project-dir DIR` | project to sandbox; `sandbox.yml` is read from its root |
| `--environment KEY=VALUE` | set one `environment:` key, overriding `sandbox.yml` for that key; repeatable |
| `--bind SRC[:DST[:OPTS]]` | extra mount, read-only unless `OPTS` is `rw`; repeatable |
| `--allow-external-binds` | mount binds outside the project without the interactive confirmation |
| `--allow-external-gitdir` | mount, read-only, a git dir that a worktree or submodule `.git` file points to outside every bound tree |
| `--ignore-warnings` | start a run that warned even when there is no terminal to confirm on |
| `--worktree BRANCH` | run in a throwaway worktree on `agent/BRANCH` (below) |
| `--commit-model MODEL` | model for the generated commit message in worktree mode |
| `--rebuild` | rebuild the image even if it exists |
| `--no-update-check` | skip the agent-version check |
| `-v`, `-vv` | host-side log detail |
| `-h`, `--help` | the help header |

`SANDBOX_ENGINE_IMAGE_DIR` sets where images are stored (default
`~/.apptainer/images`). The run's exit status is the agent's.

## `sandbox.yml`

Optional, at the project root. `sandbox.example.yml` is an annotated sample.
The host reads this file before any container exists, so it is honoured only
when it is committed and its working-tree copy is identical to HEAD. Otherwise
the run refuses and lists what the uncommitted version would change;
committing it is how you accept those changes. Edits to comments and blank lines
are ignored by this check. A symlink at that path is refused.

### `environment:` (the base image)

The first key set wins, in this order:

| key | meaning |
| --- | --- |
| `image: REF` | this image, verbatim |
| `dockerfile: PATH` | a Dockerfile relative to the project; its last stage becomes the base |
| `preset: NAME` | a named base (below); default `uv` |
| `python_version: "3.13"` | used by the `python` preset only |

| preset | base |
| --- | --- |
| `uv` | uv on Python 3.13 (default interpreter) plus uv-managed 3.10 through 3.14 (`sandbox/uv/Dockerfile`) |
| `python` | `python:<version>-slim-bookworm` |
| `shell` | the `uv` base (Python 3.13) plus shellcheck, dash and ksh (`sandbox/shell/Dockerfile`) |
| `latex` | full TeX Live plus uv (`sandbox/latex/Dockerfile`) |

The `shell` preset ships the interpreters for shellcheck's dialects (sh/dash,
bash, ksh; shellcheck also models bats). `zsh`, `fish`, `tcsh` and `csh` are
stubs that print why they are not installed and exit 127, so a script is never
run by an interpreter shellcheck did not check it against.

Only the `uv`, `shell` and `latex` bases include uv. A custom image or
Dockerfile has to install it itself, for example with
`COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/`.

The `uv` preset (and only it: not `shell`, `latex` or a custom base) also
carries uv-managed CPython 3.10 through 3.14 in `/opt/uv-python`
(`sandbox/uv/Dockerfile`), with `python3.10` ... `python3.14` on
`PATH` after the base interpreter. `requires-python`, `.python-version` and
`uv run --python X` resolve offline for any of them.
`UV_PYTHON_DOWNLOADS=never` is set there (the image is read-only at run
time), so a version outside that range fails with uv's "downloads are set to
never" error. Edit `sandbox/uv/Dockerfile` to change the set.

The image is `<agent>.<env-tag>.sif`, built on first use. The tag changes
whenever the environment changes, and that change triggers a fresh build.
Every build installs the agent's current release: from the template's first
`RUN` on, no layer is taken from the builder's cache; the base stage (a
preset's or your Dockerfile) can be. The image records its build id in
`/etc/sandbox-engine-build-id`. See `apptainer.md`.

### `binds:` (extra mounts)

```yaml
binds:
  - /data                # same path inside, read-only
  - /data:/mnt/data      # another path inside, read-only
  - /scratch/out:/out:rw # read-write
```

Relative sources resolve against the project directory, and `~` expands to
`$HOME`. `--bind` adds more binds on top of this list. After symlinks are
resolved, a source outside the project directory needs confirmation on the
terminal: the prompt shows its size and file count, and the answers are `y`
(mount as asked), `r` (mount read-only) or anything else (refuse). Use
`--allow-external-binds` to skip the prompt. With no terminal, the run refuses.
Every mount of the run is printed to stderr once at startup.

### `patches:` (the patch channel)

A gitignored directory in the checkout (default `.agent/patches`) where the
agent can leave a unified diff for a file it cannot write. Each run gets its
own subdirectory. At exit, every file in it is listed with its `git apply`
command. Nothing is applied or deleted. Before creating its own subdirectory,
a run removes any sibling subdirectory that is both empty and not owned by a
still-running sandbox process, so a run that never writes a patch leaves
nothing behind. If the directory is not gitignored, the channel is off for
that run. Details: `project-config-masking.md`, "The patch channel".

## What the session sees

- **The project**, read-write, and every `.git` in it read-only. Remote URLs and
  credentials are redacted from what git can read. `push` still works, while
  commit, checkout, rebase and gc fail. See `git-breakout.md`.
- **Project config** that agents, editors or hooks load: shown only if it is
  committed and clean, and then as a read-only copy of HEAD. Everything else is
  hidden. A file the agent creates at such a path is reported at exit. See
  `project-config-masking.md`.
- **The agent's global config**, read-only. Writable state is bound path by
  path. omp gets a per-run `~/.omp`; claude a per-run `$HOME`, where its
  login is your own `~/.claude/.credentials.json` and of its `~/.claude.json`
  only theme and onboarding state merge back at exit. claude runs with its
  own `CLAUDE_CODE_SANDBOXED` flag, so it never asks whether to trust the
  checkout. `.env` files are never mounted. See `project-config-masking.md`.
- `/tmp`: a per-run host directory. `/` is the image, read-only. See
  `apptainer.md`.
- **The network** is not restricted. ONNX Runtime telemetry is switched off
  with `ORT_DISABLE_TELEMETRY=1` in every container. omp's local models use
  ONNX Runtime, which would otherwise report to Microsoft and write
  `:memory:.ses` into the checkout.

`$HOME/.sandbox-limitations.md`, inside the session, tells the agent the same
things.

## Before the agent starts

**Warnings hold the start.** Any host-side warning is printed again just before
the agent takes the terminal, and the run waits for input. A run with no
warnings does not wait. With no terminal, a run that warned refuses unless
`--ignore-warnings` was passed.

**Agent updates.** For an image that already exists, the run compares the
agent's version inside the image with the latest upstream release, at most
once an hour (cached in `<image>.info`). If upstream is newer, it asks whether
to rebuild; without a terminal it prints a note. After every build it compares
again and warns if the new image does not hold the latest release. `-v` prints
the versions compared; `-vv` also each upstream query with its HTTP status,
and why a check was skipped. Failures are otherwise silent.

## Worktree mode (`--worktree BRANCH`)

The agent works in `~/.agent/worktrees/<project>-<hash>/BRANCH`, a worktree on
`agent/BRANCH`. On the terminal you choose how the main checkout is mounted:
read-only (`r`), read-write (`w`), or working tree not mounted (`n`; its `.git`
stays readable). Its `.git` stays read-only in every case, so the agent cannot
commit.

When the container exits, the host shows the change and a commit message:
either the one the agent wrote to `$HOME/.sandbox-commit-message`, or one
generated in a second, isolated container. Nothing is committed without your
explicit approval, and nothing is pushed: an approved change becomes a commit
on `agent/BRANCH`, and the run prints the push command. Rejecting offers to
keep the worktree, re-run the agent in it, or discard it. The agent's message
file belongs to the worktree: a re-run, or a later `--worktree BRANCH` that
resumes a kept or crashed worktree, starts from the message the earlier
session wrote, and the review says when a session left it unchanged. A commit
or a discard deletes it. Branch collisions are never guessed: a matching
worktree and branch resume, and anything else refuses. Interactive use only.
See `worktree-mode.md` and `commit-message-generation.md`.

## Host state outside the checkout

| path | content |
| --- | --- |
| `$SANDBOX_ENGINE_IMAGE_DIR` (`~/.apptainer/images`) | images and their update-check cache |
| `${TMPDIR:-/tmp}/sandbox-engine.*` | per-run scratch, removed at exit, reaped on the next run if a run was killed |
| `~/.agent/worktrees/` | worktree mode: worktrees, locks, pending commit messages, review log |
| `~/.agent/omp-logs/`, `~/.agent/omp-history/` | omp logs and prompt history, per project |
| `~/.agent/opencode-share/` | opencode's data directory, per project |
| `~/.agent/opencode-cache/` | opencode's cache directory (models.dev catalog etc.), per project |
| `~/.agent/claude.json.last-session` | the last session's copy of `~/.claude.json`, when it changed |

## Fact records

`git-breakout.md` (the `.git` mask), `project-config-masking.md` (project and
`$HOME` config), `apptainer.md` (the launch line and the image build), `worktree-mode.md`,
`commit-message-generation.md`, `parallelization.md`, `maintenance.md`.
