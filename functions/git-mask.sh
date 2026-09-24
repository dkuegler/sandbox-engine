#!/bin/bash
# Read-only .git mask: the sole git-access control now that the agent image
# ships a real `git` binary directly (decided 2026-09-17: option
# A). Every .git under the project tree -- and under every read-write extra
# bind -- is bind-mounted read-only into the agent container, kernel-
# enforced, so it holds regardless of whether the git binary the agent uses
# came from the image or was fetched/installed by the agent itself. On top
# of the read-only mask, every masked gitdir's remote-identifying files
# (config, config.worktree, FETCH_HEAD, logs/HEAD) get a sanitized,
# read-only overlay copy with URLs and credential references redacted --
# the agent keeps the refs (`git log origin/master`, ahead/behind) but not
# where `origin` points.

# sanitize_git_config SRC DST: copy an INI-style git config file (top-level
# config, a submodule's config, or a worktree's config.worktree) from SRC to
# DST with every remote-identifying value redacted. Keeps `[remote
# "origin"]`'s name and structure -- ahead/behind counts and `git log
# origin/master` still work -- but rewrites `url`/`pushurl` to an opaque
# placeholder. Drops `[credential]`, `[http "<url>"]`/`[http.*]`, and
# `[url "<url>"]` sections entirely (their whole body, including the
# section header, which for `http`/`url` sections is itself a URL) --
# preferring redaction over deletion everywhere it is possible to keep a
# section meaningfully present (remote), and dropping only where the
# section's entire reason to exist is the thing being hidden. `[include]`/
# `[includeIf ...]` are dropped too: their `path` can point at host config
# outside the repo, and the path itself can leak host directory structure.
# Not handled (not this repo's job): `.gitmodules`, tracked working-tree
# content the agent must be able to read like any other file -- if it
# names its own upstream (it usually does), that is a known, stated
# limitation, not a gap in this sanitiser.
sanitize_git_config() {
    local src="$1" dst="$2" line lower in_drop_section=0 in_remote_section=0
    : > "$dst"
    [[ -f "$src" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lower="$(tr '[:upper:]' '[:lower:]' <<<"$line" | sed -e 's/^[[:space:]]*//')"
        if [[ "$lower" == \[* ]]; then
            in_drop_section=0
            in_remote_section=0
            case "$lower" in
                '[credential'* | '[http '* | '[http.'* | '[url '* | '[url.'* | '[include]'* | '[includeif '*)
                    in_drop_section=1
                    ;;
                '[remote '*)
                    in_remote_section=1
                    ;;
            esac
            [[ "$in_drop_section" -eq 1 ]] && continue
            printf '%s\n' "$line" >>"$dst"
            continue
        fi
        [[ "$in_drop_section" -eq 1 ]] && continue
        if [[ "$in_remote_section" -eq 1 && "$lower" =~ ^(url|pushurl)[[:space:]]*= ]]; then
            printf '\turl = REDACTED-BY-SANDBOX\n' >>"$dst"
            continue
        fi
        printf '%s\n' "$line" >>"$dst"
    done <"$src"
}

# redact_urls SRC DST: copy a plain-text git-internal file (FETCH_HEAD,
# logs/HEAD) from SRC to DST with every URL-shaped token replaced.
# FETCH_HEAD names the source URL on every line; the reflog's first entry
# is `clone: from <url>` and fetch/pull entries carry it too. Neither file
# needs to survive intact for `git log`/`git status` to work, so this is
# a blunt whole-line-token replacement rather than a structured parse.
redact_urls() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        sed -E \
            -e 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]]+#REDACTED-BY-SANDBOX#g' \
            -e 's#[[:alnum:]_.-]+@[[:alnum:]_.-]+:[^[:space:]]+#REDACTED-BY-SANDBOX#g' \
            "$src" >"$dst"
    else
        : >"$dst"
    fi
}

# sanitize_gitdir_metadata REALDIR: for one gitdir actually being mounted
# read-only (the top-level .git, a submodule's, a worktree's, or a
# worktree's own per-worktree metadata directory), write sanitized copies
# of every file known to carry a remote URL or credential reference into
# RUN_DIR, and append a read-only bind overriding the real path with the
# sanitized copy -- same trick bind_augmented_instructions
# (functions/agents.sh) already uses. No
# ordering requirement on the BINDS array itself: apptainer sorts mounts by
# destination depth (mask_git_readonly's own comment below), and
# "$REALDIR/config" is always deeper than the "$REALDIR" mask this
# overrides, so it always applies after regardless of insertion order.
#
# Recurses into "$REALDIR/worktrees/*/" (each entry is itself a
# per-worktree metadata directory with its own config.worktree/logs/HEAD)
# so a *registered* worktree's credentials are sanitized purely from
# REALDIR being masked at all -- regardless of whether that worktree's own
# checkout ".git" file is itself reachable inside the sandbox. Without
# this, a worktree's config.worktree/logs/HEAD ride along on REALDIR's own
# blanket read-only mount, in full, unredacted: mask_git_readonly()'s
# find-based walk only calls this function for something literally named
# ".git" or resolved *from* one, and "worktrees/<name>/" is neither.
# Terminates after one level: a per-worktree metadata directory has no
# worktrees/ of its own.
sanitize_gitdir_metadata() {
    local realdir="$1"
    local -a rels=(config config.worktree FETCH_HEAD logs/HEAD)
    local rel src out wt
    ensure_run_dir
    GIT_SANITIZE_IDX=$((${GIT_SANITIZE_IDX:-0} + 1))
    for rel in "${rels[@]}"; do
        src="$realdir/$rel"
        [[ -f "$src" ]] || continue
        out="$RUN_DIR/gitsan-$GIT_SANITIZE_IDX-$(tr '/' '-' <<<"$rel")"
        case "$rel" in
            config | config.worktree) sanitize_git_config "$src" "$out" ;;
            FETCH_HEAD | logs/HEAD) redact_urls "$src" "$out" ;;
        esac
        BINDS+=(-B "$out:$src:ro")
    done
    for wt in "$realdir"/worktrees/*/; do
        [[ -d "$wt" ]] || continue
        sanitize_gitdir_metadata "${wt%/}"
    done
}

# resolve_git_dir PATH: echoes the real git directory for a .git entry.
# In a worktree or submodule checkout .git is a FILE containing
# "gitdir: <path>" (possibly relative), and that target holds the actual
# refs/objects, so it must be masked too.
resolve_git_dir() {
    local entry="$1" target base
    if [[ -d "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi
    [[ -f "$entry" ]] || return 0
    target="$(sed -n 's/^gitdir:[[:space:]]*//p' "$entry" | head -n1)"
    [[ -n "$target" ]] || return 0
    if [[ "$target" != /* ]]; then
        base="$(dirname "$entry")"
        target="$base/$target"
    fi
    target="$(readlink -f "$target" 2>/dev/null || true)"
    [[ -n "$target" && -e "$target" ]] && printf '%s\n' "$target"
}

# git_dir_visible PATH ROOTS...: true if PATH is at or under any of the
# given roots -- i.e. already visible in the container without needing
# its own extra bind. Shared by mask_git_readonly's containment check
# and its caller so both agree on what "inside the sandbox" means.
git_dir_visible() {
    local p="$1" root
    shift
    for root in "$@"; do
        [[ "$p" == "$root" || "$p" == "$root"/* ]] && return 0
    done
    return 1
}

# mask_git_readonly: appends a read-only bind for every .git under the
# project tree and every read-write extra bind (top level, submodules,
# nested repositories) plus the real git directory each one points at.
#
# apptainer sorts mount points by destination depth, shallowest first
# (PointList.Less/Sort in internal/pkg/util/fs/mount/mount_linux.go), so
# the shallow read-write project-dir/extra-bind mounts land before these
# deeper read-only binds and the kernel then enforces the boundary
# regardless of what tries to write .git inside the container. A
# read-only extra bind needs no mask of its own (the kernel already
# refuses the write), and a source inside the project dir is already
# covered by the project-dir walk.
#
# This walks each root once per run (`find` cannot know where a .git
# might be without looking), which is the dominant cost of every
# invocation on a large tree and grows with the number of read-write
# extra binds (sandbox.yml binds:/--bind) sandbox.sh covers. The elapsed
# time is reported per root so that cost is visible instead of silent.
#
# Caching the result across runs was considered and rejected: this is
# the sole enforcement point for a security boundary (F8), and a cache
# with any TTL creates a window where a `.git` created *by the agent
# itself* between runs -- e.g. after `git init` in a subdirectory, or a
# fresh `git clone`, both ordinary agent activity now that git ships in
# the image -- would not be masked on the next run until the cache
# expired. Any invalidation cheap enough to be worth doing (mtime of the
# project root, of RUN_DIR, ...) does not detect a new nested repository
# several directories down, so it would not actually be safe, only
# appear to be. There is no way to know "nothing changed" without a walk
# at least as expensive as the one being avoided.
mask_git_readonly() {
    local entry real root start_ts end_ts elapsed j
    local -a masked=()
    local -a roots=("$PROJECT_DIR")
    local -a extra_srcs=(${EXTRA_BIND_SRCS[@]+"${EXTRA_BIND_SRCS[@]}"})
    local -a extra_ro=(${EXTRA_BIND_RO[@]+"${EXTRA_BIND_RO[@]}"})
    for ((j = 0; j < ${#extra_srcs[@]}; j++)); do
        [[ "${extra_ro[$j]}" -eq 1 ]] && continue
        [[ "${extra_srcs[$j]}" == "$PROJECT_DIR" || "${extra_srcs[$j]}" == "$PROJECT_DIR"/* ]] && continue
        roots+=("${extra_srcs[$j]}")
    done
    # --worktree mode (functions/worktree.sh) binds a git worktree
    # READ-WRITE from outside the project tree, so it is walked exactly
    # like a read-write extra bind. That walk is what masks the three
    # paths a worktree's history is reachable through: its own ".git"
    # (a "gitdir:" pointer FILE -- bound read-only over itself here, so
    # the agent cannot repoint it at somewhere writable either), the
    # <main>/.git/worktrees/<name>/ directory resolve_git_dir() reads out
    # of it, and, via the PROJECT_DIR root above, <main>/.git itself.
    # A linked worktree shares the main repository's object database and
    # ref namespace, so leaving any of the three writable would hand the
    # container write access to the main repository's history.
    if [[ -n "${WORKTREE_DIR:-}" ]]; then
        roots+=("$WORKTREE_DIR")
    fi

    for root in "${roots[@]}"; do
        start_ts="$(date +%s.%N)"
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            BINDS+=(-B "$entry:$entry:ro")
            masked+=("$entry")
            # entry is itself the gitdir (ordinary/nested repo case) --
            # sanitize it directly. A worktree/submodule .git is a file,
            # not a gitdir, so there is nothing under it to sanitize; its
            # target (real, below) is the actual gitdir in that case.
            [[ -d "$entry" ]] && sanitize_gitdir_metadata "$entry"
            real="$(resolve_git_dir "$entry")"
            # A gitdir outside every bound tree is not covered by any
            # read-write bind, so only mask it when it is actually
            # visible in the container -- or explicitly opted into.
            if [[ -n "$real" && "$real" != "$entry" ]] && git_dir_visible "$real" "${roots[@]}"; then
                BINDS+=(-B "$real:$real:ro")
                masked+=("$real")
                sanitize_gitdir_metadata "$real"
            elif [[ -n "$real" && "$real" != "$entry" ]]; then
                if [[ "${ALLOW_EXTERNAL_GITDIR:-0}" -eq 1 ]]; then
                    BINDS+=(-B "$real:$real:ro")
                    masked+=("$real")
                    sanitize_gitdir_metadata "$real"
                    echo "note: mounting external git dir $real read-only (--allow-external-gitdir)" >&2
                else
                    echo "note: git dir $real lies outside the bound trees and is not mounted into the sandbox; pass --allow-external-gitdir to mount it read-only" >&2
                fi
            fi
        done < <(find "$root" -mindepth 1 -name .git -prune -print 2>/dev/null)
        end_ts="$(date +%s.%N)"
        elapsed="$(awk -v a="$start_ts" -v b="$end_ts" 'BEGIN { printf "%.3f", b - a }')"
        echo "git: scanned $root for .git entries in ${elapsed}s" >&2
        log_debug "find root: $root (${elapsed}s)"
    done

    # shellcheck disable=SC2034  # GIT_MASK_COUNT is read by sandbox.sh's post-configure_agent summary log
    GIT_MASK_COUNT=${#masked[@]}
    if [[ ${#masked[@]} -gt 0 ]]; then
        echo "git: masking ${#masked[@]} path(s) read-only in the sandbox: ${masked[*]}" >&2
    fi
}
