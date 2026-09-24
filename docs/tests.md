# tests/

Last verified: 2026-09-24

Two independent suites, one per threat: `tests/git-escape/` (git write
containment) and `tests/config-escape/` (agent config surface and
host-state leakage). Neither depends on the other.

## Run everything

```
bash -n sandbox.sh functions/*.sh tests/git-escape/*.sh tests/config-escape/*.sh
shellcheck sandbox.sh functions/*.sh
shellcheck -S warning tests/git-escape/*.sh tests/config-escape/*.sh
./tests/git-escape/worktree_check.sh
./tests/git-escape/sanitize_check.sh
./tests/config-escape/mask_check.sh
./tests/git-escape/run.sh
./tests/git-escape/run.sh --negative
```

`worktree_check.sh`, `sanitize_check.sh` and `mask_check.sh` run on the
host alone, no container needed. `run.sh` (both invocations) needs
`apptainer`. Each script prints `ok`/`FAIL` per assertion and exits
non-zero on any failure; `run.sh --negative` is a meta-test and is
expected to *fail* its assertions (see below).

## tests/git-escape/ — git write containment

`fixtures.sh` is shared fixture data, not itself a test.

- **`worktree_check.sh`** — `--worktree` mode end to end on the host:
  branch-name validation, per-checkout (not per-basename) worktree
  paths, create/resume/discard, the concurrent-run lock (including
  stale and foreign-host takeover), that the writable worktree cannot
  reopen a path to the main repository's history, diff rendering and
  commit-message generation (including per-agent flag/tool lockdown),
  and the host-side commit landing on `agent/<branch>`.
- **`sanitize_check.sh`** — the credential/URL sanitizer
  (`sanitize_git_config`/`redact_urls`/`sanitize_gitdir_metadata`,
  `functions/git-mask.sh`) against real fixtures: project, submodule,
  worktree and extra-bind gitdirs each get a distinct fake credential,
  and every sanitized overlay file must be clean while the raw files
  (outside the mask) still carry it, proving the fixture is real.
- **`run.sh` / `probe.sh`** — the actual kernel-enforced mask, run
  inside a live `apptainer` container: every `.git` write is refused
  (`EROFS`), commits/fetches fail atomically, push succeeds but leaves
  tracking refs stale, path-aliasing (`--git-dir`/`-C`/`GIT_DIR`)
  cannot reach a writable `.git`, and no fixture credential is
  reachable anywhere bound into the sandbox. `--negative` reruns the
  same probe with no mask (on the host) and requires it to fail — the
  suite's own proof that it can fail at all.

See [`git-breakout.md`](git-breakout.md) for the property being
verified and the recorded "Standing verification" result, and
[`worktree-mode.md`](worktree-mode.md) for `--worktree` itself.

## tests/config-escape/ — agent config surface and host-state leakage

- **`mask_check.sh`** — host-side, apptainer-free, against real
  fixtures and the real functions: the project config mask table
  (`mask_project_agent_config`, `functions/binds.sh`) — visible iff
  tracked in `HEAD` and identical to it, absent means unbound, a
  symlinked config path refuses the run, and the shipped
  `config/mask.toml` parses the same as any TOML parser; the global
  `$HOME` surface's read-only binds (`bind_ro`,
  `bind_augmented_instructions`) — an absent path is never created or
  bound unless a read-write parent covers it, and per-agent state
  directories (opencode's) are per-run or per-project, never the
  host's; the `~/.claude.json` key scanner
  (`functions/claude-json.sh`) — the top-level value survives decoys
  and a duplicated/escaped key refuses rather than guessing, and the
  real file is never bound or written, only a per-run copy; and omp's
  per-run `~/.omp` (`functions/omp-home.sh`) — the host's natives,
  `run/` and logs are never bound, `config.yml` is a plain per-run
  copy, only `modelRoles`/`cycleOrder` merge back in the exact form
  omp writes, and a profile/directory override reaching the sandbox
  refuses the run.

See [`project-config-masking.md`](project-config-masking.md) for the
convention this suite enforces.
