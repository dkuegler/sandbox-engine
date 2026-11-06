#!/bin/bash
# argv parsing: usage(), --environment KEY=VALUE handling, and the main
# option loop. Populates PROJECT_DIR, AGENT, ARGS, CLI_ENV_*, CLI_BINDS,
# WORKTREE_BRANCH, WORKTREE_START_POINT.

usage() {
    echo "Usage: $0 [--project-dir DIR] [--worktree BRANCH [--start-point COMMIT]] [--commit-model MODEL] [--environment KEY=VALUE ...] [--bind SRC[:DST[:OPTS]]] [--allow-external-binds] [--allow-external-gitdir] [--ignore-warnings] [-v|--verbose|-vv] [--rebuild] [--no-update-check] <claude|opencode|omp|script> [agent-args...]" >&2
    exit 1
}

# print_help: dumps sandbox.sh's own top-of-file comment block (between the
# "# --- START OF HELPTEXT ---" and "# --- END OF HELPTEXT ---" markers) to
# stdout with the "#"/"# " comment markers stripped, so the header
# documentation IS the --help text rather than a second copy to keep in sync.
print_help() {
    sed -n '/^# --- START OF HELPTEXT ---$/,/^# --- END OF HELPTEXT ---$/p' "$SCRIPT_DIR/sandbox.sh" \
        | sed '1d;$d' \
        | sed -E 's/^#( )?//'
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
    # shellcheck disable=SC2034  # CLI_ENV_IMAGE is read by resolve_environment (functions/environment.sh) via ${CLI_ENV_IMAGE:-$ENV_IMAGE}
    CLI_ENV_IMAGE=""
    # shellcheck disable=SC2034  # CLI_ENV_DOCKERFILE: same as above
    CLI_ENV_DOCKERFILE=""
    # shellcheck disable=SC2034  # CLI_ENV_PRESET: same as above
    CLI_ENV_PRESET=""
    # shellcheck disable=SC2034  # CLI_ENV_PYTHON_VERSION: same as above
    CLI_ENV_PYTHON_VERSION=""
    CLI_BINDS=()
    ALLOW_EXTERNAL_BINDS=0
    ALLOW_EXTERNAL_GITDIR=0
    # Explicit opt-in to start a run that warned, when there is no
    # terminal to confirm on. Same shape as the two flags above: stated on
    # the command line, never inferred from the environment.
    IGNORE_WARNINGS=0
    VERBOSE=0
    REBUILD=0
    NO_UPDATE_CHECK=0
    # Empty means "no worktree mode"; any value is the branch suffix the
    # caller asked for, used verbatim (functions/worktree.sh never invents
    # a branch name). Validated there, not here.
    WORKTREE_BRANCH=""
    # git's <start-point> for a NEW agent/<branch>: empty means HEAD, as in
    # git itself. Only meaningful with --worktree; resolved and validated
    # in functions/worktree.sh. WORKTREE_START_POINT_SET tells an explicit
    # empty value (refused) apart from the flag being absent.
    WORKTREE_START_POINT=""
    WORKTREE_START_POINT_SET=0
    # Explicit override for the model that writes a commit message when the
    # agent left its own message file empty (functions/commit-message.sh).
    # Empty means "let the agent resolve it": omp's own "commit" model
    # role, claude's built-in "haiku" alias, opencode's configured
    # small_model. Never inherits the coding run's --model -- that model is
    # chosen for writing code, not for summarising a diff.
    COMMIT_MODEL=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir)
                [[ $# -ge 2 ]] || usage
                PROJECT_DIR="$2"
                shift 2
                ;;
            --project-dir=*)
                # shellcheck disable=SC2034  # PROJECT_DIR is read throughout sandbox.sh and functions/*.sh after parse_argv returns
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
                # shellcheck disable=SC2034  # ALLOW_EXTERNAL_BINDS is read by functions/binds.sh's confirm-or-refuse check
                ALLOW_EXTERNAL_BINDS=1
                shift
                ;;
            --allow-external-gitdir)
                # shellcheck disable=SC2034  # ALLOW_EXTERNAL_GITDIR is read by functions/git-mask.sh's external-gitdir check
                ALLOW_EXTERNAL_GITDIR=1
                shift
                ;;
            --ignore-warnings)
                # shellcheck disable=SC2034  # IGNORE_WARNINGS is read by confirm_warnings (functions/log.sh)
                IGNORE_WARNINGS=1
                shift
                ;;
            --worktree)
                [[ $# -ge 2 ]] || usage
                WORKTREE_BRANCH="$2"
                shift 2
                ;;
            --worktree=*)
                # shellcheck disable=SC2034  # WORKTREE_BRANCH is read by functions/worktree.sh and sandbox.sh after parse_argv returns
                WORKTREE_BRANCH="${1#--worktree=}"
                shift
                ;;
            --start-point)
                [[ $# -ge 2 ]] || usage
                WORKTREE_START_POINT="$2"
                WORKTREE_START_POINT_SET=1
                shift 2
                ;;
            --start-point=*)
                # shellcheck disable=SC2034  # WORKTREE_START_POINT is read by functions/worktree.sh after parse_argv returns
                WORKTREE_START_POINT="${1#--start-point=}"
                WORKTREE_START_POINT_SET=1
                shift
                ;;
            --commit-model)
                [[ $# -ge 2 ]] || usage
                COMMIT_MODEL="$2"
                shift 2
                ;;
            --commit-model=*)
                # shellcheck disable=SC2034  # COMMIT_MODEL is read by functions/commit-message.sh after parse_argv returns
                COMMIT_MODEL="${1#--commit-model=}"
                shift
                ;;
            -h|--help)
                # Position-scoped like -v/-vv: before the agent name this is
                # sandbox's own help; after it, it's the agent's own -h/--help
                # and must be forwarded untouched -- but flag on stderr that
                # what's about to print is the agent's help, not sandbox's,
                # since both share the same flag and a user could easily
                # mistake one for the other.
                if [[ -z "$AGENT" ]]; then
                    print_help
                    exit 0
                else
                    echo "Note: forwarding $1 to '$AGENT' -- this is $AGENT's own help, not sandbox.sh's. For sandbox.sh's own documentation, run: $0 --help (before the agent name)." >&2
                    ARGS+=("$1")
                fi
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
                # shellcheck disable=SC2034  # REBUILD is read by build_images (functions/environment.sh)
                REBUILD=1
                shift
                ;;
            --no-update-check)
                # shellcheck disable=SC2034  # NO_UPDATE_CHECK is read by check_agent_update (functions/environment.sh)
                NO_UPDATE_CHECK=1
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
    # Refused rather than ignored: a start point that silently does nothing
    # would run the agent on code the caller did not ask for.
    if [[ "$WORKTREE_START_POINT_SET" -eq 1 && -z "$WORKTREE_BRANCH" ]]; then
        echo "error: --start-point is only valid together with --worktree BRANCH" >&2
        exit 1
    fi
}
