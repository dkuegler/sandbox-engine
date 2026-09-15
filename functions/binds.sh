#!/bin/bash
# Extra bind resolution: sandbox.yml "binds:" list + repeatable --bind
# flags, validated and expanded (relative paths against the project dir,
# "~/" against $HOME) into the BINDS array apptainer consumes via -B.

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
        # Before resolving links: reject a spec that textually leaves the
        # project dir ("../..", an absolute path elsewhere, "~/.ssh").
        bind_scope_check "$src" "$origin" "unresolved"
        src="$(readlink -f "$src")"
        # After resolving: catch a symlink inside the project that points out.
        bind_scope_check "$src" "$origin" "resolved"
        if [[ -n "$dst" ]]; then
            dst="${dst/#\~/$HOME}"
            BINDS+=(-B "$src:$dst${opts:+:$opts}")
        elif [[ -n "$opts" ]]; then
            BINDS+=(-B "$src:$opts")
        else
            BINDS+=(-B "$src")
        fi
        echo "bind ($origin): $src${dst:+ -> $dst}${opts:+ [$opts]}" >&2
        EXTRA_BIND_SRCS+=("$src")
        EXTRA_BIND_RO+=("$([[ ",$opts," == *,ro,* ]] && echo 1 || echo 0)")
    done
}

# bind_scope_check PATH ORIGIN STAGE: a bind source outside the project
# directory can expose anything on the host (~/.ssh, /etc), and
# sandbox.yml travels with an untrusted checkout, so it is
# attacker-controlled. Allowed only with --allow-external-binds, or
# after an interactive confirmation.
bind_scope_check() {
    local p="$1" origin="$2" stage="$3" reply
    [[ "$p" == "$PROJECT_DIR" || "$p" == "$PROJECT_DIR"/* ]] && return 0
    if [[ "$ALLOW_EXTERNAL_BINDS" -eq 1 ]]; then
        echo "warning: bind ($origin) '$p' is outside the project dir $PROJECT_DIR (allowed by --allow-external-binds)" >&2
        return 0
    fi
    # -r alone is not a reliable predictor: /dev/tty exists and is
    # world-readable even with no controlling terminal (a detached/CI
    # process), where opening it fails with ENXIO. Folding the printf
    # into the if's condition, not a statement inside its body, is what
    # keeps that failure from tripping the caller's `set -e` -- a
    # command's exit status inside an if/&&/|| condition never does.
    if [[ -r /dev/tty ]] && printf 'bind (%s) %s is outside the project dir %s (%s path).\nMount it read-write into the sandbox? [y/N] ' \
        "$origin" "$p" "$PROJECT_DIR" "$stage" 2>/dev/null >/dev/tty; then
        read -r reply </dev/tty 2>/dev/null || reply=""
        [[ "$reply" == [yY]* ]] && return 0
    fi
    echo "refusing bind ($origin) '$p': outside the project dir $PROJECT_DIR. Pass --allow-external-binds to allow it." >&2
    exit 1
}

# bind_ro PATH: bind PATH read-only over itself, so a read-write bind of
# an ancestor cannot be written through at PATH. Silently skips a path
# that does not exist on the host -- apptainer fails the run on a missing
# bind source, and these paths are all optional per-agent config.
# Records the path in RO_MASKED for --verbose reporting.
bind_ro() {
    local p="$1"
    [[ -e "$p" ]] || return 0
    BINDS+=(-B "$p:$p:ro")
    RO_MASKED+=("$p")
}
