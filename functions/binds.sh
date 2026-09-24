#!/bin/bash
# Extra bind resolution: sandbox.yml "binds:" list + repeatable --bind
# flags, validated and expanded (relative paths against the project dir,
# "~/" against $HOME) into the BINDS array the sandbox backend consumes
# (functions/apptainer.sh).

# sanitize_agent_display: stdin -> stdout, minus the control bytes a
# terminal acts on rather than prints.
#
# The commit message, the diff body and the post-run reports are
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

# config_display_type PATH: empty output when PATH is a plain regular file
# that is safe to read; otherwise a short description of what it actually
# is. Every place that shows the human an AGENT-CHOSEN path has to ask
# this first, because the agent picks the file's TYPE as well as its name
# and both of the obvious reads go wrong on a type nobody checked:
#
#   - a fifo blocks the reader forever on open(2), so the review the human
#     is in the middle of never reaches its own prompt;
#   - a symlink is displayed as its TARGET's content while git stores the
#     LINK, so the bytes reviewed and the bytes committed are different
#     files -- and the target can be any host file the user can read.
#
# -L is tested before -f deliberately: -f follows the link and would call
# a symlink-to-a-regular-file "a regular file", which is the exact case
# that has to be caught. A link's target string is agent-chosen too, and
# is printed, so it goes through sanitize_agent_display like any other
# agent-authored bytes on their way to the terminal.
config_display_type() {
    local p="$1" target
    if [[ -L "$p" ]]; then
        target="$(readlink -- "$p" 2>/dev/null | sanitize_agent_display)"
        printf '%s' "symlink -> ${target:-<unreadable>}"
        return 0
    fi
    if [[ -p "$p" ]]; then printf '%s' "named pipe (fifo)"; return 0; fi
    if [[ -S "$p" ]]; then printf '%s' "socket"; return 0; fi
    if [[ -b "$p" || -c "$p" ]]; then printf '%s' "device node"; return 0; fi
    if [[ -d "$p" ]]; then printf '%s' "directory"; return 0; fi
    if [[ ! -f "$p" ]]; then printf '%s' "not a regular file"; return 0; fi
    printf ''
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
# in RO_MASKED for --verbose reporting. Used for the agents' GLOBAL config
# surfaces (configure_agent); the PROJECT surface routes through
# mask_project_agent_config instead.
#
# An ABSENT path is not bound at all. Under --containall with --no-mount
# home (functions/apptainer.sh), $HOME exists inside the container only
# where a bind scaffolds it, so a path nothing binds cannot reach the
# host: the session cannot create it there. A bind over it would instead
# make apptainer materialise the missing destination, and under a
# read-write parent that happens on the REAL filesystem.
#
# The one exception is exactly that: an absent PATH under a read-write
# bind this run already resolved (bind_rw_covers). Left unbound it would
# be creatable, on the host, through the parent -- e.g. opencode's bin/
# inside its writable state directory, which the host opencode executes
# from. So it is created empty on the host (KIND: "file", the default, or
# "dir") and then bound read-only. A dangling symlink there cannot be
# replaced safely by either route, so the run refuses.
bind_ro() {
    local p="$1" kind="${2:-file}"
    if [[ ! -e "$p" ]]; then
        bind_rw_covers "$p" || return 0
        if [[ -L "$p" ]]; then
            echo "sandbox: refusing to start -- $p is a dangling symlink inside a read-write" >&2
            echo "  bind, so the session could replace it. Remove it or point it at a real path." >&2
            exit 1
        fi
        if [[ "$kind" == dir ]]; then
            mkdir -p -- "$p" || return 1
        else
            mkdir -p -- "${p%/*}" && : >"$p" || return 1
        fi
    fi
    BINDS+=(-B "$p:$p:ro")
    RO_MASKED+=("$p")
}

# bind_rw_covers PATH: true when a read-WRITE bind this run already
# resolved contains PATH -- the condition under which apptainer would
# have to materialise a missing PATH on the REAL host filesystem, and
# under which the session itself could create it there. A bind whose
# source is this run's scratch directory does not count: anything
# materialised in there lands in $RUN_DIR and goes with it.
bind_rw_covers() {
    local p="$1" entry src dst opts
    for entry in ${BINDS[@]+"${BINDS[@]}"}; do
        [[ "$entry" == "-B" ]] && continue
        src="${entry%%:*}"
        dst="$src"
        opts=""
        case "$entry" in
            *:*:*) dst="${entry#*:}"; dst="${dst%%:*}"; opts="${entry##*:}" ;;
            *:*)   dst="${entry#*:}" ;;
        esac
        [[ "$opts" == "ro" ]] && continue
        if [[ -n "${RUN_DIR:-}" && ( "$src" == "$RUN_DIR" || "$src" == "$RUN_DIR"/* ) ]]; then
            continue
        fi
        [[ "$p" == "$dst"/* ]] && return 0
    done
    return 1
}

# bind_state_rw PATH KIND [INITIAL]: bind PATH read-WRITE, creating it on
# the host first if it is missing (KIND: "file" or "dir"). A file is
# created holding INITIAL (default: empty); a JSON state file passes "{}",
# since an empty file is not JSON and the next unsandboxed CLI would have
# to parse it. For the paths an agent genuinely has to write -- session
# databases, caches, credentials it refreshes itself -- named one at a
# time.
#
# Creating the source host-side is required, not incidental: apptainer
# refuses a bind whose SOURCE does not exist. It is also the point. Each
# writable path is a line of its own rather than a consequence of binding
# a whole tree, and the failure direction inverts with it -- forgetting a
# path here costs a lost cache the user notices at once, where forgetting
# one in a subtract-from-the-parent list is a silently writable config
# file.
bind_state_rw() {
    local p="$1" kind="${2:-dir}" initial="${3:-}"
    if [[ ! -e "$p" && ! -L "$p" ]]; then
        if [[ "$kind" == dir ]]; then
            mkdir -p -- "$p" || return 1
        else
            mkdir -p -- "${p%/*}" || return 1
            printf '%s' "$initial" >"$p" || return 1
        fi
    fi
    BINDS+=(-B "$p")
}

# bind_never CREDENTIAL REASON: a path deliberately NOT passed into the
# container, announced when it exists so its absence in-session is a
# stated decision rather than a silent hole the user debugs later.
# Credentials are a different class from configuration: a .env holds live
# API keys, and mounting one read-only still makes every key in it
# readable by the sandboxed agent and echoable into a transcript. Keys
# reach an agent only through the auditable require_host_env path.
bind_never() {
    local p="$1" reason="$2"
    [[ -e "$p" || -L "$p" ]] || return 0
    log_warn "not passed through to the agent: $p ($reason)"
}

# PROJECT_CONFIG_MASK_FILE: the table of known executable-config surfaces
# (its own header explains the format and the perimeter it draws). Located
# relative to this file, never through the environment or the project's
# working directory: the table decides what the sandbox masks, so where
# it is read from is not something a caller gets to choose.
PROJECT_CONFIG_MASK_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config/mask.toml"

# PROJECT_CONFIG_MASK_KIND / PROJECT_CONFIG_MASK_PATH: the "[project.*]"
# entries, index-aligned, kind "file" or "dir"; PROJECT_CONFIG_MASK_ANYWHERE:
# the "[anywhere]" basenames. Filled once by project_config_mask_load().
PROJECT_CONFIG_MASK_KIND=()
PROJECT_CONFIG_MASK_PATH=()
PROJECT_CONFIG_MASK_ANYWHERE=()

# project_config_mask_refuse DETAIL: the table cannot be trusted as a
# perimeter, so the run does not start. A mask that silently lost rows to
# a typo would look exactly like a mask that works.
project_config_mask_refuse() {
    printf '%s\n  %s\n' "sandbox: refusing to start -- the config mask table is unusable:" \
        "$1" >&2
    exit 1
}

# project_config_mask_load: read PROJECT_CONFIG_MASK_FILE into the arrays
# above, once per run.
#
# The file is TOML, but only the strict subset its header documents is
# accepted, parsed line by line without a TOML library (none can be
# assumed on the host). Every line is a comment, blank, or one of:
#
#   "[project.GROUP]"   GROUP made only of [a-z0-9-], each table once;
#   "[anywhere]"        once;
#   "files = [" / "dirs = ["   inside a "[project.*]" table, each once;
#   "names = ["         inside "[anywhere]", once;
#   "    \"VALUE\","    inside an open array: a "files"/"dirs" VALUE made
#                       only of [A-Za-z0-9._/-], relative, with no empty,
#                       "." or ".." component -- anything else would bind
#                       something other than the checkout path the row
#                       names; a "names" VALUE made only of [A-Za-z0-9._-]
#                       and neither "." nor "..";
#   "]"                 closing the open array.
#
# Both character sets make every value a TOML basic string that needs no
# escape, so the lines read the same to tomllib. Anything else refuses, as
# does a missing or unreadable file, a table or array with no entries, a
# path or name listed twice, and no "[anywhere]" at all: an empty
# "anywhere" would silently switch off the tree-wide half of the mask.
# Callers iterate the arrays rather than a "< <(...)" stream, so a refusal
# here always reaches the real shell.
project_config_mask_load() {
    local line n=0 table="" key="" entries=0 tentries=0 val where
    declare -A seen_table=() seen_key=() seen_val=()
    [[ ${#PROJECT_CONFIG_MASK_PATH[@]} -gt 0 ]] && return 0
    if [[ ! -f "$PROJECT_CONFIG_MASK_FILE" || ! -r "$PROJECT_CONFIG_MASK_FILE" ]]; then
        project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE is missing or unreadable"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        where="$PROJECT_CONFIG_MASK_FILE:$n"
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ -n "$key" ]]; then
            if [[ "$line" == "]" ]]; then
                [[ "$entries" -gt 0 ]] || project_config_mask_refuse "$where: \"$key\" has no entries"
                key=""
                continue
            fi
            if [[ ! "$line" =~ ^\ \ \ \ \"([^\"]*)\",$ ]]; then
                project_config_mask_refuse "$where: not a '    \"VALUE\",' entry in \"$key\""
            fi
            val="${BASH_REMATCH[1]}"
            if [[ "$key" == names ]]; then
                if [[ ! "$val" =~ ^[A-Za-z0-9._-]+$ || "$val" == . || "$val" == .. ]]; then
                    project_config_mask_refuse "$where: $val is not a plain file name"
                fi
                [[ -z "${seen_val[name:$val]+x}" ]] || project_config_mask_refuse "$where: $val is listed twice"
                seen_val["name:$val"]=1
                PROJECT_CONFIG_MASK_ANYWHERE+=("$val")
            else
                # "/$val/" also turns an empty value or a leading "/" into
                # an empty component.
                if [[ ! "$val" =~ ^[A-Za-z0-9._/-]+$ || "/$val/" == *//* \
                      || "/$val/" == */./* || "/$val/" == */../* ]]; then
                    project_config_mask_refuse "$where: $val is not a plain checkout-relative path"
                fi
                [[ -z "${seen_val[path:$val]+x}" ]] || project_config_mask_refuse "$where: $val is listed twice"
                seen_val["path:$val"]=1
                PROJECT_CONFIG_MASK_KIND+=("${key%s}")
                PROJECT_CONFIG_MASK_PATH+=("$val")
            fi
            entries=$((entries + 1))
            tentries=$((tentries + 1))
            continue
        fi
        if [[ "$line" =~ ^\[(project\.[a-z0-9-]+|anywhere)\]$ ]]; then
            [[ -z "$table" || "$tentries" -gt 0 ]] || project_config_mask_refuse "$where: [$table] has no entries"
            table="${BASH_REMATCH[1]}"
            [[ -z "${seen_table[$table]+x}" ]] || project_config_mask_refuse "$where: [$table] appears more than once"
            seen_table["$table"]=1
            tentries=0
            continue
        fi
        if [[ "$line" =~ ^(files|dirs|names)\ =\ \[$ ]]; then
            key="${BASH_REMATCH[1]}"
            case "$table:$key" in
                project.*:files | project.*:dirs | anywhere:names) ;;
                *) project_config_mask_refuse "$where: \"$key\" does not belong in [${table:-no table}]" ;;
            esac
            [[ -z "${seen_key[$table:$key]+x}" ]] || project_config_mask_refuse "$where: \"$key\" appears twice in [$table]"
            seen_key["$table:$key"]=1
            entries=0
            continue
        fi
        project_config_mask_refuse "$where: not a comment, a [project.GROUP] or [anywhere] header, or a '\"files\"/\"dirs\"/\"names\" = [' line"
    done <"$PROJECT_CONFIG_MASK_FILE"
    [[ -z "$key" ]] || project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE: \"$key\" in [$table] is never closed"
    [[ -z "$table" || "$tentries" -gt 0 ]] || project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE: [$table] has no entries"
    if [[ ${#PROJECT_CONFIG_MASK_PATH[@]} -eq 0 ]]; then
        project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE: no [project.*] entries"
    fi
    if [[ ${#PROJECT_CONFIG_MASK_ANYWHERE[@]} -eq 0 ]]; then
        project_config_mask_refuse "$PROJECT_CONFIG_MASK_FILE: [anywhere] has no entries"
    fi
}

declare -a CFG_MASK_STATE=() CFG_MASK_PATH=() CFG_MASK_OWNER=()

# config_mask_materialize_head DIR REL DEST: materialize REL as it exists
# in DIR's HEAD tree into DEST, a fresh RUN_DIR path the caller binds
# read-only over the checkout's path. The copy rather than a self-bind is
# the point: `-B p:p:ro` mounts the HOST inode, and a read-only bind on a
# shared filesystem is defeatable by a hardlink alias -- `ln p alias`
# needs only write access to the alias's parent directory, and a write
# through the alias mutates the committed file on the host. A copy is a
# different inode: every alias the agent can create hits the copy, and
# the checkout stays untouched.
#
# A path HEAD records as a symlink is refused, never materialized: the
# copy would itself be a link, and the bind would follow it
# (config_mask_symlink_refuse). A tree is materialized file by file out
# of the HEAD tree -- a link inside it copied as a link, resolved only
# inside the container -- so what the session sees is the committed
# content even when the working tree has it modified or deleted, and
# neither export-ignore nor working-tree state can shorten it.
config_mask_materialize_head() {
    local dir="$1" rel="$2" dest="$3" snap meta m p mode fm fpath target
    ensure_run_dir
    snap="$RUN_DIR/cfgmask-snap"
    mkdir -p -- "$snap"
    if ! git -C "$dir" ls-tree -z HEAD -- "$rel" >"$snap/head-entry" 2>/dev/null; then
        printf '%s%s\n' "sandbox: cannot read HEAD:$rel in $dir -- refusing to " \
            "build a partial config copy" >&2
        exit 1
    fi
    meta=""
    while IFS=$'\t' read -r -d '' m p; do meta="$m"; done <"$snap/head-entry"
    mode="${meta%% *}"
    case "$mode" in
        120000)
            config_mask_symlink_refuse "HEAD records $dir/$rel as a symlink" \
                "Commit the file itself in place of the link, then re-run."
            ;;
        100644|100755)
            git -C "$dir" cat-file blob "HEAD:$rel" >"$dest"
            ;;
        *)
            # A tree (mode 40000), or anything unexpected: materialize the
            # committed file tree file by file.
            mkdir -p -- "$dest"
            if ! git -C "$dir" ls-tree -r -z HEAD -- "$rel" >"$snap/head-tree" 2>/dev/null; then
                printf '%s%s\n' "sandbox: cannot read the HEAD tree under $rel in $dir -- " \
                    "refusing to build a partial config copy" >&2
                exit 1
            fi
            while IFS=$'\t' read -r -d '' m fpath; do
                fm="${m%% *}"
                target="$dest/${fpath#"$rel"/}"
                mkdir -p -- "${target%/*}"
                case "$fm" in
                    120000)
                        ln -sfn "$(git -C "$dir" cat-file blob "HEAD:$fpath")" "$target"
                        ;;
                    *)
                        git -C "$dir" cat-file blob "HEAD:$fpath" >"$target"
                        ;;
                esac
            done <"$snap/head-tree"
            ;;
    esac
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
# Shared deliberately by the two consumers that need the same answer:
# mask_project_agent_config() decides what to bind from it, and the
# host-side sandbox.yml trust gate (parse_project_sandbox_config,
# functions/project-sandbox-config.sh) decides whether to honour that
# file at all.
# Two implementations of "is this committed" would be two things to keep
# in agreement, and the one that drifted would fail open.
#
# The answer is returned in a GLOBAL, never echoed for the caller to read
# through "$(...)". A command substitution is a subshell, and the `exit 1`
# refusals below would die inside it while the caller saw an empty string
# and carried on -- an unmasked path, or an untrusted sandbox.yml honoured
# because the check could not be completed. The refusal has to be able to
# reach the real shell.
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

# config_mask_symlink_refuse REASON HINT: a known config path is a symlink
# -- on disk, or as HEAD records it. Refused, not followed: a bind is
# resolved to wherever a link points, not to the path it names. As a bind
# source the link sends the mount to some other host file (a relative
# target resolves against $RUN_DIR, an absolute one exposes whatever host
# path it names); as a destination it moves the mask off the path the
# agent CLI reads. Config paths are regular files or directories, and a
# link inside a masked directory is unaffected: it is copied from HEAD
# and only resolved inside the container.
config_mask_symlink_refuse() {
    printf '%s\n  %s\n  %s\n  %s\n' \
        "sandbox: refusing to start -- $1." \
        "Known config paths must be regular files or directories: a bind over a" \
        "link is resolved to wherever it points, not to the path it names." \
        "$2" >&2
    exit 1
}

# config_deep_instruction_paths DIR OUT: every path in DIR's tree, at any
# depth, whose basename is one of the table's "[anywhere]" names (the
# always-loaded instruction files discovery reaches below the root, and
# direnv's .envrc) -- tracked or not, including gitignored ones, since an
# ignore rule must not be a place to hide a plant. Writes NUL-separated
# checkout-relative paths to OUT; non-zero return means the enumeration
# failed and the caller must refuse.
#
# The matching is done by git, through ":(glob)**/<name>" pathspecs, not
# by a bash loop over every untracked path. That is the difference between
# one C-speed tree walk and an O(untracked x patterns) shell loop over a
# checkout that may hold tens of thousands of ignored files (node_modules,
# .venv, build output) -- the walk that would otherwise make every startup
# slower in proportion to tree size.
#
# Enumeration uses the INDEX for tracked paths (ls-tree does not accept
# glob pathspec magic). That is only a candidate list: whether each
# candidate is trusted is still decided against HEAD by config_path_state,
# so an index entry that HEAD does not have comes back "uncommitted" and
# is hidden, exactly as if it had been found as an untracked file.
config_deep_instruction_paths() {
    local dir="$1" out="$2" name tracked others
    local -a specs=()
    project_config_mask_load
    for name in "${PROJECT_CONFIG_MASK_ANYWHERE[@]}"; do
        specs+=(":(glob)**/$name")
    done
    ensure_run_dir
    mkdir -p -- "$RUN_DIR/cfgmask-snap"
    tracked="$RUN_DIR/cfgmask-snap/deep-cached"
    others="$RUN_DIR/cfgmask-snap/deep-others"
    : >"$out" || return 1
    # Not a checkout: there is no tree to walk and nothing is committed
    # anywhere. The root-level table still applies; this half is empty.
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    git -C "$dir" ls-files --cached -z -- "${specs[@]}" >"$tracked" 2>/dev/null || return 1
    git -C "$dir" ls-files --others -z -- "${specs[@]}" >"$others" 2>/dev/null || return 1
    LC_ALL=C sort -z -u -- "$tracked" "$others" >"$out" || return 1
    return 0
}

# config_mask_record STATE ABS DIR: one row of the startup/exit report.
# The checkout each row came from is recorded alongside it, because
# worktree mode masks two checkouts and "which one is this uncommitted
# file in" is the whole point of the line.
config_mask_record() {
    CFG_MASK_STATE+=("$1")
    CFG_MASK_PATH+=("$2")
    CFG_MASK_OWNER+=("$3")
}

# config_mask_one DIR REL: apply the git-known convention (see
# mask_project_agent_config below) to ONE path, relative to checkout DIR.
config_mask_one() {
    local dir="$1" rel="$2" abs src state
    abs="$dir/$rel"
    if [[ ! -e "$abs" && ! -L "$abs" ]]; then
        config_mask_record "unbound" "$abs" "$dir"
        return 0
    fi
    if [[ -L "$abs" ]]; then
        config_mask_symlink_refuse "$abs is a symlink" \
            "Replace the link with the file itself (and commit it), then re-run."
    fi
    # Committed-tree membership and cleanliness, per path -- the one
    # predicate, shared with the host-side sandbox.yml trust gate.
    config_path_state "$dir" "$rel"
    state="$CFG_PATH_STATE"
    src="$RUN_DIR/cfgmask/$(printf '%s' "$abs" | sha256sum | cut -c1-16)"
    case "$state" in
        committed|uncommitted-dirty)
            config_mask_materialize_head "$dir" "$rel" "$src"
            # A path HEAD knows as a file but the working tree now has as
            # a directory (or the reverse) would have apptainer mount a
            # file over a directory, which fails at launch as an opaque
            # mount error rather than as anything a reader could act on.
            # Name it here instead.
            if [[ -d "$abs" && ! -L "$abs" && ! -d "$src" ]] \
               || { [[ ! -d "$abs" || -L "$abs" ]] && [[ -d "$src" ]]; }; then
                printf '%s\n  %s\n  %s\n' \
                    "sandbox: $abs is a different kind of path than HEAD has committed there" \
                    "(one is a directory and the other is not), so it cannot be masked." \
                    "Reconcile the working tree with HEAD at that path and re-run." >&2
                exit 1
            fi
            ;;
        uncommitted)
            # Empty placeholder; the shape follows the path AS IT IS ON
            # DISK, not as the table guessed, so the mount always matches
            # the destination that exists.
            if [[ -d "$abs" && ! -L "$abs" ]]; then
                mkdir -p -- "$src"
            else
                : >"$src"
            fi
            ;;
    esac
    BINDS+=(-B "$src:$abs:ro")
    case "$state" in
        committed)
            RO_MASKED+=("$abs (committed; read-only copy)")
            config_mask_record "committed" "$abs" "$dir"
            ;;
        uncommitted)
            RO_MASKED+=("$abs (uncommitted; hidden)")
            config_mask_record "hidden" "$abs" "$dir"
            ;;
        uncommitted-dirty)
            # ONE array element. A line continuation between two quoted
            # strings appends TWO, and the second one becomes a bogus
            # bullet in the agent's own limitations file and an inflated
            # read-only-bind count on the startup line.
            RO_MASKED+=("$abs (uncommitted changes; hidden, session sees the committed version)")
            config_mask_record "hidden" "$abs" "$dir"
            ;;
    esac
}

# mask_project_agent_config DIR: apply the git-known convention to every
# table path (project_config_mask_load) under the checkout DIR, which is
# otherwise bound plain read-write so the agent can do its actual job:
#
#     visible to the session  <=>  tracked in DIR's HEAD tree AND
#                                  identical to it in the working tree
#
# - committed & clean -> a fresh per-run COPY of the committed content,
#   bound read-only over the path. Read-only, as before: an agent write
#   here would persist uncommitted on the host and run on the human's
#   next bare-host session.
# - uncommitted -> hidden. The session is blind to it: an empty
#   placeholder for untracked paths, the HEAD copy for tracked paths
#   whose working-tree content has drifted (so the session sees the
#   branch's config, and the local deltas or local secrets they may hold
#   are invisible). Over an existing destination this materializes
#   nothing on the host.
# - absent on disk -> NOT BOUND, whatever its tracked state. There is
#   nothing to hide at a path that does not exist, and any bind would
#   make apptainer materialize a placeholder there -- the git-status
#   clutter this convention removes. A file the agent creates at such a
#   path does not load in the current session (config is read at CLI
#   startup), is invisible to every later sandboxed run (uncommitted ->
#   hidden), and reaches the host only through a human act: the exit
#   report (report_created_config_paths) in normal mode, the approval
#   gate's review in worktree mode.
#
# Unconditional, independent of $AGENT: omp's own MCP discovery reads
# other tools' project config in addition to its own, so a file written
# by *any* agent this run, or left over from a prior run, is a live
# MCP-server-launch vector for omp specifically, and a hook/plugin-
# execution vector for its native tool on the human's next bare-host run
# of whichever CLI that is. Masking every table path regardless of which
# agent this run is using is what actually closes that.
#
# The report accumulators are NOT reset here. Worktree mode calls this
# once for the main checkout and once for the worktree, and resetting
# would silently drop the main checkout's partition from the startup
# report -- exactly the checkout where an uncommitted config plant is
# most consequential, since that is the one the human keeps using. Both
# calls' rows survive, and report_config_masking() labels each row with
# the checkout it came from.
#
# Two halves: every table entry first, then every deep instruction file
# the tree-wide sweep finds (config_deep_instruction_paths), through the
# same config_mask_one -- so a deep AGENTS.md is decided by exactly the
# same code as a root-level one.
mask_project_agent_config() {
    local dir="$1" i rel d under
    project_config_mask_load
    ensure_run_dir
    mkdir -p -- "$RUN_DIR/cfgmask"
    declare -A seen=()
    local -a table_dirs=()
    for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
        seen["${PROJECT_CONFIG_MASK_PATH[i]}"]=1
        [[ "${PROJECT_CONFIG_MASK_KIND[i]}" == dir ]] && table_dirs+=("${PROJECT_CONFIG_MASK_PATH[i]}")
        config_mask_one "$dir" "${PROJECT_CONFIG_MASK_PATH[i]}"
    done
    # The tree-wide half: the always-loaded instruction files reach the
    # session from ANY depth, so masking only the checkout root would
    # leave sub/AGENTS.md writable and loadable. Root-level paths the
    # table already covered are skipped rather than bound twice, and so is
    # anything inside a table directory: that entry already decides its
    # whole content, and a second bind nested in it could land in an
    # empty placeholder that has no mount point for it.
    local deep="$RUN_DIR/cfgmask-snap/deep-paths"
    if ! config_deep_instruction_paths "$dir" "$deep"; then
        printf '%s%s\n' "sandbox: cannot enumerate the deep instruction files of $dir -- " \
            "refusing to resolve the config mask from a partial tree" >&2
        exit 1
    fi
    while IFS= read -r -d '' rel; do
        [[ -n "${seen["$rel"]+x}" ]] && continue
        under=0
        for d in ${table_dirs[@]+"${table_dirs[@]}"}; do
            [[ "$rel" == "$d"/* ]] && { under=1; break; }
        done
        [[ "$under" -eq 1 ]] && continue
        seen["$rel"]=1
        config_mask_one "$dir" "$rel"
    done <"$deep"
}

# report_config_masking: the startup confirmation -- informational only,
# no prompt, nothing decided. It states the partition the session runs
# under in the human's own words, and it doubles as the plant tripwire:
# a config file that appeared in a checkout uninvited (a plant left by a
# crashed run) is uncommitted, so it shows up in the hidden section by
# name, every run, until the human acts on it. Paths are printed %q-quoted,
# like every other path the agent may have chosen the name of.
report_config_masking() {
    local state label row abs owner tag multi=0 first=""
    # Worktree mode masks two checkouts, and "which checkout is this
    # uncommitted file in" is the point of the line, so each row carries
    # its own tag once more than one checkout contributed rows.
    for row in "${!CFG_MASK_OWNER[@]}"; do
        owner="${CFG_MASK_OWNER[row]}"
        if [[ -z "$first" ]]; then
            first="$owner"
        elif [[ "$owner" != "$first" ]]; then
            multi=1
        fi
    done
    {
        echo
        echo "sandbox: agent-config masking (the session sees a known config" \
            "path's committed content only):"
        for state in committed hidden unbound; do
            case "$state" in
                committed) label="read-only, committed (the human authored it at some commit):" ;;
                hidden)
                    label="hidden, not committed (the session sees nothing at these paths):"
                    ;;
                unbound)
                    label="not present at launch, not bound (the agent may create files"
                    label+=" there; anything it creates is surfaced when the run ends):"
                    ;;
            esac
            local -a lines=()
            for row in "${!CFG_MASK_STATE[@]}"; do
                if [[ "${CFG_MASK_STATE[row]}" == "$state" ]]; then
                    abs="$(printf '%q' "${CFG_MASK_PATH[row]}")"
                    if [[ "$multi" -eq 1 ]]; then
                        owner="${CFG_MASK_OWNER[row]}"
                        if [[ -n "${WORKTREE_DIR:-}" && "$owner" == "$WORKTREE_DIR" ]]; then
                            tag="[worktree]  "
                        else
                            tag="[main]      "
                        fi
                        lines+=("$tag$abs")
                    else
                        lines+=("$abs")
                    fi
                fi
            done
            if [[ ${#lines[@]} -gt 0 ]]; then
                echo "  $label"
                printf '    %s\n' "${lines[@]}"
            fi
        done
        if [[ -n "${WORKTREE_DIR:-}" ]]; then
            echo "  (worktree mode: files the agent created at the unbound [worktree]" \
                "paths are decided individually at the approval gate)"
            # The unbound heading says the agent MAY create files there;
            # for the main checkout that depends on how it is mounted.
            case "${WORKTREE_PROJECT_MODE:-ro}" in
                rw)
                    echo "  (the main checkout is mounted read-write this run: files the agent" \
                        "creates at its unbound [main] paths are reported after each round)"
                    ;;
                deny)
                    echo "  (the main checkout is not mounted this run: nothing can be created" \
                        "at its [main] paths)"
                    ;;
                *)
                    echo "  (the main checkout is read-only this run: nothing can be created" \
                        "at its [main] paths)"
                    ;;
            esac
        else
            echo "  (normal mode: files the agent created at the unbound paths are" \
                "reported in full when the run ends)"
        fi
    } >&2
}

# report_created_config_paths DIR: normal mode has no approval gate, so
# this is the review of what the agent created at config paths that were
# absent when it started: every unbound path under DIR that exists now is
# named, directories listed file by file, file content printed (through
# sanitize_agent_display -- it is agent-authored bytes on their way to a
# terminal). Nothing is deleted and nothing is committed: keep it, commit
# it by hand, or remove it -- the human's call, made after reading it.
report_created_config_paths() {
    local dir="$1" i abs n f ftype
    [[ -n "$dir" ]] || return 0
    local -a created=()
    for i in "${!CFG_MASK_STATE[@]}"; do
        if [[ "${CFG_MASK_STATE[i]}" == "unbound" ]]; then
            abs="${CFG_MASK_PATH[i]}"
            if [[ "$abs" == "$dir"/* && ( -e "$abs" || -L "$abs" ) ]]; then
                created+=("$abs")
            fi
        fi
    done
    if [[ ${#created[@]} -eq 0 ]]; then
        return 0
    fi
    {
        echo
        printf '%s%s\n' "sandbox: the agent created ${#created[@]} path(s) at config" \
            " locations that were absent when it started:"
        for abs in ${created[@]+"${created[@]}"}; do
            printf '    %q\n' "$abs"
            ftype="$(config_display_type "$abs")"
            if [[ -d "$abs" && ! -L "$abs" ]]; then
                printf '%s\n' "      (directory; contents:)"
                while IFS= read -r -d '' f; do
                    n="$(stat -c %s "$f" 2>/dev/null || echo '?')"
                    printf '      %q  (%s bytes)\n' "${f#"$abs"/}" "$n"
                done < <(find "$abs" -type f -print0 2>/dev/null | sort -z)
            elif [[ -n "$ftype" ]]; then
                # Not a regular file: name what it is and read nothing.
                # Reading it would either block this report forever (fifo)
                # or print some other file's bytes under this path's name
                # (symlink) -- see config_display_type().
                printf '%s\n' "      type: $ftype"
                printf '%s\n' "      (content not shown: only a regular file is read here)"
            elif [[ ! -r "$abs" ]]; then
                # The agent picks the mode too; an unreadable file is
                # named, not skipped.
                printf '%s\n' "      (content not shown: the file is not readable)"
            else
                printf '%s\n' "      ----"
                sanitize_agent_display <"$abs" | head -n 60
                if [[ "$(wc -l <"$abs" 2>/dev/null | tr -d '[:space:]')" -gt 60 ]]; then
                    printf '%s\n' "      ... (truncated; read the file for the rest)"
                fi
                printf '%s\n' "      ----"
            fi
        done
        printf '%s%s\n' "sandbox: nothing here is deleted or committed automatically." \
            " Keep it, commit it by hand, or remove it."
    } >&2
}

# config_shaped_untracked DIR OUT: every untracked path under DIR
# (including gitignored ones) that is config-shaped: a mask-entry path,
# anything inside a mask-entry directory, or an "[anywhere]" name at
# any depth. Writes NUL-separated absolute paths to OUT; the worktree
# approval gate's per-file decisions feed from it. Deliberately
# over-inclusive: a false positive costs one question the human answers
# with a keystroke, a false negative is a plant that loads on the human's
# next bare-host session.
#
# Matching is handed to git as pathspecs rather than done in a bash loop
# over every untracked path. Ignored files stay in scope -- an ignore rule
# must not be a place to hide a plant -- and that list can hold tens of
# thousands of entries (node_modules/, .venv/, a build tree), so the loop
# has to be git's, in C.
#
# Results go to a caller-named FILE and the caller checks the exit status,
# rather than being streamed out of a process substitution. That is not a
# style choice: the git read below can fail, and inside "< <(...)" that
# failure is invisible -- the caller sees an empty list, and an empty list
# is indistinguishable from "the agent created no config files". The
# per-file gate would then be skipped and `git add -A` would sweep every
# plant into the commit unreviewed. The same trap is documented at
# worktree_render_state()'s own untracked-list capture, for the same
# reason.
config_shaped_untracked() {
    local dir="$1" out="$2" i rel name hits
    local -a specs=()
    project_config_mask_load
    for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
        rel="${PROJECT_CONFIG_MASK_PATH[i]}"
        if [[ "${PROJECT_CONFIG_MASK_KIND[i]}" == dir ]]; then
            # Anything anywhere under a masked config directory.
            specs+=(":(literal,top)$rel" ":(glob,top)$rel/**")
        else
            specs+=(":(literal,top)$rel")
        fi
    done
    for name in "${PROJECT_CONFIG_MASK_ANYWHERE[@]}"; do
        specs+=(":(glob,top)**/$name")
    done
    : >"$out" || return 1
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    ensure_run_dir
    mkdir -p -- "$RUN_DIR/cfgmask-snap"
    hits="$RUN_DIR/cfgmask-snap/shaped-untracked"
    if ! git -C "$dir" ls-files --others -z -- "${specs[@]}" >"$hits" 2>/dev/null; then
        return 1
    fi
    while IFS= read -r -d '' rel; do
        printf '%s\0' "$dir/$rel" >>"$out" || return 1
    done <"$hits"
    return 0
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
