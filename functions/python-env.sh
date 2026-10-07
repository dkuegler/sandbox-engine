#!/bin/bash
# Python environments for the sandboxed session: a fresh, empty per-run
# directory over every host virtualenv at the root of a mounted checkout,
# and one uv cache on the host that every sandbox run shares.
#
# Why the host's virtualenvs are hidden:
# - They do not work in the image. A venv records the absolute path of the
#   interpreter that made it (pyvenv.cfg's "home", the bin/ shebangs), and
#   that interpreter is the host's, not the image's.
# - A writable host venv is gitignored code that the human's next host
#   session executes without review: anything the session writes into
#   site-packages, bin/ or a .pth file runs there, and no diff shows it.
#
# What is masked, at a checkout's ROOT only: .venv by name, plus every
# root-level directory holding a pyvenv.cfg. A directory git tracks files
# in is never masked: hiding it would hide committed work. Inside the
# session, `uv sync`, `uv venv` and `python -m venv` build a working venv
# in the empty directory, and that venv is discarded when the run ends.
#
# When a checkout has no venv at all -- no .venv entry of any kind and no
# root-level pyvenv.cfg directory -- an empty .venv is created on the host
# as the mount point, so the session's venv still lands in a per-run
# directory and never in the checkout. git ignores an empty directory, so
# worktree review and `git worktree remove` are unaffected while it
# exists. It is removed when the LAST sandbox run using it exits: a
# concurrent run in the same checkout (normal mode takes no per-checkout
# lock) may have mounted over the same directory, and on the host it is
# not a mount point, so an rmdir there would succeed and detach that run's
# venv mount (mount_namespaces(7)). A registry under ~/.agent/venv-mounts
# records which runs use which created .venv; see venv_registry_lock.
#
# Sourced after functions/log.sh, functions/apptainer.sh and
# functions/agents.sh: log_warn, log_info, backend_forward_env and
# ensure_run_dir are called at call time.

# shellcheck disable=SC2034  # read by sandbox.sh, functions/git-mask.sh, functions/binds.sh, functions/agents.sh
VENV_MASKED=()
# The image's UV_CACHE_DIR (sandbox/agent/Dockerfile.template).
UV_CACHE_DST="/tmp/.cache/uv"
# Host side of that bind; set by bind_uv_cache.
UV_CACHE_HOST=""
# Registry of the .venv mount points sandbox runs created: one directory
# per mount point, keyed by its canonical path. Set (from $HOME) by
# venv_registry_lock; the tests redirect $HOME.
VENV_REGISTRY=""
# fd of the held registry lock (venv_registry_lock).
VENV_REGISTRY_FD=""
# Canonical .venv paths whose registry entry names this run; released by
# venv_mounts_release on exit.
VENV_REGISTERED=()

# venv_dst_bound ABS: true when an entry already in BINDS has ABS as its
# destination -- a binds:/--bind entry resolve_extra_binds resolved
# earlier. Such a bind was asked for by name and wins over the mask.
# Entries parse the same way as bind_rw_covers (functions/binds.sh).
venv_dst_bound() {
    local p="$1" entry dst
    for entry in ${BINDS[@]+"${BINDS[@]}"}; do
        [[ "$entry" == "-B" ]] && continue
        dst="$entry"
        case "$entry" in *:*) dst="${entry#*:}"; dst="${dst%%:*}" ;; esac
        [[ "$dst" == "$p" ]] && return 0
    done
    return 1
}

# venv_tracked DIR NAME: true when git tracks any file under DIR/NAME.
# A failed git read refuses the run: "unknown" must not turn into either
# answer. The pathspec is relative to DIR (no `top` magic), so a project
# dir that is a subdirectory of a repository works.
venv_tracked() {
    local dir="$1" name="$2" list="$RUN_DIR/venvmask/tracked.z"
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    if ! git -C "$dir" ls-files --cached -z -- ":(literal)$name" >"$list" 2>/dev/null; then
        printf 'sandbox: refusing to start -- cannot list the files git tracks under %q\n' "$dir/$name" >&2
        exit 1
    fi
    [[ -s "$list" ]]
}

# venv_mask_bind ABS: bind a fresh, empty per-run directory over ABS,
# read-write. The source is named by hash, like the config mask's.
venv_mask_bind() {
    local abs="$1" src
    src="$RUN_DIR/venvmask/$(printf '%s' "$abs" | sha256sum | cut -c1-16)"
    mkdir -p -- "$src"
    BINDS+=(-B "$src:$abs")
    VENV_MASKED+=("$abs")
}

# venv_mask_one ABS DIR NAME: decide one existing candidate directory
# ABS (= DIR/NAME). Paths are printed %q-quoted: an earlier session may
# have chosen the name.
venv_mask_one() {
    local abs="$1" dir="$2" name="$3"
    if venv_dst_bound "$abs"; then
        log_info "venv: $(printf '%q' "$abs") is bound by binds:/--bind; not masked"
        return 0
    fi
    if venv_tracked "$dir" "$name"; then
        log_warn "not masking $(printf '%q' "$abs") as a virtualenv: git tracks files in it" \
            "the session sees it as the host has it, read-write"
        return 0
    fi
    venv_mask_bind "$abs"
    printf 'venv: %q -> per-run empty directory\n' "$abs" >&2
}

# The registry, ~/.agent/venv-mounts/:
#   .lock                  the flock file; never removed, because unlinking
#                          a lock file races its waiters
#   <sha16>/path           the canonical path of one sandbox-created .venv
#   <sha16>/users/<h>.<p>  one per run using it (host, pid of sandbox.sh)
# An entry existing means a sandbox run created that .venv and it has not
# been removed yet. It sits outside every bind, so no session can read or
# forge it, and under $HOME so that runs on two hosts sharing a network
# checkout also share it -- the same reason the worktree lock lives there.
#
# The lock is a kernel flock, not worktree_lock_acquire's mkdir+pid lock:
# that one refuses when busy and needs stale takeover, while this critical
# section must WAIT the few milliseconds another run holds it, and a
# holder killed mid-section must not wedge later runs. A flock gives both:
# the kernel drops it with its last fd.

# venv_registry_lock: take the registry's single lock; 1 if it cannot be
# taken within 30 s (or flock(1) is missing). A no-op while this shell
# already holds it: an exit inside a locked section reaches the EXIT
# trap with the fd still open, and a second open of the file would block
# on this process's own flock (flock conflicts per open file, not per
# process).
venv_registry_lock() {
    [[ -z "$VENV_REGISTRY_FD" ]] || return 0
    VENV_REGISTRY="$HOME/.agent/venv-mounts"
    if ! mkdir -p -- "$VENV_REGISTRY" || ! chmod 700 -- "$VENV_REGISTRY"; then return 1; fi
    if ! exec {VENV_REGISTRY_FD}>>"$VENV_REGISTRY/.lock"; then
        VENV_REGISTRY_FD=""
        return 1
    fi
    if ! flock -w 30 "$VENV_REGISTRY_FD" 2>/dev/null; then
        venv_registry_unlock
        return 1
    fi
}

# venv_registry_unlock: drop the lock by closing its fd; a no-op when not
# held.
venv_registry_unlock() {
    [[ -n "$VENV_REGISTRY_FD" ]] || return 0
    exec {VENV_REGISTRY_FD}>&-
    VENV_REGISTRY_FD=""
}

# venv_registry_entry CANON: the registry directory for one canonical .venv path.
venv_registry_entry() {
    printf '%s/%s' "$VENV_REGISTRY" "$(printf '%s' "$1" | sha256sum | cut -c1-16)"
}

# venv_registry_live_users ENTRY: drop every user whose run is gone; true
# when any user remains. A user on another host is never decided from here
# (kill -0 means nothing across machines, and $HOME may be shared) and
# always counts as live -- worktree_lock_acquire's reasoning. An entry
# name that does not parse counts as live too: never remove on a guess.
venv_registry_live_users() {
    local entry="$1" f name host pid this_host live=1
    this_host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    for f in "$entry"/users/*; do
        [[ -e "$f" ]] || continue
        name="${f##*/}"
        host="${name%.*}"
        pid="${name##*.}"
        if [[ "$host" == "$this_host" && "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
            rm -f -- "$f"
            continue
        fi
        live=0
    done
    return "$live"
}

# venv_registry_add CANON: record this run ("<host>.<pid of sandbox.sh>")
# as a user of the sandbox-created .venv at CANON; release it on exit.
# Called under the registry lock.
venv_registry_add() {
    local canon="$1" entry this_host
    entry="$(venv_registry_entry "$canon")"
    this_host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    mkdir -p -- "$entry/users" || return 1
    printf '%s\n' "$canon" >"$entry/path" || return 1
    : >"$entry/users/$this_host.$$" || return 1
    VENV_REGISTERED+=("$canon")
    register_cleanup_hook venv_mounts_release
}

# venv_mounts_release: the cleanup hook venv_registry_add registers.
# cleanup() calls it as `"$fn" || true` (functions/cleanup.sh), so set -e
# is inactive in here.
#
# Removes a .venv only when no live run is left: on the host it is not a
# mount point, so rmdir there would succeed and detach a concurrent run's
# venv mount. rmdir, never rm -r: only an empty directory is removed -- if
# anything wrote into it on the host, it is not the sandbox's to delete.
venv_mounts_release() {
    local canon entry this_host
    [[ ${#VENV_REGISTERED[@]} -gt 0 ]] || return 0
    if ! venv_registry_lock; then
        printf 'sandbox: cannot lock %q; the .venv mount point(s) this run created stay until a later run removes them\n' \
            "$HOME/.agent/venv-mounts/.lock" >&2
        return 0
    fi
    this_host="${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
    for canon in "${VENV_REGISTERED[@]}"; do
        entry="$(venv_registry_entry "$canon")"
        rm -f -- "$entry/users/$this_host.$$"
        if ! venv_registry_live_users "$entry"; then
            rmdir -- "$canon" 2>/dev/null || true
            rm -rf -- "$entry"
        fi
    done
    VENV_REGISTERED=()
    venv_registry_unlock
}

# venv_dot_decide DIR ABS CANON CREATE FOUND: the .venv decision for
# checkout DIR, whose .venv is ABS (the path the session sees) and CANON
# (its canonical path, the registry key). CREATE is 1 when this checkout
# may get a fresh .venv; FOUND is 1 when it already has a root-level
# pyvenv.cfg directory. Always runs under the registry lock, so "check,
# then create or join" is atomic against every other run's start and exit.
#
# An exit in here (or in venv_tracked's refusal) runs with the lock still
# held; the EXIT trap's venv_mounts_release then works under it -- its
# venv_registry_lock is a no-op while the fd is set -- and its
# venv_registry_unlock closes it. Nothing deadlocks.
venv_dot_decide() {
    local dir="$1" abs="$2" canon="$3" create="$4" found="$5" entry
    entry="$(venv_registry_entry "$canon")"
    if [[ -L "$abs" ]]; then
        rm -rf -- "$entry"
        log_warn "not masking $(printf '%q' "$abs"): it is a symlink, and a bind over a link lands wherever it points" \
            "the session sees the link as the host has it; replacing it in the session replaces it in the checkout"
        return 0
    fi
    if [[ -d "$abs" ]]; then
        if [[ -d "$entry" && -z "$(find "$abs" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            # A sandbox run made it and it is still empty on the host: join,
            # so the run that made it does not remove it from under this one.
            # A run that joins and then does not mask (a --bind at this
            # path) stays registered until its exit; that only delays removal.
            if ! venv_registry_add "$canon"; then
                printf 'sandbox: refusing to start -- cannot record %q in %q\n' "$canon" "$VENV_REGISTRY" >&2
                exit 1
            fi
        else
            # No record, or something filled it on the host: it is the host's.
            rm -rf -- "$entry"
        fi
        venv_mask_one "$abs" "$dir" .venv
        return 0
    fi
    # Absent or not a directory: any record of it is stale.
    rm -rf -- "$entry"
    if [[ -e "$abs" ]]; then
        log_info "venv: $(printf '%q' "$abs") is not a directory; not masked"
        return 0
    fi
    if [[ "$create" -ne 1 || "$found" -ne 0 ]]; then return 0; fi
    if ! mkdir -- "$abs" 2>/dev/null; then
        log_warn "could not create $(printf '%q' "$abs") as the mount point for a per-run venv" \
            "the session has no per-run .venv; a venv it creates lands in the checkout"
        return 0
    fi
    if ! venv_registry_add "$canon"; then
        rmdir -- "$abs" 2>/dev/null || true
        printf 'sandbox: refusing to start -- cannot record %q in %q\n' "$canon" "$VENV_REGISTRY" >&2
        exit 1
    fi
    venv_mask_bind "$abs"
    printf 'venv: %q -> per-run empty directory (created on the host as its mount point; removed when the last run using it exits)\n' "$abs" >&2
}

# mask_project_venvs DIR CREATE: mask the host virtualenvs at the root of
# checkout DIR; CREATE is 1 when DIR may get a fresh .venv (it has none),
# 0 when only existing ones are masked (sandbox.sh decides which checkout
# is which). The registry lock is released before this returns, so it is
# never held across the container run.
#
# The registry key is the canonical path (readlink -f of DIR), so runs
# that reach one checkout through different symlinked paths share one
# record; the bind destination stays DIR/.venv, the path the session sees.
mask_project_venvs() {
    local dir="$1" create="$2" cfg name found=0 dot_done=0
    [[ -d "$dir" ]] || return 0
    ensure_run_dir
    mkdir -p -- "$RUN_DIR/venvmask"
    # Root-level directories holding a pyvenv.cfg. -H follows DIR itself
    # when it is a symlink (a --project-dir given through a link) and
    # nothing below it: find does not follow a symlinked directory there,
    # and -type f skips a symlinked pyvenv.cfg, so links are never
    # candidates here.
    while IFS= read -r -d '' cfg; do
        name="${cfg%/pyvenv.cfg}"
        name="${name##*/}"
        if [[ "$name" == .git ]]; then continue; fi
        found=1
        if [[ "$name" == .venv ]]; then dot_done=1; fi
        venv_mask_one "$dir/$name" "$dir" "$name"
    done < <(find -H "$dir" -mindepth 2 -maxdepth 2 -name pyvenv.cfg -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    if [[ "$dot_done" -eq 1 ]]; then return 0; fi
    if ! venv_registry_lock; then
        printf 'sandbox: refusing to start -- cannot take the venv registry lock %q (needs flock(1), util-linux)\n' \
            "$HOME/.agent/venv-mounts/.lock" >&2
        exit 1
    fi
    venv_dot_decide "$dir" "$dir/.venv" "$(readlink -f -- "$dir")/.venv" "$create" "$found"
    venv_registry_unlock
}

# bind_uv_cache: uv's cache in the session is ~/.agent/uv-cache on the
# host, read-write, created 0700 on first use.
#
# Shared by choice: one directory for every project's runs. Any session
# can change cached packages that later sessions of any project install
# (uv does not re-verify an unpacked cache entry), and a git dependency's
# clone in it keeps its remote URL. The host's own uv never reads it (its
# cache is ~/.cache/uv).
#
# UV_CACHE_DIR is forwarded, so the cache lands on this bind whatever the
# base image's ENV or a host APPTAINERENV_UV_CACHE_DIR says -- the same
# reason configure_agent forwards ORT_DISABLE_TELEMETRY (functions/agents.sh).
#
# UV_LINK_MODE=copy: cache and venv are separate mounts, so a hardlink
# fails with EXDEV and uv would warn on every install. A copy also never
# shares an inode with the cache, so editing an installed file in place
# cannot rewrite the cached copy that other runs install.
bind_uv_cache() {
    UV_CACHE_HOST="$HOME/.agent/uv-cache"
    if ! mkdir -p -- "$UV_CACHE_HOST" || ! chmod 700 -- "$UV_CACHE_HOST"; then
        printf 'sandbox: refusing to start -- cannot create the uv cache directory %q\n' "$UV_CACHE_HOST" >&2
        exit 1
    fi
    BINDS+=(-B "$UV_CACHE_HOST:$UV_CACHE_DST")
    backend_forward_env UV_CACHE_DIR "$UV_CACHE_DST"
    backend_forward_env UV_LINK_MODE copy
}
