#!/bin/bash
# Execution-environment resolution (image/dockerfile/preset -> BASE_IMAGE/
# ENV_TAG/ENV_MODE) and Dockerfile generation from the template.
# Requires SANDBOX_DIR, PROJECT_DIR, AGENT and the ENV_*/CLI_ENV_* vars set
# by parse_argv/parse_project_sandbox_config.

sanitize_tag() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# resolve_environment: merges CLI_ENV_* over ENV_* (sandbox.yml), then
# derives ENV_MODE (image|dockerfile|preset), BASE_IMAGE, CUSTOM_DOCKERFILE,
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
            uv) BASE_IMAGE="ghcr.io/astral-sh/uv:python${ENV_PYTHON_VERSION}-bookworm-slim"; ENV_TAG="preset-uv-py$(sanitize_tag "$ENV_PYTHON_VERSION")" ;;
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
            *)
                echo "environment.preset '$ENV_PRESET' (from sandbox.yml/--environment): unknown, expected uv|python|shell|latex" >&2
                exit 1
                ;;
        esac
    fi
}

# generate_dockerfile: substitutes sandbox/agent/Dockerfile.template's
# "$BASE_IMAGE"/"$AGENT" arguments textually into sandbox/agent/Dockerfile,
# since apptainer's Dockerfile bootstrap does not evaluate ARG in FROM
# lines. In dockerfile mode, splices the custom Dockerfile in as the
# "base" stage.
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

    rm -f "$out"
    {
        printf '%s\n' "$head_part"
        printf '%s\n' "$body"
        printf '%s\n' "$tail_part"
    } > "$out"
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
# curl-piped install scripts), so every rebuild installs whatever is
# current at build time and the baked-in version silently drifts from
# upstream between rebuilds with nothing else to surface that.
#
# Every step here is best-effort: no runtime or curl, no network, a
# malformed response, or no /dev/tty to prompt on all degrade silently to
# build/reuse the image exactly as before -- this must never fail or add
# meaningful latency to a run, so every fallible command substitution
# below is paired with an explicit `|| var=""` fallback (a pipeline's
# failure under `set -o pipefail` otherwise trips the caller's `set -e`,
# even when a later stage of that same pipe succeeds). The per-(agent,
# environment) cache is written on every attempt, successful or not, so a
# persistently offline host pays the short, timeout-bounded network cost
# at most once an hour, not once per invocation.
check_agent_update() {
    [[ "${NO_UPDATE_CHECK:-0}" -eq 1 ]] && return 0
    backend_image_present || return 0 # nothing built yet to compare against
    backend_available || return 0
    command -v curl >/dev/null 2>&1 || return 0

    local cache_file="$SANDBOX_IMAGE_INFO"
    if [[ -f "$cache_file" ]]; then
        local mtime age
        mtime="$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)"
        age=$(( $(date +%s) - mtime ))
        [[ "$age" -lt 3600 ]] && return 0
    fi

    local latest=""
    case "$IMAGE_AGENT" in
        claude)
            latest="$(curl -fsSL --max-time 3 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
                | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" || latest=""
            ;;
        opencode)
            # Same endpoint opencode.ai/v2/install itself queries for its own latest version.
            latest="$(curl -fsSL --max-time 3 https://opencode.ai/update/api/latest/cli/npm 2>/dev/null \
                | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" || latest=""
            ;;
        omp)
            # Same endpoint omp.sh/install.sh's binary-install path itself queries.
            latest="$(curl -fsSL --max-time 3 https://api.github.com/repos/can1357/oh-my-pi/releases/latest 2>/dev/null \
                | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')" || latest=""
            latest="${latest#v}"
            ;;
        *)
            : # unknown agent (e.g. script mode's fallback) -- nothing to compare against
            ;;
    esac

    printf 'Agent: %s\nDate: %s\nVersion available: %s\n' "$IMAGE_AGENT" "$(date +%s)" "$latest" > "$cache_file" \
      2>/dev/null || true
    [[ -n "$latest" ]] || return 0

    local baked_version
    baked_version="$(backend_agent_version "$IMAGE_AGENT" 2>/dev/null)" || baked_version=""
    baked_version="${baked_version##* }"
    # omp prints "omp/<version>" as a single space-free token (claude/opencode
    # print "<name> <version>", already handled by the space-split above), so
    # strip a leading "<name>/" the same way before the "v" strip below --
    # otherwise baked_version stays "omp/18.2.7" against a bare "18.2.7"
    # latest and the two never compare equal even when they are the same
    # release.
    baked_version="${baked_version#"$IMAGE_AGENT"/}"
    baked_version="${baked_version#v}"
    [[ -n "$baked_version" ]] || return 0
    [[ "$baked_version" == "$latest" ]] && return 0

    if [[ ! -r /dev/tty ]]; then
        printf "note: a newer %s release is available (%s -> %s); pass --rebuild to update." "$IMAGE_AGENT" \
          "$baked_version" "$latest" >&2
        return 0
    fi

    local reply
    if printf 'A newer %s release is available (%s -> %s). Rebuild the image now? [y/N] ' \
          "$IMAGE_AGENT" "$baked_version" "$latest" 2>/dev/null >/dev/tty; then
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "$reply" in
            [yY]*)
                # shellcheck disable=SC2034  # REBUILD is read by build_images (functions/environment.sh)
                REBUILD=1
                ;;
        esac
    fi
    return 0
}

# build_images: builds the agent image on first use, or unconditionally
# when REBUILD=1 (set by --rebuild; see functions/argv.sh). Requires
# backend_image_ref (functions/apptainer.sh) to have set the image.
build_images() {
    if [[ "$REBUILD" -eq 1 ]] || ! backend_image_present; then
        backend_image_remove
        generate_dockerfile
        backend_build_image "$SANDBOX_DIR/agent" \
            "USERNAME=${USER:-$(id -un)}" \
            "UID=$(id -u)" \
            "GID=$(id -g)" \
            "AGENT=${IMAGE_AGENT:-$AGENT}"
        log_info "agent image: $SANDBOX_IMAGE (built)"
    else
        log_info "agent image: $SANDBOX_IMAGE (reused)"
    fi
}
