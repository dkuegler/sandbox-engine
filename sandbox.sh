#!/bin/bash
# --- START OF HELPTEXT ---
#
# Unified sandbox entrypoint. Usage:
#   ./sandbox.sh [--project-dir DIR] [--worktree BRANCH] [--commit-model MODEL] [--environment KEY=VALUE ...] [--bind SRC[:DST[:OPTS]]] [--allow-external-binds] [--allow-external-gitdir] [--ignore-warnings] [-v|--verbose|-vv] [--rebuild] [--no-update-check] [-h|--help] <claude|opencode|omp> [agent-args...]
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
#   log.sh          -v/-vv verbosity helpers, log_warn and the warning gate
#   apptainer.sh    the sandbox backend: every runtime-specific flag and call
#   argv.sh         --project-dir/--environment/--bind/agent argv parsing
#   sandbox_yml.sh  <project-dir>/sandbox.yml parsing
#   environment.sh  base-image resolution, Dockerfile generation, image build
#   binds.sh        extra bind resolution (sandbox.yml binds: / --bind)
#   git-mask.sh     read-only .git mask
#   agents.sh       per-agent state binds, RUN_CMD
#   cleanup.sh      EXIT trap and the teardown hooks registered against it
#   run-dir.sh      per-run scratch directory lifecycle (teardown, reap)
#   worktree.sh     --worktree branch/worktree lifecycle, review, commit
#   commit-message.sh  sandboxed commit-message generation for --worktree
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
#   answerable "y" (mount as requested), "r" (mount read-only instead,
#   overriding a requested :rw), or anything else (refuse) -- or allowed
#   non-interactively with --allow-external-binds. With no TTY available
#   (CI, </dev/null) the run refuses and names the flag. The check runs
#   once, on the source after resolving symlinks -- the path that is
#   actually mounted -- so a symlink inside the project pointing outside
#   is caught, and a path outside that resolves inside the project needs
#   no confirmation. Every
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
#
# Project config masking (the git-known convention):
#   Every project-root path an agent CLI would execute or auto-load on
#   the human's NEXT interaction with the checkout is on a fixed table
#   (config/mask.yml), and the session's view of each path is decided by
#   one rule: visible <=> tracked in the checkout's HEAD tree AND
#   identical to it in the working tree. Only the user commits, so
#   committed config is user-authored and safe to show; everything else
#   is uncommitted state and the session is blind to it.
#
#   - committed & clean: a fresh per-run copy of the committed content is
#     bound READ-ONLY over the path. An agent write here would persist
#     uncommitted on the host and run outside the sandbox later.
#   - uncommitted (untracked, or tracked but locally modified): hidden.
#     The session sees an empty placeholder -- or, for a tracked path
#     with local drift, the committed copy -- and can neither read the
#     local content nor write the path.
#   - absent on disk: not bound at all. There is nothing to hide, and a
#     bind would make apptainer materialize an empty placeholder in the
#     checkout. If the agent creates a file at such a path, it does not
#     load in this session and is invisible to later sandboxed runs; it
#     reaches the host only through a human act: reported in full when
#     the run ends (normal mode, and a main checkout mounted read-write
#     in worktree mode) or shown in the approval gate's review (worktree
#     mode).
#   - a symlink, on disk or as HEAD records it: the run is refused. A
#     bind follows a link to wherever it points, so config paths must be
#     regular files or directories.
#
#   sandbox.yml is gated one layer earlier than the rest, because the
#   HOST parses it before any container exists and no container mask can
#   intercept that read. A sandbox.yml that is not tracked in HEAD and
#   identical to it is refused outright, naming what the uncommitted
#   version would change about the run; committing it is how you accept
#   it. Comment and blank-line edits are ignored by that check. A
#   symlink at that path is refused too: git would vouch for the link
#   while the parser reads its target.
#
#   report_config_masking states this partition at startup; the exit
#   report and the gate are where agent-created files surface.
#
# Warnings (--ignore-warnings):
#   Every host-side warning is collected as well as printed. If a run
#   produced any, the agent does not start until a human has seen them:
#   they are printed again, together, and the run waits for Enter on
#   /dev/tty -- a full-screen agent would otherwise repaint over them. A
#   run with no warnings prints nothing extra and does not wait. With no
#   TTY available (CI, </dev/null) a run that warned refuses to start
#   unless --ignore-warnings was passed; with a TTY the flag changes
#   nothing.
#
# Worktree mode (--worktree BRANCH):
#   Runs the agent in a throwaway git worktree checked out on
#   "agent/BRANCH" under $HOME/.agent/worktrees/<project>/<branch>, instead
#   of in the project's own checkout. The worktree is bind-mounted
#   read-write and becomes the container's cwd; the main checkout will be
#   mounted READ-ONLY if it is interactively confirmed on /dev/tty, so the
#   agent can read the untracked/ignored files a worktree does not contain
#   (local notes, .env, build output) without being able to modify them.
#
#   Note: --worktree BRANCH is designed to be used in terminal sessions.
#   Usage without a terminal are not supported!
#
#   Every .git stays read-only-masked exactly as above -- including the
#   worktree's own "gitdir:" pointer file and the <main>/.git/worktrees/
#   metadata directory it names. That is not belt-and-braces: a linked
#   worktree shares the main repository's object database and ref
#   namespace, so a writable worktree gitdir would be write access to the
#   main repository's history. The agent therefore cannot commit at all.
#
#   After the container exits, on the host: the change is shown on the TTY
#   together with a commit message, and an explicit approval is required
#   before anything is committed. There is no --yes, no environment
#   variable and no unattended path. Rejecting offers to keep the worktree,
#   re-run the agent in it, or discard it.
#
#   The message is the one the agent wrote to $HOME/.sandbox-commit-message.
#   If it left that file empty, one is generated by asking the agent again
#   -- in a second, smaller container built from the same image, holding
#   the agent's config and credentials but NOT the project or the worktree,
#   with the agent's own tools switched off and the diff passed in as inert
#   text. Generation never runs on the host: the diff it is fed is
#   agent-authored. The model defaults to the agent's own small/commit
#   model: omp's "commit" model role if one is configured (else omp's
#   default model), claude's built-in "haiku" alias, or opencode's own
#   "commit" agent if one is defined (else its small_model, else
#   opencode's default). --commit-model MODEL overrides all three and
#   never inherits the coding run's own --model. See
#   docs/commit-message-generation.md.
#
#   Nothing is ever pushed: an approved run commits onto agent/BRANCH in
#   the main repository and prints the push command for you to run. No
#   forge credential or real remote URL enters the container for this.
#
#   Branch collisions are never guessed at: worktree + branch both present
#   and matching resumes that worktree; a branch that exists without its
#   worktree (or the reverse) refuses and names what it found.
# --- END OF HELPTEXT ---

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # SANDBOX_DIR is read by functions/environment.sh (generate_dockerfile, build_images, the shell/latex preset paths)
SANDBOX_DIR="$SCRIPT_DIR/sandbox"
FUNCTIONS_DIR="$SCRIPT_DIR/functions"

# shellcheck source=functions/log.sh
source "$FUNCTIONS_DIR/log.sh"
# shellcheck source=functions/apptainer.sh
source "$FUNCTIONS_DIR/apptainer.sh"
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
# shellcheck source=functions/cleanup.sh
source "$FUNCTIONS_DIR/cleanup.sh"
# shellcheck source=functions/run-dir.sh
source "$FUNCTIONS_DIR/run-dir.sh"
# shellcheck source=functions/commit-message.sh
source "$FUNCTIONS_DIR/commit-message.sh"
# shellcheck source=functions/worktree.sh
source "$FUNCTIONS_DIR/worktree.sh"

# cleanup() (functions/cleanup.sh) runs every teardown hook a module
# registered for the state it created -- the per-run scratch directory
# (functions/run-dir.sh) and, in worktree mode, the per-worktree lock
# (functions/worktree.sh). Registered before anything can create that state.
trap cleanup EXIT

# Reap any leaked scratch directory from a run that was SIGKILLed before the
# EXIT trap above could run remove_run_dir() (functions/run-dir.sh), before
# this run creates its own.
reap_orphaned_run_dirs

parse_argv "$@"

[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log_info "project dir: $PROJECT_DIR"

# --worktree: validate, confirm the read-only main checkout on the TTY, and
# resolve create-vs-resume-vs-refuse -- all before the image build, so an
# ambiguous repository state costs a second rather than a full agent
# session. worktree_prepare() also takes the per-worktree lock, which
# registers its own release with the EXIT trap (functions/cleanup.sh).
if [[ -n "${WORKTREE_BRANCH:-}" ]]; then
    worktree_preflight
    worktree_confirm_readonly_project
    worktree_prepare
    log_info "worktree: $WORKTREE_DIR on $WORKTREE_REF"
fi

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

# The image and where it lives are the backend's (functions/apptainer.sh).
backend_image_ref "$IMAGE_AGENT" "$ENV_TAG"

# Best-effort: never blocks or fails a run (functions/environment.sh's own
# doc comment). May set REBUILD=1 if the human accepts the prompt, in
# which case build_images below rebuilds through its existing path --
# --no-update-check (functions/argv.sh) skips this entirely.
check_agent_update || true

build_images

# In worktree mode the writable checkout is the worktree, and the project's
# own checkout is demoted to read-only (confirmed on the TTY above), so the
# agent's changes can only exist where the approval gate will look for them.
BINDS=()
if [[ -n "${WORKTREE_DIR:-}" ]]; then
    case "$WORKTREE_PROJECT_MODE" in
        rw)
            BINDS+=(-B "$PROJECT_DIR")
            ;;
        deny)
            # main checkout not bound at all; mask_git_readonly() below still
            # mounts $PROJECT_DIR/.git read-only, which is all git itself needs.
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

# sandbox.yml is an ordinary row on the config-mask table
# (config/mask.yml): the thing that actually protects it is the
# tracked-and-clean refusal in parse_sandbox_yml() above, which ran
# before this run built anything from it. The mask below only keeps the
# session from reading an uncommitted copy or rewriting a committed one,
# exactly like every other known-config path.

# Masks every .git in the project tree read-only in BINDS.
mask_git_readonly

# Masks every project-root file/dir an agent CLI treats as executable
# config (MCP server command lines, plugins, hooks) read-only, on top of
# the plain read-write project-dir bind -- functions/binds.sh's
# mask_project_agent_config(). Both the main checkout and the worktree
# copy are masked: the worktree holds its own tracked copy of every table
# path, and the main checkout's copy is masked here rather than relying
# solely on its whole-tree read-only bind in worktree mode, since a
# non-worktree run leaves it read-write.
mask_project_agent_config "$PROJECT_DIR"
if [[ -n "${WORKTREE_DIR:-}" ]]; then
    mask_project_agent_config "$WORKTREE_DIR"
fi
# The startup confirmation: states the partition each session runs under
# (informational, no prompt) and names every uncommitted config path, so
# a plant left by a crashed run is visible by name on every run until
# the human acts on it.
report_config_masking

configure_agent
# The config-only tail of BINDS (see AGENT_CONFIG_BIND_START,
# functions/agents.sh): the agent's own state and credentials, without the
# project dir, the worktree, the extra binds or the .git masks. This is the
# entire bind set the sandboxed commit-message generator runs with, so that
# an agent-authored diff cannot reach a checkout whose instruction files
# would then be auto-loaded (functions/commit-message.sh).
#
# An unset offset is a hard error rather than a 0 default: slicing from 0
# would hand the generator the whole bind set -- project dir, worktree,
# extra binds, .git masks -- which is precisely the isolation this slice
# exists to create, and it would do so silently. configure_agent() sets
# the offset unconditionally, so reaching this means the invariant it
# rests on no longer holds and nothing here can guess a safe substitute.
if [[ -z "${AGENT_CONFIG_BIND_START:-}" ]]; then
    echo "sandbox: configure_agent left AGENT_CONFIG_BIND_START unset -- refusing to run the commit-message generator with an unknown bind set" >&2
    exit 1
fi
# shellcheck disable=SC2034  # AGENT_CONFIG_BINDS is read by commit_msg_generate (functions/commit-message.sh)
AGENT_CONFIG_BINDS=("${BINDS[@]:${AGENT_CONFIG_BIND_START:-0}}")
log_info "masks: ${GIT_MASK_COUNT:-0} .git path(s) read-only, ${#RO_MASKED[@]} read-only config bind(s)"
log_resolved_binds

# GPU passthrough only when the host's GPU stack looks present, so a plain
# CPU host doesn't get the runtime probing for a driver that isn't there.
backend_gpu_args

if [[ "$VERBOSE" -ge 2 ]]; then
    for __bind_spec in "${BINDS[@]}"; do
        [[ "$__bind_spec" == "-B" ]] && continue
        log_debug "bind: $__bind_spec"
    done
    log_argv "GPU_ARGS" ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
    log_argv "RUN_CMD" "${RUN_CMD[@]}"
fi

# --writable-tmpfs gives only 64 MiB total, shared between / and /tmp
# (measured: `df` reports `tmpfs 64M 64M 0 100% /tmp` inside a live
# agent) -- too small for ordinary work (a `pip install`, an `npm i`,
# one extracted Debian package). `--containall`'s own `--contain` mounts
# a fresh tiny tmpfs over /tmp, so /tmp needs a separate bind on top.
# RUN_DIR (ensure_run_dir(), functions/agents.sh) is already removed
# unconditionally on exit by remove_run_dir() and reaped if orphaned
# (reap_orphaned_run_dirs, both functions/run-dir.sh), so both pieces
# below ride that same lifecycle for free -- no new cleanup path needed.
ensure_run_dir
mkdir -p "$RUN_DIR/tmp"

# The launch line -- containment, network, HOME pinning -- is the
# backend's (functions/apptainer.sh).
backend_launch_argv "${WORKTREE_DIR:-$PROJECT_DIR}" "$RUN_DIR/tmp" "${RUN_CMD[@]}"
EXEC_ARGV=("${BACKEND_ARGV[@]}")

# The last host-side moment before the agent takes the terminal. Every
# check that can warn has run by now, and from here on a full-screen TUI
# repaints over anything already printed -- so if this run warned about
# anything, stop and make sure a human has read it. Silent when the run
# was clean. Called once, above both modes: worktree mode re-execs inside
# a loop below, and the gate is about this run's host-side findings, not
# about each round.
confirm_warnings
# Project mode: the agent's own exit status is this script's exit status.
# Captured rather than left to `set -e`, because the host-side step below
# has to run whether the agent succeeded or not -- and it must not be
# able to overwrite the status the agent reported.
if [[ -z "${WORKTREE_DIR:-}" ]]; then
    log_argv "$SANDBOX_BACKEND argv" "${EXEC_ARGV[@]}"
    AGENT_RC=0
    "${EXEC_ARGV[@]}" || AGENT_RC=$?
    # Normal mode has no approval gate: the review of what the agent
    # created at config paths that were absent at launch happens here.
    report_created_config_paths "$PROJECT_DIR" || true
    exit "$AGENT_RC"
fi

# Worktree mode. Everything below runs on the HOST, after the container has
# exited -- the container is never given a way to commit, and the commit
# that eventually happens uses this host's own ambient git identity and
# config. Every exit path leaves the worktree on disk except the single one
# the human explicitly asks to discard.
WORKTREE_DIFF_STATE="$RUN_DIR/diff_state.txt"
WORKTREE_MSG_FINAL="$RUN_DIR/commit-message.final"
while true; do
    log_argv "$SANDBOX_BACKEND argv" "${EXEC_ARGV[@]}"
    CONTAINER_RC=0
    "${EXEC_ARGV[@]}" || CONTAINER_RC=$?
    # A main checkout mounted read-write (worktree_confirm_readonly_project)
    # is outside the approval gate, which only reviews the worktree -- so
    # config the agent created at its unbound paths gets the normal-mode
    # exit report, each round, whatever the container's status.
    if [[ "${WORKTREE_PROJECT_MODE:-ro}" == rw ]]; then
        report_created_config_paths "$PROJECT_DIR" || true
    fi
    if [[ "$CONTAINER_RC" -ne 0 ]]; then
        # Never reached the gate: left intact for inspection, never
        # auto-committed and never discarded.
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
            # Fresh message file per round: the gate must show the message
            # for the change it is actually displaying, never a stale one.
            : >"${WORKTREE_MSG_HOST:-/dev/null}"
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
