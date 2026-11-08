#!/bin/bash
# --- START OF HELPTEXT ---
#
# Runs a coding agent CLI in an apptainer sandbox: the project directory
# read-write, every .git in it read-only, the agent's own config from $HOME.
#
# Usage:
#   ./sandbox.sh [options] <claude|opencode|omp> [agent-args...]
#
# Options are recognised anywhere in argv; everything else goes to the agent.
# -h/--help and -v/-vv belong to sandbox.sh only before the agent name.
#
#   --project-dir DIR          project to sandbox (default: current directory)
#   --environment KEY=VALUE    override one sandbox.yml environment: key
#   --bind SRC[:DST[:OPTS]]    extra mount, read-only unless OPTS is rw
#   --allow-external-binds     no confirmation for binds outside the project
#   --allow-external-gitdir    mount an outside git dir a .git file points to (ro)
#   --ignore-warnings          start after warnings with no terminal to confirm
#   --worktree BRANCH          run in a worktree on agent/BRANCH; commit on approval
#   --start-point COMMIT       with --worktree: create agent/BRANCH from COMMIT
#                              instead of HEAD (git's <start-point>)
#   --commit-model MODEL       model for the generated worktree commit message
#   --rebuild                  rebuild the image
#   --no-update-check          skip the agent-version check
#   -v, -vv                    more host-side logging
#   -h, --help                 this text
#
#   SANDBOX_ENGINE_IMAGE_DIR   image directory (default ~/.apptainer/images)
#
# Project settings: <project-dir>/sandbox.yml (environment:, binds:,
# patches:), honoured only when committed and clean; see sandbox.example.yml.
#
# Full reference: docs/usage.md.
# --- END OF HELPTEXT ---

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # SANDBOX_DIR is read by functions/environment.sh (generate_dockerfile, build_images, the bundled preset paths)
SANDBOX_DIR="$SCRIPT_DIR/sandbox"
FUNCTIONS_DIR="$SCRIPT_DIR/functions"

# shellcheck source=functions/log.sh
source "$FUNCTIONS_DIR/log.sh"
# shellcheck source=functions/apptainer.sh
source "$FUNCTIONS_DIR/apptainer.sh"
# shellcheck source=functions/argv.sh
source "$FUNCTIONS_DIR/argv.sh"
# shellcheck source=functions/project-sandbox-config.sh
source "$FUNCTIONS_DIR/project-sandbox-config.sh"
# shellcheck source=functions/environment.sh
source "$FUNCTIONS_DIR/environment.sh"
# shellcheck source=functions/binds.sh
source "$FUNCTIONS_DIR/binds.sh"
# shellcheck source=functions/python-env.sh
source "$FUNCTIONS_DIR/python-env.sh"
# shellcheck source=functions/omp-home.sh
source "$FUNCTIONS_DIR/omp-home.sh"
# shellcheck source=functions/claude-json.sh
source "$FUNCTIONS_DIR/claude-json.sh"
# shellcheck source=functions/claude-home.sh
source "$FUNCTIONS_DIR/claude-home.sh"
# shellcheck source=functions/git-mask.sh
source "$FUNCTIONS_DIR/git-mask.sh"
# shellcheck source=functions/agents.sh
source "$FUNCTIONS_DIR/agents.sh"
# shellcheck source=functions/cleanup.sh
source "$FUNCTIONS_DIR/cleanup.sh"
# shellcheck source=functions/run-dir.sh
source "$FUNCTIONS_DIR/run-dir.sh"
# shellcheck source=functions/commit-message.sh
source "$FUNCTIONS_DIR/commit-message.sh"
# shellcheck source=functions/worktree.sh
source "$FUNCTIONS_DIR/worktree.sh"

# Runs every teardown hook a module registers (functions/cleanup.sh);
# installed before anything creates state that needs one.
trap cleanup EXIT

# Remove scratch directories left by runs that were SIGKILLed.
reap_orphaned_run_dirs

parse_argv "$@"

# Hard gate: apptainer missing or too old fails fast, with one clear
# message, instead of surfacing deep inside a failed build. After
# parse_argv so -h/--help still works without apptainer installed.
backend_available || { echo "sandbox: $BACKEND_UNAVAILABLE_REASON" >&2; exit 1; }

[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log_info "project dir: $PROJECT_DIR"

# --worktree: validate, confirm the main-checkout mount, and resolve
# create/resume/refuse before the image build, so an ambiguous repository
# state fails fast. worktree_prepare also takes the per-worktree lock.
if [[ -n "${WORKTREE_BRANCH:-}" ]]; then
    worktree_preflight
    worktree_confirm_readonly_project
    worktree_prepare
    log_info "worktree: $WORKTREE_DIR on $WORKTREE_REF"
fi

# `script` runs its trailing argv instead of an agent CLI, in an ordinary
# agent image with the same masks (tests/git-escape/run.sh uses it).
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
parse_project_sandbox_config
resolve_environment
log_info "environment: mode=$ENV_MODE base_image=$BASE_IMAGE env_tag=$ENV_TAG"

# Image name and location belong to the backend (functions/apptainer.sh).
backend_image_ref "$IMAGE_AGENT" "$ENV_TAG"

# Best-effort; may set REBUILD=1 when the human accepts the prompt.
check_agent_update || true

build_images
# Whether the agent can run uv in this image: asked of the image itself.
detect_image_uv

# Worktree mode: the worktree is the writable checkout; the main checkout
# is mounted as chosen on the TTY, so the agent's changes land where the
# approval gate looks.
BINDS=()
if [[ -n "${WORKTREE_DIR:-}" ]]; then
    case "$WORKTREE_PROJECT_MODE" in
        rw)
            BINDS+=(-B "$PROJECT_DIR")
            ;;
        deny)
            # Not bound; mask_git_readonly still mounts its .git read-only.
            ;;
        *)
            BINDS+=(-B "$PROJECT_DIR:$PROJECT_DIR:ro")
            ;;
    esac
    BINDS+=(-B "$WORKTREE_DIR")
else
    BINDS+=(-B "$PROJECT_DIR")
fi
# shellcheck disable=SC2034  # EXTRA_BIND_SRCS/EXTRA_BIND_RO are appended to by resolve_extra_binds (functions/binds.sh) and read by mask_git_readonly (functions/git-mask.sh)
EXTRA_BIND_SRCS=()
# shellcheck disable=SC2034  # see EXTRA_BIND_SRCS above
EXTRA_BIND_RO=()
RO_MASKED=()
resolve_extra_binds

# Host virtualenvs at the root of every mounted checkout: an empty per-run
# directory over each (functions/python-env.sh). Before the .git walk and
# the config mask, which bind nothing beneath them. Only the checkout the
# agent works in gets a fresh .venv, and only when it has no venv at all.
if [[ -n "${WORKTREE_DIR:-}" ]]; then
    if [[ "$WORKTREE_PROJECT_MODE" != deny ]]; then
        mask_project_venvs "$PROJECT_DIR" 0
    fi
    mask_project_venvs "$WORKTREE_DIR" 1
else
    mask_project_venvs "$PROJECT_DIR" 1
fi
# uv's cache: one host directory every sandbox run shares.
bind_uv_cache

# Every .git under the checkout and under read-write extra binds, read-only.
mask_git_readonly

# Project config on config/mask.toml: committed and clean -> read-only HEAD
# copy, uncommitted -> hidden, absent -> unbound. In worktree mode, both
# checkouts.
mask_project_agent_config "$PROJECT_DIR"
if [[ -n "${WORKTREE_DIR:-}" ]]; then
    mask_project_agent_config "$WORKTREE_DIR"
fi
# States that partition at startup and names every uncommitted config path.
report_config_masking

configure_agent
# The commit-message generator gets only the agent's config binds (the
# tail of BINDS from AGENT_CONFIG_BIND_START): no checkout whose
# instruction files it could load. An unset offset must fail: slicing from
# 0 would silently hand it the whole bind set.
if [[ -z "${AGENT_CONFIG_BIND_START:-}" ]]; then
    echo "sandbox: configure_agent left AGENT_CONFIG_BIND_START unset -- refusing to run the commit-message generator with an unknown bind set" >&2
    exit 1
fi
# shellcheck disable=SC2034  # AGENT_CONFIG_BINDS is read by commit_msg_generate (functions/commit-message.sh)
AGENT_CONFIG_BINDS=("${BINDS[@]:${AGENT_CONFIG_BIND_START:-0}}")
log_info "masks: ${GIT_MASK_COUNT:-0} .git path(s) read-only, ${#RO_MASKED[@]} read-only config bind(s), ${#VENV_MASKED[@]} per-run venv dir(s)"
log_resolved_binds

# GPU passthrough only when the host's GPU stack looks present.
backend_gpu_args

if [[ "$VERBOSE" -ge 2 ]]; then
    for __bind_spec in "${BINDS[@]}"; do
        [[ "$__bind_spec" == "-B" ]] && continue
        log_debug "bind: $__bind_spec"
    done
    log_argv "GPU_ARGS" ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
    log_argv "RUN_CMD" "${RUN_CMD[@]}"
fi

# /tmp is a per-run host directory: --contain's own /tmp is a small tmpfs
# (docs/apptainer.md). It shares RUN_DIR's removal and reaping.
ensure_run_dir
mkdir -p "$RUN_DIR/tmp"

# Containment, network and HOME pinning are the backend's (functions/apptainer.sh).
backend_launch_argv "${WORKTREE_DIR:-$PROJECT_DIR}" "$RUN_DIR/tmp" "${RUN_CMD[@]}"
EXEC_ARGV=("${BACKEND_ARGV[@]}")

# Last host-side moment before a TUI repaints the terminal: if anything
# warned, wait until a human has read it. Once, not per worktree round.
confirm_warnings
# Normal mode: the agent's exit status is the script's; the reports run
# whatever it was and cannot change it.
if [[ -z "${WORKTREE_DIR:-}" ]]; then
    log_argv "$SANDBOX_BACKEND argv" "${EXEC_ARGV[@]}"
    AGENT_RC=0
    "${EXEC_ARGV[@]}" || AGENT_RC=$?
    # omp: merge modelRoles/cycleOrder back, name what was discarded.
    omp_home_finish || true
    # claude: merge theme/onboarding back into ~/.claude.json, name the rest.
    claude_json_finish || true
    report_agent_patches || true
    # No approval gate here: agent-created config paths are reported instead.
    report_created_config_paths "$PROJECT_DIR" || true
    exit "$AGENT_RC"
fi

# Worktree mode, on the host after the container exits: the commit uses
# the host's own git identity. Every path keeps the worktree except an
# explicit discard.
WORKTREE_DIFF_STATE="$RUN_DIR/diff_state.txt"
WORKTREE_MSG_FINAL="$RUN_DIR/commit-message.final"
while true; do
    # The message file outlives sessions; the gate names one this session
    # left untouched.
    worktree_message_snapshot
    log_argv "$SANDBOX_BACKEND argv" "${EXEC_ARGV[@]}"
    CONTAINER_RC=0
    "${EXEC_ARGV[@]}" || CONTAINER_RC=$?
    # Per round, whatever the container's status.
    omp_home_finish || true
    claude_json_finish || true
    # A read-write main checkout is outside the approval gate: report
    # config the agent created there, as in normal mode.
    if [[ "${WORKTREE_PROJECT_MODE:-ro}" == rw ]]; then
        report_created_config_paths "$PROJECT_DIR" || true
    fi
    # Reported per round, while it is clear which round produced them.
    report_agent_patches || true
    if [[ "$CONTAINER_RC" -ne 0 ]]; then
        # Never reaches the gate: left intact, never committed or discarded.
        worktree_report_crash "$CONTAINER_RC"
        exit "$CONTAINER_RC"
    fi

    worktree_build_diff_state "$WORKTREE_DIFF_STATE"
    if worktree_has_changes; then
        worktree_resolve_message "$WORKTREE_MSG_FINAL" "$WORKTREE_DIFF_STATE"
        if worktree_approval_gate "$WORKTREE_MSG_FINAL" "$WORKTREE_DIFF_STATE"; then
            if worktree_commit "$WORKTREE_MSG_FINAL"; then
                worktree_after_commit
                exit 0
            fi
        fi
    else
        echo "worktree: the agent left no changes in $WORKTREE_DIR" >&2
    fi

    worktree_reject_menu
    case "$WORKTREE_REJECT_ACTION" in
        rerun)
            # The message file is kept: the next session revises it, and
            # the gate says so if it does not.
            echo "worktree: re-running the agent in $WORKTREE_DIR" >&2
            ;;
        discard)
            worktree_discard
            exit 1
            ;;
        *)
            worktree_report_keep
            exit 1
            ;;
    esac
done
