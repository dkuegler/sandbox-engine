#!/bin/bash
# sandbox.yml parsing: top-level "environment:" block and "binds:" list.
# Populates ENV_IMAGE, ENV_DOCKERFILE, ENV_PRESET, ENV_PYTHON_VERSION,
# YML_BINDS. Requires SANDBOX_YML to be set by the caller.

parse_sandbox_yml() {
    ENV_IMAGE=""
    ENV_DOCKERFILE=""
    ENV_PRESET=""
    ENV_PYTHON_VERSION=""
    YML_BINDS=()

    [[ -f "$SANDBOX_YML" ]] || return 0

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
