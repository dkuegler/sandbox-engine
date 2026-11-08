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
| `--start-point COMMIT` | with `--worktree`: create `agent/BRANCH` from `COMMIT` instead of `HEAD` |
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
| `sdaps` | the `latex` base plus SDAPS 1.9.13 (`sandbox/sdaps/Dockerfile`) |

The `shell` preset ships the interpreters for shellcheck's dialects (sh/dash,
bash, ksh; shellcheck also models bats). `zsh`, `fish`, `tcsh` and `csh` are
stubs that print why they are not installed and exit 127, so a script is never
run by an interpreter shellcheck did not check it against.

The `sdaps` preset puts [SDAPS](https://sdaps.org) on `PATH` as `sdaps`. It
is built from the 1.9.13 release tarball, pinned by checksum, into
`/opt/sdaps`: a venv on a uv-managed CPython 3.13 carrying every optional
dependency (reportlab, Pillow, OpenCV, pandas, pyarrow, and PyGObject with
the Poppler and Pango introspection data), next to `zbarimg` for code128 and
QR IDs. A script that imports `sdaps` runs under `/opt/sdaps/bin/python`;
uv in the session does not see that interpreter or venv, so a project's own
environment works as in the `latex` preset. Questionnaires use TeX Live's
`sdaps` class, the one this release bundles. `sdaps gui` is not available:
no display reaches the sandbox, and GTK is not installed. The image build
ends with SDAPS's own end-to-end test (`test/run-test.sh`: `setup tex`,
`stamp`, `add --convert`, `recognize`, both reports) against the installed
command, so a dependency release that breaks SDAPS fails the build instead
of producing an image.

Only the `uv`, `shell`, `latex` and `sdaps` bases include uv. A custom image or
Dockerfile has to install it itself, for example with
`COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/`.
Whenever the agent can run uv in the image, its instruction file
(`AGENTS.md`, or `CLAUDE.md` for claude) also tells it to manage Python
packages and environments with uv. Every run asks the image itself:
`command -v uv`, as the session's user, on the image's own `PATH`
(`detect_image_uv()`, `functions/environment.sh`). Neither the preset name
nor the Dockerfile's text decides, so a custom image or Dockerfile that
installs uv gets the line too, however it installs it, and a uv that is off
that `PATH` or in a directory the session's user cannot enter does not.

The `uv` preset (and only it: not `shell`, `latex`, `sdaps` or a custom
base) also carries uv-managed CPython 3.10 through 3.14 in `/opt/uv-python`
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

## Building images on another machine

`apptainer build` turns the generated Dockerfile into an image with a
`buildctl` or `docker` client on this host. The BuildKit or Docker daemon
that the client talks to can run on another machine. `sandbox.sh` takes no
option for this. It inherits the builder variables from the shell you start
it in. See `apptainer.md`, "Which builder a build reaches", for the
mechanism.

| client on `PATH` | used when | daemon address |
| --- | --- | --- |
| `buildctl` | `DOCKER_BUILDKIT` is unset or empty | `BUILDKIT_HOST`; default `/run/buildkit/buildkitd.sock` |
| `docker` | there is no `buildctl`, or `DOCKER_BUILDKIT` is set to any value | `DOCKER_HOST` |

Forward the remote daemon's socket to a socket of your own over SSH, then
point the client at it:

```sh
# BuildKit (buildkitd on build-host, your user allowed on its socket)
ssh -fN -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
    -L "$XDG_RUNTIME_DIR/buildkitd.sock:/run/buildkit/buildkitd.sock" build-host
export BUILDKIT_HOST="unix://$XDG_RUNTIME_DIR/buildkitd.sock"

# Docker (your user in the docker group on build-host)
ssh -fN -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
    -L "$XDG_RUNTIME_DIR/docker.sock:/var/run/docker.sock" build-host
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
export DOCKER_BUILDKIT=1    # only needed if buildctl is also installed here

./sandbox.sh --rebuild omp
```

If `$XDG_RUNTIME_DIR` is unset, use any directory only you can enter. ssh
creates the local socket owner-only (its `StreamLocalBindMask` default).
The build host's sshd must allow socket forwarding
(`AllowStreamLocalForwarding`, on by default). Do not use the following:

- **`docker context use`.** apptainer runs `docker build` with a temporary
  `DOCKER_CONFIG` that holds no contexts, but it runs `docker save` with
  yours. The two commands can reach different daemons. Use `DOCKER_HOST`.
- **A `tcp://` `BUILDKIT_HOST`.** apptainer passes `buildctl` no TLS flags,
  so the connection is plaintext and unauthenticated. A Docker daemon over
  TCP needs `DOCKER_TLS_VERIFY=1` and an explicit `DOCKER_CERT_PATH`,
  because the default certificate path is the replaced `DOCKER_CONFIG`.
- **A buildx builder that is not the daemon's own (`docker` driver).**
  `docker save` needs the image in the daemon's image store.

The build daemon decides what every session of that image runs: treat it
as part of the sandbox. It receives the generated Dockerfile, which in
`dockerfile` mode includes your project Dockerfile's text.

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
  only theme and onboarding state merge back at exit. If you set
  `CLAUDE_CONFIG_DIR` on the host, those files are taken from that directory
  (and `.claude.json` from inside it) instead; the session still sees them at
  `~/.claude` and `~/.claude.json`. claude runs with its
  own `CLAUDE_CODE_SANDBOXED` flag, so it never asks whether to trust the
  checkout. `.env` files are never mounted. See `project-config-masking.md`.
- **Python virtualenvs** at the root of each mounted checkout (`.venv`, and
  every root-level directory holding a `pyvenv.cfg`): an empty per-run
  directory, read-write, instead of the host's. Build the environment in the
  session (`uv sync`, `uv venv`, `python -m venv`); it is discarded at exit. A
  host venv does not run in the image, and anything written into one would run
  in your next host session unreviewed. Not masked, each with a warning: a
  directory git tracks files in, and a symlinked `.venv`. A path a
  `binds:`/`--bind` entry targets keeps that bind. Only the checkout the agent
  works in, and only when it has no venv at all, gets an empty `.venv` created
  on the host as the mount point; the last sandbox run using it removes it at
  exit, and it is left in place if anything was written into it on the host.
  Coordinating concurrent runs needs `flock(1)` (util-linux) on the host. See
  `functions/python-env.sh`.
- **uv's cache**: `~/.agent/uv-cache` on the host, read-write, shared by every
  sandbox run of every project (`UV_CACHE_DIR` points there, and
  `UV_LINK_MODE=copy`). Any session can change cached packages that later
  sessions install. Bound even when the image has no uv.
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
`agent/BRANCH`. A new `agent/BRANCH` starts from the main checkout's `HEAD`, or
from `--start-point COMMIT`: git's `<start-point>`, so any commit-ish works
(`main`, `origin/main`, `v1.2`, a SHA, `HEAD~3`). It is resolved to a commit
before the image build and that commit is used, so a ref moving meanwhile
changes nothing. Only local refs count: nothing is fetched. `--start-point`
without `--worktree`, or with an `agent/BRANCH` that already exists, refuses
the run; an existing branch is never moved. On the terminal you choose how
the main checkout is mounted:
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
| `~/.agent/omp-models/` | omp's downloaded local model weights (`~/.omp/agent/cache/tiny-models`): session-title, memory and judge models, speech (Kokoro), dictation (Whisper, Parakeet) and word completion; shared by every project and session so each run does not download its own copy |
| `~/.agent/omp-embeddings/` | omp's downloaded embedding-model weights (`~/.omp/cache/fastembed`, used by memory), shared likewise |
| `~/.agent/opencode-share/` | opencode's data directory, per project |
| `~/.agent/opencode-cache/` | opencode's cache directory (models.dev catalog etc.), per project |
| `~/.agent/claude.json.last-session` | the last session's copy of `~/.claude.json`, when it changed |
| `~/.agent/uv-cache/` | uv's cache, shared by every sandbox run of every project |
| `~/.agent/venv-mounts/` | the `.venv` mount points sandbox runs created and the runs using each, so only the last one removes it |

## Fact records

`git-breakout.md` (the `.git` mask), `project-config-masking.md` (project and
`$HOME` config), `apptainer.md` (the launch line and the image build), `worktree-mode.md`,
`commit-message-generation.md`, `parallelization.md`, `maintenance.md`.
