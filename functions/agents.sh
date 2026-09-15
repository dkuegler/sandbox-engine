#!/bin/bash
# Per-agent config: bind mounts for each agent's persistent state, the
# RUN_CMD to exec, and (when GIT_MCP_SOCKET is set) the agent-specific MCP
# config wiring so it can reach the git sidecar. Every agent spawns the
# sidecar as a *local* MCP server via `nc -U <socket>`: nc just relays its
# stdin/stdout to the Unix socket the sidecar listens on, which is bound
# into this container from the same RUN_DIR the sidecar wrote it into.
# There is no network hop and nothing to authenticate -- the socket
# file's own permissions (0600, in a 0700 RUN_DIR) are the access
# control. Per-agent config shapes for a local/stdio server:
#   claude:   --mcp-config <file> --strict-mcp-config; {"type":"stdio","command","args"}
#   opencode: OPENCODE_CONFIG=<path> env var; mcp.<name> = {"type":"local","command":[...]}
#   omp:      <project-dir>/.omp/mcp.json (auto-discovered); {"command","args"}

# write_mcp_config PATH JSON: create the file with 0600 *before* writing.
# No secret travels through these files any more (the git server has no
# token), but the RUN_DIR paths it names are still nobody else's business.
write_mcp_config() {
    local path="$1" body="$2"
    : > "$path"
    chmod 600 "$path"
    printf '%s\n' "$body" > "$path"
}

configure_agent() {
    AGENT_ENV=()

    case "$AGENT" in
        claude)
            mkdir -p "$HOME/.claude" "$HOME/.config/claude"
            touch "$HOME/.claude.json"
            BINDS+=(
                -B "$HOME/.claude"
                -B "$HOME/.config/claude"
                -B "$HOME/.claude.json"
            )
            RUN_CMD=(claude "${ARGS[@]}")
            if [[ -n "$GIT_MCP_SOCKET" ]]; then
                local mcp_config_file="$RUN_DIR/claude-mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"mcpServers\":{\"git\":{\"type\":\"stdio\",\"command\":\"nc\",\"args\":[\"-U\",\"$GIT_MCP_SOCKET\"]}}}"
                BINDS+=(-B "$RUN_DIR")
                RUN_CMD=(claude --mcp-config "$mcp_config_file" --strict-mcp-config "${ARGS[@]}")
            fi
            ;;
        opencode)
            mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                "$HOME/.local/state/opencode" "$HOME/.opencode"
            BINDS+=(
                -B "$HOME/.config/opencode"
                -B "$HOME/.local/share/opencode"
                -B "$HOME/.local/state/opencode"
                -B "$HOME/.opencode"
            )
            RUN_CMD=(opencode "${ARGS[@]}")
            if [[ -n "$GIT_MCP_SOCKET" ]]; then
                local mcp_config_file="$RUN_DIR/opencode-mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"\$schema\":\"https://opencode.ai/config.json\",\"mcp\":{\"git\":{\"type\":\"local\",\"command\":[\"nc\",\"-U\",\"$GIT_MCP_SOCKET\"],\"enabled\":true}}}"
                BINDS+=(-B "$RUN_DIR")
                AGENT_ENV+=(--env "OPENCODE_CONFIG=$mcp_config_file")
            fi
            ;;
        omp)
            # oh-my-pi (can1357/oh-my-pi) keeps all config/auth/state under
            # ~/.omp (e.g. ~/.omp/agent/config.yml, models.yml). Project-level
            # session files live under .omp/ in the repo, already covered by
            # the project-dir bind above.
            # Source: https://github.com/can1357/oh-my-pi/blob/main/README.md
            # and https://deepwiki.com/can1357/oh-my-pi/13-configuration-reference
            mkdir -p "$HOME/.omp"
            BINDS+=(
                -B "$HOME/.omp"
            )
            RUN_CMD=(omp "${ARGS[@]}")
            if [[ -n "$GIT_MCP_SOCKET" ]]; then
                # omp auto-discovers <project>/.omp/mcp.json, which lives
                # inside the user's repository. Writing our own config
                # there directly would clobber a config the user may
                # already have. So the real file is written to RUN_DIR
                # and bind-mounted over that path for the lifetime of the
                # container; any bind point we had to create is removed
                # by cleanup().
                local mcp_config_file="$RUN_DIR/omp-mcp.json"
                local omp_dir="$PROJECT_DIR/.omp"
                local omp_target="$omp_dir/mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"mcpServers\":{\"git\":{\"command\":\"nc\",\"args\":[\"-U\",\"$GIT_MCP_SOCKET\"]}}}"
                if [[ ! -d "$omp_dir" ]]; then
                    mkdir -p "$omp_dir"
                    OMP_MCP_DIR_CREATED="$omp_dir"
                fi
                if [[ ! -e "$omp_target" ]]; then
                    : > "$omp_target"
                    OMP_MCP_PLACEHOLDER="$omp_target"
                fi
                BINDS+=(-B "$mcp_config_file:$omp_target:ro" -B "$RUN_DIR")
            fi
            ;;
    esac
}
