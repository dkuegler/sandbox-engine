#!/bin/bash
# ~/.claude.json key access: read one TOP-LEVEL key's value, or put a
# different value in its place, without touching any other byte.
#
# ~/.claude.json keeps state claude must carry between runs -- session
# records, per-project trust decisions, MCP OAuth tokens -- in the SAME
# file as `mcpServers`, a list of command lines a later bare-host `claude`
# will spawn. Handling that file key by key needs exactly two operations:
# the value of one top-level key, and the file with that value replaced.
#
# No jq and no python3. Neither can be assumed present, so the key
# extraction below is a small explicit JSON scanner in awk: it tracks
# string and escape state, counts nesting, and reports the byte span of
# one TOP-LEVEL key's value. Byte spans rather than re-serialised JSON is
# deliberate -- nothing here may reformat, reorder or re-encode a file
# claude owns, and splicing a span leaves every other byte exactly as the
# agent left it.
#
# Every awk run is LC_ALL=C: in a UTF-8 locale gawk's length() and
# substr() count characters, not bytes, and the spans are cut by byte
# offset -- one non-ASCII character before a key (a project path, say)
# would shift every offset after it.

# CLAUDE_JSON_SCANNER: awk program, shared by the three operations below.
# MODE=validate  -> exit status only (0 structurally sound, 1 not)
# MODE=span      -> prints "START LENGTH" (1-based byte offset) for KEY's
#                   value, one line per occurrence at depth 1, or nothing
#                   when the key is absent
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
# to be: it catches the failure a key-by-key merge actually has to
# survive, which is a truncated or half-written file, and anything it
# passes is spliced by byte offset rather than re-encoded.
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

# claude_json_splice FILE KEY REPLFILE OUT: write FILE to OUT with the
# value of top-level KEY replaced by REPLFILE's exact bytes; every other
# byte of FILE is copied unchanged. Non-zero -- and OUT not to be used --
# when KEY is absent or ambiguous (claude_json_span), or when the result
# is not well-formed (claude_json_wellformed), so a bad replacement can
# never produce a file the caller installs.
claude_json_splice() {
    local f="$1" key="$2" repl="$3" out="$4" span start len
    span="$(claude_json_span "$f" "$key")" || return 1
    [[ -n "$span" ]] || return 1
    start="${span%% *}"
    len="${span##* }"
    {
        head -c "$((start - 1))" -- "$f"
        cat -- "$repl"
        tail -c +"$((start + len))" -- "$f"
    } >"$out" || return 1
    claude_json_wellformed "$out"
}
