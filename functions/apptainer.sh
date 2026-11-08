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
#   backend_available                         can the runtime be invoked, built against? On
#                                             "no": BACKEND_UNAVAILABLE_REASON
#   backend_image_ref AGENT TAG               sets SANDBOX_IMAGE, SANDBOX_IMAGE_INFO
#   backend_image_present                     does SANDBOX_IMAGE exist?
#   backend_image_remove                      deletes SANDBOX_IMAGE
#   backend_build_image CONTEXT KEY=VALUE...  builds SANDBOX_IMAGE from CONTEXT/Dockerfile
#   backend_forward_env VAR VALUE             VAR=VALUE inside the next container,
#                                             never on a command line
#   backend_forwarded_env VAR                 is VAR set inside the next container?
#                                             0 yes (value on stdout), 1 no
#   backend_gpu_args                          sets GPU_ARGS for the host's GPU stack
#   backend_launch_argv CWD TMP CMD...        sets BACKEND_ARGV: the agent's launch
#   backend_generator_argv CWD TMP CMD...     sets BACKEND_ARGV: the commit-message generator
#   backend_agent_version AGENT               prints AGENT --version from SANDBOX_IMAGE
#   backend_image_has_path PATH               does PATH exist in SANDBOX_IMAGE? 0 yes,
#                                             1 no, 2 the image could not be asked
#   backend_image_has_command CMD             does CMD resolve on SANDBOX_IMAGE's PATH?
#                                             0 yes, 1 no, 2 the image could not be asked

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

# backend_available: can the runtime be invoked at all, and built against?
# True only when "apptainer" resolves on PATH and its version is at least
# APPTAINER_MIN_VERSION, which backend_build_image's "dockerfile:" build
# source needs: 1.5.0 added OCI/BuildKit-based building (apptainer's
# "Announcing Apptainer release 1.5.0"), and an older apptainer rejects
# that build spec outright. On "no", BACKEND_UNAVAILABLE_REASON names why,
# for the one caller that treats it as fatal (sandbox.sh, at startup);
# every other caller (the agent-update check, the commit-message
# generator) is best-effort and just degrades silently.
APPTAINER_MIN_VERSION="1.5.0"

backend_available() {
    BACKEND_UNAVAILABLE_REASON=""
    if ! command -v apptainer >/dev/null 2>&1; then
        BACKEND_UNAVAILABLE_REASON="apptainer not found on PATH; sandbox-engine requires apptainer $APPTAINER_MIN_VERSION or later (https://apptainer.org/docs/admin/latest/installation.html)"
        return 1
    fi
    local raw found
    raw="$(apptainer version 2>/dev/null)" || raw=""
    found="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$raw" | head -1)"
    if [[ -z "$found" ]]; then
        log_warn "apptainer version: could not parse '$raw'" "proceeding without the minimum-version check (sandbox-engine requires $APPTAINER_MIN_VERSION or later)"
        return 0
    fi
    if [[ "$(printf '%s\n%s\n' "$APPTAINER_MIN_VERSION" "$found" | sort -V | head -1)" != "$APPTAINER_MIN_VERSION" ]]; then
        BACKEND_UNAVAILABLE_REASON="apptainer $found found, sandbox-engine requires $APPTAINER_MIN_VERSION or later: the image build needs 1.5's OCI/BuildKit-based building (https://apptainer.org/docs/admin/latest/installation.html)"
        return 1
    fi
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
#
# No --fakeroot (docs/apptainer.md). The Dockerfile's RUN steps execute in
# the BuildKit or Docker daemon, and a "dockerfile:" spec is not a
# definition file, so apptainer does not imply fakeroot for it. The local
# part -- unpacking the returned image and mksquashfs -- runs umoci's
# rootless mode and PRoot (or -all-root) either way, because inside the
# fakeroot namespace namespaces.IsUnprivileged() still sees the caller's
# host uid. --fakeroot only added host requirements (a user namespace,
# /etc/subuid or the fakeroot command) and their failures: apptainer
# before 1.6 on WSL 2.8.9+ with systemd stops with "failed to mount
# binfmt_misc filesystem: invalid argument".
backend_build_image() {
    local context="$1" kv
    shift
    local -a args=()
    for kv in "$@"; do
        args+=(--build-arg "$kv")
    done
    apptainer build ${args[@]+"${args[@]}"} "$SANDBOX_IMAGE" "dockerfile:$context"
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

# backend_forwarded_env VAR: whether VAR will be set inside the next
# container, printing its value if so. Every exec runs with --containall,
# which includes --cleanenv, so the host's own environment does not cross
# the boundary: only a variable exported as APPTAINERENV_VAR does -- by
# backend_forward_env, or by the user. A check about what the agent will
# see has to ask this, not the host variable of the same name.
backend_forwarded_env() {
    local name="APPTAINERENV_$1"
    [[ -n "${!name+x}" ]] || return 1
    printf '%s' "${!name}"
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

# apptainer_image_ask CMD...: runs CMD... (a POSIX sh command line, as
# separate words) inside SANDBOX_IMAGE itself. Returns 0 when it succeeds, 1
# when it fails, 2 when the image could not be asked. Contained and unbound
# like backend_agent_version: the answer has to describe the image, not
# whatever the host's apptainer.conf would mount into it. "Fails" gets its
# own exit status because a container that failed to start is no evidence
# about the image.
apptainer_image_ask() {
    local rc=0
    # shellcheck disable=SC2016  # "$@" is the inner sh's argv, deliberately not expanded here
    "${APPTAINER_EXEC[@]}" --cwd / "$SANDBOX_IMAGE" \
        sh -c '"$@" || exit 100' _ "$@" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        100) return 1 ;;
        *) return 2 ;;
    esac
}

# backend_image_has_path PATH: does PATH exist inside SANDBOX_IMAGE?
backend_image_has_path() {
    apptainer_image_ask test -e "$1"
}

# backend_image_has_command CMD: does CMD resolve on SANDBOX_IMAGE's PATH,
# for the user the session runs as? --containall drops the host's
# environment, so PATH is the image's own, as it is for the agent; a binary
# off that PATH, or in a directory this user cannot search, is not found.
backend_image_has_command() {
    apptainer_image_ask command -v "$1"
}
