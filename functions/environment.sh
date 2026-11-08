#!/bin/bash
# Execution-environment resolution (image/dockerfile/preset -> BASE_IMAGE/
# ENV_TAG/ENV_MODE) and Dockerfile generation from the template.
# Requires SANDBOX_DIR, PROJECT_DIR, AGENT and the ENV_*/CLI_ENV_* vars set
# by parse_argv/parse_project_sandbox_config.

sanitize_tag() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# resolve_environment: merges CLI_ENV_* over ENV_* (sandbox.yml), then
# derives ENV_MODE (image|dockerfile|preset), BASE_IMAGE, CUSTOM_DOCKERFILE
# and ENV_TAG (used in the built SIF's filename).
resolve_environment() {
    log_debug "resolve_environment inputs: ENV_IMAGE=$ENV_IMAGE CLI_ENV_IMAGE=$CLI_ENV_IMAGE ENV_DOCKERFILE=$ENV_DOCKERFILE CLI_ENV_DOCKERFILE=$CLI_ENV_DOCKERFILE ENV_PRESET=$ENV_PRESET CLI_ENV_PRESET=$CLI_ENV_PRESET ENV_PYTHON_VERSION=$ENV_PYTHON_VERSION CLI_ENV_PYTHON_VERSION=$CLI_ENV_PYTHON_VERSION"
    ENV_IMAGE="${CLI_ENV_IMAGE:-$ENV_IMAGE}"
    ENV_DOCKERFILE="${CLI_ENV_DOCKERFILE:-$ENV_DOCKERFILE}"
    ENV_PRESET="${CLI_ENV_PRESET:-$ENV_PRESET}"
    ENV_PYTHON_VERSION="${CLI_ENV_PYTHON_VERSION:-$ENV_PYTHON_VERSION}"
    ENV_PYTHON_VERSION="${ENV_PYTHON_VERSION:-3.13}"

    CUSTOM_DOCKERFILE=""
    BASE_IMAGE=""

    if [[ -n "$ENV_IMAGE" ]]; then
        ENV_MODE="image"
        BASE_IMAGE="$ENV_IMAGE"
        ENV_TAG="image-$(sanitize_tag "$ENV_IMAGE")"
    elif [[ -n "$ENV_DOCKERFILE" ]]; then
        ENV_MODE="dockerfile"
        CUSTOM_DOCKERFILE="$ENV_DOCKERFILE"
        [[ "$CUSTOM_DOCKERFILE" = /* ]] || CUSTOM_DOCKERFILE="$PROJECT_DIR/$CUSTOM_DOCKERFILE"
        if [[ ! -f "$CUSTOM_DOCKERFILE" ]]; then
            echo "environment.dockerfile '$ENV_DOCKERFILE' (from sandbox.yml/--environment) not found under $PROJECT_DIR" >&2
            exit 1
        fi
        if [[ "$CUSTOM_DOCKERFILE" != *"Dockerfile" ]]; then
            echo "environment.dockerfile '$ENV_DOCKERFILE' (from sandbox.yml/--environment) is not named 'Dockerfile'" >&2
            exit 1
        fi
        # sandbox.yml ships with the project, so it is as trustworthy as
        # the code being worked on: keep it from pulling an arbitrary host
        # file (via "../.." or an absolute path) into the image build.
        CUSTOM_DOCKERFILE="$(readlink -f "$CUSTOM_DOCKERFILE")"
        if [[ "$CUSTOM_DOCKERFILE" != "$PROJECT_DIR/"* ]]; then
            echo "environment.dockerfile '$ENV_DOCKERFILE' resolves to $CUSTOM_DOCKERFILE, outside the project dir $PROJECT_DIR" >&2
            exit 1
        fi
        ENV_TAG="dockerfile-$(sha256sum "$CUSTOM_DOCKERFILE" | cut -c1-12)"
    else
        ENV_MODE="preset"
        ENV_PRESET="${ENV_PRESET:-uv}"
        ENV_TAG="preset-${ENV_PRESET}"
        # shellcheck disable=SC2034  # ENV_TAG (set in the uv/python arms below) is read by sandbox.sh after resolve_environment returns
        case "$ENV_PRESET" in
            uv)
                # Same bundled/trusted dockerfile-splice pattern as
                # "shell"/"latex" below (see sandbox/uv/Dockerfile). Its base
                # is fixed, so python_version does not apply to this preset.
                ENV_MODE="dockerfile"
                CUSTOM_DOCKERFILE="$SANDBOX_DIR/uv/Dockerfile"
                ;;
            python) BASE_IMAGE="python:${ENV_PYTHON_VERSION}-slim-bookworm"; ENV_TAG="preset-python-py$(sanitize_tag "$ENV_PYTHON_VERSION")" ;;
            shell)
                # Bundled, trusted dockerfile (ships with sandbox-engine,
                # not the project being sandboxed) -- reuses generate_dockerfile's
                # dockerfile-mode splice without the external-path containment
                # check below, which only guards project-supplied
                # environment.dockerfile paths.
                ENV_MODE="dockerfile"
                CUSTOM_DOCKERFILE="$SANDBOX_DIR/shell/Dockerfile"
                ;;
            latex)
                # Same bundled/trusted dockerfile-splice pattern as
                # "shell" above: a full TeX Live install plus uv (see
                # sandbox/latex/Dockerfile). Also reachable directly via
                # environment.dockerfile: sandbox/latex/Dockerfile for
                # projects that want it without going through the preset
                # name (e.g. to combine with a fork of that file).
                ENV_MODE="dockerfile"
                CUSTOM_DOCKERFILE="$SANDBOX_DIR/latex/Dockerfile"
                ;;
            sdaps)
                # Same bundled/trusted dockerfile-splice pattern: the latex
                # preset's TeX Live and uv plus SDAPS, built from its
                # checksum-pinned release tarball (see sandbox/sdaps/Dockerfile).
                ENV_MODE="dockerfile"
                CUSTOM_DOCKERFILE="$SANDBOX_DIR/sdaps/Dockerfile"
                ;;
            *)
                echo "environment.preset '$ENV_PRESET' (from sandbox.yml/--environment): unknown, expected uv|python|shell|latex|sdaps" >&2
                exit 1
                ;;
        esac
    fi
}

# generate_dockerfile: substitutes sandbox/agent/Dockerfile.template's
# "$BASE_IMAGE"/"$AGENT"/"$SANDBOX_BUILD_ID" placeholders textually into
# sandbox/agent/Dockerfile, since apptainer's Dockerfile bootstrap neither
# evaluates ARG in FROM lines nor passes --build-arg on (docs/apptainer.md).
# In dockerfile mode, splices the custom Dockerfile in as the "base" stage.
# Sets SANDBOX_BUILD_ID.
generate_dockerfile() {
    local template="$SANDBOX_DIR/agent/Dockerfile.template"
    local out="$SANDBOX_DIR/agent/Dockerfile"
    local baseimage_line head_part tail_part body

    # shellcheck disable=SC2016  # single quotes intentional: matching the literal text "$BASE_IMAGE" in the template, not expanding it
    baseimage_line="$(grep -n '^FROM \$BASE_IMAGE AS base$' "$template" | head -n1 | cut -d: -f1)"
    if [[ -z "$baseimage_line" ]]; then
        echo "sandbox/agent/Dockerfile.template: missing 'FROM \$BASE_IMAGE AS base' baseimage line" >&2
        exit 1
    fi
    head_part="$(sed -n "1,$((baseimage_line - 1))p" "$template")"
    tail_part="$(sed -n "$((baseimage_line + 1)),\$p" "$template")"

    if [[ "$ENV_MODE" == "dockerfile" ]]; then
        # Splice the custom Dockerfile in as the "base" stage: its own last
        # FROM becomes the thing the shared toolchain/uv layer builds on top
        # of, so "dockerfile:" behaves like an implicit custom base image.
        local last_from lineno content alias custom
        last_from="$(grep -n '^FROM ' "$CUSTOM_DOCKERFILE" | tail -n1)"
        if [[ -z "$last_from" ]]; then
            echo "environment.dockerfile '$ENV_DOCKERFILE' has no FROM line" >&2
            exit 1
        fi
        lineno="${last_from%%:*}"
        content="${last_from#*:}"
        custom="$(cat "$CUSTOM_DOCKERFILE")"
        if [[ "$content" =~ AS[[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$ ]]; then
            alias="${BASH_REMATCH[1]}"
            body="$custom"$'\n'"FROM $alias AS base"
        else
            body="$(printf '%s\n' "$custom" | sed "${lineno}s/\$/ AS base/")"
        fi
    else
        body="FROM $BASE_IMAGE AS base"
    fi

    # Same textual substitution as the $BASE_IMAGE splice above:
    # apptainer's Dockerfile bootstrap does not evaluate ARG in FROM
    # lines, so the agent stage selector is substituted here.
    # IMAGE_AGENT, not AGENT: `script` is a run mode with no Dockerfile
    # stage of its own (sandbox.sh sets it to a real agent's name).
    tail_part="${tail_part//FROM \$AGENT AS/FROM ${IMAGE_AGENT:-$AGENT} AS}"

    # A fresh id per build. The builder keys a RUN layer on its command text
    # and its parent, so the template's first RUN, which carries this id, and
    # every layer after it are rebuilt instead of served from its cache --
    # which is what would otherwise pin the agent to whatever release was
    # current when that layer was first built. Refused if the template lost
    # the placeholder: the build would quietly be cacheable again.
    # $RANDOM, not $$: the id ends up inside the image, a host PID need not.
    SANDBOX_BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    # shellcheck disable=SC2016  # single quotes intentional: the literal placeholder text
    if [[ "$tail_part" != *'$SANDBOX_BUILD_ID'* ]]; then
        echo "sandbox/agent/Dockerfile.template: missing the \$SANDBOX_BUILD_ID placeholder" >&2
        exit 1
    fi
    tail_part="${tail_part//\$SANDBOX_BUILD_ID/$SANDBOX_BUILD_ID}"

    rm -f "$out"
    {
        printf '%s\n' "$head_part"
        printf '%s\n' "$body"
        printf '%s\n' "$tail_part"
    } > "$out"
}

# agent_upstream_version AGENT: the latest upstream release of AGENT on
# stdout, or status 1 when it cannot be told: unknown agent, no curl, no
# network, an HTTP error (GitHub's unauthenticated API allows 60 requests
# an hour per IP, and a shared institute address runs out), or a reply
# without a well-formed version. Each endpoint is the one the agent's own
# installer resolves "latest" from, so the answer names what a build of
# sandbox/agent/Dockerfile.template installs. Bounded by a 3 s timeout;
# -vv logs the request and its outcome.
agent_upstream_version() {
    local url response="" status body latest="" rc=0
    case "$1" in
        claude) url="https://registry.npmjs.org/@anthropic-ai/claude-code/latest" ;;
        # Same endpoint opencode.ai/v2/install itself queries for its own latest version.
        opencode) url="https://opencode.ai/update/api/latest/cli/npm" ;;
        # Same endpoint omp.sh/install.sh's binary-install path itself queries.
        omp) url="https://api.github.com/repos/can1357/oh-my-pi/releases/latest" ;;
        *)
            log_debug "agent version: no upstream endpoint known for '$1'"
            return 1
            ;;
    esac
    if ! command -v curl >/dev/null 2>&1; then
        log_debug "agent version: no curl on the host"
        return 1
    fi

    # -w appends the HTTP status as a line of its own; 000 means no reply.
    response="$(curl -sL --max-time 3 -w '\n%{http_code}' "$url" 2>/dev/null)" || rc=$?
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "$status" == 200 ]]; then
        case "$1" in
            omp)
                latest="$(printf '%s\n' "$body" \
                    | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')" || latest=""
                latest="${latest#v}"
                ;;
            *)
                latest="$(printf '%s\n' "$body" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" || latest=""
                ;;
        esac
    else
        # The reply is network content headed for the terminal: one line,
        # control bytes removed (functions/binds.sh).
        log_debug "agent version: reply from $url: $(printf '%s' "${body:0:200}" | tr '\t\n' '  ' | sanitize_agent_display)"
    fi
    # The version is printed in the rebuild prompt and compared as text, so
    # anything but one short version token (an escape sequence, a second
    # match on another line) counts as no answer.
    if [[ -n "$latest" && ! "$latest" =~ ^[0-9A-Za-z.+-]{1,64}$ ]]; then
        log_debug "agent version: reply from $url holds no well-formed version"
        latest=""
    fi
    log_debug "agent version: GET $url -> HTTP ${status:-none} (curl exit $rc), latest release '$latest'"
    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

# image_agent_version: the version IMAGE_AGENT reports inside SANDBOX_IMAGE
# on stdout, or status 1. Every agent's --version prints the semver
# somewhere in otherwise varying decoration ("2.1.281 (Claude Code)" for
# claude, "omp/1.2.3" for omp, "opencode v1.2.3" for opencode) -- pulling
# out the first dotted-numeric token is robust to all three instead of
# assuming a fixed field position (a trailing "(Claude Code)" parenthetical
# used to be picked as the "version" by a last-whitespace-field split).
image_agent_version() {
    local raw="" version=""
    raw="$(backend_agent_version "$IMAGE_AGENT" 2>/dev/null)" || raw=""
    version="$(printf '%s' "$raw" | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1)" || version=""
    log_debug "agent version: '$IMAGE_AGENT --version' in $SANDBOX_IMAGE printed" \
        "'$(printf '%s' "$raw" | tr '\t\n' '  ' | sanitize_agent_display)' -> '$version'"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

# agent_update_cache_write LATEST IN_IMAGE: records one version comparison
# in SANDBOX_IMAGE_INFO. Its mtime is what rate-limits check_agent_update.
agent_update_cache_write() {
    printf 'Agent: %s\nDate: %s\nVersion available: %s\nVersion in image: %s\n' \
        "$IMAGE_AGENT" "$(date +%s)" "$1" "$2" 2>/dev/null >"$SANDBOX_IMAGE_INFO" || true
}

# check_agent_update: best-effort, rate-limited check for whether a newer
# <agent> CLI release exists than the one already baked into the image,
# and if so, offers to rebuild. This is about the *agent CLI's* version
# drift, not sandbox-engine's own version, and not image *build-input*
# staleness either -- that is already automatic: ENV_TAG changes with
# sandbox.yml/--environment/base image, so a changed tag builds a fresh
# image on its own, and --rebuild forces one regardless. None of the three
# agents pin a version in sandbox/agent/Dockerfile.template (`claude` is
# `npm install -g @anthropic-ai/claude-code`; `opencode`/`omp` are
# curl-piped install scripts), and generate_dockerfile's per-build id keeps
# the builder from serving the install from its cache, so every build
# installs whatever is current at build time and the baked-in version
# drifts from upstream between builds with nothing else to surface that.
#
# Every step here is best-effort: no runtime or curl, no network, a
# malformed response, or no /dev/tty to prompt on all degrade to
# build/reuse the image exactly as before -- this must never fail or add
# meaningful latency to a run, so every fallible command substitution
# below is paired with an explicit `|| var=""` fallback (a pipeline's
# failure under `set -o pipefail` otherwise trips the caller's `set -e`,
# even when a later stage of that same pipe succeeds). -v prints the two
# versions compared, -vv the step a check stopped at. The per-(agent,
# environment) cache is written on every attempt, successful or not, so a
# persistently offline host pays the short, timeout-bounded network cost
# at most once an hour, not once per invocation.
check_agent_update() {
    if [[ "${NO_UPDATE_CHECK:-0}" -eq 1 ]]; then
        log_debug "update check: off (--no-update-check)"
        return 0
    fi
    if ! backend_image_present; then
        log_debug "update check: skipped, $SANDBOX_IMAGE is not built yet"
        return 0
    fi
    if ! backend_available; then
        log_debug "update check: skipped, $SANDBOX_BACKEND cannot be invoked"
        return 0
    fi

    local cache_file="$SANDBOX_IMAGE_INFO" mtime age
    if [[ -f "$cache_file" ]]; then
        mtime="$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)"
        age=$(( $(date +%s) - mtime ))
        if [[ "$age" -lt 3600 ]]; then
            log_debug "update check: skipped, the last one was ${age}s ago" \
                "($cache_file: $(tr '\n' ' ' <"$cache_file" | sanitize_agent_display))"
            return 0
        fi
    fi

    local latest="" baked_version=""
    latest="$(agent_upstream_version "$IMAGE_AGENT")" || latest=""
    if [[ -n "$latest" ]]; then
        baked_version="$(image_agent_version)" || baked_version=""
    fi
    agent_update_cache_write "$latest" "$baked_version"
    log_info "update check: $IMAGE_AGENT ${baked_version:-unknown} in the image, ${latest:-unknown} upstream"
    [[ -n "$latest" && -n "$baked_version" ]] || return 0
    [[ "$baked_version" == "$latest" ]] && return 0

    # -r alone is not a reliable predictor: /dev/tty is world-readable even
    # with no controlling terminal, where opening it fails with ENXIO. So
    # the prompt's own printf decides, and the note covers every run it
    # could not reach.
    local reply
    if [[ -r /dev/tty ]] && printf 'A newer %s release is available (%s -> %s). Rebuild the image now? [y/N] ' \
          "$IMAGE_AGENT" "$baked_version" "$latest" 2>/dev/null >/dev/tty; then
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "$reply" in
            [yY]*)
                # shellcheck disable=SC2034  # REBUILD is read by build_images (functions/environment.sh)
                REBUILD=1
                ;;
        esac
        return 0
    fi
    printf "note: a newer %s release is available (%s -> %s); pass --rebuild to update.\n" "$IMAGE_AGENT" \
      "$baked_version" "$latest" >&2
    return 0
}

# check_built_agent_version: after a build, compares the agent version the
# new image holds with upstream's latest release. With the per-build id in
# place they differ only when the build installed something other than the
# current release (an installer resolving "latest" elsewhere, a release
# published mid-build), so a difference warns, which holds the start
# (functions/log.sh). The result also restarts the update-check cache's
# hour. --no-update-check skips the network query.
check_built_agent_version() {
    local installed="" latest=""
    installed="$(image_agent_version)" || installed=""
    log_info "agent image: $SANDBOX_IMAGE (built, $IMAGE_AGENT ${installed:-version unknown})"
    if [[ "${NO_UPDATE_CHECK:-0}" -eq 1 ]]; then
        return 0
    fi
    latest="$(agent_upstream_version "$IMAGE_AGENT")" || latest=""
    agent_update_cache_write "$latest" "$installed"
    if [[ -n "$installed" && -n "$latest" && "$installed" != "$latest" ]]; then
        log_warn "the $IMAGE_AGENT just built into $SANDBOX_IMAGE is $installed, but upstream's latest release is $latest." \
            "Build id $SANDBOX_BUILD_ID (/etc/sandbox-engine-build-id in the image); -vv shows both queries."
    fi
    return 0
}

# build_images: builds the agent image on first use, or unconditionally
# when REBUILD=1 (set by --rebuild, see functions/argv.sh, or by accepting
# check_agent_update's prompt). Requires backend_image_ref
# (functions/apptainer.sh) to have set the image.
build_images() {
    local reason
    if [[ "$REBUILD" -eq 1 ]]; then
        reason="rebuild requested"
    elif ! backend_image_present; then
        reason="not built yet"
    else
        log_info "agent image: $SANDBOX_IMAGE (reused)"
        return 0
    fi
    backend_image_remove
    generate_dockerfile
    log_info "agent image: building $SANDBOX_IMAGE ($reason), build id $SANDBOX_BUILD_ID"
    backend_build_image "$SANDBOX_DIR/agent" \
        "USERNAME=${USER:-$(id -un)}" \
        "UID=$(id -u)" \
        "GID=$(id -g)" \
        "AGENT=${IMAGE_AGENT:-$AGENT}"
    check_built_agent_version
}

# detect_image_uv: sets ENV_HAS_UV=1 when the agent can run uv in the
# image, which adds the uv line to its instruction overlay
# (bind_augmented_instructions, functions/agents.sh). Asked of the built
# image on every run (backend_image_has_command), never inferred from the
# preset or the Dockerfile's text: uv arrives many ways (a uv base image,
# COPY --from, the standalone installer, pip), and only the image can tell
# whether the result is on the session's PATH and reachable by its user.
# The answer is an exit status; nothing read from the image reaches the
# overlay. An image that could not be asked counts as having no uv.
# shellcheck disable=SC2034  # ENV_HAS_UV is read by bind_augmented_instructions (functions/agents.sh)
detect_image_uv() {
    local rc=0
    ENV_HAS_UV=0
    backend_image_has_command uv || rc=$?
    case "$rc" in
        0)
            ENV_HAS_UV=1
            log_info "agent image: uv on PATH; the instruction overlay names it"
            ;;
        1) log_info "agent image: no uv on PATH" ;;
        *) log_info "agent image: could not be asked for uv; treated as absent" ;;
    esac
}
