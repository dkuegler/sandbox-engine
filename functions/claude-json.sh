#!/bin/bash
# ~/.claude.json: a per-run copy bound in place of the real file, which a
# sandboxed run never writes back, and the key-level scanner the exit
# report reads it with.
#
# ~/.claude.json keeps state claude rewrites constantly -- session
# records, per-project trust decisions -- in the SAME file as what a later
# bare-host `claude` spawns and trusts: top-level `mcpServers` (user
# scope), and under `projects.<path>` the local-scope `mcpServers`,
# `hasTrustDialogAccepted` (workspace trust without a dialog) and the
# enabled/disabled server lists (Claude Code's MCP docs). A merge that
# let any of it back would hand the session the next unsandboxed run's
# spawn list and trust decisions, so nothing is merged: the session works
# on its copy, and what it changed is reported at exit.
#
# No jq and no python3. Neither can be assumed present, so the key
# extraction below is a small explicit JSON scanner in awk: it tracks
# string and escape state, counts nesting, and reports the byte span of
# one TOP-LEVEL key's value, so two versions of a key compare byte for
# byte.
#
# Every awk run is LC_ALL=C: in a UTF-8 locale gawk's length() and
# substr() count characters, not bytes, and the spans are cut by byte
# offset -- one non-ASCII character before a key (a project path, say)
# would shift every offset after it.

# CLAUDE_JSON_SCANNER: awk program, shared by the operations below.
# MODE=validate  -> exit status only (0 structurally sound, 1 not)
# MODE=span      -> prints "START LENGTH" (1-based byte offset) for KEY's
#                   value, one line per occurrence at depth 1, or nothing
#                   when the key is absent
# MODE=keys      -> prints every top-level key, one per line, in file
#                   order, repeats included
#
# RS='\0' makes the whole file one record: a NUL cannot occur in JSON text,
# so this reads the exact bytes without awk appending a newline the file
# did not have.
# read -d '' stops at end of input, not at a NUL, and so always returns 1:
# without "|| true", sourcing this file under sandbox.sh's set -e exits.
read -r -d '' CLAUDE_JSON_SCANNER <<'AWK' || true
function fail(msg) { bad = 1; exit 1 }
{
    s = $0
    n = length(s)
    depth = 0; instr = 0; esc = 0
    keystart = 0; keyend = 0
    laststart = 0; lastend = 0
    pending = ""
    vstart = 0; vlen = 0
    i = 1
    while (i <= n) {
        c = substr(s, i, 1)
        if (instr) {
            if (esc) { esc = 0 }
            else if (c == "\\") { esc = 1 }
            else if (c == "\"") { instr = 0; lastend = i }
            i++
            continue
        }
        if (c == "\"") { instr = 1; laststart = i; i++; continue }
        if (c == "{" || c == "[") { depth++; i++; continue }
        if (c == "}" || c == "]") { depth--; if (depth < 0) fail("unbalanced"); i++; continue }
        if (c == ":" && depth == 1) {
            # The string that just closed is this pair's key.
            pending = substr(s, laststart + 1, lastend - laststart - 1)
            if (pending ~ /\\/) escaped = 1
            i++
            # Value begins at the next non-whitespace byte.
            while (i <= n && substr(s, i, 1) ~ /[ \t\r\n]/) i++
            if (i > n) fail("truncated")
            vs = i
            # Walk exactly one value, honouring nesting and strings.
            vdepth = 0
            while (i <= n) {
                c = substr(s, i, 1)
                if (instr) {
                    if (esc) { esc = 0 }
                    else if (c == "\\") { esc = 1 }
                    else if (c == "\"") { instr = 0 }
                    i++
                    continue
                }
                if (c == "\"") { instr = 1; i++; continue }
                if (c == "{" || c == "[") { vdepth++; i++; continue }
                if (c == "}" || c == "]") {
                    if (vdepth == 0) break
                    vdepth--
                    i++
                    if (vdepth == 0) break
                    continue
                }
                if (c == "," && vdepth == 0) break
                i++
            }
            ve = i - 1
            # Trim trailing whitespace from the value span.
            while (ve > vs && substr(s, ve, 1) ~ /[ \t\r\n]/) ve--
            nkeys++
            keylist[nkeys] = pending
            if (pending == key) {
                nmatch++
                spanlist[nmatch] = vs " " (ve - vs + 1)
            }
            continue
        }
        i++
    }
    if (instr || depth != 0) fail("unterminated")
    # A top-level key written with a backslash escape is refused outright.
    # "\u006dcpServers" is the same key as "mcpServers" to every real JSON
    # parser and a DIFFERENT one to a byte comparison, so allowing it would
    # let a session smuggle a server definition straight past this gate.
    # No claude-written key needs an escape, so refusing costs nothing.
    if (escaped) fail("escaped top-level key")
    if (mode == "span") {
        # Every match, not just the last: a file with the key twice is
        # ambiguous (parsers disagree on which wins), and the caller must
        # refuse rather than pick one.
        for (m = 1; m <= nmatch; m++) print spanlist[m]
    }
    if (mode == "keys") {
        for (m = 1; m <= nkeys; m++) print keylist[m]
    }
}
END { if (bad) exit 1 }
AWK

# claude_json_scan MODE KEY FILE: run the scanner over FILE.
claude_json_scan() {
    LC_ALL=C awk -v RS='\0' -v mode="$1" -v key="$2" "$CLAUDE_JSON_SCANNER" <"$3"
}

# claude_json_wellformed FILE: structurally sound JSON-ish -- balanced
# braces and brackets, every string terminated, no top-level key written
# with a backslash escape. Not a full validator, and it does not pretend
# to be: it catches a truncated or half-written file, and a key spelled so
# that a byte comparison and a JSON parser would disagree about it.
claude_json_wellformed() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    claude_json_scan validate "" "$f" >/dev/null 2>&1
}

# claude_json_span FILE KEY: "START LENGTH" of top-level KEY's value;
# empty when the key is absent. Non-zero when FILE is unusable or the key
# occurs more than once at top level: JSON parsers disagree about which of
# two same-named keys wins, so there is no single honest answer and the
# caller must not be handed a guess.
claude_json_span() {
    local span
    span="$(claude_json_scan span "$2" "$1" 2>/dev/null)" || return 1
    [[ "$span" != *$'\n'* ]] || return 1
    printf '%s' "$span"
}

# claude_json_value FILE KEY: the raw text of top-level KEY's value, or
# nothing when the key is absent. Non-zero when FILE is unusable or the
# key is ambiguous (claude_json_span).
claude_json_value() {
    local f="$1" span
    [[ -s "$f" ]] || return 0
    span="$(claude_json_span "$f" "$2")" || return 1
    [[ -n "$span" ]] || return 0
    tail -c +"${span%% *}" -- "$f" | head -c "${span##* }"
}

# claude_json_keys FILE: FILE's top-level keys, sorted, each once.
claude_json_keys() {
    claude_json_scan keys "" "$1" 2>/dev/null | LC_ALL=C sort -u
}

# CLAUDE_JSON_COPY: the per-run file bound at ~/.claude.json, empty when
# this run is not a claude run; CLAUDE_JSON_ORIG: its launch state, which
# the exit report compares against.
CLAUDE_JSON_COPY=""
CLAUDE_JSON_ORIG=""

# CLAUDE_JSON_LAST: where the session's last version of the file is kept
# on the host for the human to inspect -- one file, overwritten by each
# run that changed it, outside every checkout.
CLAUDE_JSON_LAST="$HOME/.agent/claude.json.last-session"

# claude_json_prepare: bind a per-run COPY of ~/.claude.json in place of
# the real file (an empty object when the host has none). The real file is
# never bound and never written by the run.
claude_json_prepare() {
    local real="$HOME/.claude.json"
    ensure_run_dir
    CLAUDE_JSON_COPY="$RUN_DIR/claude.json"
    CLAUDE_JSON_ORIG="$RUN_DIR/claude.json.orig"
    if [[ -f "$real" ]]; then
        cp -- "$real" "$CLAUDE_JSON_COPY" || return 1
    else
        printf '%s\n' '{}' >"$CLAUDE_JSON_COPY" || return 1
    fi
    cp -- "$CLAUDE_JSON_COPY" "$CLAUDE_JSON_ORIG" || return 1
    chmod 600 -- "$CLAUDE_JSON_COPY" "$CLAUDE_JSON_ORIG"
    BINDS+=(-B "$CLAUDE_JSON_COPY:$real")
}

# claude_json_report: after every container exit, on the host. Names the
# top-level keys the session changed in its copy, keeps its version at
# CLAUDE_JSON_LAST and says how to compare it; the real file is not
# touched. Key names come from the session, so the output is sanitized.
claude_json_report() {
    local key a b keep="$CLAUDE_JSON_LAST"
    local -a changed=()
    [[ -n "${CLAUDE_JSON_COPY:-}" && -f "$CLAUDE_JSON_COPY" && ! -L "$CLAUDE_JSON_COPY" ]] || return 0
    cmp -s -- "$CLAUDE_JSON_ORIG" "$CLAUDE_JSON_COPY" && return 0
    if ! claude_json_wellformed "$CLAUDE_JSON_COPY"; then
        changed=("(the file is truncated, or a top-level key is written with a backslash escape)")
    else
        while IFS= read -r key; do
            a="$(claude_json_value "$CLAUDE_JSON_ORIG" "$key")" || a=$'\001ambiguous'
            b="$(claude_json_value "$CLAUDE_JSON_COPY" "$key")" || b=$'\002ambiguous'
            [[ "$a" == "$b" ]] || changed+=("$key")
        done < <({ claude_json_keys "$CLAUDE_JSON_ORIG"; claude_json_keys "$CLAUDE_JSON_COPY"; } | LC_ALL=C sort -u)
    fi
    if [[ -L "$keep" ]] || ! { mkdir -p -- "${keep%/*}" && cp -- "$CLAUDE_JSON_COPY" "$keep" && chmod 600 -- "$keep"; }; then
        keep=""
    fi
    {
        printf '%s\n' "sandbox: the session changed its copy of ~/.claude.json; your real file is untouched."
        printf '%s\n' "  A sandboxed run never writes it back: mcpServers and projects.<path> there"
        printf '%s\n' "  decide what an unsandboxed claude spawns and which folders it trusts."
        printf '%s\n' "  Changed top-level keys: ${changed[*]:-(formatting only)}"
        if [[ -n "$keep" ]]; then
            printf '%s\n' "  The session's version: $keep"
            printf '%s\n' "    compare: diff -u ~/.claude.json $keep"
        fi
    } | sanitize_agent_display >&2 || true
    return 0
}
