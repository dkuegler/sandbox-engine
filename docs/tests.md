# tests/

Last verified: 2026-11-06

Three independent suites: `tests/git-escape/` (git write containment),
`tests/config-escape/` (agent config surface and host-state leakage) and
`tests/worktree/` (`--worktree` mode's behaviour). None depends on another.

## Run everything

```
bash -n sandbox.sh functions/*.sh tests/lib/*.sh tests/git-escape/*.sh tests/config-escape/*.sh tests/worktree/*.sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck sandbox.sh functions/*.sh
    shellcheck -S warning tests/lib/*.sh tests/git-escape/*.sh tests/config-escape/*.sh tests/worktree/*.sh
fi
./tests/worktree/worktree_check.sh
./tests/git-escape/worktree_mask_check.sh
./tests/git-escape/sanitize_check.sh
./tests/config-escape/mask_check.sh
./tests/git-escape/run.sh
./tests/git-escape/run.sh --negative
```

`worktree_check.sh`, `worktree_mask_check.sh`, `sanitize_check.sh`,
`mask_check.sh` and `run.sh --negative` run on the host alone, no
container needed; `run.sh` needs `apptainer`. It runs `sandbox.sh` with
no controlling terminal (`setsid`), so no `/dev/tty` prompt can block it,
from a terminal or not. Each script prints `ok`/`FAIL` per assertion,
then a summary of the expected result against the tested one:

```
expected: 5 passed, 21 failed: A1 A2a ...
tested:   5 passed, 21 failed: A1 A2a ...
```

Any difference is printed as a `MISMATCH:` line naming the assertions
that failed but should have passed, passed but should have failed, or
were expected to fail but never ran, and the script exits non-zero.
A normal run expects every assertion to pass; `run.sh --negative` is a
meta-test that expects a fixed list to *fail* (see below). The shared
`ok`/`bad`/`report_summary`/`check_warnings`/`expect_failures` helpers
are `tests/lib/report.sh`.

Warnings are asserted, not just printed. `run.sh` captures
`sandbox.sh`'s stderr instead of showing it, and its `WARN` assertion
(`check_warnings`) requires exactly the expected warnings: one per bind
outside the project dir, which the suite requests on purpose. A warning
counts if its line starts with `warning:`/`WARNING:`/`error:`/`ERROR:`
(git, apptainer, `functions/binds.sh`) or if it is listed by the warning
gate (`sandbox: this run produced N warning line(s):`, every `log_warn`).
The one warning allowed besides those is the reaping of a run directory
an earlier, killed run left behind, which depends on state outside the
suite. Every warning seen is listed under the `WARN` line, pass or fail,
tagged `required:`, `allowed:` or `unexpected:`, plus a `missing ...`
line per required warning that did not appear exactly once. Any
unexpected or missing one fails `WARN`, which then also prints the
whole captured stderr; so does a failing probe. The other scripts are
expected to print no warnings. Their fixtures are built so git has
nothing to warn about.

Every assertion line reads `STATUS ID [NOTE] MESSAGE`. An assertion
expected to fail carries its expectation inline, so a line can be
interpreted without knowing the test: `FAIL A1 (expected) ...` is a
wanted failure, `ok A1 (expected FAIL) ...` an assertion that should
have failed but did not. A plain `FAIL` is always a real failure.

A negative control (`run.sh --negative`) also announces the `FAIL`
lines it will print, one per expected ID, before the first assertion,
then prints the assertions' actual output as a separate block:

```
The following test expects 21 FAILURE(S):
=== STDOUT (expected)
FAIL A1 ...
FAIL A2a ...
...
=== STDOUT (measured; indented lines are details of the line above)
FAIL A1     (expected) ...
...
===
```

That list is the same one the summary checks, so it is enforced.

## tests/git-escape/ — git write containment

`fixtures.sh` is shared fixture data, not itself a test.

- **`worktree_mask_check.sh`** — that `--worktree` mode's writable
  worktree does not reopen a path to the main repository's history: the
  worktree's `.git` file, its metadata directory and the main `.git` are
  all bound read-only, with a negative control showing the worktree's
  `.git` is unmasked without the worktree root; and a project dir that
  is itself a linked worktree is refused.
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
  same probe with no mask (on the host) and requires exactly the mask
  assertions to fail — the list is in `run.sh` — the suite's own proof
  that each of them can fail at all. It gives the probe a throwaway
  `HOME` holding a `.gitconfig` and `.git-credentials`, so A9 fails
  regardless of the caller's own home directory.

See [`git-breakout.md`](git-breakout.md) for the property being
verified and the recorded "Standing verification" result, and
[`worktree-mode.md`](worktree-mode.md) for `--worktree` itself.

## tests/worktree/ — `--worktree` mode

- **`worktree_check.sh`** — `--worktree` mode end to end on the host:
  branch-name validation, `--start-point` resolution and refusals,
  per-checkout (not per-basename) worktree paths, create/resume/discard,
  the concurrent-run lock (including stale and foreign-host takeover),
  diff rendering and commit-message generation (including per-agent
  flag/tool lockdown), the agent's message file across sessions (kept on
  resume, emptied on create, labelled when unchanged, deleted on commit
  and discard, a symlink refused), and the host-side commit landing on
  `agent/<branch>`. Its containment half is `worktree_mask_check.sh`
  above.

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
  host's; the `~/.claude.json` key scanner and merge
  (`functions/claude-json.sh`) — the top-level value survives decoys,
  a duplicated/escaped key or anything but one object refuses rather
  than guessing, the per-run copy is a plain file, and only `theme`,
  `hasCompletedOnboarding` and `lastOnboardingVersion` merge back, in
  claude's own shape, never over a host-side change or through a
  symlink; claude's per-run `$HOME` (`functions/claude-home.sh`) — the
  login is the host's, config is read-only with a read-only placeholder
  where the host has none, `~/.claude` is never bound whole, a
  forwarded directory override refuses the run, and a host
  `CLAUDE_CONFIG_DIR` is the source of every claude bind while the
  session still sees `~/.claude`; omp's
  per-run `~/.omp` (`functions/omp-home.sh`) — the host's natives,
  `run/` and logs are never bound, `config.yml` is a plain per-run
  copy, only `modelRoles`/`cycleOrder` merge back in the exact form
  omp writes, and a profile/directory override reaching the sandbox
  refuses the run; and the virtualenv masks
  (`functions/python-env.sh`) — every root-level venv gets an empty
  per-run directory unless git tracks files in it, a symlinked `.venv`
  is never bound over, the `.git` walk and the deep config sweep bind
  nothing inside a masked venv, a failed git read refuses, and a
  sandbox-created `.venv` is removed only by the last live run using
  it and never once something was written into it on the host.

See [`project-config-masking.md`](project-config-masking.md) for the
convention this suite enforces.
