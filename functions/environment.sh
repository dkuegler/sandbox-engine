#!/bin/bash
# Execution-environment resolution (image/dockerfile/preset -> BASE_IMAGE/
# ENV_TAG/ENV_MODE) and Dockerfile generation from the template.
# Requires SANDBOX_DIR, PROJECT_DIR, AGENT and the ENV_*/CLI_ENV_* vars set
# by parse_argv/parse_sandbox_yml.

sanitize_tag() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# resolve_environment: merges CLI_ENV_* over ENV_* (sandbox.yml), then
# derives ENV_MODE (image|dockerfile|preset), BASE_IMAGE, CUSTOM_DOCKERFILE,
# and ENV_TAG (used in the built SIF's filename).
resolve_environment() {
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
        case "$ENV_PRESET" in
            uv) BASE_IMAGE="ghcr.io/astral-sh/uv:python${ENV_PYTHON_VERSION}-bookworm-slim" ;;
            python3.13) BASE_IMAGE="python:3.13-slim-bookworm" ;;
            python) BASE_IMAGE="python:${ENV_PYTHON_VERSION}-slim-bookworm" ;;
            *)
                echo "environment.preset '$ENV_PRESET' (from sandbox.yml/--environment): unknown, expected uv|python|python3.13" >&2
                exit 1
                ;;
        esac
        ENV_TAG="preset-${ENV_PRESET}"
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

    rm -f "$out"
    {
        printf '%s\n' "$head_part"
        printf '%s\n' "$body"
        printf '%s\n' "$tail_part"
    } | sed "s/FROM \$AGENT AS/FROM $AGENT AS/g" > "$out"
}

# build_images: builds sandbox/<agent>.<env-tag>.sif and sandbox/gitmcp.sif
# on first use. Requires SIF_IMAGE/GITMCP_SIF to be set.
#
# apptainer's "dockerfile:" bootstrap (an alias for "buildkit:", see
# internal/pkg/build/conveyorPacker.go) takes a build CONTEXT DIRECTORY,
# and the recipe filename inside it is fixed to "Dockerfile" unless a def
# file overrides it (conveyorPacker_buildkit.go: bk.context =
# Header["from"], bk.filename defaults to "Dockerfile"). So the spec must
# name a directory holding a file literally called Dockerfile.
build_images() {
    if [ ! -f "$SIF_IMAGE" ]; then
        generate_dockerfile
        apptainer build --fakeroot \
            --build-arg "USERNAME=${USER:-$(id -un)}" \
            --build-arg "UID=$(id -u)" \
            --build-arg "GID=$(id -g)" \
            --build-arg "AGENT=$AGENT" \
            "$SIF_IMAGE" "dockerfile:$SANDBOX_DIR/agent"
    fi

    if [ ! -f "$GITMCP_SIF" ]; then
        apptainer build --fakeroot \
            --build-arg "USERNAME=${USER:-$(id -un)}" \
            --build-arg "UID=$(id -u)" \
            --build-arg "GID=$(id -g)" \
            "$GITMCP_SIF" "dockerfile:$SANDBOX_DIR/gitmcp"
    fi
}
