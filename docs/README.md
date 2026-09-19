# docs/

Archival fact records for `sandbox-engine`. What is true, how it was
established, and how to re-establish it.

## Contents

| document | subject |
| --- | --- |
| [`git-breakout.md`](git-breakout.md) | the git boundary: what the read-only `.git` mask enforces, measured behaviour of git against it, what is not contained, reproduction |
| [`commit-message-generation.md`](commit-message-generation.md) | the `--worktree` message fallback: why it runs inside the sandbox, which model each agent uses, and which of the run's own flags propagate |
| [`parallelization.md`](parallelization.md) | how claude-code, omp and opencode handle concurrent sessions, and why opencode's server mode does not survive `--containall` unmodified |
| [`worktree-mode.md`](worktree-mode.md) | `--worktree`: what a writable git worktree shares with the main repository, which paths are masked, and where the commit happens |

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
