#!/bin/bash
# Per-agent config: bind mounts for each agent's persistent state, the
# RUN_CMD to exec, and (when GIT_MCP_URL is set) the agent-specific MCP
# config wiring so it can reach the git sidecar. See the per-agent table
# in the project plan for the source of each shape:
#   claude:   --mcp-config <file> --strict-mcp-config
#   opencode: OPENCODE_CONFIG=<path> env var (mcp key, not mcpServers)
#   omp:      <project-dir>/.omp/mcp.json (auto-discovered)

# write_mcp_config PATH JSON: create the file with 0600 *before* writing,
# so the bearer token it carries is never briefly world-readable.
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
            if [[ -n "$GIT_MCP_URL" ]]; then
                local mcp_config_file="$RUN_DIR/claude-mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"mcpServers\":{\"git\":{\"type\":\"http\",\"url\":\"$GIT_MCP_URL\",\"headers\":{\"Authorization\":\"Bearer $SESSION_TOKEN\"}}}}"
                BINDS+=(-B "$mcp_config_file")
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
            if [[ -n "$GIT_MCP_URL" ]]; then
                local mcp_config_file="$RUN_DIR/opencode-mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"\$schema\":\"https://opencode.ai/config.json\",\"mcp\":{\"git\":{\"type\":\"remote\",\"url\":\"$GIT_MCP_URL\",\"headers\":{\"Authorization\":\"Bearer $SESSION_TOKEN\"},\"enabled\":true}}}"
                BINDS+=(-B "$mcp_config_file")
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
            if [[ -n "$GIT_MCP_URL" ]]; then
                # omp auto-discovers <project>/.omp/mcp.json, which lives
                # inside the user's repository. Writing the bearer token
                # there directly would clobber a config the user may
                # already have and would leave a live token behind in the
                # working tree (and in `git status`) after the run. So the
                # real file is written to RUN_DIR and bind-mounted over
                # that path for the lifetime of the container; any
                # bind point we had to create is removed by cleanup().
                local mcp_config_file="$RUN_DIR/omp-mcp.json"
                local omp_dir="$PROJECT_DIR/.omp"
                local omp_target="$omp_dir/mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"mcpServers\":{\"git\":{\"type\":\"http\",\"url\":\"$GIT_MCP_URL\",\"headers\":{\"Authorization\":\"Bearer $SESSION_TOKEN\"}}}}"
                if [[ ! -d "$omp_dir" ]]; then
                    mkdir -p "$omp_dir"
                    OMP_MCP_DIR_CREATED="$omp_dir"
                fi
                if [[ ! -e "$omp_target" ]]; then
                    : > "$omp_target"
                    OMP_MCP_PLACEHOLDER="$omp_target"
                fi
                BINDS+=(-B "$mcp_config_file:$omp_target:ro")
            fi
            ;;
    esac
}
