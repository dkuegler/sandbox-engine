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
                # OPENCODE_CONFIG_CONTENT is merged last over every config
                # file (https://opencode.ai/docs/config/ "Precedence
                # order"), so this adds the git server without reading,
                # rewriting, or shadowing the user's own global/project
                # config or their own OPENCODE_CONFIG.
                #
                # APPTAINERENV_-prefixed, not --env: apptainer strips the
                # prefix and sets the variable inside the container, so the
                # value never appears in the world-readable
                # /proc/<pid>/cmdline of the apptainer process.
                # /proc/<pid>/environ is owner-only.
                export APPTAINERENV_OPENCODE_CONFIG_CONTENT="{\"mcp\":{\"git\":{\"type\":\"local\",\"command\":[\"nc\",\"-U\",\"$GIT_MCP_SOCKET\"],\"enabled\":true}}}"
                BINDS+=(-B "$RUN_DIR")
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
            # extensions/ is likewise safe to mask. natives/ (the
            # ~180 MB pi_natives addon omp self-extracts on first run of a
            # given version, into ~/.omp/natives/<version>/) is left
            # read-write on purpose: masking it read-only breaks startup
            # with an EROFS mkdir the moment the image's omp is upgraded to
            # a version whose native addon the host has never extracted
            # before (see notes/handoffs for the incident). agent/AGENTS.md
            # is the confirmed user-level instruction file (see omp's
            # context-files doc: "~/.omp/agent/AGENTS.md" -- not
            # "~/.omp/AGENTS.md", which does not exist). Left read-write:
            # agent/*.db/-wal/-shm (continuously written),
            # agent/sessions/, agent/cache/, agent/terminal-sessions/,
            # agent/last-changelog-version, cache/, logs/, run/,
            # gpu_cache.json, install-id, natives/.
            for p in agent/config.yml agent/models.yml agent/mcp.json agent/.mcp.json \
                     agent/.env .env agent/agents agent/skills agent/tools agent/hooks \
                     agent/commands extensions agent/AGENTS.md; do
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

                # omp's own discovery is first-found-wins over
                # .omp/mcp.json then .omp/.mcp.json, so merging whichever
                # exists into the file bound over mcp.json preserves it
                # instead of shadowing it. A zero-byte file is not valid
                # JSON (and is how earlier runs of this script leave a
                # placeholder behind, see OMP_MCP_PLACEHOLDER below), so
                # it is treated the same as "absent" rather than fed to
                # the python3 merge below.
                local src=""
                if [[ -s "$omp_dir/mcp.json" ]]; then
                    src="$omp_dir/mcp.json"
                elif [[ -s "$omp_dir/.mcp.json" ]]; then
                    src="$omp_dir/.mcp.json"
                fi

                if [[ -n "$src" ]] && ! command -v python3 >/dev/null 2>&1; then
                    echo "error: merging $src needs python3 on the host; install python3 or move the file aside" >&2
                    exit 1
                fi

                # Pick our server name: "git", unless the source config
                # already defines one by that name, in which case fall
                # back to "sandbox-git" rather than prompt or fail.
                local name="git"
                if [[ -n "$src" ]] && command -v python3 >/dev/null 2>&1 && python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    cfg = json.load(fh)
sys.exit(0 if "git" in cfg.get("mcpServers", {}) else 1)
' "$src" 2>/dev/null; then
                    name="sandbox-git"
                    echo "note: project .omp config already defines an MCP server named \"git\"; exposing the sandbox git sidecar as \"sandbox-git\" instead" >&2
                fi

                # 0600 is applied before any content exists (write_mcp_config
                # truncates and chmods before writing); python3 below then
                # overwrites the contents.
                write_mcp_config "$mcp_config_file" '{}'
                if command -v python3 >/dev/null 2>&1; then
                    if ! python3 - "$src" "$mcp_config_file" "$name" "$GIT_MCP_SOCKET" <<'PY'
import json, sys
src, out, name, sock = sys.argv[1:5]
cfg = {}
if src:
    with open(src) as fh:
        cfg = json.load(fh)
cfg.setdefault("mcpServers", {})[name] = {
    "type": "stdio", "command": "nc", "args": ["-U", sock],
}
with open(out, "w") as fh:
    json.dump(cfg, fh)
PY
                    then
                        echo "error: $src is not valid JSON; fix it or move it aside" >&2
                        exit 1
                    fi
                else
                    # No source config and no python3: nothing to merge,
                    # so keep the direct write (today's path).
                    write_mcp_config "$mcp_config_file" \
                        "{\"mcpServers\":{\"$name\":{\"type\":\"stdio\",\"command\":\"nc\",\"args\":[\"-U\",\"$GIT_MCP_SOCKET\"]}}}"
                fi

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
