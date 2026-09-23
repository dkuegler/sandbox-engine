#!/bin/bash
# Extra bind resolution: sandbox.yml "binds:" list + repeatable --bind
# flags, validated and expanded (relative paths against the project dir,
# "~/" against $HOME) into the BINDS array the sandbox backend consumes
# (functions/apptainer.sh).

# sanitize_agent_display: stdin -> stdout, minus the control bytes a
# terminal acts on rather than prints.
#
# The commit message and the diff body are
# agent-authored bytes on their way to the human's terminal, and a
# terminal executes what it is sent: "\e[2J\e[H" clears the screen and
# homes the cursor, so agent content can end by repainting the display
# with a short, innocent-looking summary and a counterfeit "[y/N]"
# prompt -- the human then approves a change they never saw. File content
# and the commit-message file are the two channels. Filenames are not
# one: git C-quotes every path holding a control or non-ASCII byte
# before printing it.
#
# `cat -v` would do this too and is deliberately not used: it renders
# every byte >= 0x80 as "M-" noise, which turns any UTF-8 diff into
# garbage. A byte-oriented tr (LC_ALL=C) cannot touch a multibyte
# sequence, because every one of its bytes is >= 0x80 and no range below
# reaches there. The ranges delete 000-010 and 013-037 plus 177 (DEL), so
# exactly 011 (tab) and 012 (newline) survive.
#
# 015 (CR) is deleted with the rest, which costs nothing and closes a
# real hole. A lone CR returns the cursor to column 0, so the remainder
# of the line overprints what was already drawn: a diff body of
# "+ os.system(...)\r+ # harmless comment" is displayed as the comment
# alone. Hiding one line is the whole attack -- it does not need to
# repaint the screen. Nothing is lost on ordinary content either, since
# this filters the DISPLAY, not the file: a CRLF line still ends at its
# LF.
sanitize_agent_display() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# resolve_extra_binds: extra binds default to READ-ONLY. A spec must say
# ":rw" to opt into read-write; ":ro" is accepted too, redundantly, for
# clarity. Read-write is something a project opts into per bind, since the
# common case never needs to write to a mounted path and read-write turns
# disclosure of a mounted dataset into destruction of it too.
resolve_extra_binds() {
    local spec src rest dst opts origin
    local n_yml=${#YML_BINDS[@]}
    local i=0
    for spec in ${YML_BINDS[@]+"${YML_BINDS[@]}"} ${CLI_BINDS[@]+"${CLI_BINDS[@]}"}; do
        # sandbox.yml travels with the project, so a bind it requests is
        # attacker-controlled for an untrusted checkout. We honour it (it
        # is the documented feature) but always report it, so mounting
        # something like ~/.ssh cannot happen silently.
        if [[ $i -lt $n_yml ]]; then origin="sandbox.yml"; else origin="--bind"; fi
        i=$((i + 1))
        # Strip a trailing "# comment" and surrounding blanks, then split
        # SRC[:DST[:OPTS]] on the first two colons (same comment convention
        # as the environment: block).
        spec="$(sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' <<<"$spec")"
        [[ -n "$spec" ]] || continue
        src="${spec%%:*}"
        rest="${spec#*:}"
        [[ "$src" = ~* ]] && src="${src/#\~/$HOME}"
        [[ "$src" = /* ]] || src="$PROJECT_DIR/$src"
        dst=""
        opts=""
        if [[ "$rest" != "$spec" ]]; then
            if [[ "$rest" == *:* ]]; then
                dst="${rest%%:*}"
                opts="${rest#*:}"
            else
                dst="$rest"
            fi
        fi
        if [[ ! -e "$src" ]]; then
            echo "bind source '$src' (from sandbox.yml binds:/--bind) does not exist" >&2
            exit 1
        fi

        # Resolve the ro/rw decision before the scope check, so the
        # confirmation prompt can state the mode it is actually asking about.
        local is_ro=1
        [[ ",$opts," == *,rw,* ]] && is_ro=0
        if [[ ",$opts," != *,rw,* && ",$opts," != *,ro,* ]]; then
            opts="${opts:+$opts,}ro"
        fi

        # Resolve first: the scope a mount actually gets is the resolved
        # path's scope, so the confirmation is asked about -- and asked
        # exactly once for -- the directory that is really mounted. A
        # spec that is textually inside the project but resolves outside
        # it (a symlink pointing out) is caught by the same single check,
        # because the resolved path IS what apptainer mounts; a spec that
        # is textually outside but resolves inside needs no prompt at
        # all, since mounting a path that resolves inside the project is
        # no different from mounting the project path itself.
        BIND_SCOPE_FORCE_RO=0
        src="$(readlink -f "$src")"
        bind_scope_check "$src" "$origin" "$is_ro"
        if [[ "$BIND_SCOPE_FORCE_RO" -eq 1 && "$is_ro" -eq 0 ]]; then
            opts="${opts/rw/ro}"
            is_ro=1
        fi

        if [[ -n "$dst" ]]; then
            dst="${dst/#\~/$HOME}"
            BINDS+=(-B "$src:$dst:$opts")
        else
            BINDS+=(-B "$src:$opts")
        fi
        echo "bind ($origin): $src${dst:+ -> $dst} [$opts]" >&2
        EXTRA_BIND_SRCS+=("$src")
        EXTRA_BIND_RO+=("$is_ro")
    done
}

# bind_scope_check PATH ORIGIN IS_RO: a bind source outside the project
# directory can expose anything on the host (~/.ssh, /etc), and sandbox.yml
# travels with an untrusted checkout, so it is attacker-controlled. Allowed
# only with --allow-external-binds, or after an interactive confirmation.
# PATH is the RESOLVED source (the caller resolves links first): it is the
# directory that is actually mounted, and one check on it covers both a
# spec that textually leaves the project and one that textually stays
# inside but resolves out through a symlink. Reports the path's size and
# file count so "mount it?" is an informed answer, not a blind y/N, and
# offers downgrading to read-only as a distinct reply -- sets
# BIND_SCOPE_FORCE_RO=1 for the caller to act on rather than mounting
# read-write just because that is what was asked for.
bind_scope_check() {
    local p="$1" origin="$2" is_ro="$3" reply mode size count
    [[ "$p" == "$PROJECT_DIR" || "$p" == "$PROJECT_DIR"/* ]] && return 0
    mode="read-write"
    [[ "$is_ro" -eq 1 ]] && mode="read-only"
    if [[ "$ALLOW_EXTERNAL_BINDS" -eq 1 ]]; then
        echo "warning: bind ($origin) '$p' is outside the project dir $PROJECT_DIR" >&2
        echo "  (allowed by --allow-external-binds, mounted $mode)" >&2
        return 0
    fi
    # -r alone is not a reliable predictor: /dev/tty exists and is
    # world-readable even with no controlling terminal (a detached/CI
    # process), where opening it fails with ENXIO. Folding the printfs
    # into the if's condition, not statements inside its body, is what
    # keeps that failure from tripping the caller's `set -e` -- a
    # command's exit status inside an if/&&/|| condition never does.
    if [[ -r /dev/tty ]]; then
        size="$(du -sh "$p" 2>/dev/null | cut -f1)"
        count="$(find "$p" 2>/dev/null | wc -l | tr -d '[:space:]')"
        if printf 'bind (%s) %s is outside the project dir %s (resolved), mode=%s.\n' \
                "$origin" "$p" "$PROJECT_DIR" "$mode" 2>/dev/null >/dev/tty \
            && printf '%s, %s path(s) under it.\n' "${size:-size unknown}" "${count:-?}" \
                2>/dev/null >/dev/tty \
            && printf 'Mount it %s into the sandbox? [y/r/N] (r=read-only) ' "$mode" \
                2>/dev/null >/dev/tty; then
            read -r reply </dev/tty 2>/dev/null || reply=""
            case "$reply" in
                [oOrR]*)
                    BIND_SCOPE_FORCE_RO=1
                    return 0
                    ;;
                [yY]*)
                    return 0
                    ;;
            esac
        fi
    fi
    echo "refusing bind ($origin) '$p': outside the project dir $PROJECT_DIR. Pass" >&2
    echo "  --allow-external-binds to allow it." >&2
    exit 1
}

# bind_ro PATH [KIND]: bind PATH read-only over itself, so a read-write
# bind of an ancestor cannot be written through at PATH. Records the path
# in RO_MASKED for --verbose reporting.
#
# When PATH does not exist on the host, an empty RUN_DIR placeholder is
# bound read-only over it instead of skipping the mask (KIND selects
# "file" (default) or "dir"). This closes a real gap: startup only
# pre-creates the top-level per-agent directories (~/.claude,
# ~/.config/opencode, ~/.omp, ...), not the specific children this
# function masks (settings.json, plugins/, ...). For every one of those
# a given host happens not to have yet, the parent is bound read-write
# and the specific child was previously left unbound entirely -- so the
# agent could create it inside the container, and it would exist,
# unmasked, on the host the moment the container exits, ready to execute
# on the human's next bare-host run of that agent. The RUN_DIR-source
# pattern (bind something ensure_run_dir() creates over a destination
# that may not exist on the host) is the same one
# bind_augmented_instructions() already relies on. No write ever touches
# the real (missing) path or its parent on the host.
bind_ro() {
    local p="$1" kind="${2:-file}" placeholder
    if [[ ! -e "$p" ]]; then
        ensure_run_dir
        placeholder="$RUN_DIR/ro-mask-$(printf '%s' "$p" | sha256sum | cut -c1-16)"
        if [[ "$kind" == dir ]]; then
            mkdir -p "$placeholder"
        else
            : > "$placeholder"
        fi
        BINDS+=(-B "$placeholder:$p:ro")
        RO_MASKED+=("$p (absent on host; masked empty)")
        return 0
    fi
    BINDS+=(-B "$p:$p:ro")
    RO_MASKED+=("$p")
}

# PROJECT_CONFIG_MASK_FILE: the table of known executable-config surfaces
# (its own header explains the format and the perimeter it draws). Located
# relative to this file, never through the environment or the project's
# working directory: the table decides what the sandbox masks, so where
# it is read from is not something a caller gets to choose.
PROJECT_CONFIG_MASK_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config/mask.yml"

# PROJECT_CONFIG_MASK_KIND / PROJECT_CONFIG_MASK_PATH: the "project:"
# entries, index-aligned, filled once by project_config_mask_load().
PROJECT_CONFIG_MASK_KIND=()
PROJECT_CONFIG_MASK_PATH=()

# project_config_mask_refuse DETAIL: the table cannot be trusted as a
# perimeter, so the run does not start. A mask that silently lost rows to
# a typo would look exactly like a mask that works.
project_config_mask_refuse() {
    printf '%s\n  %s\n' "sandbox: refusing to start -- the config mask table is unusable:" \
        "$1" >&2
    exit 1
}

# project_config_mask_load: read the "project:" list of
# PROJECT_CONFIG_MASK_FILE into the two arrays above, once per run.
#
# The file is YAML, but only the strict subset its header documents is
# accepted, parsed line by line without a YAML library (none can be
# assumed on the host). Every line is a comment, blank, the "project:"
# key, or an entry "  - file: PATH" / "  - dir: PATH" with PATH made only
# of [A-Za-z0-9._/-] -- a plain YAML string that no quoting, anchor, tag
# or flow syntax can reinterpret. Anything else refuses, as does a
# missing, unreadable or empty table, and a PATH that is absolute or has
# an empty, "." or ".." component: each of those would bind something
# other than the checkout path the row names. Callers iterate the arrays
# rather than a "< <(...)" stream, so a refusal here always reaches the
# real shell.
project_config_mask_load() {
    local line n=0 kind rel in_project=0
    [[ ${#PROJECT_CONFIG_MASK_PATH[@]} -gt 0 ]] && return 0
    if [[ ! -f "$PROJECT_CONFIG_MASK_FILE" || ! -r "$PROJECT_CONFIG_MASK_FILE" ]]; then
        project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE is missing or unreadable"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ "$line" == "project:" ]]; then
            # A second "project:" key is a duplicate mapping key: YAML
            # parsers disagree on which one wins, so there is no single
            # table to honour.
            if [[ "$in_project" -eq 1 ]]; then
                project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE:$n: \"project:\" appears more than once"
            fi
            in_project=1
            continue
        fi
        if [[ "$in_project" -ne 1 || ! "$line" =~ ^\ \ -\ (file|dir):\ ([A-Za-z0-9._/-]+)$ ]]; then
            project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE:$n: not a \"  - file|dir: PATH\" entry under \"project:\""
        fi
        kind="${BASH_REMATCH[1]}"
        rel="${BASH_REMATCH[2]}"
        case "/$rel/" in
            *//* | */./* | */../*)
                project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE:$n: $rel is not a plain checkout-relative path"
                ;;
        esac
        PROJECT_CONFIG_MASK_KIND+=("$kind")
        PROJECT_CONFIG_MASK_PATH+=("$rel")
    done <"$PROJECT_CONFIG_MASK_FILE"
    if [[ ${#PROJECT_CONFIG_MASK_PATH[@]} -eq 0 ]]; then
        project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE has no entries"
    fi
}

# CFG_PATH_STATE: set by config_path_state() below. A global rather than
# an echoed result on purpose -- see that function's own note.
declare CFG_PATH_STATE=""

# config_path_state DIR REL: the ONE predicate behind the git-known
# convention -- "visible <=> tracked in DIR's HEAD tree AND identical to
# it in the working tree" -- resolved for a single path. Sets
# CFG_PATH_STATE to exactly one of:
#
#   committed          in HEAD, and the working tree matches it
#   uncommitted-dirty  in HEAD, but the working tree has drifted
#   uncommitted        not in HEAD at all (untracked, no commit yet, or
#                      not a git checkout)
#
# The host-side sandbox.yml trust gate (parse_sandbox_yml,
# functions/sandbox_yml.sh) decides from it whether to honour that file
# at all. Every other "is this committed" question belongs here too, not
# in a second implementation: two would be two things to keep in
# agreement, and the one that drifted would fail open.
#
# The answer is returned in a GLOBAL, never echoed for the caller to read
# through "$(...)". A command substitution is a subshell, and the `exit 1`
# refusals below would die inside it while the caller saw an empty string
# and carried on -- an untrusted sandbox.yml honoured because the check
# could not be completed. The refusal has to be able to reach the real
# shell.
#
# Not being a repository, and having no commit yet, are not failures but
# states this degrades on: nothing is committed anywhere, so every path
# is uncommitted -- the fail-closed reading. A git read that fails for
# any OTHER reason refuses the run instead of guessing, because a state
# computed from a partial answer cannot be told apart from a real one.
config_path_state() {
    local dir="$1" rel="$2" listing rc=0
    CFG_PATH_STATE=""
    ensure_run_dir
    mkdir -p -- "$RUN_DIR/cfgmask-snap"
    listing="$RUN_DIR/cfgmask-snap/tracked-under"
    if ! git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
        CFG_PATH_STATE="uncommitted"
        return 0
    fi
    # Captured to a file before it is inspected: a failing read must never
    # be indistinguishable from "HEAD does not have this path".
    if ! git -C "$dir" ls-tree -r HEAD --name-only -z -- "$rel" >"$listing" 2>/dev/null; then
        printf '%s%s\n' "sandbox: cannot resolve the tracked state of $rel in $dir -- " \
            "refusing to guess" >&2
        exit 1
    fi
    if [[ ! -s "$listing" ]]; then
        CFG_PATH_STATE="uncommitted"
        return 0
    fi
    git -C "$dir" diff HEAD --quiet -- "$rel" 2>/dev/null || rc=$?
    # shellcheck disable=SC2034  # read by require_trusted_sandbox_yml (functions/sandbox_yml.sh), sourced before this file
    case "$rc" in
        0) CFG_PATH_STATE="committed" ;;
        1) CFG_PATH_STATE="uncommitted-dirty" ;;
        *)
            printf '%s%s\n' "sandbox: cannot compare $rel in $dir against HEAD " \
                "(git exited $rc) -- refusing to guess" >&2
            exit 1
            ;;
    esac
}

# mask_project_agent_config DIR: bind-mask, read-only, every
# table path (project_config_mask_load) under the checkout DIR -- MCP server
# command lines, plugin/hook code, permission overrides, and sandbox.yml
# -- the same class of surface already masked under each agent's global
# config dir in configure_agent(), but for the project itself, which is
# otherwise bound plain read-write so the agent can do its actual job.
#
# Unconditional, independent of $AGENT: omp's own MCP discovery reads
# other tools' project config in addition to its own, so a file written
# by *any* agent this run, or left over from a prior run, is a live
# MCP-server-launch vector for omp specifically, and a hook/plugin-
# execution vector for its native tool on the human's next bare-host run
# of whichever CLI that is. Masking every table path regardless of which
# agent this run is using is what actually closes that.
mask_project_agent_config() {
    local dir="$1" i
    project_config_mask_load
    for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
        bind_ro "$dir/${PROJECT_CONFIG_MASK_PATH[i]}" "${PROJECT_CONFIG_MASK_KIND[i]}"
    done
}

# log_resolved_binds: one summary line per run naming every bind actually
# handed to the backend -- source, destination (if any), and ro/rw -- so an
# after-the-fact question about what a run could see has an answer.
# BINDS entries are "-B" markers interleaved with "SRC[:DST[:OPTS]]"
# strings; only the latter are real binds.
log_resolved_binds() {
    local entry
    echo "resolved binds for this run:" >&2
    for entry in "${BINDS[@]}"; do
        [[ "$entry" == "-B" ]] && continue
        echo "  $entry" >&2
    done
}
