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
        src="$(readlink -f "$src")"
        if [[ -n "$dst" ]]; then
            dst="${dst/#\~/$HOME}"
            BINDS+=(-B "$src:$dst${opts:+:$opts}")
        elif [[ -n "$opts" ]]; then
            BINDS+=(-B "$src:$opts")
        else
            BINDS+=(-B "$src")
        fi
        echo "bind ($origin): $src${dst:+ -> $dst}${opts:+ [$opts]}" >&2
    done
}
