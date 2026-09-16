#!/bin/bash
# argv parsing: usage(), --environment KEY=VALUE handling, and the main
# option loop. Populates PROJECT_DIR, AGENT, ARGS, CLI_ENV_*, CLI_BINDS.

usage() {
    echo "Usage: $0 [--project-dir DIR] [--environment KEY=VALUE ...] [--bind SRC[:DST[:OPTS]]] [--allow-external-binds] [--allow-external-gitdir] [-v|--verbose|-vv] [--rebuild] <claude|opencode|omp|script> [agent-args...]" >&2
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

# parse_argv "$@": pulls out --project-dir, --environment, --bind, and the
# agent name; forwards the rest into ARGS for the agent CLI itself.
parse_argv() {
    PROJECT_DIR="$(pwd)"
    AGENT=""
    ARGS=()
    CLI_ENV_IMAGE=""
    CLI_ENV_DOCKERFILE=""
    CLI_ENV_PRESET=""
    CLI_ENV_PYTHON_VERSION=""
    CLI_BINDS=()
    ALLOW_EXTERNAL_BINDS=0
    ALLOW_EXTERNAL_GITDIR=0
    VERBOSE=0
    REBUILD=0

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
            --bind)
                [[ $# -ge 2 ]] || usage
                CLI_BINDS+=("$2")
                shift 2
                ;;
            --bind=*)
                CLI_BINDS+=("${1#--bind=}")
                shift
                ;;
            --allow-external-binds)
                ALLOW_EXTERNAL_BINDS=1
                shift
                ;;
            --allow-external-gitdir)
                ALLOW_EXTERNAL_GITDIR=1
                shift
                ;;
            -v|--verbose)
                # Position-scoped: only sandbox verbosity before the agent
                # name is seen. `./sandbox.sh omp -v` is omp's own flag,
                # not ours -- see the "-v"/"-vv" note in sandbox.sh's header.
                if [[ -z "$AGENT" ]]; then
                    VERBOSE=$((VERBOSE + 1))
                else
                    ARGS+=("$1")
                fi
                shift
                ;;
            -vv)
                if [[ -z "$AGENT" ]]; then
                    VERBOSE=$((VERBOSE + 2))
                else
                    ARGS+=("$1")
                fi
                shift
                ;;
            --rebuild)
                REBUILD=1
                shift
                ;;
            claude|opencode|omp|script)
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
}
