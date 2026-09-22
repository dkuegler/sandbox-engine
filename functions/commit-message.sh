#!/bin/bash
# Commit-message generation for --worktree mode (functions/worktree.sh):
# asking an agent to describe a change it did not describe itself. Full
# rationale in docs/commit-message-generation.md; in short:
#
# - Runs IN THE SANDBOX, not the host: the diff handed to the generator
#   is attacker-controlled text the sandboxed agent just wrote. Goes
#   through the sandbox backend against the same image the agent ran in; only
#   the generated stdout text crosses back, for a human to approve.
# - Its bind set is SMALLER than the agent's own: no project checkout or
#   worktree, so an agent-authored CLAUDE.md/AGENTS.md there cannot
#   dictate the generator's own system prompt. AGENT_CONFIG_BINDS
#   (sandbox.sh) is the config-only bind slice, captured automatically
#   from configure_agent's own appends rather than re-listed here.
# - Tools are OFF too (per-agent switches in docs/commit-message-generation.md):
#   containment stops the generator reaching the host, not acting inside
#   a container that holds live credentials and open egress. Worst case
#   surviving both layers: a misleading commit message, shown to the
#   human next to the diff it claims to describe.
#
# Globals published for functions/worktree.sh:
#   COMMIT_MSG_CMD        the agent argv built by commit_msg_build_cmd()
#   COMMIT_MSG_MODEL_NOTE human-readable "which model, chosen how"

# The generator is a single non-interactive turn over a bounded diff; if it
# has not answered in this long it is wedged, and the placeholder path
# (functions/worktree.sh) is a better outcome than a hung run.
COMMIT_MSG_TIMEOUT=180

# ---------------------------------------------------------------------------
# Flag propagation
# ---------------------------------------------------------------------------
# Generation is a DIFFERENT task from the coding run, so the run's own argv
# is not forwarded wholesale. Each flag below was checked against its
# agent's documented behaviour and kept only if it changes *which
# configuration and credentials resolve* -- never what the agent may do,
# never which model the coding run picked, never session continuity.
# docs/commit-message-generation.md carries the full per-flag reasoning,
# including why the obvious candidates are excluded.
#
#   omp     --profile   selects an isolated profile for auth AND settings;
#                       without it the commit role resolves against the
#                       wrong profile and may not even be authenticated.
#           --config    a config.yml overlay can define modelRoles.commit,
#                       which is precisely "the commit model, changed on
#                       the command line". Repeatable, so all occurrences
#                       are kept.
#   claude  --settings / --setting-sources
#                       select which settings files apply, including the
#                       env and credential-helper entries that decide how
#                       the run authenticates.
#   opencode            no equivalent flag exists: its config selection is
#                       environment-driven (OPENCODE_CONFIG,
#                       OPENCODE_CONFIG_DIR), not argv-driven.
#
# Both spellings of every flag are handled: "--flag value" and "--flag=value".
commit_msg_passthrough() {
    COMMIT_MSG_PASSTHROUGH=()
    local -a propagable=()
    case "$AGENT" in
        omp)      propagable=(--profile --config) ;;
        claude)   propagable=(--settings --setting-sources) ;;
        opencode) return 0 ;;
        *)        return 0 ;;
    esac

    local i=0 arg flag
    while [[ $i -lt ${#ARGS[@]} ]]; do
        arg="${ARGS[$i]}"
        for flag in "${propagable[@]}"; do
            if [[ "$arg" == "$flag" ]]; then
                # Value-taking flag: keep the pair, and only the pair. A
                # trailing "--profile" with no value is the user's own
                # error and is dropped rather than swallowing the prompt.
                if [[ $((i + 1)) -lt ${#ARGS[@]} ]]; then
                    COMMIT_MSG_PASSTHROUGH+=("$flag" "${ARGS[$((i + 1))]}")
                    i=$((i + 1))
                fi
                break
            elif [[ "$arg" == "$flag="* ]]; then
                COMMIT_MSG_PASSTHROUGH+=("$arg")
                break
            fi
        done
        i=$((i + 1))
    done
}

# commit_msg_passthrough_value FLAG: the value the run's own argv gives
# FLAG, empty when it does not. Used to find which omp profile/config the
# role lookup below has to read, so the lookup follows the same
# configuration the generator will actually run under.
commit_msg_passthrough_value() {
    local flag="$1" i=0
    while [[ $i -lt ${#COMMIT_MSG_PASSTHROUGH[@]} ]]; do
        if [[ "${COMMIT_MSG_PASSTHROUGH[$i]}" == "$flag" ]]; then
            [[ $((i + 1)) -lt ${#COMMIT_MSG_PASSTHROUGH[@]} ]] && \
                printf '%s\n' "${COMMIT_MSG_PASSTHROUGH[$((i + 1))]}"
            return 0
        elif [[ "${COMMIT_MSG_PASSTHROUGH[$i]}" == "$flag="* ]]; then
            printf '%s\n' "${COMMIT_MSG_PASSTHROUGH[$i]#"$flag"=}"
            return 0
        fi
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------
# omp resolves model ROLES itself: `--model commit` is measured to select
# whatever modelRoles.commit names (git 2.39.5 host, omp v18.2.5 -- the
# reply's own model signature came back as the configured haiku, and an
# unresolvable --model value is refused outright rather than silently
# falling back to the default). So the role name is passed through and omp
# does the resolution, which is what makes --profile/--config overlays take
# effect for free. Reading the model out of config.yml here instead would
# hard-code one profile's answer and ignore both.
#
# The one thing that cannot be delegated is whether the role EXISTS: an
# undefined role is a hard error, which would turn "no commit role
# configured" into a failed generation every single run. Hence a presence
# check -- and only a presence check, never a value extraction -- against
# the same config files the generator will see.
commit_msg_omp_role_defined() {
    local cfg profile
    local -a candidates=()

    profile="$(commit_msg_passthrough_value --profile)"
    if [[ -n "$profile" ]]; then
        # --profile is documented as an ISOLATED profile (auth, sessions,
        # settings, caches), so the base config is deliberately not
        # consulted as a fallback: if the profile does not define the role,
        # the generator runs on the profile's default model.
        candidates+=("$HOME/.omp/profiles/$profile/agent/config.yml")
    else
        candidates+=("$HOME/.omp/agent/config.yml")
    fi
    # Overlays are applied on top of whichever of the above is active and
    # can introduce the role by themselves.
    local i=0
    while [[ $i -lt ${#COMMIT_MSG_PASSTHROUGH[@]} ]]; do
        case "${COMMIT_MSG_PASSTHROUGH[$i]}" in
            --config)   [[ $((i + 1)) -lt ${#COMMIT_MSG_PASSTHROUGH[@]} ]] && \
                            candidates+=("${COMMIT_MSG_PASSTHROUGH[$((i + 1))]}") ;;
            --config=*) candidates+=("${COMMIT_MSG_PASSTHROUGH[$i]#--config=}") ;;
        esac
        i=$((i + 1))
    done

    for cfg in "${candidates[@]}"; do
        [[ -f "$cfg" ]] || continue
        if sed -n '/^modelRoles:/,/^[^[:space:]]/p' "$cfg" 2>/dev/null \
            | grep -q '^[[:space:]]\{1,\}commit:[[:space:]]*[^[:space:]]'; then
            return 0
        fi
    done
    return 1
}

# opencode has no model-role concept, but it does have named AGENTS, and an
# agent carries its own `model` (opencode docs, Agents -> Model). A commit
# agent is therefore the opencode-native spelling of "the model this task
# uses": it is selected with `--agent` and opencode resolves the model
# behind it, exactly as the omp path leaves role resolution to omp. No
# model id is ever hard-coded here, because provider catalogs change and a
# pinned id that disappears would fail every generation from then on.
#
# A bespoke key (e.g. "commit_model") in opencode.json was considered and
# rejected: opencode validates its config with a strict schema that refuses
# unknown keys outright, so shipping one would break the user's own
# opencode rather than just this generator.
#
# Global config only, for the same reason as small_model below: the project
# is deliberately not mounted into the generator's container, so a
# project-scope agent would not exist there to resolve.
COMMIT_MSG_OPENCODE_AGENT='commit'

commit_msg_opencode_agent_defined() {
    local dir="$HOME/.config/opencode" f
    # Markdown agents take their name from the file name. opencode's
    # current layout uses plural subdirectories and keeps the singular ones
    # for backwards compatibility; both are loaded, so both are checked.
    for f in "$dir/agents/$COMMIT_MSG_OPENCODE_AGENT.md" \
             "$dir/agent/$COMMIT_MSG_OPENCODE_AGENT.md"; do
        [[ -f "$f" ]] && return 0
    done
    for f in "$dir/opencode.json" "$dir/opencode.jsonc"; do
        [[ -f "$f" ]] || continue
        commit_msg_json_defines_agent "$f" && return 0
    done
    return 1
}

# commit_msg_json_defines_agent FILE: whether FILE's top-level "agent"
# object defines COMMIT_MSG_OPENCODE_AGENT. Brace depth is tracked instead
# of grepping for the bare name, so the name occurring inside a prompt
# string, a command block or a different agent's body cannot be mistaken
# for a definition. Presence only -- never a value extraction -- because
# resolving the model behind the name is opencode's job.
#
# Both outcomes are safe and visible: a miss falls through to small_model
# or opencode's default, and a false hit fails the run into the placeholder
# path. Either way COMMIT_MSG_MODEL_NOTE names what was chosen.
commit_msg_json_defines_agent() {
    local file="$1" line opens closes tmp
    local depth=0 agent_depth=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        # JSONC comments, but only whole-line ones: stripping from the
        # first "//" anywhere would also truncate a line at the "//" of a
        # URL value and lose the brace that follows it.
        [[ "$line" =~ ^[[:space:]]*// ]] && continue
        if [[ $agent_depth -ge 0 && $depth -eq $agent_depth ]] &&
           [[ "$line" =~ ^[[:space:]]*\"$COMMIT_MSG_OPENCODE_AGENT\"[[:space:]]*: ]]; then
            return 0
        fi
        if [[ $agent_depth -lt 0 && "$line" =~ \"agent\"[[:space:]]*: ]]; then
            agent_depth=$((depth + 1))
            # Compact spelling: "agent": { "commit": { ... } } on one line.
            if [[ "${line#*\"agent\"}" =~ \"$COMMIT_MSG_OPENCODE_AGENT\"[[:space:]]*: ]]; then
                return 0
            fi
        fi
        tmp="${line//[^\{]/}"; opens=${#tmp}
        tmp="${line//[^\}]/}"; closes=${#tmp}
        depth=$((depth + opens - closes))
        [[ $agent_depth -ge 0 && $depth -lt $agent_depth ]] && agent_depth=-1
    done < "$file"
    return 1
}

# `small_model` is the fallback when no commit agent is defined. It is an
# official config field but the wrong one semantically: opencode consults
# it only for its own hardcoded lightweight tasks (title/summary
# generation), never for `opencode run`. There is therefore nothing to
# delegate -- selecting it for this run means naming its value on the
# command line, so the value is read here. Global config only: project
# config is not consulted because the project is deliberately not mounted
# into the generator's container.
commit_msg_opencode_small_model() {
    local cfg
    for cfg in "$HOME/.config/opencode/opencode.json" \
               "$HOME/.config/opencode/opencode.jsonc"; do
        [[ -f "$cfg" ]] || continue
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*\"small_model\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                printf '%s\n' "${BASH_REMATCH[1]}"
                return 0
            fi
        done < "$cfg"
    done
    return 1
}

# commit_msg_model_args: the --model flag (if any) for this agent, plus a
# note naming how it was chosen, which gets logged and shown on failure.
# --commit-model always wins: it is the explicit, agent-independent
# override, and it is the only way to name a model for an agent whose
# configuration does not offer one.
commit_msg_model_args() {
    COMMIT_MSG_MODEL_ARGS=()
    COMMIT_MSG_MODEL_NOTE=""
    # Read by commit_msg_generate: selecting a user-defined agent means its
    # own permission block has to be overridden at agent scope.
    COMMIT_MSG_OPENCODE_AGENT_SELECTED=0
    local value

    if [[ -n "${COMMIT_MODEL:-}" ]]; then
        COMMIT_MSG_MODEL_ARGS=(--model "$COMMIT_MODEL")
        COMMIT_MSG_MODEL_NOTE="$COMMIT_MODEL (--commit-model)"
        return 0
    fi

    case "$AGENT" in
        omp)
            if commit_msg_omp_role_defined; then
                COMMIT_MSG_MODEL_ARGS=(--model commit)
                COMMIT_MSG_MODEL_NOTE="omp's own \"commit\" model role"
            else
                COMMIT_MSG_MODEL_NOTE="omp's default model (no modelRoles.commit configured)"
            fi
            ;;
        claude)
            # "haiku" is a documented built-in model alias, resolved by
            # Claude Code itself against whatever haiku generation it
            # currently ships. No configuration is required for it to work,
            # so unlike the other two agents there is nothing to check.
            COMMIT_MSG_MODEL_ARGS=(--model haiku)
            COMMIT_MSG_MODEL_NOTE="claude's built-in \"haiku\" alias"
            ;;
        opencode)
            if commit_msg_opencode_agent_defined; then
                COMMIT_MSG_MODEL_ARGS=(--agent "$COMMIT_MSG_OPENCODE_AGENT")
                COMMIT_MSG_OPENCODE_AGENT_SELECTED=1
                COMMIT_MSG_MODEL_NOTE="opencode's own \"$COMMIT_MSG_OPENCODE_AGENT\" agent"
            elif value="$(commit_msg_opencode_small_model)"; then
                COMMIT_MSG_MODEL_ARGS=(--model "$value")
                COMMIT_MSG_MODEL_NOTE="$value (opencode's small_model)"
            else
                COMMIT_MSG_MODEL_NOTE="opencode's default model (no \"$COMMIT_MSG_OPENCODE_AGENT\" agent, no small_model)"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# The agent command
# ---------------------------------------------------------------------------
# COMMIT_MSG_CWD is the container's working directory for a generation
# run: it exists, it is empty, and no agent discovers an instruction file
# in it (see the header above for why that matters).
#
# Created inside $scratch with the /tmp prefix STRIPPED, because $scratch
# is itself bound at /tmp: "$scratch$COMMIT_MSG_CWD" would create
# /tmp/tmp/commit-msg-cwd inside the container and leave --cwd pointing
# at a directory that does not exist (docs/commit-message-generation.md
# has the measured failure mode).
COMMIT_MSG_CWD='/tmp/commit-msg-cwd'

# commit_msg_build_cmd PROMPT: the agent argv, hardened per agent.
#
# The prompt is one argv string for all three agents. Their file-attach
# mechanisms all differ (omp's "@file", claude's stdin pipe, opencode's
# -f), and the diff is already truncated to a bounded number of lines by
# the caller, so one shape that works identically everywhere beats three
# that each need their own verification.
commit_msg_build_cmd() {
    local prompt="$1"
    COMMIT_MSG_CMD=()
    commit_msg_passthrough
    commit_msg_model_args

    case "$AGENT" in
        omp)
            # --no-tools/--no-lsp remove the execution surface; the four
            # discovery switches stop anything on disk from being loaded as
            # instructions. --cwd is passed in addition to the backend's own
            # --cwd because omp documents relocating itself out of $HOME on
            # its own, and this is the agent whose behaviour is directly
            # testable here.
            COMMIT_MSG_CMD=(omp -p
                --no-tools --no-lsp --no-extensions --no-skills --no-rules
                --no-session --no-title
                --cwd "$COMMIT_MSG_CWD")
            ;;
        claude)
            # --bare is Claude Code's own documented minimal mode: no
            # hooks, skills, custom commands, subagents, plugins, MCP
            # servers, auto memory or CLAUDE.md discovery. It deliberately
            # still leaves Bash/read/edit available, so --tools "" (the
            # documented "disable all" value) is what actually removes the
            # execution surface. --strict-mcp-config with no --mcp-config
            # leaves no MCP server configurable at all.
            COMMIT_MSG_CMD=(claude -p --bare --tools "" --strict-mcp-config)
            ;;
        opencode)
            # opencode has no --no-tools flag; tool availability is config,
            # not argv. Its schema accepts a bare-string PermissionConfig,
            # so "permission":"deny" denies EVERY tool -- including ones
            # added upstream later, which an enumerated tools:{} map would
            # silently start allowing. Delivered through
            # OPENCODE_CONFIG_CONTENT (opencode's documented inline-config
            # env var, which overrides global, custom and project config)
            # in commit_msg_generate below.
            COMMIT_MSG_CMD=(opencode run)
            ;;
        *)
            return 1
            ;;
    esac

    COMMIT_MSG_CMD+=(${COMMIT_MSG_MODEL_ARGS[@]+"${COMMIT_MSG_MODEL_ARGS[@]}"})
    COMMIT_MSG_CMD+=(${COMMIT_MSG_PASSTHROUGH[@]+"${COMMIT_MSG_PASSTHROUGH[@]}"})
    COMMIT_MSG_CMD+=("$prompt")
}

# commit_msg_available: whether a sandboxed generation can even be
# attempted. `script` is a run mode rather than an agent -- there is no
# agent CLI in the image to ask -- and a missing image or runtime means
# the same thing as a failed generation: the placeholder path takes over.
commit_msg_available() {
    case "$AGENT" in
        claude|opencode|omp) ;;
        *) return 1 ;;
    esac
    backend_available || return 1
    backend_image_present || return 1
    return 0
}

# commit_msg_generate OUT PROMPT: run the generator in its own container
# and leave its answer in OUT. Returns non-zero on any failure, leaving the
# caller to fall back to a placeholder -- generation is a convenience, and
# no failure here may block the human from reviewing the change.
commit_msg_generate() {
    local out="$1" prompt="$2" rc=0
    local scratch="$RUN_DIR/commit-msg"

    if ! commit_msg_available; then
        echo "worktree: no sandboxed generator available for agent '$AGENT'" >&2
        return 1
    fi
    if ! commit_msg_build_cmd "$prompt"; then
        return 1
    fi

    # The scratch directory becomes the container's whole /tmp, so the
    # generator gets a private, empty, writable temp space and an empty
    # cwd. It lives under RUN_DIR, which remove_run_dir()/
    # reap_orphaned_run_dirs() (functions/run-dir.sh) already own, so this
    # adds no new cleanup path.
    rm -rf "$scratch"
    mkdir -p "$scratch${COMMIT_MSG_CWD#/tmp}" || return 1  # Strip /tmp: $scratch IS /tmp in container

    # Same containment as the agent's own launch, minus the checkout
    # (backend_generator_argv, functions/apptainer.sh).
    backend_generator_argv "$COMMIT_MSG_CWD" "$scratch" "${COMMIT_MSG_CMD[@]}"
    local -a argv=("${BACKEND_ARGV[@]}")

    log_info "commit message: generating in the sandbox with ${COMMIT_MSG_MODEL_NOTE:-the default model}"
    log_argv "commit-message $SANDBOX_BACKEND argv" "${argv[@]}"

    # Subshell, so the opencode override cannot leak into the environment
    # of the NEXT agent run: the reject menu's "re-run" path re-executes
    # the real agent from this same shell, and an inherited
    # permission:"deny" would silently cripple it. backend_forward_env
    # keeps the value off every command line (functions/apptainer.sh).
    (
        if [[ "$AGENT" == "opencode" ]]; then
            # Config sources are MERGED, and an agent's own settings override
            # the global ones -- so a user-defined commit agent carrying
            # `permission: {bash: allow}`, or the deprecated but still
            # schema-valid `tools: {bash: true}` (documented as equivalent
            # to `{"*": "allow"}`), would hand tools back to the one run
            # that must not have them. Inline config is the
            # highest-precedence user tier, so both spellings are denied
            # again at agent scope, and only when that agent was actually
            # selected: injecting the key otherwise would invent a nameless
            # agent that fails opencode's own schema (`description` is
            # required).
            if [[ "${COMMIT_MSG_OPENCODE_AGENT_SELECTED:-0}" -eq 1 ]]; then
                backend_forward_env OPENCODE_CONFIG_CONTENT "{\"permission\":\"deny\",\"agent\":{\"$COMMIT_MSG_OPENCODE_AGENT\":{\"permission\":\"deny\",\"tools\":{\"*\":false}}}}"
            else
                backend_forward_env OPENCODE_CONFIG_CONTENT '{"permission":"deny"}'
            fi
        fi
        if command -v timeout >/dev/null 2>&1; then
            exec timeout "$COMMIT_MSG_TIMEOUT" "${argv[@]}"
        else
            exec "${argv[@]}"
        fi
    ) >"$out" 2>/dev/null || rc=$?

    if [[ "$rc" -ne 0 ]] || ! grep -q '[^[:space:]]' "$out" 2>/dev/null; then
        echo "worktree: sandboxed message generation failed (exit $rc, ${COMMIT_MSG_MODEL_NOTE:-default model})" >&2
        return 1
    fi
    chmod 600 "$out"
    return 0
}
