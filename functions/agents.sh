#!/bin/bash
# Per-agent config: bind mounts for each agent's persistent state and the
# RUN_CMD to exec. Git access no longer routes through this file (decided
# 2026-09-17): the agent image ships `git` directly, and the read-only
# `.git` mask (functions/git-mask.sh) is the only control, so there is no
# per-agent MCP server to wire up here.

# ensure_run_dir: create the per-run scratch directory on first use -- the
# home of every per-run copy and overlay the sandbox binds; remove_run_dir()
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

# project_state_key: "<basename>-<8 hex>" of the checkout, the same key
# --worktree uses under ~/.agent/worktrees, so both modes -- and every
# worktree of one repository -- share one set of sandbox-owned per-project
# state (omp's history and logs, opencode's data directory).
project_state_key() {
    local top="${WORKTREE_REPO_ROOT:-$PROJECT_DIR}"
    printf '%s-%s' "$(basename "$top")" "$(printf '%s' "$top" | sha256sum | cut -c1-8)"
}

# require_host_env VAR CONTEXT: forward the host's VAR into the container
# via backend_forward_env if this shell's environment has it set (e.g. because
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
    # backend_forward_env (functions/apptainer.sh) keeps the value off
    # every command line. commit_msg_generate()
    # (functions/commit-message.sh) forwards OPENCODE_CONFIG_CONTENT the
    # same way, for the same reason.
    backend_forward_env "$var" "${!var}"
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
        echo "This session runs inside \`sandbox-engine\` (backend: $SANDBOX_BACKEND). Two"
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
            case "${WORKTREE_PROJECT_MODE:-ro}" in
                rw) echo "- \`$PROJECT_DIR\` -- read-write (the project's main checkout)." ;;
                deny) echo "- \`$PROJECT_DIR\` -- not mounted (denied); only its \`.git\` is reachable, read-only." ;;
                *) echo "- \`$PROJECT_DIR\` -- read-only (the project's main checkout)." ;;
            esac
        else
            echo "- \`$PROJECT_DIR\` -- read-write (the project this session sandboxes)."
        fi
        for ((j = 0; j < ${#EXTRA_BIND_SRCS[@]}; j++)); do
            mode="read-write"
            [[ "${EXTRA_BIND_RO[$j]}" -eq 1 ]] && mode="read-only"
            echo "- \`${EXTRA_BIND_SRCS[$j]}\` -- $mode."
        done
        for p in ${RO_MASKED[@]+"${RO_MASKED[@]}"}; do
            # "PATH (state)" entries carry their state after the code span.
            if [[ "$p" == *" ("*")" ]]; then
                p="${p%)}"
                echo "- \`${p% (*}\` -- ${p##* (}."
            else
                echo "- \`$p\` -- read-only."
            fi
        done
        # claude's $HOME is a per-run directory (functions/claude-home.sh).
        if [[ "${AGENT:-}" == claude ]]; then
            echo "- Anything else you create under \`\$HOME\` is per-run scratch: it works"
            echo "  for this session and is discarded when it ends."
        fi
        echo
        echo "## Project config and instruction files are read-only"
        echo
        echo "Config paths under the project root (agent settings, MCP servers,"
        echo "hooks, plugins, editor tasks, .envrc, pre-commit config,"
        echo "sandbox.yml) run on the human's next bare-host interaction, and"
        echo "instruction files (AGENTS.md, CLAUDE.md, rules directories) load"
        echo "into their next agent session, so this session may not change them."
        echo "Their state this run is in the list above."
        echo
        echo "- committed: read-only by design (EROFS). Don't delete and recreate"
        echo "  it, write it elsewhere, or retry; propose a change instead (below)."
        echo "- uncommitted: hidden -- you see an empty file or the committed"
        echo "  version. A config path that looks missing may be a hidden local"
        echo "  file; don't reconstruct it. Other uncommitted files (source, data,"
        echo "  build output) are unaffected."
        echo "- not present: you may create it. It does not load this session; the"
        echo "  human sees it, with its content, after the run. Say in your summary"
        echo "  what you created and why."
        echo
        if [[ -n "${AGENT_PATCH_DIR_REL:-}" ]]; then
            echo "To propose a change to ANY path this run mounted read-only, config"
            echo "or not, write a unified diff to \`$AGENT_PATCH_DIR_REL/<name>.patch\`,"
            echo "relative to your working directory (read-write, gitignored, so it"
            echo "stays out of the commit). The human sees it after the run and"
            echo "decides whether to apply it. Say in your summary that you left one."
        else
            echo "No patch directory is configured this run: describe a change you"
            echo "would make to a read-only path, and why, in your final summary."
        fi
        if [[ -n "${WORKTREE_DIR:-}" ]]; then
            echo
            echo "## Worktree mode"
            echo
            echo "This session runs in a throwaway git worktree checked out on"
            echo "\`$WORKTREE_REF\`, not in the project's main checkout."
            echo
            echo "- The working directory is \`$WORKTREE_DIR\`. Make every change there."
            if [[ "${WORKTREE_PROJECT_MODE:-ro}" == deny ]]; then
                echo "- \`$PROJECT_DIR\` (the main checkout) is **not mounted** this session --"
                echo "  denied at the start of the run. Only its \`.git\` is reachable (read-only,"
                echo "  needed because the worktree shares its object store). Anything untracked"
                echo "  or \`.gitignore\`d in the main checkout -- local notes directories, \`.env\`"
                echo "  files, build output, virtualenvs -- is not reachable this session at all."
            else
                echo "- **A worktree holds only files git tracks.** Anything untracked or"
                echo "  \`.gitignore\`d in the main checkout -- local notes directories,"
                echo "  \`.env\` files, build output, virtualenvs -- is NOT here. Look for it"
                echo "  under \`$PROJECT_DIR\` (the main checkout) before concluding it does"
                echo "  not exist."
                if [[ "${WORKTREE_PROJECT_MODE:-ro}" == ro ]]; then
                    echo "- \`$PROJECT_DIR\` is read-only this session: read from it freely,"
                    echo "  write only inside the worktree."
                fi
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
# unless REAL already carries the same marker. A sanitized copy bound over
# the real path, so the host's own instruction content survives untouched
# underneath the appended note.
#
# Worktree mode appends a second, run-specific block naming the two paths
# and the commit-message file. That block is deliberately NOT behind the
# marker check: the marker only guards the static notice, and the worktree
# facts (which directory is writable, where the main checkout is, what
# file to write) are the ones an agent needs before its first tool call,
# not after it thinks to read a lookup file. Most importantly it says
# where to look for the untracked/ignored files a worktree does not have.
#
# Kept terse on purpose: every line here loads into every session's system
# prompt, unlike generate_limitations_file()'s output (read only on
# demand, agents.sh:157-166). Verbosity here was reviewed and trimmed
# once already: no fact was dropped, only restated tighter (fewer clauses
# per fact, abbreviated ro/rw, no second full sentence pointing at
# .sandbox-limitations.md when the base marker block four lines above
# already gave that pointer). If a fact stops being needed before the
# agent's first tool call, move it into generate_limitations_file()
# instead of re-trimming it here.
bind_augmented_instructions() {
    local real="$1" out
    # An instruction file the host does not have is bound anyway -- the
    # notice is worth more than the absent file -- but only where that
    # bind cannot reach the host: where a read-write bind of a host
    # directory covers the destination, apptainer would have to create the
    # missing file in that real directory to mount over it. There the
    # overlay is skipped and the limitations file is still mounted at
    # $HOME/.sandbox-limitations.md; only the pointer to it is lost.
    if [[ ! -e "$real" && ! -L "$real" ]] && bind_rw_covers "$real"; then
        log_warn "not creating $real just to add the sandbox notice;" \
            "the agent's limitations are still at \$HOME/.sandbox-limitations.md"
        return 0
    fi
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
            echo "Throwaway git worktree on branch \`$WORKTREE_REF\`:"
            echo "- Write changes in \`$WORKTREE_DIR\` (rw)."
            case "${WORKTREE_PROJECT_MODE:-ro}" in
                deny)
                    echo "- Main checkout \`$PROJECT_DIR\` is NOT mounted (denied); only its"
                    echo "  \`.git\` is reachable (ro). Untracked/gitignored files there are"
                    echo "  unreachable entirely."
                    ;;
                rw)
                    echo "- Main checkout \`$PROJECT_DIR\` (rw, explicit confirmation). Edits"
                    echo "  there are outside the worktree and won't appear in the approval"
                    echo "  diff or reach \`$WORKTREE_REF\`."
                    ;;
                *)
                    echo "- Main checkout \`$PROJECT_DIR\` (ro). Worktrees hold only tracked"
                    echo "  files -- untracked/gitignored paths (notes dirs, \`.env\`, build"
                    echo "  output) exist only there."
                    ;;
            esac
            echo "- No commits: \`.git\` is read-only. Put the commit message in"
            echo "  \`\$HOME/$WORKTREE_MSG_NAME\`; a human applies it on the host."
        } >>"$out"
    fi
    chmod 600 "$out"
    BINDS+=(-B "$out:$real:ro")
}

# --- the patch channel ---------------------------------------------------
#
# The agent's one way to propose a change to a path this run mounted
# read-only. It is an ordinary directory inside the writable checkout --
# not a separate bind, not $HOME scratch -- chosen by sandbox.yml's
# `patches:` key and required to be gitignored, which is what makes it
# safe to put there: a patch dropped in an ignored directory is never
# swept into the commit the patch is about, and it survives the run
# because it was never in $RUN_DIR to begin with.
#
# AGENT_PATCH_DIR_HOST is the absolute per-run directory, empty when the
# channel is off. AGENT_PATCH_DIR_REL is the same path relative to the
# checkout, which is what the agent is told.
AGENT_PATCH_DIR_HOST=""
AGENT_PATCH_DIR_REL=""

# PATCH_RUN_INFO_NAME: hidden bookkeeping file dropped inside each run's
# patch directory, recording the owner pid and hostname. Kept out of the
# directory name itself (which is now just the minute-resolution
# timestamp, plus a letter suffix on collision -- see resolve_patch_dir())
# so a patch path stays short and readable. prune_empty_patch_dirs() reads
# it to tell a same-host dead run from a foreign-host one, the same
# host-then-pid reasoning as worktree_lock_acquire() (functions/worktree.sh):
# kill -0 is meaningless across machines, so a directory whose recorded
# host is not this host is never touched. report_agent_patches() excludes
# this exact name from what it reports -- it is not a patch.
PATCH_RUN_INFO_NAME=".sandbox-run-info"

# prune_empty_patch_dirs BASE: remove this run's dead siblings under BASE
# (the resolved "$dir/$rel" patch root) before adding a new one -- run
# once per invocation of resolve_patch_dir(), so the directory does not
# accumulate one empty per-run folder for every run that never wrote a
# patch. Only directories that are both empty (ignoring their own
# PATCH_RUN_INFO_NAME file) AND whose owner pid is confirmed no longer
# running are removed: a live pid means that run may still write into it,
# and any non-empty directory holds an actual patch, whose retention is
# the user's call (see report_agent_patches() below) not this function's.
# rmdir rather than rm -rf: it fails closed if the directory gains real
# content between the emptiness check and the removal (the info file
# itself is removed first so rmdir still sees a truly empty directory,
# not the disappearance of a race window).
#
# A directory whose PATCH_RUN_INFO_NAME names a different host is left
# alone unconditionally -- kill -0 cannot tell a live remote pid from a
# reused local one, so liveness is simply not decided from here (compare
# worktree_lock_acquire()'s "$HOME can be a network mount" reasoning).
# Likewise a directory with no readable pid (info file missing or
# unparsable, e.g. this run crashed between mkdir and the write) is left
# alone rather than guessed at -- except the legacy "<stamp>-<pid>" shape
# from before this info file existed, whose pid was always the name's own
# trailing digits and always meant this host.
#
# Unrecognized entries (wrong name shape, not a directory) are left
# alone rather than guessed at, the same stance reap_orphaned_run_dirs()
# (functions/run-dir.sh) takes for RUN_DIR.
prune_empty_patch_dirs() {
    local base="$1" entry name pid host_in_file this_host info
    [[ -d "$base" ]] || return 0
    this_host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    for entry in "$base"/*; do
        [[ -d "$entry" ]] || continue
        name="${entry##*/}"
        host_in_file=""
        pid=""
        if [[ "$name" =~ ^[0-9]{6}-[0-9]{4}[a-z]?$ ]]; then
            info="$entry/$PATCH_RUN_INFO_NAME"
            if [[ -f "$info" ]]; then
                host_in_file="$(sed -n 's/^host=//p' "$info" 2>/dev/null | head -n1)"
                pid="$(sed -n 's/^pid=//p' "$info" 2>/dev/null | head -n1)"
            fi
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
        elif [[ "$name" =~ ^[0-9]{6}-[0-9]{4}-[0-9]+$ ]]; then
            pid="${name##*-}"
        else
            continue
        fi
        [[ -z "$host_in_file" || "$host_in_file" == "$this_host" ]] || continue
        kill -0 "$pid" 2>/dev/null && continue
        rm -f -- "$entry/$PATCH_RUN_INFO_NAME" 2>/dev/null
        rmdir -- "$entry" 2>/dev/null || true
    done
}

# resolve_patch_dir DIR: decide the channel for the writable checkout DIR,
# and create this run's directory when it is available. Gitignored is a
# requirement, not a preference: an un-ignored patch directory would put
# agent-authored diffs in front of `git add -A`.
#
# Unavailable is not an error. Nothing is refused and no fallback is
# invented -- the channel is a convenience, and an agent that has nowhere
# to write a proposal simply says so in its summary instead.
resolve_patch_dir() {
    local dir="$1" rel base stamp real_dir real_base rc=0
    local suf leaf host
    AGENT_PATCH_DIR_HOST=""
    AGENT_PATCH_DIR_REL=""
    [[ -n "$dir" && -d "$dir" ]] || return 0
    rel="${YML_PATCHES:-.agent/patches}"
    # An absolute path would land outside the checkout, where the project
    # bind does not reach and no gitignore rule applies.
    if [[ "$rel" == /* ]]; then
        log_info "patches: '$rel' is absolute; the patch channel is relative to the checkout, so it is off this run"
        return 0
    fi
    git -C "$dir" check-ignore -q -- "$rel" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log_warn "no patch channel this run -- '$rel' is not gitignored in $dir." \
            "Set a gitignored 'patches:' directory in sandbox.yml to give the agent one."
        return 0
    fi
    base="$dir/$rel"
    # The directory must really be inside the checkout once symlinks are
    # resolved -- checked BEFORE anything is created: a symlinked
    # component (".agent" a link out of the tree) would otherwise have the
    # host create, and later scan, a directory somewhere else entirely.
    # readlink -m resolves the components that exist and tolerates the
    # ones that do not yet. Checking "$base" itself (rather than a
    # specific run's leaf) is equivalent here and suffix-independent: any
    # escape lives in $dir or $rel, not in the leaf name chosen below.
    real_dir="$(readlink -f -- "$dir")"
    real_base="$(readlink -m -- "$base")"
    if [[ -z "$real_dir" || "$real_base" != "$real_dir"/* ]]; then
        log_warn "no patch channel this run -- '$rel' resolves outside $dir."
        return 0
    fi
    prune_empty_patch_dirs "$base"
    if ! mkdir -p -- "$base"; then
        log_warn "could not create the patch directory $base; the patch channel is off this run"
        return 0
    fi
    # Minute resolution, no pid: two runs starting in the same minute
    # would otherwise collide, so mkdir (atomic create-or-fail) is tried
    # first bare, then with a single letter suffix a, b, c, ... -- the
    # first one that did not already exist is this run's directory.
    # Exhausting the alphabet inside one minute is not handled further;
    # it fails closed like any other mkdir failure below.
    stamp="$(date +%y%m%d-%H%M)"
    leaf=""
    for suf in "" a b c d e f g h i j k l m n o p q r s t u v w x y z; do
        if mkdir -- "$base/$stamp$suf" 2>/dev/null; then
            leaf="$stamp$suf"
            break
        fi
    done
    if [[ -z "$leaf" ]]; then
        log_warn "could not create the patch directory under $base (all of ${stamp}[a-z] are taken); the patch channel is off this run"
        return 0
    fi
    AGENT_PATCH_DIR_HOST="$base/$leaf"
    AGENT_PATCH_DIR_REL="$rel/$leaf"
    host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    printf 'pid=%s\nhost=%s\n' "$$" "$host" >"$AGENT_PATCH_DIR_HOST/$PATCH_RUN_INFO_NAME" 2>/dev/null || true
    log_info "patches: $AGENT_PATCH_DIR_REL (gitignored, inside the checkout)"
}

# report_agent_patches: after the container exits, surface whatever the
# agent dropped into the channel.
#
# Nothing is copied and nothing is deleted. The files are already in their
# final, durable location inside the user's own project directory -- a
# copy-out step would only create a second place to look, and deleting
# from a directory the user owns after merely reporting it is exactly the
# "the sandbox removed files from my checkout" behaviour this design rules
# out. Retention of old per-run directories is the user's, like any other
# directory they own.
#
# `find -type f` is the selection, with PATCH_RUN_INFO_NAME (the pid/host
# bookkeeping file resolve_patch_dir() drops in every run's directory)
# excluded by name -- it is not a patch, and is otherwise indistinguishable
# from one to a plain file listing. It does not follow symlinks, so a
# link the agent planted there is not reported as a patch either.
#
# Nothing is applied and nothing is parsed -- a human judgement call.
# Paths are printed %q-quoted because the agent chose the filename, so it
# can carry terminal escapes or shell metacharacters, and %q renders both
# inert while keeping the printed command copy-pasteable.
report_agent_patches() {
    local dir="${AGENT_PATCH_DIR_HOST:-}" target f
    [[ -n "$dir" && -d "$dir" ]] || return 0
    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -mindepth 1 -type f -not -name "$PATCH_RUN_INFO_NAME" -print0 2>/dev/null | sort -z)
    [[ ${#files[@]} -gt 0 ]] || return 0
    # The worktree is the tree the patch was written against when there is
    # one; otherwise the agent worked in the project checkout directly.
    # Both are read with a default: this also runs from teardown paths that
    # can be reached before either global was resolved, and `set -u`
    # aborting the report would lose the patches with it.
    target="${WORKTREE_DIR:-${PROJECT_DIR:-}}"
    printf '%s\n  %s\n' "sandbox: the sandboxed agent left ${#files[@]} proposed patch(es) for" \
        "paths this run mounted read-only:" >&2
    for f in "${files[@]}"; do
        printf '  %q\n' "$f" >&2
        if [[ -n "$target" ]]; then
            printf '    git -C %q apply %q\n' "$target" "$f" >&2
        else
            printf '    git apply %q   # run from the checkout this patch is against\n' "$f" >&2
        fi
    done
    printf '%s\n  %s\n' "sandbox: those patches were written by the sandboxed agent. Nothing has" \
        "been applied -- reading each one before applying it is your job." >&2
    return 0
}

configure_agent() {
    if [[ "$AGENT" != "script" ]]; then
        ensure_run_dir
        # Resolved BEFORE the limitations file is generated, so that file
        # can tell the agent where the channel is. The writable checkout
        # is the worktree when there is one -- the patch has to land where
        # the agent can write it and where the gitignore rule that keeps
        # it out of the commit actually applies. The channel needs no bind
        # of its own: it is an ordinary directory inside that checkout.
        resolve_patch_dir "${WORKTREE_DIR:-${PROJECT_DIR:-}}"
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
            # claude's $HOME is a per-run directory with the host's paths
            # bound into it one at a time -- login and session state
            # read-write, config read-only, a read-only placeholder for
            # config the host lacks; the layout and the reasons are in
            # functions/claude-home.sh. ~/.claude.json is a plain per-run
            # copy in there, of which only an allowlist of keys merges back
            # at exit (functions/claude-json.sh).
            claude_home_refuse_overrides
            if ! claude_home_prepare || ! claude_json_prepare; then
                echo "error: could not build claude's per-run home in $RUN_DIR" >&2
                exit 1
            fi
            # CLAUDE.md is the always-loaded instruction file: overlaid
            # with a copy of itself plus a pointer at the generated
            # limitations lookup file, rather than a plain read-only bind.
            bind_augmented_instructions "$HOME/.claude/CLAUDE.md"
            # claude's own flag for running inside a sandbox: the workspace
            # counts as trusted, so there is no trust dialog and nothing is
            # recorded for it. Committed project permission rules then
            # apply in the session, as in a trusted folder on the host.
            backend_forward_env CLAUDE_CODE_SANDBOXED 1
            # No --strict-mcp-config, and no interception of the user's own
            # --mcp-config: ARGS passes through untouched, exactly as it
            # does for opencode and omp. The MCP definitions claude reads
            # each have their own gate, and whatever a definition spawns
            # runs inside this container:
            #
            #   project .mcp.json / .claude/settings.json -- the project
            #     mask: committed and clean is a read-only copy,
            #     uncommitted is hidden;
            #   ~/.claude.json (user- and local-scope servers) -- the
            #     per-run copy; its mcpServers and projects never merge
            #     back, so nothing a session writes there reaches a later
            #     run;
            #   ~/.claude/settings.json, mcp.json and the rest of the
            #     global surface -- read-only, human-authored outside any
            #     repo the agent can reach.
            RUN_CMD=(claude "${ARGS[@]}")
            ;;
        opencode)
            # ~/.config/opencode's DIRECTORY ENTRY itself has to be
            # writable, not just specific files in it: opencode writes
            # tui.json and service.json (below) with an atomic rename
            # (write "<name>.tmp", then rename it over "<name>"), and a
            # rename is a metadata operation on the ENCLOSING directory
            # (unlink one dentry, create another) -- binding "tui.json" or
            # "service.json" individually, as their own separate mount
            # points, does not make their shared parent directory
            # writable, so the rename itself still hits EROFS even though
            # both names are themselves bound read-write (measured:
            # opencode v2.0.16, "PlatformError ... EROFS ... rename
            # '.../service.json.tmp' -> '.../service.json'").
            #
            # So the base is a fresh, empty, per-run directory -- never
            # the host's real ~/.config/opencode -- bound in its place,
            # with the host's real config layered back in through deeper
            # binds below (opencode.json, plugin/, agent/, ...), the same
            # shallow-rw-then-deeper-ro layering `mask_git_readonly` uses
            # for the project dir vs. its `.git` (apptainer sorts mounts
            # by destination depth, so the deeper read-only binds always
            # apply after this one regardless of insertion order). Losing
            # anything the session writes at the base level (tui.json,
            # service.json, or a stray top-level file opencode invents)
            # costs nothing real: it goes with $RUN_DIR, and none of it
            # was ever the host's to keep.
            local oc_config
            oc_config="$RUN_DIR/opencode-config"
            mkdir -p -- "$oc_config" && chmod 700 -- "$oc_config"
            BINDS+=(-B "$oc_config:$HOME/.config/opencode")
            # Writable, and why: tui.json is rewritten every session.
            bind_state_rw "$HOME/.config/opencode/tui.json" file '{}'
            # ~/.local/share/opencode is a sandbox-owned per-project
            # directory, never the host's. The host's holds the session
            # database of EVERY project on the machine, storage/, log/ and
            # bin/ (tools opencode downloads and executes): shared, a
            # session could read every other project's sessions, and leave
            # data or binaries the next unsandboxed opencode reads or runs.
            # Keyed like omp's history (project_state_key), so every run
            # and worktree of this project share it; sessions started on
            # the host are not visible here, nor these on the host. Bound
            # as a DIRECTORY, deliberately: the database is sqlite, and
            # sqlite creates and removes its own "-wal"/"-shm" siblings next
            # to it, which a per-file bind makes impossible (an unlink of a
            # bind-mounted file fails). Only the credentials opencode
            # refreshes itself are the host's, bound in by name over mount
            # points made in the private directory.
            local oc_share
            oc_share="$HOME/.agent/opencode-share/$(project_state_key)"
            mkdir -p -- "$oc_share" && chmod 700 -- "$oc_share"
            BINDS+=(-B "$oc_share:$HOME/.local/share/opencode")
            for p in auth.json mcp-auth.json; do
                : >>"$oc_share/$p"
                bind_state_rw "$HOME/.local/share/opencode/$p" file '{}'
            done
            # ~/.cache/opencode is where opencode caches the models.dev
            # provider catalog (models.json) and, per opencode's own docs,
            # other "download caches and temporary data" whose exact
            # contents beyond models.json are not confirmed here -- unlike
            # ~/.local/share/opencode's bin/ above, which opencode's docs
            # explicitly describe as downloaded tools it executes. Treated
            # with the same never-the-host's-real-path caution regardless:
            # the host's ~/.cache/opencode is shared by every project on
            # the machine and by unsandboxed opencode runs, so anything
            # this session writes there -- confirmed executable or not --
            # must not leak into it.
            #
            # Unlike opencode-share above, this is a CACHE, not session
            # state: losing it costs a re-fetch of the catalog, nothing
            # more, so it does not belong in ~/.agent among the directories
            # nothing ever purges (docs/maintenance.md, "The $HOME agent
            # surfaces"). Housed under TMPDIR instead, keyed like
            # opencode-share so every run/worktree of one project reuses
            # it rather than refetching every session, but reclaimable by
            # the OS's own tmp janitor (systemd-tmpfiles, tmpwatch, or a
            # tmpfs /tmp cleared at reboot) instead of a purge mechanism
            # this repository would otherwise have to build and maintain.
            # Named apart from "sandbox-engine.*" (functions/run-dir.sh)
            # on purpose: that glob is per-run scratch reaped by PID
            # liveness (reap_orphaned_run_dirs), which does not apply to a
            # directory meant to outlive any single run.
            #
            # Bound read-write, not read-only: opencode's own mkdir of
            # ~/.cache (never otherwise scaffolded under --no-mount home)
            # fails with EROFS without a writable bind here -- that
            # failure is the bug this bind fixes.
            local oc_cache
            oc_cache="${TMPDIR:-/tmp}/sandbox-engine-cache/opencode/$(project_state_key)"
            mkdir -p -- "$oc_cache" && chmod 700 -- "$oc_cache"
            BINDS+=(-B "$oc_cache:$HOME/.cache/opencode")
            # ~/.local/state/opencode is a fresh per-run directory, never
            # the host's. opencode registers its background server there
            # (service.json: pid, http://127.0.0.1:<port>, password;
            # docs/parallelization.md), and the container shares the
            # host's network: the host's own file would hand the session
            # the password of a HOST opencode server, which runs its tools
            # unsandboxed, and a file the session wrote would point the
            # next host opencode at a server the session controls. Per run
            # rather than per project, so concurrent runs cannot attach to
            # each other's server either.
            mkdir -p -- "$RUN_DIR/opencode-state" && chmod 700 -- "$RUN_DIR/opencode-state"
            BINDS+=(-B "$RUN_DIR/opencode-state:$HOME/.local/state/opencode")
            # ~/.config/opencode/service.json is the SAME registry's second
            # copy, and needs no bind of its own now (unlike tui.json
            # above, it gets no deeper bind back to a real host file
            # either -- it never had one, and still doesn't; it just lives
            # in the ephemeral base like everything else this session
            # invents there): the base directory is already a writable
            # per-run directory, so opencode's create-then-rename of
            # service.json.tmp -> service.json succeeds inside it. (An
            # earlier fix bound service.json and service.json.tmp
            # individually by name over the old read-only base, which
            # covered the create but not the rename -- a rename's
            # unlink+create pair needs its shared parent directory
            # writable, not just the two names in isolation; measured
            # failing with "EROFS ... rename '.../service.json.tmp' ->
            # '.../service.json'" even with both names bound.)
            # ~/.opencode is the host install directory holding the
            # opencode binary (the image installs its own at
            # /usr/local/opencode/bin, see sandbox/agent/Dockerfile.template);
            # a writable bind would let the sandbox replace a binary the
            # human then executes on the bare host.
            bind_ro "$HOME/.opencode" dir
            # opencode.json/opencode.jsonc define mcp.<name>.command arrays,
            # plugin paths, lsp.*.command, formatter.*.command and
            # experimental.hook.* -- all executed; plugins/ is JS/TS loaded
            # at startup, and agents/, commands/ and skills/ are prompt
            # content that persists into the human's next bare-host run.
            # BOTH spellings of every subdirectory are masked: opencode's
            # current layout is the plural one (agents/, commands/, modes/,
            # plugins/, skills/, tools/, themes/) and the singular names are
            # kept for backwards compatibility, so both are loaded and
            # masking only one spelling would leave a writable path that
            # executes on the host.
            for p in opencode.json opencode.jsonc \
                     plugin plugins agent agents command commands \
                     mode modes tool tools skill skills theme themes; do
                case "$p" in
                    opencode.json | opencode.jsonc)
                        scan_opencode_api_keys "$HOME/.config/opencode/$p"
                        bind_ro "$HOME/.config/opencode/$p"
                        ;;
                    *)
                        bind_ro "$HOME/.config/opencode/$p" dir
                        ;;
                esac
            done
            # AGENTS.md is the always-loaded instruction file.
            bind_augmented_instructions "$HOME/.config/opencode/AGENTS.md"
            RUN_CMD=(opencode "${ARGS[@]}")
            ;;
        omp)
            # oh-my-pi (can1357/oh-my-pi). Its ~/.omp is a per-run
            # directory with the host's paths bound into it one at a time;
            # the layout and the reasons are in functions/omp-home.sh.
            # Project-level .omp/ config is covered by the project mask like
            # any other checkout path. Only the default profile is mounted:
            # a named profile or a forwarded directory override refuses the
            # run, as does an image without the build-time native addons.
            omp_home_refuse_overrides
            omp_home_require_natives
            # .env files are credential stores, not configuration, and are
            # never mounted -- not even read-only. Mounting one would make
            # every key in it readable by the sandboxed agent and echoable
            # into a transcript. Model credentials reach the agent only
            # through require_host_env, which is auditable per variable.
            bind_never "$HOME/.omp/.env" "a .env is a credential store, not configuration"
            bind_never "$HOME/.omp/agent/.env" "a .env is a credential store, not configuration"
            if ! omp_home_prepare; then
                echo "error: could not build omp's per-run home in $RUN_DIR" >&2
                exit 1
            fi
            # agent/AGENTS.md is the always-loaded instruction file. Its
            # destination is inside the per-run home, so the notice is bound
            # even when the host has no such file.
            bind_augmented_instructions "$HOME/.omp/agent/AGENTS.md"
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
