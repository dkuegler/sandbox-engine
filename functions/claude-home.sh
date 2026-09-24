#!/bin/bash
# claude's $HOME inside the sandbox: a per-run directory.
#
# claude saves every file it keeps the same way: it takes a lock by
# creating the directory "<file>.lock" beside the file, writes
# "<file>.tmp.<suffix>" beside it and renames that over the file; when the
# rename fails because the file is a bind mount (EBUSY), it rewrites the
# file in place instead. So the file's DIRECTORY has to be writable, not
# just the file. A by-name bind never makes its directory writable, and the
# directories apptainer creates to hold such binds are read-only
# (docs/apptainer.md): every save of ~/.claude/.credentials.json and of
# ~/.claude.json failed with EROFS, so a login never persisted, not even
# within the session.
#
# So a claude run gets $RUN_DIR/claude-home as its $HOME, with the host's
# paths bound into it one at a time:
#
#   .claude.json       a plain per-run copy (functions/claude-json.sh); at
#                      exit an allowlist of keys merges back, the rest is
#                      reported
#   .claude/.credentials.json  .claude/history.jsonl
#   .claude/{projects,shell-snapshots,todos,statsig,file-history,ide}/
#                      the host's own, read-write: the login (shared with
#                      the host's claude), sessions, history
#   .claude/{settings.json,settings.local.json,mcp.json,.mcp.json}
#   .claude/{hooks,plugins,agents,commands,skills,rules,output-styles}/
#   .config/claude/    the host's, read-only; where the host has none, an
#                      empty read-only placeholder, so the session cannot
#                      create one either: hooks, statusLine and apiKeyHelper
#                      there are commands claude runs, and permission rules
#                      there pre-approve tool calls
#   .claude/CLAUDE.md  the instruction overlay (bind_augmented_instructions)
#
# Everything else under $HOME is per-run scratch: writable in the session,
# gone with $RUN_DIR, never the host's. The deeper binds -- the checkout,
# extra binds, .sandbox-limitations.md -- sit on top of it: apptainer
# mounts user binds shallowest destination first, and creates a missing
# mount point under a bound host directory inside that directory, i.e. in
# $RUN_DIR, never in the host's $HOME.
#
# Workspace trust is not stored at all. claude records an accepted trust
# dialog in ~/.claude.json, which never merges that back, so it would ask
# on every run; CLAUDE_CODE_SANDBOXED=1 (functions/agents.sh), claude's own
# flag for running inside a sandbox, makes it treat the workspace as
# trusted without asking or writing anything.

# CLAUDE_HOME_DIR: the per-run directory bound at $HOME for a claude run,
# empty for every other agent.
CLAUDE_HOME_DIR=""

# claude_home_mountpoint REL KIND: create REL (under the per-run home) as
# the mount point for a nested bind, KIND "file" or "dir".
claude_home_mountpoint() {
    local p="$CLAUDE_HOME_DIR/$1"
    if [[ "$2" == dir ]]; then
        mkdir -p -- "$p"
    else
        mkdir -p -- "${p%/*}" && : >"$p"
    fi
}

# claude_home_bind_shared PATH KIND [INITIAL]: the host's own PATH (under
# $HOME), read-write at the same path; bind_state_rw creates it on the host
# when it is missing. The mount point takes the kind the host path has.
claude_home_bind_shared() {
    local p="$1" kind="file"
    bind_state_rw "$p" "$2" "${3:-}" || return 1
    if [[ -d "$p" ]]; then
        kind="dir"
    fi
    claude_home_mountpoint "${p#"$HOME"/}" "$kind"
}

# claude_home_bind_config PATH KIND: the host's PATH (under $HOME),
# read-only, where the host has it. Where it does not, an empty placeholder
# of KIND -- "{}" for a file, since every such file is JSON claude parses --
# bound read-only over itself, so the session cannot create PATH in the
# per-run home and have claude load it.
claude_home_bind_config() {
    local p="$1" kind="$2" mp
    mp="$CLAUDE_HOME_DIR/${p#"$HOME"/}"
    if [[ -e "$p" ]]; then
        kind="file"
        if [[ -d "$p" ]]; then
            kind="dir"
        fi
        claude_home_mountpoint "${p#"$HOME"/}" "$kind" || return 1
        bind_ro "$p"
        return 0
    fi
    if [[ "$kind" == dir ]]; then
        mkdir -p -- "$mp" || return 1
    else
        { mkdir -p -- "${mp%/*}" && printf '{}\n' >"$mp"; } || return 1
    fi
    BINDS+=(-B "$mp:$p:ro")
    RO_MASKED+=("$p")
}

# claude_home_prepare: build $RUN_DIR/claude-home and append its binds to
# BINDS. Sets CLAUDE_HOME_DIR. ~/.claude.json is claude_json_prepare's.
claude_home_prepare() {
    local p
    ensure_run_dir
    CLAUDE_HOME_DIR="$RUN_DIR/claude-home"
    mkdir -p -- "$CLAUDE_HOME_DIR/.claude" || return 1
    chmod 700 -- "$CLAUDE_HOME_DIR" "$CLAUDE_HOME_DIR/.claude" || return 1
    BINDS+=(-B "$CLAUDE_HOME_DIR:$HOME")

    claude_home_bind_shared "$HOME/.claude/.credentials.json" file '{}' || return 1
    claude_home_bind_shared "$HOME/.claude/history.jsonl" file || return 1
    for p in projects shell-snapshots todos statsig file-history ide; do
        claude_home_bind_shared "$HOME/.claude/$p" dir || return 1
    done

    for p in settings.json settings.local.json mcp.json .mcp.json; do
        claude_home_bind_config "$HOME/.claude/$p" file || return 1
    done
    for p in hooks plugins agents commands skills rules output-styles; do
        claude_home_bind_config "$HOME/.claude/$p" dir || return 1
    done
    # The alternate settings location.
    claude_home_bind_config "$HOME/.config/claude" dir || return 1

    # Mount point of the instruction overlay, bound whether or not the host
    # has the file (bind_augmented_instructions, functions/agents.sh).
    claude_home_mountpoint .claude/CLAUDE.md file
}

# claude_home_refuse_overrides: a variable that moves claude's directories
# makes it read and write paths this layout does not build -- the login
# would again land where nothing keeps it. Checked as the container will
# see them (backend_forwarded_env, functions/apptainer.sh), and refused
# even when empty: an empty CLAUDE_CONFIG_DIR makes claude keep its files
# in the working directory.
claude_home_refuse_overrides() {
    local var
    for var in CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR; do
        if backend_forwarded_env "$var" >/dev/null; then
            echo "error: $var is forwarded into the sandbox; it moves claude's directories outside" >&2
            echo "       the layout the sandbox builds for it. Stop forwarding it for sandboxed claude runs." >&2
            exit 1
        fi
    done
}
