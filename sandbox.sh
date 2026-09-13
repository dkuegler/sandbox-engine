#!/bin/bash
#
# Unified sandbox entrypoint. Usage:
#   ./sandbox.sh [--project-dir DIR] [--environment KEY=VALUE ...] <claude|opencode|omp> [agent-args...]
#
# Builds sandbox/<agent>.<env-tag>.sif on first use (from sandbox/Dockerfile,
# selecting the agent via --build-arg AGENT=<agent> and the base image per the
# project's execution environment, see below) and then execs the agent inside
# it, with the project directory bind-mounted and set as cwd.
#
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
#       image: <ref>            # use this image reference verbatim
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
#   get it for free — sandbox/Dockerfile.template no longer installs uv on
#   top of an arbitrary base (apptainer's Dockerfile bootstrap has no clean
#   way to skip a layer conditionally). A project that needs both uv and a
#   non-uv base (e.g. TeX Live) should use "dockerfile:" pointing at a small
#   Dockerfile that layers uv onto that base via
#   `COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/` (see
#   sandbox/texlive-uv.Dockerfile for a worked example). uv itself discovers
#   pyproject.toml/.venv relative to cwd, so `uv run ...` transparently uses
#   the project's own `.venv` once the project directory is bind-mounted.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$SCRIPT_DIR/sandbox"

usage() {
    echo "Usage: $0 [--project-dir DIR] [--environment KEY=VALUE ...] <claude|opencode|omp> [agent-args...]" >&2
    exit 1
}

set_cli_env() {
    local kv="$1" key val
    if [[ "$kv" != *=* ]]; then
        echo "--environment expects KEY=VALUE (got '$kv')" >&2
        exit 1
    fi
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
        image) CLI_ENV_IMAGE="$val" ;;
        dockerfile) CLI_ENV_DOCKERFILE="$val" ;;
        preset) CLI_ENV_PRESET="$val" ;;
        python_version) CLI_ENV_PYTHON_VERSION="$val" ;;
        *)
            echo "--environment: unknown key '$key' (expected image|dockerfile|preset|python_version)" >&2
            exit 1
            ;;
    esac
}

# --- argv: pull out --project-dir, --environment, and the agent name, -----
# --- forward the rest ------------------------------------------------------

PROJECT_DIR="$(pwd)"
AGENT=""
ARGS=()
CLI_ENV_IMAGE=""
CLI_ENV_DOCKERFILE=""
CLI_ENV_PRESET=""
CLI_ENV_PYTHON_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            [[ $# -ge 2 ]] || usage
            PROJECT_DIR="$2"
            shift 2
            ;;
        --project-dir=*)
            PROJECT_DIR="${1#--project-dir=}"
            shift
            ;;
        --environment)
            [[ $# -ge 2 ]] || usage
            set_cli_env "$2"
            shift 2
            ;;
        --environment=*)
            set_cli_env "${1#--environment=}"
            shift
            ;;
        claude|opencode|omp)
            if [[ -z "$AGENT" ]]; then
                AGENT="$1"
            else
                ARGS+=("$1")
            fi
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

[[ -n "$AGENT" ]] || usage

[[ -d "$PROJECT_DIR" ]] || { echo "Project dir not found: $PROJECT_DIR" >&2; exit 1; }
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# --- resolve the execution environment from <project-dir>/sandbox.yml, ----
# --- overridden per-key by --environment flags -----------------------------

SANDBOX_YML="$PROJECT_DIR/sandbox.yml"
ENV_IMAGE=""
ENV_DOCKERFILE=""
ENV_PRESET=""
ENV_PYTHON_VERSION=""

if [[ -f "$SANDBOX_YML" ]]; then
    in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^environment:[[:space:]]*(#.*)?$ ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+([A-Za-z_]+):[[:space:]]*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                val="${val%%#*}"
                val="$(sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//" <<<"$val")"
                case "$key" in
                    image) ENV_IMAGE="$val" ;;
                    dockerfile) ENV_DOCKERFILE="$val" ;;
                    preset) ENV_PRESET="$val" ;;
                    python_version) ENV_PYTHON_VERSION="$val" ;;
                esac
                continue
            elif [[ -n "$line" && ! "$line" =~ ^[[:space:]] ]]; then
                in_block=0
            fi
        fi
    done < "$SANDBOX_YML"
fi

ENV_IMAGE="${CLI_ENV_IMAGE:-$ENV_IMAGE}"
ENV_DOCKERFILE="${CLI_ENV_DOCKERFILE:-$ENV_DOCKERFILE}"
ENV_PRESET="${CLI_ENV_PRESET:-$ENV_PRESET}"
ENV_PYTHON_VERSION="${CLI_ENV_PYTHON_VERSION:-$ENV_PYTHON_VERSION}"

ENV_PYTHON_VERSION="${ENV_PYTHON_VERSION:-3.13}"

sanitize_tag() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

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

SIF_IMAGE="$SANDBOX_DIR/$AGENT.$ENV_TAG.sif"

# --- generate sandbox/Dockerfile from the template for this environment ---
#
# apptainer does not support ARG in FROM strings in Dockerfiles, so the
# template's "$BASE_IMAGE"/"$AGENT" placeholders are substituted textually
# rather than passed as --build-arg.

generate_dockerfile() {
    local template="$SANDBOX_DIR/Dockerfile.template"
    local out="$SANDBOX_DIR/Dockerfile"
    local placeholder_line head_part tail_part body

    placeholder_line="$(grep -n '^FROM \$BASE_IMAGE AS base$' "$template" | head -n1 | cut -d: -f1)"
    if [[ -z "$placeholder_line" ]]; then
        echo "sandbox/Dockerfile.template: missing 'FROM \$BASE_IMAGE AS base' placeholder" >&2
        exit 1
    fi
    head_part="$(sed -n "1,$((placeholder_line - 1))p" "$template")"
    tail_part="$(sed -n "$((placeholder_line + 1)),\$p" "$template")"

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

if [ ! -f "$SIF_IMAGE" ]; then
    generate_dockerfile
    apptainer build --fakeroot \
        --build-arg "USERNAME=${USER}" \
        --build-arg "UID=$(id -u)" \
        --build-arg "GID=$(id -g)" \
        --build-arg "AGENT=$AGENT" \
        "$SIF_IMAGE" "dockerfile:$SANDBOX_DIR"
fi

# Extra project-specific binds (e.g. a shared texmf tree, extra data
# volumes) can be appended to BINDS here before the apptainer exec call
# below.
BINDS=(
    -B "$PROJECT_DIR"
)

case "$AGENT" in
    claude)
        mkdir -p "$HOME/.claude" "$HOME/.config/claude"
        touch "$HOME/.claude.json"
        BINDS+=(
            -B "$HOME/.claude"
            -B "$HOME/.config/claude"
            -B "$HOME/.claude.json"
        )
        RUN_CMD=(claude "${ARGS[@]}")
        ;;
    opencode)
        mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
            "$HOME/.local/state/opencode" "$HOME/.opencode"
        BINDS+=(
            -B "$HOME/.config/opencode"
            -B "$HOME/.local/share/opencode"
            -B "$HOME/.local/state/opencode"
            -B "$HOME/.opencode"
        )
        RUN_CMD=(opencode "${ARGS[@]}")
        ;;
    omp)
        # oh-my-pi (can1357/oh-my-pi) keeps all config/auth/state under
        # ~/.omp (e.g. ~/.omp/agent/config.yml, models.yml). Project-level
        # session files live under .omp/ in the repo, already covered by
        # the project-dir bind above.
        # Source: https://github.com/can1357/oh-my-pi/blob/main/README.md
        # and https://deepwiki.com/can1357/oh-my-pi/13-configuration-reference
        mkdir -p "$HOME/.omp"
        BINDS+=(
            -B "$HOME/.omp"
        )
        RUN_CMD=(omp "${ARGS[@]}")
        ;;
esac

apptainer exec --containall --no-home \
    --cwd "$PROJECT_DIR" \
    "${BINDS[@]}" \
    --home "$HOME" \
    --nv --writable-tmpfs \
    "$SIF_IMAGE" \
    "${RUN_CMD[@]}"
