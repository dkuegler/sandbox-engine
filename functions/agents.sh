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
                -B "$HOME/.claude.json"
            )
            # ~/.config/claude is the alternate settings location; nothing
            # writes it, so mask it read-only instead of leaving it
            # read-write like ~/.claude above.
            bind_ro "$HOME/.config/claude"
            # settings.json/settings.local.json carry hooks (shell commands
            # run on tool events), apiKeyHelper (a shell command run on
            # credential expiry), statusLine (a shell command run per
            # render), and mcpServers (spawned command lines); hooks/ and
            # plugins/ hold executed code; agents/, commands/, skills/,
            # rules/, output-styles/, and CLAUDE.md are prompt/instruction
            # content that persists into the human's next bare-host run.
            # Left read-write: ~/.claude/.credentials.json (OAuth refresh,
            # note the leading dot), ~/.claude.json (rewritten constantly:
            # session state, per-project trust, MCP OAuth tokens), and
            # projects/, shell-snapshots/, todos/, statsig/, file-history/,
            # history.jsonl, ide/.
            for p in settings.json settings.local.json CLAUDE.md \
                     hooks plugins agents commands skills rules output-styles; do
                bind_ro "$HOME/.claude/$p"
            done
            RUN_CMD=(claude "${ARGS[@]}")
            if [[ -n "$GIT_MCP_SOCKET" ]]; then
                local mcp_config_file="$RUN_DIR/claude-mcp.json"
                write_mcp_config "$mcp_config_file" \
                    "{\"mcpServers\":{\"git\":{\"type\":\"stdio\",\"command\":\"nc\",\"args\":[\"-U\",\"$GIT_MCP_SOCKET\"]}}}"
                BINDS+=(-B "$RUN_DIR")
                # Fold every user --mcp-config value into one occurrence together with
                # ours. `--mcp-config` takes space-separated values, so one flag with
                # several values loads all of them; emitting a second occurrence would
                # depend on whether repeats accumulate.
                local -a user_mcp=() rest=()
                local i=0
                while [[ $i -lt ${#ARGS[@]} ]]; do
                    case "${ARGS[$i]}" in
                        --mcp-config)
                            i=$((i + 1))
                            while [[ $i -lt ${#ARGS[@]} && "${ARGS[$i]}" != -* ]]; do
                                user_mcp+=("${ARGS[$i]}")
                                i=$((i + 1))
                            done
                            ;;
                        --mcp-config=*)
                            user_mcp+=("${ARGS[$i]#--mcp-config=}")
                            i=$((i + 1))
                            ;;
                        --strict-mcp-config)
                            i=$((i + 1))
                            ;;
                        *)
                            rest+=("${ARGS[$i]}")
                            i=$((i + 1))
                            ;;
                    esac
                done
                # --strict-mcp-config stays unconditional by decision: user-
                # and project-scope MCP servers from the host (~/.claude.json,
                # .mcp.json, settings.json) name host command lines that
                # either do not exist in the container or are exactly the
                # injection vector the .git masking exists to contain. A user
                # who wants their own servers passes --mcp-config, preserved
                # above.
                RUN_CMD=(claude --mcp-config "$mcp_config_file"
                         ${user_mcp[@]+"${user_mcp[@]}"}
                         --strict-mcp-config ${rest[@]+"${rest[@]}"})
            fi
            ;;
        opencode)
            mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                "$HOME/.local/state/opencode" "$HOME/.opencode"
            BINDS+=(
                -B "$HOME/.config/opencode"
                -B "$HOME/.local/share/opencode"
                -B "$HOME/.local/state/opencode"
            )
            # ~/.opencode is the host install directory holding the
            # opencode binary (the image installs its own at
            # /usr/local/opencode/bin, see sandbox/agent/Dockerfile.template);
            # a writable bind would let the sandbox replace a binary the
            # human then executes on the bare host.
            bind_ro "$HOME/.opencode"
            # opencode.json/opencode.jsonc define mcp.<name>.command arrays,
            # plugin paths, lsp.*.command, formatter.*.command and
            # experimental.hook.* -- all executed; plugin/ is JS/TS loaded
            # at startup. Left read-write: ~/.config/opencode/tui.json
            # (written every session), all of ~/.local/share/opencode
            # except bin/ (auth.json, mcp-auth.json, db.sqlite, storage/,
            # log/, project/), and ~/.local/state/opencode.
            for p in opencode.json opencode.jsonc AGENTS.md \
                     plugin agent command mode tool skill themes; do
                bind_ro "$HOME/.config/opencode/$p"
            done
            bind_ro "$HOME/.local/share/opencode/bin"
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
            # agent/config.yml is only rewritten by an explicit `omp config
            # set`, never on startup, so read-only does not break launch.
            # extensions/ and natives/ (native addons omp loads at
            # startup) are likewise safe to mask. agent/AGENTS.md is the
            # confirmed user-level instruction file (see omp's
            # context-files doc: "~/.omp/agent/AGENTS.md" -- not
            # "~/.omp/AGENTS.md", which does not exist). Left read-write:
            # agent/*.db/-wal/-shm (continuously written),
            # agent/sessions/, agent/cache/, agent/terminal-sessions/,
            # agent/last-changelog-version, cache/, logs/, run/,
            # gpu_cache.json, install-id.
            for p in agent/config.yml agent/models.yml agent/mcp.json agent/.mcp.json \
                     agent/.env .env agent/agents agent/skills agent/tools agent/hooks \
                     agent/commands extensions natives agent/AGENTS.md; do
                bind_ro "$HOME/.omp/$p"
            done
            for p in "$HOME"/.omp/profiles/*/agent/config.yml \
                     "$HOME"/.omp/profiles/*/agent/mcp.json \
                     "$HOME"/.omp/profiles/*/agent/.mcp.json; do
                bind_ro "$p"
            done
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
