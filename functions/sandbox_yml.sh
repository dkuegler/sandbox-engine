#!/bin/bash
# sandbox.yml parsing: top-level "environment:" block, "binds:" list and
# "patches:" key. Populates ENV_IMAGE, ENV_DOCKERFILE, ENV_PRESET,
# ENV_PYTHON_VERSION, YML_BINDS, YML_PATCHES. Requires SANDBOX_YML and
# PROJECT_DIR to be set by the caller.
#
# This file is also where the trust gate for sandbox.yml lives, because
# this is where the read happens. sandbox.yml is not ordinary project
# config: the HOST parses it before any container exists, and what it
# says decides which host paths the run mounts and which image it runs.
# No container mask can intercept a read that happens outside every
# container, so masking the file read-only inside the sandbox does
# nothing for this vector -- an agent that writes one configures the NEXT
# run's own containment. The gate below moves the same git-known rule the
# project mask uses onto the read itself: honoured only when the file is
# committed and clean, refused otherwise, unconditionally.

# sandbox_yml_effective FILE: FILE with whole-line comments and blank
# lines removed and trailing whitespace trimmed -- the part of the file
# that can actually change a run. Both the trust check and the impact
# report run on this, so re-flowing a comment can never trip the fence.
#
# Deliberately does NOT strip a trailing comment from a value line. The
# parser below treats "#" as a comment start anywhere in an environment:
# value but not in a binds: entry, so removing them here would either
# disagree with the parser or change what a bind entry means. The cost is
# that editing a trailing comment counts as a change and refuses; that
# errs toward refusing, which is the safe direction for this file.
sandbox_yml_effective() {
    sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^$/d' -- "$1"
}

# sandbox_yml_impact_of CONTEXT LINE: one plain sentence naming what an
# effective line would do to THIS run. CONTEXT is the top-level key the
# line sits under ("environment", "binds", or empty). An unrecognized
# line still produces a sentence rather than being skipped: the point of
# the report is that nothing in the file changes the run unnoticed.
sandbox_yml_impact_of() {
    local ctx="$1" line="$2" key val trimmed rest opts
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$ctx" in
        binds)
            case "$trimmed" in
                -*)
                    val="${trimmed#-}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    # The same comment stripping and SRC[:DST[:OPTS]] split
                    # resolve_extra_binds (functions/binds.sh) applies, so the
                    # mode named here is the mode that would be mounted: a
                    # trailing "# note" or an option list like "nosuid,rw"
                    # must not make a read-write bind read as read-only.
                    val="$(sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' <<<"$val")"
                    rest="${val#*:}"
                    opts=""
                    if [[ "$rest" != "$val" && "$rest" == *:* ]]; then
                        opts="${rest#*:}"
                    fi
                    if [[ ",$opts," == *,rw,* ]]; then
                        printf '%s' "mounts the host path \"${val%%:*}\" into every sandbox READ-WRITE"
                    else
                        printf '%s' "mounts the host path \"${val%%:*}\" into every sandbox read-only"
                    fi
                    return 0
                    ;;
            esac
            ;;
        environment)
            key="${trimmed%%:*}"
            val="${trimmed#*:}"
            val="${val#"${val%%[![:space:]]*}"}"
            case "$key" in
                image)
                    printf '%s' "runs the sandbox from the container image \"$val\""
                    return 0 ;;
                dockerfile)
                    printf '%s' "builds the sandbox image from the in-project Dockerfile \"$val\""
                    return 0 ;;
                preset)
                    printf '%s' "changes the sandbox base image to the \"$val\" preset"
                    return 0 ;;
                python_version)
                    printf '%s' "changes the sandbox Python version to \"$val\""
                    return 0 ;;
            esac
            ;;
    esac
    printf '%s' "changes sandbox configuration: $trimmed"
}

# sandbox_yml_report_impact HEAD_EFF WORK_EFF: name, in impact terms, every
# effective line the working copy has that the committed copy does not --
# and every one it has dropped. Set membership rather than a positional
# diff: the question is "what would this file do that the committed one
# does not", and moving a line changes nothing about that.
#
# Prints to stdout, for the caller to pass through sanitize_agent_display
# (functions/binds.sh): every line quoted here is from a file an earlier
# sandboxed run may have written, on its way to the human's terminal.
sandbox_yml_report_impact() {
    local head_eff="$1" work_eff="$2" line ctx=""
    declare -A committed_lines=() working_lines=()
    while IFS= read -r line; do committed_lines["$line"]=1; done <"$head_eff"
    while IFS= read -r line; do working_lines["$line"]=1; done <"$work_eff"
    while IFS= read -r line; do
        case "$line" in
            environment:*)  ctx="environment" ;;
            binds:*)        ctx="binds" ;;
            [![:space:]]*)  ctx="" ;;
        esac
        [[ -n "${committed_lines["$line"]+x}" ]] && continue
        # A bare block opener carries no setting of its own; the entries
        # under it are reported individually just below, and listing the
        # header too would read as a change that is not one.
        case "$line" in environment:|binds:) continue ;; esac
        printf '    - %s\n' "$(sandbox_yml_impact_of "$ctx" "$line")"
    done <"$work_eff"
    ctx=""
    while IFS= read -r line; do
        case "$line" in
            environment:*)  ctx="environment" ;;
            binds:*)        ctx="binds" ;;
            [![:space:]]*)  ctx="" ;;
        esac
        [[ -n "${working_lines["$line"]+x}" ]] && continue
        case "$line" in environment:|binds:) continue ;; esac
        printf '    - drops a committed setting that %s\n' \
            "$(sandbox_yml_impact_of "$ctx" "$line")"
    done <"$head_eff"
}

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
    local rel head_copy head_eff work_eff

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

    ensure_run_dir
    head_copy="$RUN_DIR/sandbox-yml-head"
    head_eff="$RUN_DIR/sandbox-yml-head.eff"
    work_eff="$RUN_DIR/sandbox-yml-work.eff"
    # The committed side is empty when there is nothing committed, which
    # makes an untracked file and a locally-rewritten one the same case
    # for the report below: every effective line is new.
    : >"$head_copy"
    if [[ "$CFG_PATH_STATE" == "uncommitted-dirty" ]]; then
        if ! git -C "$PROJECT_DIR" cat-file blob "HEAD:$rel" >"$head_copy" 2>/dev/null; then
            sandbox_yml_refuse "the committed version of $SANDBOX_YML cannot be read" \
                "its tracked state says it exists in HEAD, so this is a repository" \
                "problem, not a configuration one."
        fi
    fi
    sandbox_yml_effective "$head_copy" >"$head_eff"
    sandbox_yml_effective "$SANDBOX_YML" >"$work_eff"
    # Comments and blank lines are not configuration; a re-flowed comment
    # block must not stop a run.
    if cmp -s "$head_eff" "$work_eff"; then
        log_info "sandbox.yml: uncommitted changes are comments or blank lines only -- honoured"
        return 0
    fi
    {
        echo
        if [[ "$CFG_PATH_STATE" == "uncommitted-dirty" ]]; then
            echo "sandbox: refusing to start -- $SANDBOX_YML has uncommitted changes."
        else
            echo "sandbox: refusing to start -- $SANDBOX_YML is not committed."
        fi
        echo
        echo "  sandbox.yml is not ordinary project config. This host reads it"
        echo "  BEFORE any container exists, and it decides which host paths the"
        echo "  sandbox mounts and which image it runs -- so a copy this checkout"
        echo "  has not committed is a copy nothing has vouched for. Masking it"
        echo "  inside the container cannot help: the read happens outside."
        echo
        echo "  What the uncommitted version would do to this run:"
    } >&2
    sandbox_yml_report_impact "$head_eff" "$work_eff" | sanitize_agent_display >&2
    {
        echo
        echo "  Comment and blank-line changes are ignored by this check, so every"
        echo "  item above is real configuration."
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

parse_sandbox_yml() {
    ENV_IMAGE=""
    ENV_DOCKERFILE=""
    ENV_PRESET=""
    ENV_PYTHON_VERSION=""
    # shellcheck disable=SC2034  # YML_PATCHES is read by resolve_patch_dir (functions/agents.sh) after parse_sandbox_yml returns
    YML_PATCHES=""
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
        # Optional top-level scalar: where the agent may drop proposed
        # patches for paths it cannot write directly.
        if [[ "$line" =~ ^patches:[[:space:]]*(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            val="${val%%#*}"
            val="$(sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//" <<<"$val")"
            # shellcheck disable=SC2034  # read by resolve_patch_dir (functions/agents.sh) after parse_sandbox_yml returns
            YML_PATCHES="$val"
            in_binds=0
            in_block=0
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
