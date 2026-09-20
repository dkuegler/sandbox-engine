#!/bin/bash
# Extra bind resolution: sandbox.yml "binds:" list + repeatable --bind
# flags, validated and expanded (relative paths against the project dir,
# "~/" against $HOME) into the BINDS array apptainer consumes via -B.

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

        # Before resolving links: reject a spec that textually leaves the
        # project dir ("../..", an absolute path elsewhere, "~/.ssh").
        BIND_SCOPE_FORCE_RO=0
        bind_scope_check "$src" "$origin" "unresolved" "$is_ro"
        src="$(readlink -f "$src")"
        # After resolving: catch a symlink inside the project that points out.
        bind_scope_check "$src" "$origin" "resolved" "$is_ro"
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

# bind_scope_check PATH ORIGIN STAGE IS_RO: a bind source outside the
# project directory can expose anything on the host (~/.ssh, /etc), and
# sandbox.yml travels with an untrusted checkout, so it is
# attacker-controlled. Allowed only with --allow-external-binds, or after
# an interactive confirmation. Reports the path's size and file count so
# "mount it?" is an informed answer, not a blind y/N, and offers
# downgrading to read-only as a distinct reply -- sets
# BIND_SCOPE_FORCE_RO=1 for the caller to act on rather than mounting
# read-write just because that is what was asked for.
bind_scope_check() {
    local p="$1" origin="$2" stage="$3" is_ro="$4" reply mode size count
    [[ "$p" == "$PROJECT_DIR" || "$p" == "$PROJECT_DIR"/* ]] && return 0
    mode="read-write"
    [[ "$is_ro" -eq 1 ]] && mode="read-only"
    if [[ "$ALLOW_EXTERNAL_BINDS" -eq 1 ]]; then
        echo "warning: bind ($origin) '$p' is outside the project dir $PROJECT_DIR (allowed by --allow-external-binds, mounted $mode)" >&2
        return 0
    fi
    # -r alone is not a reliable predictor: /dev/tty exists and is
    # world-readable even with no controlling terminal (a detached/CI
    # process), where opening it fails with ENXIO. Folding the printf
    # into the if's condition, not a statement inside its body, is what
    # keeps that failure from tripping the caller's `set -e` -- a
    # command's exit status inside an if/&&/|| condition never does.
    if [[ -r /dev/tty ]]; then
        size="$(du -sh "$p" 2>/dev/null | cut -f1)"
        count="$(find "$p" 2>/dev/null | wc -l | tr -d '[:space:]')"
        if printf 'bind (%s) %s is outside the project dir %s (%s path), mode=%s.\n%s, %s path(s) under it.\nMount it %s into the sandbox? [y/N] (or "o" for read-only) ' \
            "$origin" "$p" "$PROJECT_DIR" "$stage" "$mode" "${size:-size unknown}" "${count:-?}" "$mode" 2>/dev/null >/dev/tty; then
            read -r reply </dev/tty 2>/dev/null || reply=""
            case "$reply" in
                [oO]*)
                    BIND_SCOPE_FORCE_RO=1
                    return 0
                    ;;
                [yY]*)
                    return 0
                    ;;
            esac
        fi
    fi
    echo "refusing bind ($origin) '$p': outside the project dir $PROJECT_DIR. Pass --allow-external-binds to allow it." >&2
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

# log_resolved_binds: one summary line per run naming every bind actually
# handed to apptainer -- source, destination (if any), and ro/rw -- so an
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
