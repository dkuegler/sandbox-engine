#!/bin/bash
# --- START OF HELPTEXT ---
#
# Unified sandbox entrypoint. Usage:
#   ./sandbox.sh [--project-dir DIR] [--environment KEY=VALUE ...] [--bind SRC[:DST[:OPTS]]] [--allow-external-binds] [--allow-external-gitdir] [-v|--verbose|-vv] [--rebuild] [--no-update-check] [-h|--help] <claude|opencode|omp> [agent-args...]
#
# -h/--help before the agent name prints this header (the comment block
# you're reading now) and exits; the same flag after the agent name is
# position-scoped like -v/-vv above and is forwarded untouched as that
# agent's own -h/--help instead.
#
# Builds "<agent>.<env-tag>.sif" on first use (apptainer runtime) under
# $SANDBOX_ENGINE_IMAGE_DIR (default: $HOME/.apptainer/images; override with
# the SANDBOX_ENGINE_IMAGE_DIR env var) from sandbox/agent/Dockerfile,
# selecting the agent via --build-arg AGENT=<agent> and the base image per
# the project's execution environment, see below. The agent is then exec'd
# inside it, with the project directory bind-mounted and set as cwd. Pass
# --rebuild to force rebuilding the SIF even if it already exists.
#
# Implementation is split across functions/*.sh (sourced below):
#   log.sh          -v/-vv verbosity helpers (log_info/log_debug/log_argv)
#   argv.sh         --project-dir/--environment/--bind/agent argv parsing
#   sandbox_yml.sh  <project-dir>/sandbox.yml parsing
#   environment.sh  base-image resolution, Dockerfile generation, SIF build
#   binds.sh        extra bind resolution (sandbox.yml binds: / --bind)
#   git-mask.sh     read-only .git mask
#   agents.sh       per-agent state binds, RUN_CMD
# Project directory: defaults to the current working directory; override with
# --project-dir DIR (accepted anywhere in argv, before or after the agent
# name). sandbox.yml is looked up at the root of that directory.
#
# Execution environment (sandbox.yml / --environment):
#   The Dockerfile's "base" stage image is resolved from an optional
#   "environment:" section in <project-dir>/sandbox.yml, and/or from
#   repeatable --environment KEY=VALUE flags on the command line. Recognized
#   keys (first match wins, checked in this order):
#
#     environment:
#       image: <ref>             # use this image reference verbatim
#       dockerfile: <path>       # path (relative to project dir) to a custom
#                                # Dockerfile; its last stage becomes "base"
#       preset: uv|python|shell|latex   # named base image (see below)
#       python_version: "3.13"  # only consulted by the uv/python presets
#
#   --environment KEY=VALUE sets the same keys (image/dockerfile/preset/
#   python_version) and, per key, takes precedence over sandbox.yml, e.g.:
#     ./sandbox.sh --environment preset=python --environment python_version=3.12 claude
#
#   With no sandbox.yml and no --environment flags, or an environment:
#   section with none of the above set, this defaults to "preset: uv".
#
#   Presets:
#     uv          ghcr.io/astral-sh/uv:python<python_version>-bookworm-slim
#                 (uv preinstalled; python_version default 3.13)
#     python      python:<python_version>-slim-bookworm (default 3.13)
#     shell       the uv preset's base image (Python 3.13 pinned) plus
#                 the shellcheck tool and the shells it models (sh/dash,
#                 bash, ksh);
#                 other common shells get a stub that reports the
#                 capability boundary instead of running untested
#                 (see sandbox/shell/Dockerfile)
#     latex       a full TeX Live install plus uv, for projects needing
#                 both a LaTeX toolchain and `uv run`/`uv sync`
#                 (see sandbox/latex/Dockerfile)
#
#   The "uv" preset ships uv already; other presets/images/dockerfiles don't
#   get it for free unless they layer it in themselves the way "shell" and
#   "latex" do (see sandbox/shell/Dockerfile, sandbox/latex/Dockerfile) via
#   `COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/` or an apt
#   install. uv itself discovers pyproject.toml/.venv relative to cwd, so
#   `uv run ...` transparently uses the project's own `.venv` once the
#   project directory is bind-mounted.
#
# Additional binds (sandbox.yml / --bind):
#   Extra host paths mounted into the sandbox, on top of the project dir,
#   $HOME, and the per-agent config binds above. **Read-only by default**
#   (almost no agent task needs to write to a data mount, and read-write
#   would turn disclosure of a mounted dataset into destruction of it too).
#   Add ":rw" explicitly to opt into read-write. A top-level "binds:" list
#   in sandbox.yml sets project defaults (NOT under
#   "environment:"):
#     binds:
#       - /data                  # host path mounted at the same container path, read-only
#       - /data:/mnt/data        # host path mounted at another container path, read-only
#       - /data:/mnt/data:rw     # with apptainer bind options (here: read-write)
#   Repeatable --bind SRC[:DST[:OPTS]] flags add further binds on top, e.g.:
#     ./sandbox.sh --bind /var/run/docker.sock:/var/run/docker.sock:rw claude
#   Bare relative sources resolve against the project directory; "~"-prefixed
#   paths expand to $HOME.
#
#   A bind source outside the project directory can expose anything on the
#   host (~/.ssh, /etc, ...), and sandbox.yml travels with the checkout, so
#   a "binds:" entry there is attacker-controlled for an untrusted project.
#   Such a bind is refused unless confirmed interactively -- a prompt on
#   /dev/tty (not stdin, since stdin is the agent's own input stream)
#   stating the path's size and file count and the mode being requested,
#   answerable "y" (mount as requested), "o" (mount read-only instead,
#   overriding a requested :rw), or anything else (refuse) -- or allowed
#   non-interactively with --allow-external-binds. With no TTY available
#   (CI, </dev/null) the run refuses and names the flag. The check runs
#   both on the spec as written and again after resolving symlinks, so a
#   symlink inside the project pointing outside is also caught. Every
#   resolved bind (source, destination, ro/rw) is logged once per run
#   (`log_resolved_binds`, functions/binds.sh) so an after-the-fact
#   question about what a run could see has an answer.
#
# Git access:
#   The agent image ships a real `git` binary (sandbox/agent/Dockerfile.template)
#   with GIT_OPTIONAL_LOCKS=0 and GIT_CONFIG_NOSYSTEM=1 baked in. The sole
#   access control is the kernel-enforced read-only `.git` mask below --
#   there is no MCP sidecar, no allow-listed tool set, and no operand
#   validator. The agent image already ships curl/ca-certificates with open
#   network egress (see "Additional binds" above), so this mask does not
#   prevent exfiltration or pushing to an arbitrary remote by other means;
#   it only prevents git itself from rewriting local history/refs.
#
#   Every .git in the project tree -- the top-level one, submodules, and
#   nested repositories, plus the real git dir a worktree/submodule .git
#   file points at -- is bind-mounted READ-ONLY into the agent container
#   (functions/git-mask.sh). That is kernel-enforced, not a wrapper, so it
#   holds regardless of whether the git binary in use is the one the image
#   ships or one the agent fetched/installed itself. The same walk covers
#   every read-write extra bind (sandbox.yml binds: / --bind), not just the
#   project dir, since a .git anywhere writable in the container is
#   otherwise unguarded. A gitdir a bound worktree/submodule .git file
#   points at that lands outside every bound tree is left unmounted (and
#   named on stderr) unless --allow-external-gitdir mounts it read-only.
#
#   `push` succeeds against a read-only `.git` (the remote is updated; only
#   the local `refs/remotes/*` tracking-ref update fails, with one `error:`
#   line, and the command does not fail because of it); `status`/`diff` work
#   with `GIT_OPTIONAL_LOCKS=0`; `fetch --no-write-fetch-head` can sync from
#   upstream; history-rewriting operations (`commit`, `checkout`, `rebase`,
#   `gc`, ...) fail at lock creation with `Read-only file system`.
# --- END OF HELPTEXT ---

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # SANDBOX_DIR is read by functions/environment.sh (generate_dockerfile, build_images, the shell/latex preset paths)
SANDBOX_DIR="$SCRIPT_DIR/sandbox"
FUNCTIONS_DIR="$SCRIPT_DIR/functions"

# shellcheck source=functions/log.sh
source "$FUNCTIONS_DIR/log.sh"
# shellcheck source=functions/argv.sh
source "$FUNCTIONS_DIR/argv.sh"
# shellcheck source=functions/sandbox_yml.sh
source "$FUNCTIONS_DIR/sandbox_yml.sh"
# shellcheck source=functions/environment.sh
source "$FUNCTIONS_DIR/environment.sh"
# shellcheck source=functions/binds.sh
source "$FUNCTIONS_DIR/binds.sh"
# shellcheck source=functions/git-mask.sh
source "$FUNCTIONS_DIR/git-mask.sh"
# shellcheck source=functions/agents.sh
source "$FUNCTIONS_DIR/agents.sh"

# cleanup() (functions/git-mask.sh) removes the per-run scratch directory.
# Registered before anything can create that state.
trap cleanup EXIT

# Reap any leaked scratch directory from a run that was SIGKILLed before its
# own cleanup() could fire, before this run creates its own.
reap_orphaned_run_dirs

parse_argv "$@"

[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log_info "project dir: $PROJECT_DIR"

# `script` is a run mode, not an agent: it execs an arbitrary command
# inside the sandbox (RUN_CMD = its own trailing argv) instead of an
# agent CLI, and the Dockerfile has no `script` stage. Build and reuse an
# ordinary agent image for it -- the read-only .git mask it gets is built
# by mask_git_readonly, identically for every agent. Used by the
# git-escape probe (tests/git-escape/run.sh) to run
# tests/git-escape/probe.sh inside a real agent container.
IMAGE_AGENT="$AGENT"
if [[ "$AGENT" == "script" ]]; then
    IMAGE_AGENT="${SCRIPT_IMAGE_AGENT:-omp}"
    log_info "script mode: reusing the $IMAGE_AGENT image"
fi

SANDBOX_YML="$PROJECT_DIR/sandbox.yml"
if [[ -f "$SANDBOX_YML" ]]; then
    log_info "sandbox.yml: found at $SANDBOX_YML"
else
    log_info "sandbox.yml: not found (using defaults)"
fi
parse_sandbox_yml
resolve_environment
log_info "environment: mode=$ENV_MODE base_image=$BASE_IMAGE env_tag=$ENV_TAG"

# The SIF is a build artefact, not source: keep it out of the checkout.
IMAGE_DIR="${SANDBOX_ENGINE_IMAGE_DIR:-$HOME/.apptainer/images}"
mkdir -p "$IMAGE_DIR"
SIF_IMAGE="$IMAGE_DIR/$IMAGE_AGENT.$ENV_TAG.sif"

# Best-effort: never blocks or fails a run (functions/environment.sh's own
# doc comment). May set REBUILD=1 if the human accepts the prompt, in
# which case build_images below rebuilds through its existing path --
# --no-update-check (functions/argv.sh) skips this entirely.
check_agent_update || true

build_images

BINDS=(
    -B "$PROJECT_DIR"
)
# shellcheck disable=SC2034  # EXTRA_BIND_SRCS/EXTRA_BIND_RO are appended to by resolve_extra_binds (functions/binds.sh) and read by mask_git_readonly (functions/git-mask.sh)
EXTRA_BIND_SRCS=()
# shellcheck disable=SC2034  # see EXTRA_BIND_SRCS above
EXTRA_BIND_RO=()
RO_MASKED=()
resolve_extra_binds

# sandbox.yml decides this sandbox's own binds and base image. An agent
# that can rewrite it chooses what the NEXT run mounts, so it is bound
# read-only over the read-write project-dir bind.
bind_ro "$SANDBOX_YML"

# Masks every .git in the project tree read-only in BINDS.
mask_git_readonly

configure_agent
log_info "masks: ${GIT_MASK_COUNT:-0} .git path(s) read-only, ${#RO_MASKED[@]} read-only config bind(s)"
log_resolved_binds

# Only pass --nv/--rocm when the matching GPU stack looks present, so a
# plain CPU host doesn't get apptainer probing for a driver that isn't
# there. See resolve_gpu_flags() in functions/environment.sh.
resolve_gpu_flags

if [[ "$VERBOSE" -ge 2 ]]; then
    for __bind_spec in "${BINDS[@]}"; do
        [[ "$__bind_spec" == "-B" ]] && continue
        log_debug "bind: $__bind_spec"
    done
    log_argv "AGENT_ENV" "${AGENT_ENV[@]}"
    log_argv "GPU_ARGS" ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
    log_argv "RUN_CMD" "${RUN_CMD[@]}"
fi

# --writable-tmpfs gives only 64 MiB total, shared between / and /tmp
# (measured: `df` reports `tmpfs 64M 64M 0 100% /tmp` inside a live
# agent, notes/tasks.md T13) -- too small for ordinary work (a `pip
# install`, an `npm i`, one extracted Debian package). `--containall`'s
# own `--contain` mounts a fresh tiny tmpfs over /tmp, so /tmp needs a
# separate bind on top. RUN_DIR (ensure_run_dir(), functions/agents.sh)
# is already cleaned up unconditionally by cleanup() and reaped if
# orphaned (reap_orphaned_run_dirs, both functions/git-mask.sh), so both
# pieces below ride that same lifecycle for free -- no new cleanup path
# needed.
ensure_run_dir
mkdir -p "$RUN_DIR/tmp"

EXEC_ARGV=(
    apptainer exec --containall --no-home
    --cwd "$PROJECT_DIR"
    "${BINDS[@]}"
    "${AGENT_ENV[@]}"
    --home "$HOME"
    ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
    -B "$RUN_DIR/tmp:/tmp"
    "$SIF_IMAGE"
    "${RUN_CMD[@]}"
)
log_argv "apptainer exec argv" "${EXEC_ARGV[@]}"

"${EXEC_ARGV[@]}"
