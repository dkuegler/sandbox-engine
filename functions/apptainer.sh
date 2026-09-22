#!/bin/bash
# Sandbox backend: apptainer.
#
# The one module that knows which runtime executes the sandbox. Everything
# else assembles runtime-neutral state and calls the backend_* functions
# below; a docker or microVM backend is a sibling functions/<name>.sh that
# defines the same set, sourced by sandbox.sh in this one's place.
#
# Inputs owned by the callers, in runtime-neutral form:
#   BINDS               "-B" + "SRC[:DST[:OPTS]]" pairs (functions/binds.sh).
#                       This backend passes them through; another translates
#                       each pair. Any backend must mount the shallowest
#                       destination first: the read-only masks sit deeper
#                       than the writable binds they carve out of
#                       (functions/git-mask.sh).
#   AGENT_CONFIG_BINDS  the slice of BINDS the commit-message generator gets.
#
# Interface:
#   SANDBOX_BACKEND                           name, for messages
#   backend_available                         can the runtime be invoked?
#   backend_image_ref AGENT TAG               sets SANDBOX_IMAGE, SANDBOX_IMAGE_INFO
#   backend_image_present                     does SANDBOX_IMAGE exist?
#   backend_image_remove                      deletes SANDBOX_IMAGE
#   backend_build_image CONTEXT KEY=VALUE...  builds SANDBOX_IMAGE from CONTEXT/Dockerfile
#   backend_forward_env VAR VALUE             VAR=VALUE inside the next container,
#                                             never on a command line
#   backend_gpu_args                          sets GPU_ARGS for the host's GPU stack
#   backend_launch_argv CWD TMP CMD...        sets BACKEND_ARGV: the agent's launch
#   backend_generator_argv CWD TMP CMD...     sets BACKEND_ARGV: the commit-message generator
#   backend_agent_version AGENT               prints AGENT --version from SANDBOX_IMAGE

# shellcheck disable=SC2034  # read by sandbox.sh and functions/*.sh
SANDBOX_BACKEND=apptainer

# --- containment -------------------------------------------------------
# Every exec below must hold whatever the host's apptainer.conf says:
# --no-mount refuses by name every host mount the containment relies on
# being absent, instead of inheriting that file's defaults. What each flag
# and directive does:
#   https://apptainer.org/docs/user/latest/cli/apptainer_exec.html
#   https://apptainer.org/docs/user/latest/bind_paths_and_mounts.html
#   https://apptainer.org/docs/admin/latest/configfiles.html
# Accepted residual, not pinnable from argv: apptainer.conf's "allow pid
# ns" decides whether --containall gets its own PID namespace.
APPTAINER_NO_MOUNT="home,cwd,tmp,hostfs,bind-paths"
APPTAINER_EXEC=(apptainer exec --containall --no-mount "$APPTAINER_NO_MOUNT")
# resolv.conf is bound read-only rather than left to apptainer.conf, for the
# execs that have to reach a model API. Skipped when the host has none.
APPTAINER_NET_BINDS=()
if [[ -e /etc/resolv.conf ]]; then
    APPTAINER_NET_BINDS=(-B "/etc/resolv.conf:/etc/resolv.conf:ro")
fi

# backend_available: can the runtime be invoked at all? The best-effort
# paths (version check, commit-message generator) degrade on "no".
backend_available() {
    command -v apptainer >/dev/null 2>&1
}

# backend_image_ref AGENT TAG: the image is a SIF file under
# $SANDBOX_ENGINE_IMAGE_DIR (default ~/.apptainer/images) -- a build
# artefact, kept out of the checkout. SANDBOX_IMAGE_INFO is a host file for
# per-image state (check_agent_update's cache, functions/environment.sh).
backend_image_ref() {
    local dir="${SANDBOX_ENGINE_IMAGE_DIR:-$HOME/.apptainer/images}"
    mkdir -p "$dir"
    SANDBOX_IMAGE="$dir/$1.$2.sif"
    # shellcheck disable=SC2034  # read by check_agent_update (functions/environment.sh)
    SANDBOX_IMAGE_INFO="$SANDBOX_IMAGE.info"
}

backend_image_present() {
    [[ -n "${SANDBOX_IMAGE:-}" && -f "$SANDBOX_IMAGE" ]]
}

# backend_image_remove: apptainer refuses to overwrite an existing SIF
# without --force, so a rebuild removes the old file first; that also
# leaves no half-written image behind if the build itself fails.
backend_image_remove() {
    rm -f "$SANDBOX_IMAGE"
}

# backend_build_image CONTEXT KEY=VALUE...: builds SANDBOX_IMAGE from the
# Dockerfile in CONTEXT, passing each KEY=VALUE as a build arg.
#
# apptainer's "dockerfile:" bootstrap (an alias for "buildkit:", see
# internal/pkg/build/conveyorPacker.go) takes a build CONTEXT DIRECTORY,
# and the recipe filename inside it is fixed to "Dockerfile" unless a def
# file overrides it (conveyorPacker_buildkit.go: bk.context =
# Header["from"], bk.filename defaults to "Dockerfile"). So the spec must
# name a directory holding a file literally called Dockerfile.
backend_build_image() {
    local context="$1" kv
    shift
    local -a args=()
    for kv in "$@"; do
        args+=(--build-arg "$kv")
    done
    apptainer build --fakeroot ${args[@]+"${args[@]}"} "$SANDBOX_IMAGE" "dockerfile:$context"
}

# backend_forward_env VAR VALUE: VAR=VALUE inside the next container. Via
# the APPTAINERENV_ prefix, not --env: apptainer strips the prefix and sets
# the variable inside the container, so the value never appears in the
# world-readable /proc/<pid>/cmdline of the apptainer process;
# /proc/<pid>/environ is owner-only. It is exported into the calling
# shell -- call it from a subshell to scope it to one exec.
backend_forward_env() {
    export "APPTAINERENV_$1=$2"
}

# backend_gpu_args: sets GPU_ARGS to the flags matching whatever GPU stack
# the host actually has, instead of always passing --nv. --nv is
# NVIDIA-specific (it binds in the proprietary driver's userspace
# libraries); passing it unconditionally on a host with no NVIDIA device
# at all just makes apptainer emit "no NVIDIA driver" noise. /dev/nvidia0
# is the character device the proprietary driver creates once loaded, and
# /dev/kfd is ROCm's compute device for AMD GPUs (--rocm is its apptainer
# counterpart). /dev/dri is deliberately NOT used to gate --nv: it is the
# generic DRM render-node path shared by Intel/AMD/Nvidia alike, so an
# Intel-only laptop has it too, and would trip --nv into probing for a
# CUDA stack that was never there.
backend_gpu_args() {
    GPU_ARGS=()
    # Plain "test && append" would abort the whole script under
    # set -e the moment a device is absent -- a bare "cmd1 && cmd2"
    # statement's exit status is cmd1's when cmd1 is false, and set -e
    # treats that as a script-ending failure outside an if/while/&&-or
    # context. `if` conditions are exempt, so use those instead.
    if [[ -e /dev/nvidia0 ]]; then
        GPU_ARGS+=(--nv)
    fi
    if [[ -e /dev/kfd ]]; then
        GPU_ARGS+=(--rocm)
    fi
}

# backend_launch_argv CWD TMP CMD...: sets BACKEND_ARGV to the agent's
# launch line -- the run's BINDS and GPU_ARGS, network, and the host
# directory TMP as the container's /tmp.
backend_launch_argv() {
    local cwd="$1" tmp="$2"
    shift 2
    # shellcheck disable=SC2034  # read by sandbox.sh
    BACKEND_ARGV=(
        "${APPTAINER_EXEC[@]}"
        --cwd "$cwd"
        "${BINDS[@]}"
        ${APPTAINER_NET_BINDS[@]+"${APPTAINER_NET_BINDS[@]}"}
        # Load-bearing: pins HOME, which every "$HOME/..." bind destination
        # in functions/agents.sh is written against.
        --home "$HOME"
        ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
        -B "$tmp:/tmp"
        "$SANDBOX_IMAGE"
        "$@"
    )
}

# backend_generator_argv CWD TMP CMD...: sets BACKEND_ARGV to the
# commit-message generator's line -- the same containment and network, but
# only the agent's own config binds (AGENT_CONFIG_BINDS): no checkout.
backend_generator_argv() {
    local cwd="$1" tmp="$2"
    shift 2
    # shellcheck disable=SC2034  # read by commit_msg_generate (functions/commit-message.sh)
    BACKEND_ARGV=(
        "${APPTAINER_EXEC[@]}"
        --cwd "$cwd"
        ${AGENT_CONFIG_BINDS[@]+"${AGENT_CONFIG_BINDS[@]}"}
        ${APPTAINER_NET_BINDS[@]+"${APPTAINER_NET_BINDS[@]}"}
        --home "$HOME"
        -B "$tmp:/tmp"
        "$SANDBOX_IMAGE"
        "$@"
    )
}

# backend_agent_version AGENT: prints AGENT --version from SANDBOX_IMAGE.
# Contained like every other exec, with nothing from the host bound at all:
# a version string needs no checkout, no config and no network. --cwd /
# because the host's working directory is not mounted.
backend_agent_version() {
    "${APPTAINER_EXEC[@]}" --cwd / "$SANDBOX_IMAGE" "$1" --version
}
