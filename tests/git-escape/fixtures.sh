#!/bin/bash
# Shared fixture constants for the git-escape suite's credential-sanitizer
# coverage (run.sh builds these; probe.sh and sanitize_check.sh assert
# they are gone from what the sandbox/sanitizer actually exposes). Kept in
# one file, sourced by both sides, so the values used to build a fixture
# and the values searched for can never drift apart from each other --
# exactly the class of bug this suite's own history warns about (a check
# that watches something the fixture never touches passes for free).
#
# Each constant is the full "user:token@host" credential-shaped string as
# it appears inside a "https://<this>/<path>" remote URL -- four distinct
# ones, one per gitdir shape, so an assertion that accidentally matches
# the wrong file cannot pass by accident:
# shellcheck disable=SC2034  # used by every script that sources this file (run.sh, probe.sh, sanitize_check.sh), not here
SECRET_PROJECT="alice:TOK1SECRET@forge-a.invalid"     # top-level project .git
# shellcheck disable=SC2034
SECRET_SUBMODULE="bob:TOK2SECRET@forge-b.invalid"     # submodule's real gitdir
# shellcheck disable=SC2034
SECRET_WORKTREE="carol:TOK4SECRET@forge-d.invalid"    # worktree's config.worktree
# shellcheck disable=SC2034
SECRET_EXTRA="dave:TOK3SECRET@forge-c.invalid"        # read-write extra-bind repo
