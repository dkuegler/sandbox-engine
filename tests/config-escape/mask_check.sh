#!/bin/bash
# Host-side, apptainer-free verification of the project/global config-mask
# surface: which agent-config paths a session sees, and which host state
# never crosses in. Split out of tests/git-escape/worktree_check.sh, which
# now covers --worktree mode alone; this suite is not about git write
# containment at all, and grouping it under "git-escape" mislabeled it.
# Same standard as sanitize_check.sh/worktree_check.sh: it calls the REAL
# functions against REAL fixtures and inspects their real output, rather
# than reasoning about the code.
#
# What this proves without a container:
#   - the project config mask (functions/binds.sh
#     mask_project_agent_config): visible <=> tracked in HEAD and
#     identical to it, absent means unbound, a symlinked config path (on
#     disk or in HEAD) refuses the run, the shipped config/mask.toml table
#     parses the same as any TOML parser, and a malformed table refuses
#     rather than loading with rows silently missing;
#   - the global $HOME surface's read-only binds (functions/binds.sh
#     bind_ro/bind_augmented_instructions): an absent path with no
#     read-write parent is never created or bound, one under a read-write
#     parent is created and bound read-only, a dangling symlink under a
#     read-write parent refuses, and per-agent state directories
#     (opencode's state/data dirs) are per-run or per-project, never the
#     host's;
#   - the ~/.claude.json key scanner (functions/claude-json.sh): the
#     top-level value survives decoys (the key inside a string, the same
#     key nested, non-ASCII before it), a duplicated or escaped top-level
#     key refuses instead of picking one, a truncated/unterminated file is
#     not well-formed, and the real file is never bound or written -- only
#     a per-run copy is, with changed keys named in the exit report;
#   - omp's per-run ~/.omp (functions/omp-home.sh): the host's natives,
#     run/ and logs are never bound; config.yml is a plain per-run copy;
#     only modelRoles/cycleOrder merge back, only in the exact form omp
#     itself writes, and a concurrent host-side change wins; an image
#     missing the build-time native addons refuses; and a named profile
#     or directory override reaching the sandbox refuses the run.
#
# What it cannot prove, and what needs apptainer: that the kernel actually
# refuses writes through the read-only binds asserted here.
#
# Exit: 0 all passed, 1 an assertion failed, 99 the suite could not run.
#
# `cmd && ok ... || bad ...` is used throughout, same convention as
# probe.sh/sanitize_check.sh/worktree_check.sh; ok()/bad() are plain
# printf+counter calls that cannot themselves fail, so SC2015's "C also
# runs if A succeeds but B fails" hazard does not apply.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0 FAIL=0
ok()  { printf 'ok   %-6s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %-6s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
fail_setup() { echo "PREFLIGHT: $*" >&2; exit 99; }

command -v git >/dev/null 2>&1 || fail_setup "no git binary"

W="$(mktemp -d "${TMPDIR:-/tmp}/config-escape-mask.XXXXXX")"
# shellcheck disable=SC2317  # invoked indirectly via `trap cleanup_all EXIT`, not a direct call
cleanup_all() { rm -rf "$W"; }
trap cleanup_all EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@invalid

# HOME is redirected into the fixture for the whole run: the claude.json and
# omp-home assertions below write into $HOME/.claude.json, $HOME/.omp and
# $HOME/.agent, and this suite must never touch the real ones.
HOME="$W/home"
mkdir -p "$HOME" || fail_setup "mkdir fake HOME"

# --- load the real implementation ----------------------------------------
# shellcheck source=functions/log.sh
source "$REPO_ROOT/functions/log.sh"
# shellcheck source=functions/apptainer.sh
source "$REPO_ROOT/functions/apptainer.sh"
# shellcheck source=functions/agents.sh
source "$REPO_ROOT/functions/agents.sh"
# shellcheck source=functions/binds.sh
source "$REPO_ROOT/functions/binds.sh"
# shellcheck source=functions/omp-home.sh
source "$REPO_ROOT/functions/omp-home.sh"
# shellcheck source=functions/claude-json.sh
source "$REPO_ROOT/functions/claude-json.sh"

RUN_DIR="$W/run"
mkdir -p "$RUN_DIR" || fail_setup "mkdir RUN_DIR"
# shellcheck disable=SC2034  # read by log_debug (functions/log.sh)
VERBOSE=0
# project_state_key()/omp_session_bucket() (functions/agents.sh,
# functions/omp-home.sh) only need a stable path string, not a real repo.
PROJECT_DIR="$W/main"
mkdir -p "$PROJECT_DIR"

# --- M: the project config mask -----------------------------------------
# The convention's whole contract is one rule -- visible <=> tracked in
# HEAD and identical to it -- plus "absent means unbound". Each assertion
# below fails on a plausible regression of that rule, and the ones marked
# so were written against a measured bug.
MASKREPO="$W/maskrepo"
mkdir -p "$MASKREPO/sub/deep" "$MASKREPO/vendor/pkg" "$MASKREPO/.omp" "$MASKREPO/.claude/agents"
git init --quiet "$MASKREPO"
printf 'vendor/\n' > "$MASKREPO/.gitignore"
printf 'committed root\n' > "$MASKREPO/AGENTS.md"
printf 'committed deep\n' > "$MASKREPO/sub/deep/AGENTS.md"
printf 'committed rules\n' > "$MASKREPO/.omp/RULES.md"
printf 'committed agent\n' > "$MASKREPO/.claude/agents/AGENTS.md"
printf 'x\n' > "$MASKREPO/f"
git -C "$MASKREPO" add .gitignore AGENTS.md sub/deep/AGENTS.md .omp/RULES.md .claude/agents/AGENTS.md f
git -C "$MASKREPO" commit --quiet -m "mask fixture"
printf 'committed root\nLOCAL DRIFT\n' > "$MASKREPO/AGENTS.md"
printf 'untracked plant\n' > "$MASKREPO/CLAUDE.md"
printf 'deep untracked plant\n' > "$MASKREPO/sub/CLAUDE.md"
printf 'ignored plant\n' > "$MASKREPO/vendor/pkg/AGENTS.md"

BINDS=() RO_MASKED=() CFG_MASK_STATE=() CFG_MASK_PATH=() CFG_MASK_OWNER=()
mask_project_agent_config "$MASKREPO"

mask_state_of() {
    local want="$1" i
    for i in "${!CFG_MASK_PATH[@]}"; do
        [[ "${CFG_MASK_PATH[i]}" == "$want" ]] && { printf '%s' "${CFG_MASK_STATE[i]}"; return 0; }
    done
    printf 'missing'
}
mask_src_of() {
    local want="$1" b
    for b in "${BINDS[@]}"; do
        [[ "$b" == "-B" ]] && continue
        [[ "$b" == *":$want:ro" ]] && { printf '%s' "${b%%:*}"; return 0; }
    done
    printf ''
}

[[ "$(mask_state_of "$MASKREPO/.omp/RULES.md")" == committed ]] \
    && ok M1 "committed & clean config is visible (read-only copy)" \
    || bad M1 "a committed, clean config path was not reported committed"
[[ "$(mask_state_of "$MASKREPO/CLAUDE.md")" == hidden ]] \
    && ok M2 "untracked config is hidden" \
    || bad M2 "an untracked config path was not hidden"
[[ "$(mask_state_of "$MASKREPO/AGENTS.md")" == hidden ]] \
    && ok M3 "tracked-but-modified config is hidden" \
    || bad M3 "a locally modified config path was not hidden"
# The regression the convention itself names as the one to watch.
[[ "$(mask_state_of "$MASKREPO/.claude/settings.json")" == unbound \
   && -z "$(mask_src_of "$MASKREPO/.claude/settings.json")" \
   && ! -e "$MASKREPO/.claude/settings.json" ]] \
    && ok M4 "absent config produces no bind and materialises nothing" \
    || bad M4 "an absent config path was bound, or materialised on disk"
# A committed copy must come from HEAD, never from the dirty working tree.
[[ "$(cat "$(mask_src_of "$MASKREPO/sub/deep/AGENTS.md")" 2>/dev/null)" == "committed deep" ]] \
    && ok M5 "the bound copy is HEAD's content" \
    || bad M5 "the bound copy did not match HEAD"
[[ "$(cat "$(mask_src_of "$MASKREPO/AGENTS.md")" 2>/dev/null)" == "committed root" ]] \
    && ok M6 "a dirty path shows HEAD's content, not the working tree's" \
    || bad M6 "local drift was visible through the mask"
# Tree-wide reach: the same rule at depth, and no hiding behind .gitignore.
[[ "$(mask_state_of "$MASKREPO/sub/deep/AGENTS.md")" == committed \
   && "$(mask_state_of "$MASKREPO/sub/CLAUDE.md")" == hidden ]] \
    && ok M7 "deep instruction files obey the same rule as root-level ones" \
    || bad M7 "a deep instruction file was masked differently from a root-level one"
[[ "$(mask_state_of "$MASKREPO/vendor/pkg/AGENTS.md")" == hidden ]] \
    && ok M8 "a gitignored instruction file is still masked" \
    || bad M8 "an ignore rule was a place to hide an instruction file"
# A deep match inside a table directory is decided by that directory's
# entry, not by a second bind nested in it.
[[ "$(mask_state_of "$MASKREPO/.claude/agents")" == committed \
   && "$(mask_state_of "$MASKREPO/.claude/agents/AGENTS.md")" == missing ]] \
    && ok M14 "a deep match inside a table directory is covered by that entry alone" \
    || bad M14 "a deep match inside a table directory got its own nested bind"
# One RO_MASKED element per masked path: a split append corrupts the
# agent's own limitations file and the read-only bind count.
[[ "$(printf '%s\n' "${RO_MASKED[@]}" | grep -c '^committed version)')" -eq 0 ]] \
    && ok M9 "each masked path is exactly one RO_MASKED element" \
    || bad M9 "a RO_MASKED entry was split across two array elements"
# Worktree mode masks two checkouts; both must survive in the report.
MASKWT="$W/maskwt"
cp -a "$MASKREPO" "$MASKWT"
mask_project_agent_config "$MASKWT"
main_rows=0 wt_rows=0
for _i in "${!CFG_MASK_OWNER[@]}"; do
    [[ "${CFG_MASK_OWNER[_i]}" == "$MASKREPO" ]] && main_rows=$((main_rows+1))
    [[ "${CFG_MASK_OWNER[_i]}" == "$MASKWT" ]] && wt_rows=$((wt_rows+1))
done
[[ "$main_rows" -gt 0 && "$wt_rows" -gt 0 ]] \
    && ok M10 "masking a second checkout keeps the first one's report rows" \
    || bad M10 "the second mask pass discarded the first checkout's partition"
# The gate's candidate list must propagate a failed git read, not return
# an empty list that reads as "the agent created nothing".
(
    # shellcheck disable=SC2317  # invoked indirectly, as the `git` shadow inside this subshell
    git() { [[ "$*" == *"ls-files --others"* ]] && return 1; command git "$@"; }
    config_shaped_untracked "$MASKREPO" "$W/cand-fail.z"
) >/dev/null 2>&1 \
    && bad M11 "a failed untracked-file read produced an empty candidate list" \
    || ok M11 "a failed candidate enumeration refuses instead of returning empty"
# Literal pathspecs: an excluded file whose NAME is a glob must not unstage its
# neighbours from a commit the human already approved.
GLOBREPO="$W/globrepo"
mkdir -p "$GLOBREPO/sub"
git init --quiet "$GLOBREPO"
printf 'b\n' > "$GLOBREPO/base"
git -C "$GLOBREPO" add base
git -C "$GLOBREPO" commit --quiet -m base
printf 'w\n' > "$GLOBREPO/sub/work.md"
printf 'o\n' > "$GLOBREPO/sub/other.md"
printf 'p\n' > "$GLOBREPO/sub/*.md"
git -C "$GLOBREPO" add -A
printf ':(top,literal)%s\0' 'sub/*.md' > "$W/exclude-glob.z"
git -C "$GLOBREPO" rm -q --cached --pathspec-from-file="$W/exclude-glob.z" --pathspec-file-nul
[[ "$(git -C "$GLOBREPO" diff --cached --name-only | sort | tr '\n' ' ')" == "sub/other.md sub/work.md " ]] \
    && ok M12 "a glob-named excluded file unstages only itself" \
    || bad M12 "a glob-named excluded file dropped reviewed work from the commit"
# A config path must not be a symlink, neither on disk nor as HEAD records
# it: the bind would follow the link to some other host file.
LINKREPO="$W/linkrepo"
mkdir -p "$LINKREPO/.claude"
git init --quiet "$LINKREPO"
printf 'target\n' > "$LINKREPO/real.json"
ln -s ../real.json "$LINKREPO/.claude/settings.json"
git -C "$LINKREPO" add -A
git -C "$LINKREPO" commit --quiet -m "linked config"
link_refused() { ( BINDS=() RO_MASKED=(); mask_project_agent_config "$LINKREPO" ) >/dev/null 2>&1 && return 1; return 0; }
m13=0
link_refused || m13=1
# The working tree replaced the link with a regular file: HEAD still has
# the link, and the committed copy would be one.
rm "$LINKREPO/.claude/settings.json"
printf 'plain\n' > "$LINKREPO/.claude/settings.json"
link_refused || m13=1
[[ "$m13" -eq 0 ]] \
    && ok M13 "a config path that is a symlink, on disk or in HEAD, refuses the run" \
    || bad M13 "a symlinked config path was bound"
# The mask table is the perimeter: a malformed table must refuse the run,
# never load with rows silently missing.
mask_table_refused() {
    printf '%b' "$1" >"$W/mask-variant.toml"
    (
        # shellcheck disable=SC2030,SC2034  # subshell-local on purpose; read by project_config_mask_load
        PROJECT_CONFIG_MASK_FILE="$W/mask-variant.toml" PROJECT_CONFIG_MASK_KIND=() \
            PROJECT_CONFIG_MASK_PATH=() PROJECT_CONFIG_MASK_ANYWHERE=()
        project_config_mask_load
    ) >/dev/null 2>&1 && return 1
    return 0
}
m15=0
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' && m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[project.b]\ndirs = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "../x",\n]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = ["x.json"]\n[anywhere]\nnames = [\n    "A",\n]\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n[anywhere]\nnames = [\n    "A",\n' || m15=1
mask_table_refused '[project.a]\nfiles = [\n    "x.json",\n]\n' || m15=1
[[ "$m15" -eq 0 ]] \
    && ok M15 "a malformed mask table (duplicate, '..', inline array, unclosed, no [anywhere]) refuses; a valid one loads" \
    || bad M15 "the mask loader accepted a malformed table, or refused a valid one"
# The shipped table is TOML that any parser reads the same way: the
# loader's rows equal tomllib's (Python >= 3.11; skipped without it).
if python3 -c 'import tomllib' 2>/dev/null; then
    m16_py="$(python3 -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
for t in d["project"].values():
    for k in ("files", "dirs"):
        for v in t.get(k, []): print("P", k[:-1], v)
for v in d["anywhere"]["names"]: print("A", v)' "$PROJECT_CONFIG_MASK_FILE")"
    m16_sh="$(
        project_config_mask_load
        for i in "${!PROJECT_CONFIG_MASK_PATH[@]}"; do
            printf 'P %s %s\n' "${PROJECT_CONFIG_MASK_KIND[i]}" "${PROJECT_CONFIG_MASK_PATH[i]}"
        done
        printf 'A %s\n' "${PROJECT_CONFIG_MASK_ANYWHERE[@]}"
    )"
    [[ -n "$m16_sh" && "$m16_sh" == "$m16_py" ]] \
        && ok M16 "config/mask.toml loads to exactly what tomllib reads" \
        || bad M16 "the mask loader and tomllib disagree about config/mask.toml"
else
    printf 'skip %-6s %s\n' M16 "no python3 with tomllib (>= 3.11)"
fi

# --- B: the global surface's read-only binds (functions/binds.sh) --------
# An absent global config path must never become creatable on the host:
# unbound when nothing read-write covers it, created and bound read-only
# when something does.
G="$W/global"
mkdir -p "$G/rwparent"
# b_bound PATH: some bind in BINDS has PATH as its container destination.
b_bound() {
    local b dst
    for b in "${BINDS[@]}"; do
        [[ "$b" == -B ]] && continue
        dst="$b"
        [[ "$b" == *:* ]] && { dst="${b#*:}"; dst="${dst%%:*}"; }
        [[ "$dst" == "$1" ]] && return 0
    done
    return 1
}
BINDS=() RO_MASKED=()
bind_ro "$G/absent/settings.json"
[[ ${#BINDS[@]} -eq 0 && ! -e "$G/absent" ]] \
    && ok B1 "an absent config path with no read-write parent is not bound, and nothing is created" \
    || bad B1 "an absent config path was bound or materialized on the host"
BINDS=(-B "$G/rwparent") RO_MASKED=()
bind_ro "$G/rwparent/bin" dir
[[ -d "$G/rwparent/bin" && " ${BINDS[*]} " == *" $G/rwparent/bin:$G/rwparent/bin:ro "* ]] \
    && ok B2 "an absent path under a read-write bind is created on the host and bound read-only" \
    || bad B2 "an absent path under a read-write bind was left creatable"
ln -s "$G/nowhere" "$G/rwparent/link"
( BINDS=(-B "$G/rwparent"); bind_ro "$G/rwparent/link" ) >/dev/null 2>&1 \
    && bad B3 "a dangling symlink under a read-write bind was accepted" \
    || ok B3 "a dangling symlink under a read-write bind refuses the run"
BINDS=(-B "$G/rwparent") RO_MASKED=()
bind_augmented_instructions "$G/rwparent/AGENTS.md" 2>/dev/null
[[ ! -e "$G/rwparent/AGENTS.md" ]] && ! b_bound "$G/rwparent/AGENTS.md" \
    && ok B4 "the instruction overlay is skipped where a read-write bind covers an absent destination" \
    || bad B4 "the instruction overlay would materialize a file inside a read-write bind"
BINDS=() RO_MASKED=()
# opencode's state directory holds service.json (a server's pid, port and
# password); the host's copy must never be what the session sees.
b5_binds="$(
    # shellcheck disable=SC2030,SC2034  # subshell-local; read by configure_agent
    AGENT=opencode ARGS=() BINDS=() RO_MASKED=() EXTRA_BIND_SRCS=() EXTRA_BIND_RO=()
    mkdir -p "$HOME/.local/state/opencode"
    configure_agent >/dev/null 2>&1
    printf '%s\n' "${BINDS[@]}"
)"
if grep -qx -- "$RUN_DIR/opencode-state:$HOME/.local/state/opencode" <<<"$b5_binds" \
    && ! grep -q -- "^$HOME/.local/state/opencode" <<<"$b5_binds"; then
    ok B5 "opencode's state directory (service.json) is per run, never the host's"
else
    bad B5 "the session could read or write the host's opencode service.json"
fi
# opencode's data directory holds every project's session database and the
# bin/ tools it executes: the session gets a per-project private one, and
# only the two credential files are the host's.
b6_srcs="$(grep -v -- '^-B$' <<<"$b5_binds" | sed 's/:.*//')"
b6_key="$(project_state_key)"
if grep -qx -- "$HOME/.agent/opencode-share/$b6_key:$HOME/.local/share/opencode" <<<"$b5_binds" \
    && [[ "$(grep -c -- "^$HOME/.local/share/opencode" <<<"$b6_srcs")" -eq 2 ]] \
    && grep -qx -- "$HOME/.local/share/opencode/auth.json" <<<"$b6_srcs" \
    && grep -qx -- "$HOME/.local/share/opencode/mcp-auth.json" <<<"$b6_srcs"; then
    ok B6 "opencode's data directory is per project and sandbox-owned; only auth.json and mcp-auth.json are the host's"
else
    bad B6 "the session could read or write the host's opencode data directory"
fi

# --- J: the ~/.claude.json key scanner (functions/claude-json.sh) --------
# The scanner decides which bytes are top-level mcpServers. A wrong answer
# either way is a spawned command line on the human's next bare-host run,
# so decoys that look like the key must not match, and anything ambiguous
# must refuse rather than pick.
J="$W/json"
mkdir -p "$J"
printf '%s' '{"path":"/home/ü/p","a":"x \"mcpServers\": {\"evil\":1}","p":{"mcpServers":{"n":1}},"mcpServers":{"s":{"command":"x"}},"z":[1,{"q":2}]}' >"$J/ok.json"
[[ "$(claude_json_value "$J/ok.json" mcpServers)" == '{"s":{"command":"x"}}' \
    && "$(claude_json_value "$J/ok.json" z)" == '[1,{"q":2}]' \
    && -z "$(claude_json_value "$J/ok.json" absent)" ]] \
    && ok J1 "the top-level value is found past decoys: the key inside a string, the same key nested, non-ASCII before it" \
    || bad J1 "the scanner returned the wrong span for a top-level key"
j2=0
printf '%s' '{"mcpServers":{},"mcpServers":{"s":{"command":"x"}}}' >"$J/dup.json"
claude_json_value "$J/dup.json" mcpServers >/dev/null && j2=1
printf '%s' '{"\u006dcpServers":{"s":{"command":"x"}}}' >"$J/esc.json"
claude_json_wellformed "$J/esc.json" && j2=1
[[ "$j2" -eq 0 ]] \
    && ok J2 "a duplicated or backslash-escaped top-level key refuses instead of picking one" \
    || bad J2 "an ambiguous top-level key was resolved to one reading"
j3=0
printf '%s' '{"a":1,"mcpServers":{"s":{"command":"x"' >"$J/trunc.json"
claude_json_wellformed "$J/trunc.json" && j3=1
printf '%s' '{"a":"unterminated}' >"$J/str.json"
claude_json_wellformed "$J/str.json" && j3=1
claude_json_wellformed "$J/ok.json" || j3=1
[[ "$j3" -eq 0 ]] \
    && ok J3 "a truncated file or an unterminated string is not well-formed; a sound one is" \
    || bad J3 "the well-formedness check passed a half-written file or refused a sound one"
[[ "$(claude_json_keys "$J/ok.json" | tr '\n' ' ')" == "a mcpServers p path z " ]] \
    && ok J4 "the top-level key list holds exactly the top-level keys, not the nested or quoted decoys" \
    || bad J4 "the top-level key list missed a key or listed a nested one"
# The per-run copy: the real file is never bound and never written; what
# the session changed is named, its version kept outside any checkout.
j5=0
printf '%s\n' '{"numStartups":1,"projects":{}}' >"$HOME/.claude.json"
cp "$HOME/.claude.json" "$J/real.before"
BINDS=() CLAUDE_JSON_LAST="$HOME/.agent/claude.json.last-session"
claude_json_prepare || j5=1
[[ " ${BINDS[*]} " == *" $RUN_DIR/claude.json:$HOME/.claude.json "* ]] || j5=1
printf '%s\n' '{"numStartups":1,"projects":{"/x":{"mcpServers":{"e":{"command":"sh"}},"hasTrustDialogAccepted":true}}}' >"$CLAUDE_JSON_COPY"
claude_json_report 2>"$J/report.err"
cmp -s "$HOME/.claude.json" "$J/real.before" || j5=1
grep -q 'Changed top-level keys: projects$' "$J/report.err" || j5=1
cmp -s "$CLAUDE_JSON_LAST" "$CLAUDE_JSON_COPY" || j5=1
[[ "$(stat -c %a "$CLAUDE_JSON_LAST")" == 600 ]] || j5=1
# A symlink at the keep path is not followed, not even to an existing file.
rm -f "$CLAUDE_JSON_LAST"; printf 'mine\n' >"$J/elsewhere"; ln -s "$J/elsewhere" "$CLAUDE_JSON_LAST"
claude_json_report 2>/dev/null
[[ "$(cat "$J/elsewhere")" == mine ]] || j5=1
rm -f "$CLAUDE_JSON_LAST"
[[ "$j5" -eq 0 ]] \
    && ok J5 "claude.json is a per-run copy: the real file stays untouched, the changed keys are named, a keep-path symlink is not followed" \
    || bad J5 "the session's claude.json reached the real file, or the report was wrong"
BINDS=() CLAUDE_JSON_COPY=""

# --- O: omp's per-run ~/.omp (functions/omp-home.sh) ---------------------
# The host's ~/.omp holds code omp loads (native addons, extensions/,
# settings naming modules) and sockets to host-side processes (run/). What
# is asserted: none of that is bound writable, config is a plain per-run
# copy, only the state that must persist is shared, and the settings
# merge-back takes exactly the two keys it may and nothing it should not.
OMP="$HOME/.omp"
mkdir -p "$OMP/agent/extensions" "$OMP/agent/sessions/-elsewhere" "$OMP/agent/terminal-sessions" \
    "$OMP/natives/9.9.9" "$OMP/run/daemons/x" "$HOME/projects/p"
printf 'addon\n' >"$OMP/natives/9.9.9/pi_natives.node"
printf 'setupVersion: 1\nmodelRoles:\n  default: vendor/big\n  smol: vendor/small\ntheme:\n  dark: night\ncycleOrder:\n  - vendor/big\n  - vendor/small\n' \
    >"$OMP/agent/config.yml"
printf 'rule\n' >"$OMP/agent/RULES.md"
for f in .env secret-placeholder.key history.db models.db agent.db; do : >"$OMP/agent/$f"; done
BINDS=() RO_MASKED=()
omp_home_prepare || fail_setup "omp_home_prepare"
unset APPTAINERENV_PI_CONFIG_FILES
omp_bound() { local b; for b in "${BINDS[@]}"; do [[ "$b" == "$1" ]] && return 0; done; return 1; }
# A host path bound from: PATH (or anything below it) is some bind's source.
omp_bound_src_under() { local b; for b in "${BINDS[@]}"; do [[ "$b" == "$1"* ]] && return 0; done; return 1; }
# Matches PATH as a bind's source or its destination, or anything below it.
omp_bound_under() {
    local b dst
    for b in "${BINDS[@]}"; do
        dst="${b#*:}"; dst="${dst%%:*}"
        [[ "$b" == "$1"* || "$dst" == "$1"* ]] && return 0
    done
    return 1
}
O_BUCKET="$(omp_session_bucket "$PROJECT_DIR")"
O_KEY="$(project_state_key)"

if omp_bound "$RUN_DIR/omp:$OMP" && [[ "$(readlink "$OMP_HOME_DIR/natives")" == /usr/local/omp/natives ]] \
    && ! omp_bound_src_under "$OMP/natives" && ! omp_bound_src_under "$OMP/run" \
    && ! omp_bound_src_under "$OMP/logs" && ! omp_bound_src_under "$OMP:"; then
    ok O1 "per-run ~/.omp: the host's natives, run/ and logs are not bound"
else
    bad O1 "a host ~/.omp path holding code or sockets is bound into the sandbox"
fi
if [[ -f "$OMP_HOME_DIR/agent/config.yml" && ! -L "$OMP_HOME_DIR/agent/config.yml" ]] \
    && cmp -s "$OMP_HOME_DIR/agent/config.yml" "$OMP/agent/config.yml" \
    && ! omp_bound_under "$OMP/agent/config.yml"; then
    ok O2 "config.yml is a plain per-run copy, so omp's rename-based save cannot hit EBUSY"
else
    bad O2 "config.yml is a bind (EBUSY on save) or not the host's content"
fi
if omp_bound "$OMP/agent/extensions:$OMP/agent/extensions:ro" && omp_bound "$OMP/agent/RULES.md:$OMP/agent/RULES.md:ro" \
    && omp_bound "$OMP/agent/agent.db" && omp_bound "$OMP/agent/sessions/$O_BUCKET" \
    && ! omp_bound_under "$OMP/agent/sessions/-elsewhere" && ! omp_bound_under "$OMP/agent/.env" \
    && ! omp_bound_under "$OMP/agent/secret-placeholder.key" && ! omp_bound_under "$OMP/agent/history.db" \
    && ! omp_bound_under "$OMP/agent/models.db" && ! omp_bound_under "$OMP/agent/terminal-sessions"; then
    ok O3 "host config read-only; agent.db and this checkout's sessions shared; .env, key, other state not bound"
else
    bad O3 "the agent directory's binds do not match the allowlist"
fi
if [[ "$(readlink "$OMP_HOME_DIR/agent/history.db")" == .sandbox-history/history.db ]] \
    && omp_bound "$HOME/.agent/omp-history/$O_KEY:$OMP/agent/.sandbox-history"; then
    ok O4 "history.db is this project's own database, not the host's"
else
    bad O4 "history.db does not resolve to the per-project database"
fi
if [[ "$(omp_session_bucket "$HOME/projects/p")" == -projects-p \
    && "$(omp_session_bucket /usr/share)" == --usr-share-- \
    && "$(omp_session_bucket "$W")" == "-tmp-${W#"$(readlink -f "${TMPDIR:-/tmp}")"/}" ]]; then
    ok O5 "session folders are named the way omp names them"
else
    bad O5 "omp_session_bucket disagrees with omp's scheme"
fi
# The session edits its copy; only modelRoles/cycleOrder may reach the host.
sed -i 's|default: vendor/big|default: vendor/other|; s|dark: night|dark: day|' "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
if grep -q '^  default: vendor/other$' "$OMP/agent/config.yml" && grep -q '^  dark: night$' "$OMP/agent/config.yml" \
    && [[ "$(omp_config_block "$OMP/agent/config.yml" cycleOrder)" == "$(printf 'cycleOrder:\n  - vendor/big\n  - vendor/small')" ]] \
    && grep -q 'dark: day' "$W/omp-merge.err"; then
    ok O7 "a modelRoles change merges back; a theme change is only reported"
else
    bad O7 "the merge-back took the wrong keys"
fi
sed -i 's|smol: vendor/small|smol: vendor/hostpick|' "$OMP/agent/config.yml"
sed -i 's|smol: vendor/small|smol: vendor/sessionpick|' "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  smol: vendor/hostpick$' "$OMP/agent/config.yml" && grep -q 'changed on the host' "$W/omp-merge.err" \
    && ok O8 "a change made on the host during the run wins, and is reported" \
    || bad O8 "the session overwrote a concurrent host change"
printf 'cycleOrder:\n  - vendor/big\n  - vendor/x; touch /tmp/pwn\n' >"$W/omp-bad.block"
omp_config_with_block "$OMP_HOME_DIR/agent/config.yml" cycleOrder "$W/omp-bad.block" >"$W/omp-bad.yml"
cp "$W/omp-bad.yml" "$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  - vendor/small$' "$OMP/agent/config.yml" && ! grep -q 'pwn' "$OMP/agent/config.yml" \
    && ok O9 "a value that is not a plain model id is not merged" \
    || bad O9 "a non-model-id value reached the host config"
: >"$OMP_HOME_DIR/agent/SYSTEM.md"
: >"$OMP_HOME_DIR/agent/models.db-wal"
omp_home_report_created 2>"$W/omp-created.err"
grep -q 'agent/SYSTEM.md' "$W/omp-created.err" && ! grep -q 'models.db' "$W/omp-created.err" \
    && ok O10 "a config file created in-session is named at exit; omp's own state is not" \
    || bad O10 "the exit report missed a created config file, or listed omp's state"
# The merge reads only the form omp writes (omp_config_standard). Each
# case starts from a host file, a launch copy and a session copy set here.
o_std() { printf '%b' "$1" >"$OMP/agent/config.yml"; cp "$OMP/agent/config.yml" "$RUN_DIR/omp-config.orig"; }
O_HOST='modelRoles:\n  default: vendor/a\ncycleOrder:\n  - vendor/a\n'
o12=0
# A top-level key the line scanner cannot see: nothing merged, nothing listed.
o_std "$O_HOST"
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\n"theme": x\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" && grep -q 'not in the form omp writes' "$W/omp-merge.err" \
    && grep -q '"theme": x' "$W/omp-merge.err" || o12=1
# "KEY:VALUE" without the space is a plain scalar to YAML, not a key.
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\ntheme:x\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" && grep -q 'not in the form omp writes' "$W/omp-merge.err" || o12=1
# A host file outside the form is never written, however clean the session.
o_std "$O_HOST"
printf '# mine\n%b' "$O_HOST" >"$OMP/agent/config.yml"
printf 'modelRoles:\n  default: vendor/b\ncycleOrder:\n  - vendor/a\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
grep -q '^# mine$' "$OMP/agent/config.yml" && grep -q '^  default: vendor/a$' "$OMP/agent/config.yml" \
    && grep -q 'not in the form omp writes' "$W/omp-merge.err" || o12=1
[[ "$o12" -eq 0 ]] \
    && ok O12 "a session copy or host file outside omp's written form merges nothing, and says so" \
    || bad O12 "the merge read or wrote a config.yml that is not in the form omp writes"
# omp writes an emptied list as the key followed by an indented "[]".
o_std "$O_HOST"
printf 'modelRoles:\n  default: vendor/a\ncycleOrder:\n  []\n' >"$OMP_HOME_DIR/agent/config.yml"
omp_config_merge 2>"$W/omp-merge.err"
[[ "$(omp_config_block "$OMP/agent/config.yml" cycleOrder)" == "$(printf 'cycleOrder:\n  []')" ]] \
    && ok O13 "an emptied cycleOrder, in the form omp writes it, merges back" \
    || bad O13 "omp's own empty-list form did not merge"
OMP_HOME_DIR=""
# The image-natives check: the stand-in apptainer runs the probe's own
# command on the host, which plays the image, so OMP_IMAGE_NATIVES decides
# whether the "image" has the directory.
mkdir -p "$W/bin"
PATH="$W/bin:$PATH"
SANDBOX_IMAGE="$W/agent.sif"
: > "$SANDBOX_IMAGE"
cat > "$W/bin/apptainer" <<STUB
#!/bin/sh
while [ "\$#" -gt 0 ] && [ "\$1" != "$SANDBOX_IMAGE" ]; do shift; done
[ "\$#" -gt 0 ] || exit 255
shift
exec "\$@"
STUB
chmod +x "$W/bin/apptainer"
o11=0
# shellcheck disable=SC2034  # OMP_IMAGE_NATIVES is read by omp_home_require_natives (functions/omp-home.sh)
( OMP_IMAGE_NATIVES="$W/no-such-natives"; omp_home_require_natives ) >/dev/null 2>&1 && o11=1
( OMP_IMAGE_NATIVES="$W"; omp_home_require_natives ) >/dev/null 2>&1 || o11=1
printf '#!/bin/sh\nexit 255\n' > "$W/bin/apptainer"
# shellcheck disable=SC2034  # see above
( OMP_IMAGE_NATIVES="$W/no-such-natives"; omp_home_require_natives ) >/dev/null 2>&1 || o11=1
[[ "$o11" -eq 0 ]] \
    && ok O11 "an image without the build-time native addons refuses; one that has them, or cannot be asked, does not" \
    || bad O11 "the image-natives check refused wrongly, or let an old image through"

# o_refuses ARG...: omp_home_refuse_overrides with ARGS=(ARG...), in an
# environment holding only O_ENV of the variables it reads; true if it
# refused. The container sees only APPTAINERENV_-forwarded variables, so
# those are what must refuse -- and a host-only variable must not.
o_refuses() {
    (
        unset OMP_PROFILE PI_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR PI_CODING_AGENT_SESSION_DIR
        unset APPTAINERENV_OMP_PROFILE APPTAINERENV_PI_PROFILE APPTAINERENV_PI_CODING_AGENT_DIR \
            APPTAINERENV_PI_CONFIG_DIR APPTAINERENV_PI_CODING_AGENT_SESSION_DIR
        if [[ -n "${O_ENV:-}" ]]; then export "${O_ENV?}"; fi
        # shellcheck disable=SC2034  # ARGS and VERBOSE are read by omp_home_refuse_overrides and log_info
        ARGS=("$@") VERBOSE=0
        omp_home_refuse_overrides
    ) >/dev/null 2>&1 && return 1
    return 0
}
o_fail=0
o_refuses --profile work || o_fail=1
O_ENV=APPTAINERENV_OMP_PROFILE=work o_refuses || o_fail=1
O_ENV=APPTAINERENV_PI_CODING_AGENT_DIR=/x o_refuses || o_fail=1
o_refuses --profile=default && o_fail=1
O_ENV=APPTAINERENV_OMP_PROFILE=' default ' o_refuses && o_fail=1
O_ENV=OMP_PROFILE=work o_refuses && o_fail=1
O_ENV=PI_CODING_AGENT_DIR=/x o_refuses && o_fail=1
[[ "$o_fail" -eq 0 ]] \
    && ok O6 "a named profile or directory override that reaches the sandbox refuses; the default profile, and host-only variables, run" \
    || bad O6 "profile/override refusal is wrong"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
