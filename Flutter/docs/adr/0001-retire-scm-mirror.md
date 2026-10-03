# ADR-0001: Retire the source-mirror SCM mechanism

- Status: accepted
- Date: 2026-10-01

## Context

The repository maintained a one-to-one Markdown mirror for source files under
`Flutter/scm`, required mirror-first edits and indexed files with hand-maintained
`SOURCE_TREE.md` files. The repository is pre-release and currently paused, so
there is no compatibility obligation for that workflow.

## Problems

The mirror required double writes, duplicated context, drifted from code,
created a central conflict hotspot and polluted agent context. It described
source structure that Git, the compiler, tests and a code graph already expose.
It also made unrelated developers edit a shared index before they could make a
small source change.

## Decision

Remove source-level mirrors, manual source indexes, mirror checkers and all
mirror-first instructions in one migration. Source code and tests are the
implementation truth. API contracts and schema/migrations own their respective
truth. Long-lived reasons and invariants live in concise architecture,
invariant, ADR and runbook documents.

Graphify provides a regenerable code relationship view for discovery and impact
review. Codex Plan/ExecPlan describes the current task, risks, scope and
acceptance criteria. Git branch/worktree/PR/review/CI provides isolation and
history.

## Consequences

Developers no longer create a Markdown file for a source file or update an
index when adding code. A plan is required for complex cross-module or native
work; small tasks can remain ephemeral. Graph output is local/regenerable and
never becomes a second source tree. Missing graph edges require source/LSP/
search verification.

Existing state-machine, lifecycle, native and recovery knowledge was reviewed
and condensed into `docs/architecture`, `docs/invariants`, `docs/adr` and
`docs/runbooks`. Historical execution logs and per-file descriptions were not
retained as active instructions.

## Rollback

The pre-migration tree is tagged `pre-scm-retirement-2026-10` at
`599315cce7e803be63d24d01d1bd973a844862cc`. This tag marks the committed HEAD;
pre-existing uncommitted work was separately copied before migration.
