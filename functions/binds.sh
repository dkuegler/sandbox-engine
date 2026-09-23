#!/bin/bash
# Extra bind resolution: sandbox.yml "binds:" list + repeatable --bind
# flags, validated and expanded (relative paths against the project dir,
# "~/" against $HOME) into the BINDS array the sandbox backend consumes
# (functions/apptainer.sh).

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

# mask_project_agent_config DIR: bind-mask, read-only, every project-root
# file/directory a coding-agent CLI treats as executable configuration --
# MCP server command lines, plugin/hook code, permission overrides -- the
# same class of surface already masked under each agent's global config
# dir in configure_agent() below, but for the project itself, which is
# otherwise bound plain read-write so the agent can do its actual job.
#
# DIR-root only, deliberately: every one of these agents (claude, opencode,
# omp) is always launched with its cwd at the project root (or the
# worktree root, which is what DIR is when --worktree is active) --
# settings.md's own doc for omp states discovery "does not walk ancestor
# directories looking for the nearest .omp/", and neither of the other two
# looks above its cwd either. Walking the rest of the tree for nested
# copies is not this function's job: unlike .git (mask_git_readonly()),
# these files only take effect at the fixed root the agent's cwd already
# sits at, so there is nothing below the surface a deeper walk would find
# that the agent would ever load as its own config.
#
# Unconditional, independent of $AGENT: omp's own MCP discovery
# (docs/mcp-config.md) reads a checkout's .claude/mcp.json,
# .codex/config.toml, .gemini/settings.json, project-root opencode.json,
# .cursor/mcp.json, .windsurf/mcp_config.json, and .vscode/mcp.json in
# addition to its own -- so a file written by *any* agent this run, or
# left over from a prior run, is a live MCP-server-launch vector for omp
# specifically, and a hook/plugin-execution vector for its native tool on
# the human's next bare-host run of whichever CLI that is. Masking every
# one of these regardless of which agent this run is using is what
# actually closes that, rather than only closing it for whichever CLI
# happens to be running today.
mask_project_agent_config() {
    local dir="$1" p
    # Claude Code: project-scope settings, its own MCP file, and the
    # subagent/command/skill content directories mirrored from its global
    # equivalents above.
    for p in .claude/settings.json .claude/settings.local.json \
             .claude/mcp.json .claude/.mcp.json; do
        bind_ro "$dir/$p"
    done
    for p in .claude/hooks .claude/plugins .claude/agents .claude/commands \
             .claude/skills .claude/rules .claude/output-styles; do
        bind_ro "$dir/$p" dir
    done
    # opencode: project-root config file (both spellings) and its own
    # content directories (both current-plural and back-compat-singular
    # names, same reasoning as the global opencode mask above).
    bind_ro "$dir/opencode.json"
    bind_ro "$dir/opencode.jsonc"
    for p in .opencode/plugin .opencode/plugins .opencode/agent .opencode/agents \
             .opencode/command .opencode/commands .opencode/mode .opencode/modes \
             .opencode/tool .opencode/tools .opencode/skill .opencode/skills \
             .opencode/theme .opencode/themes; do
        bind_ro "$dir/$p" dir
    done
    # omp: project-local settings/MCP files (docs/settings.md, "Project"
    # row; docs/mcp-config.md, "Project: .omp/mcp.json").
    for p in .omp/config.yml .omp/settings.json .omp/mcp.json .omp/.mcp.json; do
        bind_ro "$dir/$p"
    done
    # Root fallback MCP files every one of the three agents' discovery
    # chains can read (docs/mcp-config.md's "root mcp.json / .mcp.json"
    # fallback; Claude Code's own top-level .mcp.json).
    bind_ro "$dir/mcp.json"
    bind_ro "$dir/.mcp.json"
    # Other tools' project config omp's cross-tool MCP discovery reads
    # even when none of the three supported agents is that tool.
    bind_ro "$dir/.codex/config.toml"
    bind_ro "$dir/.gemini/settings.json"
    bind_ro "$dir/.cursor/mcp.json"
    bind_ro "$dir/.windsurf/mcp_config.json"
    bind_ro "$dir/.vscode/mcp.json"
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
