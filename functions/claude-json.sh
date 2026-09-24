#!/bin/bash
# ~/.claude.json: the per-run copy inside claude's per-run home
# (functions/claude-home.sh), the allowlist merge that brings a few of its
# keys back into the real file at exit, and the key-level scanner both
# read it with.
#
# ~/.claude.json keeps state claude rewrites constantly -- session
# records, per-project trust decisions -- in the SAME file as what a later
# bare-host `claude` spawns and trusts: top-level `mcpServers` (user
# scope), `apiKeyHelper` (a command claude runs for credentials) and `env`,
# and under `projects.<path>` the local-scope `mcpServers`,
# `hasTrustDialogAccepted` (workspace trust without a dialog) and the
# enabled/disabled server lists (Claude Code's MCP docs). A merge that
# let any of it back would hand the session the next unsandboxed run's
# spawn list and trust decisions. So the session works on its copy, only
# CLAUDE_JSON_MERGE_KEYS -- which spawn nothing and trust nothing -- ever
# reach the real file, and every other change is reported at exit.
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
# MODE=validate  -> exit status only (0 structurally sound, 1 not): one
#                   top-level object, nothing but whitespace around it
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
    depth = 0; instr = 0; esc = 0; opened = 0
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
        # Outside the top-level value only whitespace may appear, and the
        # value itself has to be one object: "{}{}" or "[]" is refused.
        if (depth == 0 && c !~ /[ \t\r\n]/) {
            if (c != "{" || opened) fail("not one object")
            opened = 1
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
    if (instr || depth != 0 || !opened) fail("unterminated")
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

# claude_json_wellformed FILE: structurally sound JSON-ish -- one top-level
# object with nothing but whitespace around it, balanced braces and
# brackets, every string terminated, no top-level key written with a
# backslash escape. Not a full validator, and it does not pretend to be: it
# catches a truncated or half-written file, and a key spelled so that a
# byte comparison and a JSON parser would disagree about it.
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

# claude_json_with_value FILE KEY VALUE: FILE on stdout with top-level KEY's
# value replaced by VALUE (raw JSON text), or with "KEY":VALUE inserted as
# the first member when FILE has no such key; every other byte is FILE's
# own. Non-zero when FILE is not well-formed or KEY is ambiguous
# (claude_json_span). KEY is one of CLAUDE_JSON_MERGE_KEYS, so it needs no
# escaping.
claude_json_with_value() {
    local f="$1" key="$2" value="$3" span open
    claude_json_wellformed "$f" || return 1
    span="$(claude_json_span "$f" "$key")" || return 1
    if [[ -n "$span" ]]; then
        head -c "$((${span%% *} - 1))" -- "$f" || return 1
        printf '%s' "$value"
        tail -c +"$((${span%% *} + ${span##* }))" -- "$f"
        return
    fi
    # The byte count up to and including the object's opening brace.
    open="$(LC_ALL=C awk -v RS='\0' 'match($0, /^[ \t\r\n]*[{]/) { print RLENGTH }' <"$f")"
    [[ "$open" =~ ^[0-9]+$ ]] || return 1
    head -c "$open" -- "$f" || return 1
    printf '"%s":%s' "$key" "$value"
    if [[ -n "$(claude_json_keys "$f")" ]]; then
        printf ','
    fi
    tail -c +"$((open + 1))" -- "$f"
}

# CLAUDE_JSON_COPY: the per-run copy, ~/.claude.json inside claude's
# per-run home, empty when this run is not a claude run; CLAUDE_JSON_ORIG:
# its launch state, outside that home, which the merge and the report
# compare against.
CLAUDE_JSON_COPY=""
CLAUDE_JSON_ORIG=""

# CLAUDE_JSON_LAST: where the session's last version of the file is kept
# on the host for the human to inspect -- one file, overwritten by each
# run that changed it, outside every checkout.
CLAUDE_JSON_LAST="$HOME/.agent/claude.json.last-session"

# CLAUDE_JSON_MERGE_KEYS: the only top-level keys that ever reach the real
# file, each with one fixed shape (claude_json_mergeable). A key belongs
# here only if nothing a later claude does with its value runs a command,
# trusts a path, or reaches a server.
CLAUDE_JSON_MERGE_KEYS=(theme hasCompletedOnboarding lastOnboardingVersion)

# CLAUDE_JSON_MERGED / CLAUDE_JSON_SKIPPED: what the last claude_json_merge
# wrote into the real file, and what it left out, each with its reason.
CLAUDE_JSON_MERGED=()
CLAUDE_JSON_SKIPPED=()

# claude_json_prepare: put a COPY of ~/.claude.json (an empty object when
# the host has none) at ~/.claude.json inside claude's per-run home, as a
# plain file, so claude's lock, temporary file and rename all land in the
# per-run home (functions/claude-home.sh). The real file is never bound.
claude_json_prepare() {
    local real="$HOME/.claude.json"
    [[ -n "${CLAUDE_HOME_DIR:-}" && -d "$CLAUDE_HOME_DIR" ]] || return 1
    CLAUDE_JSON_COPY="$CLAUDE_HOME_DIR/.claude.json"
    CLAUDE_JSON_ORIG="$RUN_DIR/claude.json.orig"
    if [[ -f "$real" ]]; then
        cp -- "$real" "$CLAUDE_JSON_COPY" || return 1
    else
        printf '%s\n' '{}' >"$CLAUDE_JSON_COPY" || return 1
    fi
    cp -- "$CLAUDE_JSON_COPY" "$CLAUDE_JSON_ORIG" || return 1
    chmod 600 -- "$CLAUDE_JSON_COPY" "$CLAUDE_JSON_ORIG"
}

# claude_json_mergeable KEY VALUE: VALUE, raw JSON text, is exactly the
# shape claude writes for KEY -- a theme name, a boolean, a version string.
claude_json_mergeable() {
    local LC_ALL=C re
    case "$1" in
        theme) re='^"[a-z][a-z0-9-]{0,31}"$' ;;
        hasCompletedOnboarding) re='^(true|false)$' ;;
        lastOnboardingVersion) re='^"[0-9]{1,5}[.][0-9]{1,5}[.][0-9]{1,5}[A-Za-z0-9.+-]{0,32}"$' ;;
        *) return 1 ;;
    esac
    [[ "$2" =~ $re ]]
}

# claude_json_is_one_of WORD LIST...: WORD equals one of LIST.
claude_json_is_one_of() {
    local w="$1" x
    shift
    for x in "$@"; do
        [[ "$x" == "$w" ]] && return 0
    done
    return 1
}

# claude_json_skip_all REASON KEY...: record each KEY as not merged.
claude_json_skip_all() {
    local reason="$1" key
    shift
    for key in "$@"; do
        CLAUDE_JSON_SKIPPED+=("$key: $reason")
    done
}

# claude_json_rewrite_ok OLD NEW KEY...: NEW is well-formed, holds the
# session's value for each KEY, and every other top-level key of OLD and
# NEW is in both or in neither, with byte-identical values.
claude_json_rewrite_ok() {
    local old="$1" new="$2" k a b
    shift 2
    claude_json_wellformed "$new" || return 1
    for k in "$@"; do
        a="$(claude_json_value "$CLAUDE_JSON_COPY" "$k")" || return 1
        b="$(claude_json_value "$new" "$k")" || return 1
        [[ -n "$b" && "$a" == "$b" ]] || return 1
    done
    while IFS= read -r k; do
        claude_json_is_one_of "$k" "$@" && continue
        a="$(claude_json_value "$old" "$k")" || return 1
        b="$(claude_json_value "$new" "$k")" || return 1
        [[ "$a" == "$b" ]] || return 1
    done < <({ claude_json_keys "$old"; claude_json_keys "$new"; } | LC_ALL=C sort -u)
}

# claude_json_merge: of the CLAUDE_JSON_MERGE_KEYS the session changed in
# its copy, bring each into the real ~/.claude.json when the new value has
# the shape claude writes, the session did not remove the key, and the real
# file still holds the launch value -- a change made on the host meanwhile
# wins. The real file is rewritten under claude's own lock (the directory
# ~/.claude.json.lock, which claude creates before every save), only when
# the rewrite differs from it in exactly the merged keys, and never when it
# is a symlink or not well-formed; with no real file, one is created that
# holds only the merged keys. A killed run never gets here, so it merges
# nothing.
claude_json_merge() {
    local real="$HOME/.claude.json" lock="$HOME/.claude.json.lock" key s_orig s_now tries=0
    local -a pending=()
    for key in "${CLAUDE_JSON_MERGE_KEYS[@]}"; do
        s_orig="$(claude_json_value "$CLAUDE_JSON_ORIG" "$key")" || s_orig=$'\001ambiguous'
        if ! s_now="$(claude_json_value "$CLAUDE_JSON_COPY" "$key")"; then
            CLAUDE_JSON_SKIPPED+=("$key: set more than once in the session's copy")
            continue
        fi
        if [[ "$s_now" == "$s_orig" ]]; then
            continue
        fi
        if [[ -z "$s_now" ]]; then
            CLAUDE_JSON_SKIPPED+=("$key: removed by the session; the real file keeps its value")
        elif ! claude_json_mergeable "$key" "$s_now"; then
            CLAUDE_JSON_SKIPPED+=("$key: not the shape claude writes")
        else
            pending+=("$key")
        fi
    done
    [[ ${#pending[@]} -gt 0 ]] || return 0
    if [[ -L "$real" || ( -e "$real" && ! -f "$real" ) ]]; then
        claude_json_skip_all "$real is a symlink or not a regular file" "${pending[@]}"
        return 0
    fi
    until mkdir -- "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [[ "$tries" -ge 30 ]]; then
            claude_json_skip_all "$lock stayed held, by a claude saving on the host" "${pending[@]}"
            return 0
        fi
        sleep 0.1
    done
    claude_json_merge_locked "${pending[@]}"
    rmdir -- "$lock" 2>/dev/null
    return 0
}

# claude_json_merge_locked KEY...: the part of claude_json_merge that runs
# while it holds claude's lock on the real file.
claude_json_merge_locked() {
    local real="$HOME/.claude.json" key s_orig s_now h_now tmp
    local snap="$RUN_DIR/claude.json.host" newf="$RUN_DIR/claude.json.new" step="$RUN_DIR/claude.json.step"
    local -a merged=()
    if [[ -f "$real" ]]; then
        if ! cp -- "$real" "$snap"; then
            claude_json_skip_all "could not read $real" "$@"
            return 0
        fi
    else
        printf '%s\n' '{}' >"$snap" || return 0
    fi
    if ! claude_json_wellformed "$snap"; then
        claude_json_skip_all "$real is not well-formed JSON, so it is not rewritten" "$@"
        return 0
    fi
    cp -- "$snap" "$newf" || return 0
    for key in "$@"; do
        s_orig="$(claude_json_value "$CLAUDE_JSON_ORIG" "$key")" || s_orig=$'\001ambiguous'
        h_now="$(claude_json_value "$snap" "$key")" || h_now=$'\002ambiguous'
        if [[ "$h_now" != "$s_orig" ]]; then
            CLAUDE_JSON_SKIPPED+=("$key: changed on the host during the run; the host's value stays")
            continue
        fi
        s_now="$(claude_json_value "$CLAUDE_JSON_COPY" "$key")" || continue
        if ! claude_json_with_value "$newf" "$key" "$s_now" >"$step"; then
            CLAUDE_JSON_SKIPPED+=("$key: could not be written into $real")
            continue
        fi
        mv -f -- "$step" "$newf" || return 0
        merged+=("$key")
    done
    [[ ${#merged[@]} -gt 0 ]] || return 0
    if ! claude_json_rewrite_ok "$snap" "$newf" "${merged[@]}"; then
        claude_json_skip_all "the rewrite would have touched more than these keys" "${merged[@]}"
        return 0
    fi
    # Written beside the real file and renamed over it, so a reader never
    # sees half a file; cp -p carries an existing file's mode over, and a
    # new one keeps mktemp's 0600.
    if ! tmp="$(mktemp "$HOME/.claude.json.sandbox-merge.XXXXXX")"; then
        claude_json_skip_all "could not write beside $real" "${merged[@]}"
        return 0
    fi
    if ! { { [[ ! -f "$real" ]] || cp -p -- "$real" "$tmp"; } && cat -- "$newf" >"$tmp" \
            && mv -f -- "$tmp" "$real"; }; then
        rm -f -- "$tmp"
        claude_json_skip_all "could not replace $real" "${merged[@]}"
        return 0
    fi
    # A worktree re-run starts from what was just merged.
    for key in "${merged[@]}"; do
        s_now="$(claude_json_value "$CLAUDE_JSON_COPY" "$key")" || continue
        if claude_json_with_value "$CLAUDE_JSON_ORIG" "$key" "$s_now" >"$step"; then
            mv -f -- "$step" "$CLAUDE_JSON_ORIG"
        fi
    done
    CLAUDE_JSON_MERGED=("${merged[@]}")
}

# claude_json_finish: after every container exit, on the host. Merges the
# allowlisted keys the session changed (claude_json_merge), names every
# other top-level key it changed, keeps its version at CLAUDE_JSON_LAST and
# says how to compare it. Key names and reasons carry session-chosen text,
# so the output is sanitized.
claude_json_finish() {
    local key a b keep="$CLAUDE_JSON_LAST"
    local -a others=()
    [[ -n "${CLAUDE_JSON_COPY:-}" && -f "$CLAUDE_JSON_COPY" && ! -L "$CLAUDE_JSON_COPY" ]] || return 0
    cmp -s -- "$CLAUDE_JSON_ORIG" "$CLAUDE_JSON_COPY" && return 0
    CLAUDE_JSON_MERGED=() CLAUDE_JSON_SKIPPED=()
    if ! claude_json_wellformed "$CLAUDE_JSON_COPY"; then
        others=("(none merged: the file is truncated, not one JSON object, or has a top-level key written with a backslash escape)")
    else
        while IFS= read -r key; do
            claude_json_is_one_of "$key" "${CLAUDE_JSON_MERGE_KEYS[@]}" && continue
            a="$(claude_json_value "$CLAUDE_JSON_ORIG" "$key")" || a=$'\001ambiguous'
            b="$(claude_json_value "$CLAUDE_JSON_COPY" "$key")" || b=$'\002ambiguous'
            [[ "$a" == "$b" ]] || others+=("$key")
        done < <({ claude_json_keys "$CLAUDE_JSON_ORIG"; claude_json_keys "$CLAUDE_JSON_COPY"; } | LC_ALL=C sort -u)
        claude_json_merge
    fi
    if [[ -L "$keep" ]] || ! { mkdir -p -- "${keep%/*}" && cp -- "$CLAUDE_JSON_COPY" "$keep" && chmod 600 -- "$keep"; }; then
        keep=""
    fi
    {
        if [[ ${#CLAUDE_JSON_MERGED[@]} -gt 0 ]]; then
            printf '%s\n' "sandbox: merged into ~/.claude.json from the session: ${CLAUDE_JSON_MERGED[*]}"
        fi
        if [[ ${#CLAUDE_JSON_SKIPPED[@]} -gt 0 ]]; then
            printf '%s\n' "sandbox: changed by the session but NOT merged into ~/.claude.json:"
            printf '    %s\n' "${CLAUDE_JSON_SKIPPED[@]}"
        fi
        if [[ ${#others[@]} -gt 0 ]]; then
            printf '%s\n' "sandbox: the session also changed these ~/.claude.json keys, which stay in the run:"
            printf '%s\n' "  ${others[*]}"
            printf '%s\n' "  Only ${CLAUDE_JSON_MERGE_KEYS[*]} ever reach your real file:"
            printf '%s\n' "  mcpServers, projects, apiKeyHelper and env there decide what an unsandboxed claude"
            printf '%s\n' "  runs and which folders it trusts."
        fi
        if [[ -n "$keep" ]] && [[ ${#CLAUDE_JSON_SKIPPED[@]} -gt 0 || ${#others[@]} -gt 0 ]]; then
            printf '%s\n' "  The session's version: $keep"
            printf '%s\n' "    compare: diff -u ~/.claude.json $keep"
        fi
    } | sanitize_agent_display >&2 || true
    return 0
}
