#!/bin/bash
# Git MCP sidecar lifecycle: starts sandbox/gitmcp.sif (the container that
# owns git access) before the agent runs, exposes it over loopback HTTP,
# masks every .git in the project tree read-only in the agent container,
# and stops the sidecar on exit.
#
# Populates (when a .git is present): RUN_DIR, GIT_SIDECAR_NAME,
# SESSION_TOKEN, GIT_MCP_PORT, GIT_MCP_URL, and appends the read-only
# .git binds to BINDS.

# cleanup is registered as the EXIT trap by sandbox.sh *before* anything
# else runs, so every variable it touches is referenced defensively.
cleanup() {
    if [[ -n "${GIT_SIDECAR_NAME:-}" ]]; then
        apptainer instance stop "$GIT_SIDECAR_NAME" >/dev/null 2>&1 || true
    fi
    # Ephemeral bind points created inside the user's project dir.
    if [[ -n "${OMP_MCP_PLACEHOLDER:-}" && -f "$OMP_MCP_PLACEHOLDER" ]]; then
        rm -f "$OMP_MCP_PLACEHOLDER"
    fi
    if [[ -n "${OMP_MCP_DIR_CREATED:-}" && -d "$OMP_MCP_DIR_CREATED" ]]; then
        rmdir "$OMP_MCP_DIR_CREATED" 2>/dev/null || true
    fi
    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
        rm -rf "$RUN_DIR"
    fi
}

# port_is_open PORT: true if something accepts a connection on loopback.
# Opens the socket with exec and closes it again rather than `echo >`,
# which would push a stray newline into the listening server.
port_is_open() {
    local port="$1"
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exec 3>&- 2>/dev/null
    return $?
}

# resolve_git_dir PATH: echoes the real git directory for a .git entry.
# In a worktree or submodule checkout .git is a FILE containing
# "gitdir: <path>" (possibly relative), and that target holds the actual
# refs/objects, so it must be masked too.
resolve_git_dir() {
    local entry="$1" target base
    if [[ -d "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi
    [[ -f "$entry" ]] || return 0
    target="$(sed -n 's/^gitdir:[[:space:]]*//p' "$entry" | head -n1)"
    [[ -n "$target" ]] || return 0
    if [[ "$target" != /* ]]; then
        base="$(dirname "$entry")"
        target="$base/$target"
    fi
    target="$(readlink -f "$target" 2>/dev/null || true)"
    [[ -n "$target" && -e "$target" ]] && printf '%s\n' "$target"
}

# mask_git_readonly: appends a read-only bind for every .git in the
# project tree (top level, submodules, nested repositories) plus the real
# git directory each one points at.
#
# apptainer sorts mount points by destination depth, shallowest first
# (PointList.Less/Sort in internal/pkg/util/fs/mount/mount_linux.go), so
# the shallow read-write project-dir bind lands before these deeper
# read-only binds and the kernel then enforces the boundary regardless of
# what tries to write .git inside the container.
mask_git_readonly() {
    local entry real
    local -a masked=()

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        BINDS+=(-B "$entry:$entry:ro")
        masked+=("$entry")
        real="$(resolve_git_dir "$entry")"
        # A gitdir outside the project dir is not covered by the
        # project-dir bind, so only mask it when it is actually visible
        # in the container.
        if [[ -n "$real" && "$real" != "$entry" && "$real" == "$PROJECT_DIR"/* ]]; then
            BINDS+=(-B "$real:$real:ro")
            masked+=("$real")
        elif [[ -n "$real" && "$real" != "$entry" ]]; then
            echo "note: git dir $real lies outside $PROJECT_DIR and is not mounted into the sandbox" >&2
        fi
    done < <(find "$PROJECT_DIR" -mindepth 1 -name .git -prune -print 2>/dev/null)

    if [[ ${#masked[@]} -gt 0 ]]; then
        echo "git: masking ${#masked[@]} path(s) read-only in the sandbox: ${masked[*]}" >&2
    fi
}

# start_git_sidecar: masks .git read-only unconditionally, then (only if
# the project root is itself a repository) starts the MCP sidecar.
# Leaves GIT_MCP_URL empty when there is no sidecar.
start_git_sidecar() {
    RUN_DIR=""
    GIT_SIDECAR_NAME=""
    SESSION_TOKEN=""
    GIT_MCP_PORT=8765
    GIT_MCP_URL=""

    mask_git_readonly

    # .git is a directory in a normal clone and a file in a worktree or
    # submodule checkout; both are repositories the sidecar can serve.
    [[ -e "$PROJECT_DIR/.git" ]] || return 0

    RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-engine.XXXXXX")"
    chmod 700 "$RUN_DIR"
    SESSION_TOKEN="$(openssl rand -hex 16)"
    if [[ ${#SESSION_TOKEN} -lt 32 ]]; then
        echo "failed to generate a session token via 'openssl rand'" >&2
        exit 1
    fi
    GIT_SIDECAR_NAME="git-sidecar-$$"

    # Pick a free loopback port starting at the default, so multiple
    # concurrent sandbox.sh runs (e.g. different projects) don't collide.
    # This is advisory: the sidecar, not this loop, owns the bind, and a
    # lost race shows up as the readiness check below failing.
    while port_is_open "$GIT_MCP_PORT"; do
        GIT_MCP_PORT=$((GIT_MCP_PORT + 1))
    done

    # The token goes through APPTAINERENV_* rather than `--env` because
    # /proc/<pid>/cmdline is world-readable (mode 0444), which would
    # expose the bearer token to every local user for the lifetime of the
    # apptainer process.
    #
    # The repository is bound READ-ONLY into the sidecar as well: every
    # tool this server exposes is read-only, so nothing in the sidecar
    # needs write access either. Exposing a mutating tool later means
    # flipping this bind back to rw for that tool's sake, deliberately.
    APPTAINERENV_GIT_MCP_TOKEN="$SESSION_TOKEN" \
    apptainer instance start \
        --containall --writable-tmpfs \
        -B "$PROJECT_DIR:$PROJECT_DIR:ro" \
        "$GITMCP_SIF" \
        "$GIT_SIDECAR_NAME" \
        --repository "$PROJECT_DIR" --port "$GIT_MCP_PORT" --host 127.0.0.1

    # Wait for the sidecar to accept connections before handing the agent
    # an MCP config that points at it.
    local ready=0 _i
    for _i in $(seq 1 50); do
        if port_is_open "$GIT_MCP_PORT"; then
            ready=1
            break
        fi
        sleep 0.2
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "git MCP sidecar did not become ready within 10s on 127.0.0.1:$GIT_MCP_PORT" >&2
        apptainer instance logs "$GIT_SIDECAR_NAME" >&2 2>/dev/null || true
        exit 1
    fi

    GIT_MCP_URL="http://127.0.0.1:$GIT_MCP_PORT/mcp"
}
