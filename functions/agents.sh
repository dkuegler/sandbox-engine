#!/bin/bash
# Per-agent config: bind mounts for each agent's persistent state and the
# RUN_CMD to exec. Git access no longer routes through this file (decided
# 2026-09-17): the agent image ships `git` directly, and the read-only
# `.git` mask (functions/git-mask.sh) is the only control, so there is no
# per-agent MCP server to wire up here.

# ensure_run_dir: create the per-run scratch directory on first use. Used
# today only by the omp branch's secrets redaction; remove_run_dir()
# (functions/run-dir.sh) removes it unconditionally on exit, as a hook on
# the EXIT trap (functions/cleanup.sh). Writes this shell's PID into the
# directory so reap_orphaned_run_dirs() (functions/run-dir.sh) can tell a
# leaked directory (owner process gone) from one still in active use.
ensure_run_dir() {
    if [[ -z "${RUN_DIR:-}" ]]; then
        RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-engine.XXXXXX")"
        chmod 700 "$RUN_DIR"
        echo "$$" > "$RUN_DIR/.owner_pid"
    fi
}

# force_omp_secrets_redaction SRC OUT: copy SRC (config.yml) to OUT with
# "secrets: enabled: true" appended, forcing on omp's built-in secret
# obfuscator (docs/secrets.md) inside the sandbox regardless of the host's
# own setting -- disabled by default upstream. This matters independently
# of *how* a credential reaches the container: measured live, omp's own
# bash tool does not scrub environment variables (`env`/`printenv` return
# a forwarded APPTAINERENV_* value in full), so without this, a
# host-supplied credential the agent chooses to print reaches the model
# verbatim. The obfuscator auto-detects env vars matching
# KEY/SECRET/TOKEN/PASSWORD/PASS/AUTH/CREDENTIAL/PRIVATE/OAUTH plus
# built-in GitLab/GitHub/OpenAI/Anthropic/AWS token-shape regexes, and only
# redacts provider-visible text -- the real value still reaches the actual
# API call. This is about a secret passed in from outside (a forge
# token); a secret the agent generates itself during a session is not this
# task's concern.
# Refuses to touch a config.yml that already defines a top-level `secrets:`
# block -- no YAML parser is available to merge into one safely (same
# constraint as elsewhere in this file: don't assume python3/its libraries) -- and warns
# instead of silently leaving redaction off.
force_omp_secrets_redaction() {
    local src="$1" out="$2"
    if [[ ! -f "$src" ]]; then
        printf 'secrets:\n  enabled: true\n' > "$out"
        chmod 600 "$out"
        echo "note: $src not found; using a minimal config with secrets.enabled: true for this sandboxed run." >&2
        return 0
    fi
    cp "$src" "$out"
    chmod 600 "$out"
    if grep -q '^secrets:' "$src"; then
        if ! grep -qE '^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$' "$src"; then
            echo "warning: $src already defines a top-level 'secrets:' block; not overriding it." >&2
            echo "         Confirm 'secrets.enabled: true' yourself -- without it, a host-supplied" >&2
            echo "         credential the agent's own tool output prints (e.g. \`env\`) reaches the" >&2
            echo "         model in plaintext instead of a redacted placeholder." >&2
        fi
        return 0
    fi
    printf '\nsecrets:\n  enabled: true\n' >> "$out"
    echo "note: $src does not set secrets.enabled; enabling omp's secret obfuscation for this" >&2
    echo "      sandboxed run only -- without it, a host-supplied credential the agent's" >&2
    echo "      own tool output prints (e.g. \`env\`) reaches the model in plaintext." >&2
}

# require_host_env VAR CONTEXT: forward the host's VAR into the container
# via APPTAINERENV_ if this shell's environment has it set (e.g. because
# the user exported it in ~/.bashrc), otherwise refuse to launch instead
# of silently starting an agent that will fail to authenticate. CONTEXT
# names the config file:line that referenced VAR, for the error message.
# No token name is ever hardcoded here -- VAR is whatever name the
# user's own config already references.
require_host_env() {
    local var="$1" context="$2"
    if [[ -z "${!var+x}" ]]; then
        echo "error: $context references \$$var, but it is not set in this shell's environment." >&2
        echo "       export it (e.g. add \"export $var=...\" to ~/.bashrc) and re-run." >&2
        exit 1
    fi
    # APPTAINERENV_-prefixed, not --env: apptainer strips the prefix and
    # sets the variable inside the container, so the value never appears
    # in the world-readable /proc/<pid>/cmdline of the apptainer process;
    # /proc/<pid>/environ is owner-only. commit_msg_generate()
    # (functions/commit-message.sh) forwards OPENCODE_CONFIG_CONTENT the
    # same way, for the same reason.
    export "APPTAINERENV_$var=${!var}"
}

# scan_omp_api_keys FILE: forward every apiKey that is already a bare
# env-var-name reference (omp's own "env-name-or-literal" resolution --
# see docs/models.md "Model-level fields") from this shell's environment
# into the container, and refuse to launch if the config still carries a
# literal secret. A live credential belongs in the user's shell (e.g.
# ~/.bashrc), referenced here by name -- not written into a file every
# sandbox run mounts and every session transcript can echo back.
scan_omp_api_keys() {
    local file="$1" line lineno=0 value
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*apiKey:[[:space:]]*\"?([^\"[:space:]]+)\"?[[:space:]]*$ ]] || continue
        value="${BASH_REMATCH[1]}"
        case "$value" in
            '!'*) continue ;; # command-resolved secret; already opaque to the sandbox
        esac
        if [[ "$value" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            require_host_env "$value" "$file:$lineno"
        else
            echo "error: $file:$lineno sets apiKey to a literal value." >&2
            echo "       Move it to an environment variable (e.g. export it in ~/.bashrc) and" >&2
            echo "       set apiKey to that variable's name instead -- or use omp's \"!cmd\"" >&2
            echo "       command-resolved secret syntax (docs/models.md). Refusing to mount a" >&2
            echo "       config file carrying a live credential into every sandbox run." >&2
            exit 1
        fi
    done < "$file"
}

# scan_opencode_api_keys FILE: same contract as scan_omp_api_keys, for
# opencode's "{env:VAR}" config substitution syntax
# (https://opencode.ai/docs/config/). Note opencode issues #19946/#27853
# report "{env:...}" not resolving for a custom provider's apiKey; that is
# an upstream bug this scan does not route around -- it forwards the
# named variable exactly as opencode's own docs say to reference it, and
# refuses a literal secret the same way scan_omp_api_keys does.
scan_opencode_api_keys() {
    local file="$1" line lineno=0 value var
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*\"apiKey\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*,?[[:space:]]*$ ]] || continue
        value="${BASH_REMATCH[1]}"
        case "$value" in
            '{env:'*'}')
                var="${value#\{env:}"
                var="${var%\}}"
                require_host_env "$var" "$file:$lineno"
                ;;
            '{file:'*'}') continue ;; # already file-indirected
            *)
                echo "error: $file:$lineno sets apiKey to a literal value." >&2
                echo "       Move it to an environment variable (e.g. export it in ~/.bashrc) and" >&2
                echo "       reference it as \"{env:VAR_NAME}\" instead. Refusing to mount a config" >&2
                echo "       file carrying a live credential into every sandbox run." >&2
                exit 1
                ;;
        esac
    done < "$file"
}

# LIMITATIONS_NOTICE_MARKER: fixed marker appended to each agent's
# always-loaded instruction file, pointing at the generated lookup file.
# Fixed so re-generating the overlay next run is idempotent instead
# of accumulating copies of the note.
LIMITATIONS_NOTICE_MARKER='<!-- sandbox-engine: sandboxed session -->'

# generate_limitations_file OUT: writes the lookup file everything except
# the two-sentence pointer goes into, so the always-loaded instruction
# file (CLAUDE.md/AGENTS.md) stays short. Static git-behavior facts (what
# the read-only `.git` mask does and does not block) plus a filesystem
# section built from this run's actual resolved binds, not a guess --
# PROJECT_DIR, every extra bind from resolve_extra_binds() with its
# resolved ro/rw (functions/binds.sh), and whatever is already in
# RO_MASKED at the point this is called (sandbox.yml; per-agent tool
# config added later by configure_agent's own branches is not user
# task-relevant and is left out on purpose).
generate_limitations_file() {
    local out="$1" j p mode
    {
        echo "# Sandbox limitations"
        echo
        echo "This session runs inside \`sandbox-engine\`, an apptainer sandbox. Two"
        echo "things are restricted relative to a bare host shell: git write access,"
        echo "and which host paths are reachable from here. If something looks"
        echo "blocked, it probably is -- retrying with different flags will not"
        echo "change that."
        echo
        echo "## Git"
        echo
        echo "- \`push\` succeeds against the read-only \`.git\` mask (the remote is"
        echo "  updated); only the local \`refs/remotes/*\` tracking-ref update fails --"
        echo "  expect one \`error: update_ref failed\` line, harmless, and the command"
        echo "  still exits 0."
        echo "- \`fetch --no-write-fetch-head\` can sync from upstream; plain \`fetch\`"
        echo "  fails with \`Read-only file system\`."
        echo "- \`status\`/\`diff\` work normally."
        echo "- History-rewriting commands (\`commit\`, \`checkout\`, \`switch\`,"
        echo "  \`merge\`, \`rebase\`, \`stash\`, \`branch -d/-c\`, \`worktree add\`,"
        echo "  \`gc\`, ...) fail at lock creation with \`Read-only file system\`. This"
        echo "  holds no matter which \`git\` binary is in use -- the one already in"
        echo "  this image, or one fetched or installed during this session."
        echo "- Remote URLs and credential references are redacted from every"
        echo "  \`.git\` this container can read (\`config\`, \`FETCH_HEAD\`, the"
        echo "  reflog); \`git log origin/master\` and ahead/behind counts still"
        echo "  work, but \`git remote -v\` shows a placeholder instead of the real"
        echo "  URL."
        echo
        echo "## Filesystem"
        echo
        if [[ -n "${WORKTREE_DIR:-}" ]]; then
            echo "- \`$WORKTREE_DIR\` -- read-write. **This is the working directory**"
            echo "  and the only place changes are collected from."
            mode="read-only"
            [[ "${WORKTREE_PROJECT_RO:-1}" -eq 1 ]] || mode="read-write"
            echo "- \`$PROJECT_DIR\` -- $mode (the project's main checkout)."
        else
            echo "- \`$PROJECT_DIR\` -- read-write (the project this session sandboxes)."
        fi
        for ((j = 0; j < ${#EXTRA_BIND_SRCS[@]}; j++)); do
            mode="read-write"
            [[ "${EXTRA_BIND_RO[$j]}" -eq 1 ]] && mode="read-only"
            echo "- \`${EXTRA_BIND_SRCS[$j]}\` -- $mode."
        done
        for p in ${RO_MASKED[@]+"${RO_MASKED[@]}"}; do
            echo "- \`$p\` -- read-only."
        done
        if [[ -n "${WORKTREE_DIR:-}" ]]; then
            echo
            echo "## Worktree mode"
            echo
            echo "This session runs in a throwaway git worktree checked out on"
            echo "\`$WORKTREE_REF\`, not in the project's main checkout."
            echo
            echo "- The working directory is \`$WORKTREE_DIR\`. Make every change there."
            echo "- **A worktree holds only files git tracks.** Anything untracked or"
            echo "  \`.gitignore\`d in the main checkout -- local notes directories,"
            echo "  \`.env\` files, build output, virtualenvs -- is NOT here. Look for it"
            echo "  under \`$PROJECT_DIR\` (the main checkout) before concluding it does"
            echo "  not exist."
            if [[ "${WORKTREE_PROJECT_RO:-1}" -eq 1 ]]; then
                echo "- \`$PROJECT_DIR\` is read-only this session: read from it freely,"
                echo "  write only inside the worktree."
            fi
            echo "- You cannot commit. Every \`.git\` is read-only, as above, and a"
            echo "  worktree shares the main repository's object store and refs, so that"
            echo "  is deliberate. A human reviews your change on the host after this"
            echo "  session exits and commits it there."
            echo "- **Write your proposed commit message to \`\$HOME/$WORKTREE_MSG_NAME\`**"
            echo "  before you finish. It starts empty and is read back on the host. Use"
            echo "  exactly this shape:"
            echo
            worktree_message_template | sed 's/^/      /'
            echo
            echo "  Add an \`Additional Notes:\` block after it only if something genuinely"
            echo "  does not fit under Issue or Solution. If you leave the file empty, one"
            echo "  is generated from your diff by a second, tool-less sandbox run instead."
        fi
        echo
        echo "Nothing outside these paths is reachable from this container."
    } >"$out"
    chmod 600 "$out"
}

# bind_augmented_instructions REAL: overlay REAL (a host instruction file
# such as CLAUDE.md/AGENTS.md -- may not exist yet) with a read-only copy
# that additionally points at the generated limitations lookup file,
# unless REAL already carries the same marker. Same "sanitized copy bound
# over the real path" technique force_omp_secrets_redaction already uses
# above, so a project's own instruction content survives untouched
# underneath the appended note.
#
# Worktree mode appends a second, run-specific block naming the two paths
# and the commit-message file. That block is deliberately NOT behind the
# marker check: the marker only guards the static notice, and the worktree
# facts (which directory is writable, where the main checkout is, what
# file to write) are the ones an agent needs before its first tool call,
# not after it thinks to read a lookup file. Most importantly it says
# where to look for the untracked/ignored files a worktree does not have.
bind_augmented_instructions() {
    local real="$1" out
    ensure_run_dir
    out="$RUN_DIR/instructions-$(basename "$real")-$(echo -n "$real" | cksum | cut -d' ' -f1)"
    if [[ -f "$real" ]]; then
        cp "$real" "$out"
    else
        : >"$out"
    fi
    if ! grep -qF "$LIMITATIONS_NOTICE_MARKER" "$out" 2>/dev/null; then
        {
            echo
            echo "$LIMITATIONS_NOTICE_MARKER"
            echo "This session is sandboxed: git write access and host filesystem reach"
            echo "are restricted. Read \$HOME/.sandbox-limitations.md before assuming a"
            echo "host-level capability."
        } >>"$out"
    fi
    if [[ -n "${WORKTREE_DIR:-}" ]]; then
        {
            echo
            echo "$LIMITATIONS_NOTICE_MARKER worktree"
            echo "This session runs in a throwaway git worktree on branch \`$WORKTREE_REF\`:"
            echo "- Working directory: \`$WORKTREE_DIR\` (read-write). Change files here."
            echo "- Main checkout: \`$PROJECT_DIR\` (read-only). A worktree contains only"
            echo "  git-tracked files, so anything untracked or gitignored -- notes"
            echo "  directories, \`.env\`, build output -- lives there, not here. Search"
            echo "  the main checkout before concluding a file does not exist."
            echo "- You cannot commit: every \`.git\` is read-only. Write the commit"
            echo "  message to \`\$HOME/$WORKTREE_MSG_NAME\` and a human reviews and"
            echo "  commits it on the host. See \$HOME/.sandbox-limitations.md."
        } >>"$out"
    fi
    chmod 600 "$out"
    BINDS+=(-B "$out:$real:ro")
}

configure_agent() {
    # shellcheck disable=SC2034  # AGENT_ENV is read by sandbox.sh's EXEC_ARGV after configure_agent returns
    AGENT_ENV=()

    if [[ "$AGENT" != "script" ]]; then
        ensure_run_dir
        local limitations_file="$RUN_DIR/sandbox-limitations.md"
        generate_limitations_file "$limitations_file"
        BINDS+=(-B "$limitations_file:$HOME/.sandbox-limitations.md:ro")
        # --worktree mode: the one file in this whole sandbox the agent is
        # given read-WRITE for a purpose other than editing the project --
        # its own proposed commit message, read back on the host after the
        # container exits (functions/worktree.sh). It lives in RUN_DIR, so
        # remove_run_dir()/reap_orphaned_run_dirs() (functions/run-dir.sh)
        # already own its lifecycle, and it is mounted under $HOME rather
        # than in the worktree so it cannot end up inside the commit it
        # describes.
        if [[ -n "${WORKTREE_DIR:-}" ]]; then
            WORKTREE_MSG_HOST="$RUN_DIR/commit-message"
            : >"$WORKTREE_MSG_HOST"
            chmod 600 "$WORKTREE_MSG_HOST"
            BINDS+=(-B "$WORKTREE_MSG_HOST:$HOME/$WORKTREE_MSG_NAME")
        fi
    fi

    # Everything appended to BINDS from here on is this agent's own
    # config/credential state, and nothing else: the project dir, the
    # worktree, the extra binds and the .git masks were all added by
    # sandbox.sh before this function was called, and the two run-specific
    # files above were added just now. sandbox.sh slices BINDS at this
    # index into AGENT_CONFIG_BINDS, which is the whole bind set the
    # sandboxed commit-message generator gets (functions/commit-message.sh)
    # -- so a per-agent config bind added to the case below is carried
    # there automatically rather than having to be remembered twice.
    # shellcheck disable=SC2034  # AGENT_CONFIG_BIND_START is read by sandbox.sh after configure_agent returns
    AGENT_CONFIG_BIND_START=${#BINDS[@]}

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
            for p in settings.json settings.local.json \
                     hooks plugins agents commands skills rules output-styles; do
                bind_ro "$HOME/.claude/$p"
            done
            # CLAUDE.md is the always-loaded instruction file: overlay
            # it with a copy of itself plus a pointer at the generated
            # limitations lookup file, instead of a plain read-only bind.
            bind_augmented_instructions "$HOME/.claude/CLAUDE.md"
            # Fold every user --mcp-config value into one occurrence and
            # force --strict-mcp-config unconditionally: user- and
            # project-scope MCP servers from the host (~/.claude.json,
            # .mcp.json, settings.json) name host command lines that
            # either do not exist in the container or are exactly the
            # injection vector the .git masking exists to contain. A user
            # who wants their own servers passes --mcp-config, preserved
            # below. `--mcp-config` takes space-separated values, so one
            # flag with several values loads all of them; emitting a
            # second occurrence would depend on whether repeats accumulate.
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
            local -a mcp_flag=()
            [[ ${#user_mcp[@]} -gt 0 ]] && mcp_flag=(--mcp-config "${user_mcp[@]}")
            RUN_CMD=(claude ${mcp_flag[@]+"${mcp_flag[@]}"}
                     --strict-mcp-config ${rest[@]+"${rest[@]}"})
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
            for p in opencode.json opencode.jsonc \
                     plugin agent command mode tool skill themes; do
                case "$p" in
                    opencode.json | opencode.jsonc)
                        scan_opencode_api_keys "$HOME/.config/opencode/$p"
                        ;;
                esac
                bind_ro "$HOME/.config/opencode/$p"
            done
            # AGENTS.md is the always-loaded instruction file.
            bind_augmented_instructions "$HOME/.config/opencode/AGENTS.md"
            bind_ro "$HOME/.local/share/opencode/bin"
            RUN_CMD=(opencode "${ARGS[@]}")
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
            # before. agent/AGENTS.md
            # is the confirmed user-level instruction file (see omp's
            # context-files doc: "~/.omp/agent/AGENTS.md" -- not
            # "~/.omp/AGENTS.md", which does not exist). Left read-write:
            # agent/*.db/-wal/-shm (continuously written),
            # agent/sessions/, agent/cache/, agent/terminal-sessions/,
            # agent/last-changelog-version, cache/, logs/, run/,
            # gpu_cache.json, install-id, natives/.
            ensure_run_dir
            local omp_config_copy="$RUN_DIR/omp-config.yml"
            force_omp_secrets_redaction "$HOME/.omp/agent/config.yml" "$omp_config_copy"
            BINDS+=(-B "$omp_config_copy:$HOME/.omp/agent/config.yml:ro")
            for p in agent/models.yml agent/mcp.json agent/.mcp.json \
                     agent/.env .env agent/agents agent/skills agent/tools agent/hooks \
                     agent/commands extensions; do
                if [[ "$p" == agent/models.yml ]]; then
                    scan_omp_api_keys "$HOME/.omp/$p"
                fi
                bind_ro "$HOME/.omp/$p"
            done
            # agent/AGENTS.md is the always-loaded instruction file.
            bind_augmented_instructions "$HOME/.omp/agent/AGENTS.md"
            for p in "$HOME"/.omp/profiles/*/agent/config.yml \
                     "$HOME"/.omp/profiles/*/agent/mcp.json \
                     "$HOME"/.omp/profiles/*/agent/.mcp.json; do
                bind_ro "$p"
            done
            RUN_CMD=(omp "${ARGS[@]}")
            ;;
        script)
            # Generic run mode, not an agent: RUN_CMD is exec'd verbatim
            # from the caller's own trailing argv, e.g.
            #   ./sandbox.sh script tests/git-escape/probe.sh <project-dir>
            # instead of an agent CLI. bind tests/ read-only so a bespoke
            # test script living there (like probe.sh, run by
            # tests/git-escape/run.sh) is visible at the same path inside
            # the container. Deliberately not a bespoke apptainer
            # invocation: the mask a script asserts is built by
            # mask_git_readonly and resolve_extra_binds, so a harness with
            # its own exec line would verify a launch path nobody uses.
            bind_ro "$SCRIPT_DIR/tests"
            # shellcheck disable=SC2034  # RUN_CMD is read by sandbox.sh's EXEC_ARGV after configure_agent returns
            RUN_CMD=("${ARGS[@]}")
            ;;
    esac
}
