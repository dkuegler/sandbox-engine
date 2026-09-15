#!/bin/bash
#
# Unified sandbox entrypoint. Usage:
#   ./sandbox.sh [--project-dir DIR] [--environment KEY=VALUE ...] [--bind SRC[:DST[:OPTS]]] [--allow-external-binds] [--allow-external-gitdir] [-v|--verbose|-vv] [--rebuild] <claude|opencode|omp> [agent-args...]
#
# Builds sandbox/<agent>.<env-tag>.sif on first use (apptainer runtime) from
# sandbox/Dockerfile, selecting the agent via --build-arg AGENT=<agent> and
# the base image per the project's execution environment, see below. The
# agent is then exec'd inside it, with the project directory bind-mounted
# and set as cwd.
#
# Implementation is split across functions/*.sh (sourced below):
#   log.sh          -v/-vv verbosity helpers (log_info/log_debug/log_argv)
#   argv.sh         --project-dir/--environment/--bind/agent argv parsing
#   sandbox_yml.sh  <project-dir>/sandbox.yml parsing
#   environment.sh  base-image resolution, Dockerfile generation, SIF build
#   binds.sh        extra bind resolution (sandbox.yml binds: / --bind)
#   git-mcp.sh       git MCP sidecar lifecycle (start/stop, .git ro mask)
#   agents.sh       per-agent state binds, RUN_CMD, MCP config injection
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
#       preset: uv|python|python3.13   # named base image (see below)
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
#     python3.13  python:3.13-slim-bookworm
#     python      python:<python_version>-slim-bookworm (default 3.13)
#
#   The "uv" preset ships uv already; other presets/images/dockerfiles don't
#   get it for free. A project that needs both uv and a non-uv base (e.g. TeX
#   Live) should use "dockerfile:" pointing at a small Dockerfile that layers
#   uv onto that base via `COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx
#   /bin/` (see sandbox/texlive-uv.Dockerfile for a worked example). uv itself
#   discovers pyproject.toml/.venv relative to cwd, so `uv run ...`
#   transparently uses the project's own `.venv` once the project directory is
#   bind-mounted.
#
# Additional binds (sandbox.yml / --bind):
#   Extra host paths mounted into the sandbox, on top of the project dir,
#   $HOME, and the per-agent config binds above. A top-level "binds:" list
#   in sandbox.yml sets project defaults (NOT under "environment:"):
#     binds:
#       - /data                  # host path mounted at the same container path
#       - /data:/mnt/data        # host path mounted at another container path
#       - /data:/mnt/data:ro     # with apptainer bind options (here: read-only)
#   Repeatable --bind SRC[:DST[:OPTS]] flags add further binds on top, e.g.:
#     ./sandbox.sh --bind /var/run/docker.sock claude
#   Bare relative sources resolve against the project directory; "~"-prefixed
#   paths expand to $HOME.
#
#   A bind source outside the project directory can expose anything on the
#   host (~/.ssh, /etc, ...), and sandbox.yml travels with the checkout, so
#   a "binds:" entry there is attacker-controlled for an untrusted project.
#   Such a bind is refused unless confirmed interactively (a y/N prompt on
#   /dev/tty, not stdin, since stdin is the agent's own input stream) or
#   allowed non-interactively with --allow-external-binds. With no TTY
#   available (CI, </dev/null) the run refuses and names the flag. The
#   check runs both on the spec as written and again after resolving
#   symlinks, so a symlink inside the project pointing outside is also
#   caught.
#
# Git access:
#   The agent image deliberately stays clean of a git binary. All git
#   access goes through a separate sidecar container (sandbox/gitmcp.sif,
#   built from sandbox/gitmcp/Dockerfile) that is exposed to the agent as
#   a local MCP server: the agent spawns `nc -U <socket>` (see
#   functions/agents.sh), which relays its stdio to a Unix domain socket
#   the sidecar created in a per-run RUN_DIR (mode 0700, socket mode
#   0600) that is bind-mounted into both containers. There is no network
#   listener and no token — an `apptainer instance` shares the host's
#   network namespace (--net needs root), so a TCP listener would be
#   reachable by every local process regardless of any bearer token; the
#   socket file's own permissions are the access control instead. It
#   exposes only read-only tools (git_status, git_log, git_diff,
#   git_show, git_blame, git_branch, git_ls_remote); see
#   sandbox/gitmcp/git-mcp-server.py. The project directory is bound
#   READ-ONLY into the sidecar too, since no exposed tool writes. The
#   sidecar is started before the agent and stopped on exit.
#
#   As defense in depth (an agent could still `apt install`/`curl` its own
#   git binary given network + package-manager access), every .git in the
#   project tree — the top-level one, submodules, and nested repositories,
#   plus the real git dir a worktree/submodule .git file points at — is
#   additionally bind-mounted READ-ONLY into the agent container. That is
#   kernel-enforced, not a wrapper, so it also blocks writes from a
#   self-installed git or any git library. The same walk covers every
#   read-write extra bind (sandbox.yml binds: / --bind), not just the
#   project dir, since a .git anywhere writable in the container is
#   otherwise unguarded. A gitdir a bound worktree/submodule .git file
#   points at that lands outside every bound tree is left unmounted (and
#   named on stderr) unless --allow-external-gitdir mounts it read-only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck source=functions/git-mcp.sh
source "$FUNCTIONS_DIR/git-mcp.sh"
# shellcheck source=functions/agents.sh
source "$FUNCTIONS_DIR/agents.sh"

# cleanup() (functions/git-mcp.sh) tears down the sidecar and any temporary
# state. Registered before anything can create that state.
trap cleanup EXIT

parse_argv "$@"

[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log_info "project dir: $PROJECT_DIR"

SANDBOX_YML="$PROJECT_DIR/sandbox.yml"
if [[ -f "$SANDBOX_YML" ]]; then
    log_info "sandbox.yml: found at $SANDBOX_YML"
else
    log_info "sandbox.yml: not found (using defaults)"
fi
parse_sandbox_yml
resolve_environment
log_info "environment: mode=$ENV_MODE base_image=$BASE_IMAGE env_tag=$ENV_TAG"

SIF_IMAGE="$SANDBOX_DIR/$AGENT.$ENV_TAG.sif"
GITMCP_SIF="$SANDBOX_DIR/gitmcp.sif"
build_images

BINDS=(
    -B "$PROJECT_DIR"
)
EXTRA_BIND_SRCS=()
EXTRA_BIND_RO=()
RO_MASKED=()
resolve_extra_binds

# sandbox.yml decides this sandbox's own binds and base image. An agent
# that can rewrite it chooses what the NEXT run mounts, so it is bound
# read-only over the read-write project-dir bind.
bind_ro "$SANDBOX_YML"

# Masks every .git in the project tree read-only in BINDS and, when the
# project root is a repository, starts the git MCP sidecar.
start_git_sidecar

configure_agent
log_info "masks: ${GIT_MASK_COUNT:-0} .git path(s) read-only, ${#RO_MASKED[@]} read-only config bind(s)"

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

EXEC_ARGV=(
    apptainer exec --containall --no-home
    --cwd "$PROJECT_DIR"
    "${BINDS[@]}"
    "${AGENT_ENV[@]}"
    --home "$HOME"
    ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} --writable-tmpfs
    "$SIF_IMAGE"
    "${RUN_CMD[@]}"
)
log_argv "apptainer exec argv" "${EXEC_ARGV[@]}"

"${EXEC_ARGV[@]}"
