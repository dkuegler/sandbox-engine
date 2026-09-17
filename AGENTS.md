# AGENTS.md

Instructions for AI agents working in this repository.

## Ground rules

- Do not assume anything. If a requirement, file layout, drifted-repo
  state, or intended behavior is unclear, ask a clarifying question
  before implementing.
- Always favor security-focused implementations. This is a sandboxing
  tool whose entire purpose is containment; a convenient-but-leaky
  choice is a bug, not a tradeoff.
- Review every change with security in mind before considering it done:
  what does it expose, what does it assume is trustworthy, what happens
  if a bind, mask, or credential path is missing or hostile.
- Verify shell changes before yielding:
  - `bash -n <file>` on every changed script.
  - If the change touches `sandbox.sh` or `functions/*.sh`, run
    `shellcheck sandbox.sh functions/*.sh` (together, so `source`
    targets resolve instead of producing spurious SC1091 warnings);
    otherwise `shellcheck` on every changed script. Fix all findings.

## `notes/`

`notes/` is a deliberate user-agent communication and organization
directory (handoffs, open questions, task tracking, patches-in-flight).
It is not part of the shipped project:

- It is not committed.
- Nothing outside `notes/` may reference it or depend on its contents
  (no `notes/...` paths, no task-id tags like `T07` in code, comments,
  or docs shipped to users).

## `docs/`

`docs/` is persistent, shipped documentation: once a finding or design
decision lands there, it is retained (not deleted alongside the `notes/`
item that motivated it).

- `docs/*` files must never reference anything in, or established only
  in, `notes/` — no `notes/...` paths, no task-id (`T<n>`) or
  question-id (`Q<n>`) tags, no "per the decision in notes/...".
- `docs/` must be self-contained: each page may reference `functions/`
  or `sandbox.sh` (the actual implementation) but nothing under
  `notes/`. A reader with no access to `notes/` must be able to use
  `docs/` in full.
