# Repository development contract

This repository is in a pre-release mechanism migration. The implementation
source of truth is source code, tests, API contracts and database
schema/migrations. Long-lived reasons belong only in `Flutter/docs/architecture`,
`Flutter/docs/invariants`, `Flutter/docs/adr` and `Flutter/docs/runbooks`.
Never create a Markdown mirror for a source file or a generated source index.

## Scope and safety

- Keep changes within the requested task. Do not change runtime behavior for a
  tooling or workflow migration.
- Complex cross-module, state-machine, database, native, BLE, Wi-Fi,
  recording-card, async-recovery, digital-twin or API work starts with a Plan or
  ExecPlan. Use `Flutter/plans/` for a persistent multi-turn plan.
- Read backend implementation and protocol docs before changing request fields,
  authentication, response handling or synchronization behavior.
- Server access is read-only. Do not edit files, restart services, deploy,
  migrate, requeue tasks or repair server data.
- Physical-device evidence must be collected from the connected device. A
  Simulator is not a physical-device substitute; follow
  `Flutter/docs/runbooks/ios-real-device-debug.md`.

## Graphify and impact review

Use the project-pinned Graphify CLI/skill when available. Before a complex
change, inspect target symbols, incoming/outgoing dependencies, related tests,
shared-package edges and native boundaries. After changing code, repeat the
impact review. Graph edges are discovery evidence, not compiler proof; verify
injection, callbacks, generated code, string routes and native channels with
source search, analyzer/LSP and tests. If Graphify is unavailable, say so and
use those fallbacks instead of inventing graph results.

## Collaboration

Use one branch per task and preferably one worktree per human or agent. Share
interfaces before implementation, assign an owner to shared hot files, keep PRs
single-purpose, review against the actual target revision and rely on PR/CI
checks before merge. Do not ask multiple agents to edit the same working tree
for a large task.

## Validation

Run formatting, static analysis, focused tests and an impact review appropriate
to the change. Do not claim real hardware, server or production behavior from a
mock or Simulator test.
