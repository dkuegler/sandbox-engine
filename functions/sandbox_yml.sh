#!/bin/bash
# sandbox.yml parsing: top-level "environment:" block and "binds:" list.
# Populates ENV_IMAGE, ENV_DOCKERFILE, ENV_PRESET, ENV_PYTHON_VERSION,
# YML_BINDS. Requires SANDBOX_YML and PROJECT_DIR to be set by the caller.
#
# This file is also where the trust gate for sandbox.yml lives, because
# this is where the read happens. sandbox.yml is not ordinary project
# config: the HOST parses it before any container exists, and what it
# says decides which host paths the run mounts and which image it runs.
# No container mask can intercept a read that happens outside every
# container, so masking the file read-only inside the sandbox does
# nothing for this vector -- an agent that writes one configures the NEXT
# run's own containment. The gate below applies the git-known rule
# (config_path_state, functions/binds.sh) to the read itself: honoured
# only when the file is committed and clean, refused otherwise,
# unconditionally.

# sandbox_yml_refuse REASON...: the hard error. No prompt and no TTY
# branch, unlike the interactive confirmations elsewhere in this repo:
# those decide whether to widen an already-contained run, while this one
# decides whether the containment itself was authored by the human. The
# recovery is a commit, which is also exactly the act that makes the
# setting permanent and reviewable.
sandbox_yml_refuse() {
    local reason="$1"
    shift
    {
        echo
        echo "sandbox: refusing to start -- $reason."
        echo
        echo "  sandbox.yml is not ordinary project config. This host reads it"
        echo "  BEFORE any container exists, and it decides which host paths the"
        echo "  sandbox mounts and which image it runs -- so a copy this checkout"
        echo "  has not committed is a copy nothing has vouched for. Masking it"
        echo "  inside the container cannot help: the read happens outside."
        local extra
        for extra in "$@"; do
            echo "  $extra"
        done
        echo
        echo "  Commit it to accept it as this checkout's permanent setting:"
        echo "      git -C ${PROJECT_DIR} add sandbox.yml"
        echo "      git -C ${PROJECT_DIR} commit -m 'sandbox.yml: ...'"
        echo
        echo "  If you did not write it, an earlier sandboxed run may have."
        echo "  Read it before committing anything."
        echo
    } >&2
    exit 1
}

# require_trusted_sandbox_yml: the gate itself. Runs before a single key
# is parsed, so an untrusted file never reaches the parser at all.
require_trusted_sandbox_yml() {
    local rel

    # A symlink is refused before anything else, and is not a corner case:
    # git tracks the LINK, while this parser reads whatever it POINTS AT.
    # A committed, clean symlink to an untracked file would therefore pass
    # a tracked-and-clean check while the bytes that configure the run are
    # unreviewed and agent-writable. There is no legitimate reason for
    # this one file to be an indirection.
    if [[ -L "$SANDBOX_YML" ]]; then
        sandbox_yml_refuse "$SANDBOX_YML is a symlink" \
            "git would vouch for the link; this parser reads its target, which is" \
            "a different file and may not be committed at all."
    fi
    if [[ ! -f "$SANDBOX_YML" ]]; then
        sandbox_yml_refuse "$SANDBOX_YML is not a regular file" \
            "only a regular, committed file can configure this sandbox."
    fi

    rel="${SANDBOX_YML#"$PROJECT_DIR"/}"
    config_path_state "$PROJECT_DIR" "$rel"
    [[ "$CFG_PATH_STATE" == "committed" ]] && return 0
    if [[ "$CFG_PATH_STATE" == "uncommitted-dirty" ]]; then
        sandbox_yml_refuse "$SANDBOX_YML has uncommitted changes"
    fi
    sandbox_yml_refuse "$SANDBOX_YML is not committed"
}

parse_sandbox_yml() {
    ENV_IMAGE=""
    ENV_DOCKERFILE=""
    ENV_PRESET=""
    ENV_PYTHON_VERSION=""
    YML_BINDS=()

    [[ -e "$SANDBOX_YML" || -L "$SANDBOX_YML" ]] || return 0
    require_trusted_sandbox_yml

    local in_block=0 in_binds=0 line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^environment:[[:space:]]*(#.*)?$ ]]; then
            in_block=1
            continue
        fi
        # Optional top-level list (outside any block): additional binds.
        if [[ "$line" =~ ^binds:[[:space:]]*(#.*)?$ ]]; then
            in_binds=1
            continue
        fi
        if [[ $in_binds -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*[^[:space:]])[[:space:]]*(#.*)?$ ]]; then
                YML_BINDS+=("${BASH_REMATCH[1]}")
                continue
            elif [[ -n "$line" && ! "$line" =~ ^[[:space:]] ]]; then
                in_binds=0
            fi
        fi
        if [[ $in_block -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+([A-Za-z_]+):[[:space:]]*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                val="${val%%#*}"
                val="$(sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//" <<<"$val")"
                # shellcheck disable=SC2034  # ENV_IMAGE/ENV_DOCKERFILE/ENV_PRESET/ENV_PYTHON_VERSION are read by resolve_environment (functions/environment.sh) after parse_sandbox_yml returns
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
}
