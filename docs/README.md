# docs/

Fact records for `sandbox-engine`: what is true, how it was established, and how
to re-establish it. `usage.md` is the user reference.

## Contents

| document | subject |
| --- | --- |
| [`usage.md`](usage.md) | the user reference: invocation and options, `sandbox.yml`, what the session sees, the start-up prompts, worktree mode, host state |
| [`apptainer.md`](apptainer.md) | apptainer behaviour the launch line relies on: `$HOME` absent unless bound, `/tmp` limits, `EBUSY` on renaming onto a bind, `EROFS` for claude's lock and temporary files beside a bound file, nested mount points under a bound directory, no gVisor through apptainer |
| [`git-breakout.md`](git-breakout.md) | the git boundary: what the read-only `.git` mask enforces, measured behaviour of git against it, what is not contained, reproduction |
| [`commit-message-generation.md`](commit-message-generation.md) | the `--worktree` message fallback: why it runs inside the sandbox, which model each agent uses, and which of the run's own flags propagate |
| [`parallelization.md`](parallelization.md) | how claude-code, omp and opencode handle concurrent sessions, and why opencode's server mode does not survive `--containall` unmodified |
| [`project-config-masking.md`](project-config-masking.md) | every path a supported agent CLI or the host tooling beside it reads as configuration from a checkout, classified by who reads it and when; where in the tree each of those reads reaches; how each path's session view is decided by git state (committed is a read-only copy, uncommitted is hidden, absent is unbound, a symlink refuses the run); the host-side gate on `sandbox.yml`; the `config/mask.toml` table; how the human's global `$HOME` config is mounted (read-only, writable state by name, a per-run `~/.omp` for omp and a per-run `$HOME` for claude, whose `~/.claude.json` merges back only theme and onboarding); what crosses the container barrier for MCP servers; where agent-created config files surface (the approval gate's per-file decisions, the exit report, the startup block); and the gitignored, `sandbox.yml`-configured patch directory an agent proposes a change through |
| [`maintenance.md`](maintenance.md) | the recurring checks whose omission is silent: the config surfaces each CLI loads, the credential-scan syntax, the `$HOME` agent surfaces, the image installers, the standing suite, and the page dates — with the trigger and pass condition for each |
| [`worktree-mode.md`](worktree-mode.md) | `--worktree`: what a writable git worktree shares with the main repository, which paths are masked, and where the commit happens |
| [`tests.md`](tests.md) | the two test suites: what to run for `tests/git-escape/` (git write containment) and `tests/config-escape/` (agent config surface and host-state leakage), and what each script covers |

## Convention

**Scope.** `docs/` holds established knowledge: claims that are settled,
evidenced, and reproducible. Provisional material — open decisions, pending work,
reasoning still in flight — does not belong here at any maturity short of
settled. Nothing in `docs/` depends on a document outside `docs/`; each page
stands alone.

**Concise, to the point, archival.** State the fact, the evidence, and the
mechanism. No pros/cons, no recommendations, no narrative of how it was
discovered. Length is a cost: every page is read under time pressure by someone
who needs one answer.

**Label every claim.** `M` = measured, with the output quoted verbatim.
`D` = derived from source, documentation, or code inspection, not exercised.
Promoting `D` to `M` requires adding the output, never added confidence. This
distinction decays faster than the claims themselves, which is why it is written
down.

**Date it.** Each page carries a "last verified" date at the top. A fact record
with no date is a rumour.

**Include the reproduction.** If a claim was measured, the commands that measured
it belong on the page, runnable, with any guard needed to detect a degenerate run
(a step that silently produces the expected failure for the wrong reason). A
finding nobody can re-check is not archival.

**One subject per file**, named for the subject (`git-breakout.md`), not for its
status or date. Correct a page in place; do not accumulate versioned copies.

**`usage.md` and the help header.** `usage.md` is the exception to the fact-record
rules above. It describes current behaviour for a user, with no `M`/`D` labels
and no date, and points to the fact records for evidence. It changes in the same
commit as the behaviour it describes. `sandbox.sh`'s help header (what `-h`
prints) stays short: the usage line, one line per option, and pointers into
`usage.md`. Detail belongs in `usage.md`, not in the header or in
`sandbox.example.yml`.
