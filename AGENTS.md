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
  - `shellcheck` on every changed script, fix all findings.

## `notes/`

`notes/` is a deliberate user-agent communication and organization
directory (handoffs, open questions, task tracking, patches-in-flight).
It is not part of the shipped project:

- It is not committed.
- Nothing outside `notes/` may reference it or depend on its contents
  (no `notes/...` paths, no task-id tags like `T07` in code, comments,
  or docs shipped to users).
