# Performance RFC: Runtime activation resident tasks

- Owner: Mobile composition/runtime activation
- Date: 2026-08-31
- Status: Accepted
- Rollback: Remove the corresponding activation leaf or coordinator schedule
  call and restore the previous provider-owned lifecycle hook.

## Work introduced

Foreground resume, Push/Chat/Feed activation, and recovery bootstrap work use
stable `runtime:*`, `recovery:*`, recording-card, Knowledge, billing, and
onboarding task keys. The app-level activation owner creates them only after
session or foreground-generation admission. `TaskOrchestrator` deduplicates
keys, applies the shared network/database permit budgets, and cooperatively
cancels foreground-only work when the app backgrounds. Deferred work uses
cancellation-aware delays; feature controllers retain their existing
single-flight and request-timeout behavior. No polling interval retains a
resource permit.

## State and rendering

The registrations live outside Widget `build` methods. They project no new UI
state and rebuild no additional subtree. Account changes and foreground
generations are the only activation signals; repeated signals for the same
generation are ignored. Reduce Motion has no effect because these tasks add no
animation.

## Persistence and privacy

Backend and existing local repositories remain authoritative. The activation
layer adds no cache, table, payload, or durable checkpoint. Task diagnostics
contain stable owner/key categories, duration, outcome, and cancellation only;
they do not include user content, credentials, request bodies, or file paths.

## Resource and failure policy

Network-only tasks declare the network permit. Material and recording recovery
declare both network and database permits. Failure is observed and reported
through the existing sanitized Flutter error path; the activation layer does
not add an unbounded retry loop. Logout, backgrounding, owner disposal, and a
new foreground generation stop or supersede eligible work. The current
`TaskSpec` entries do not add a separate scheduler deadline; the invoked API
and feature boundaries retain their existing bounded request behavior.

## Evidence

Focused coverage is owned by
`test/core/foreground_resume_coordinator_test.dart`, runtime activation widget
tests, `test/core/task_orchestrator_test.dart`, and the source architecture
checker. Profile evidence remains the workspace foreground-resume, logout,
Push bootstrap, and interrupted-recovery scenarios used by the performance
gate.

## Decision

Accept a single shared RFC for these composition-owned registrations while
requiring the RFC marker at every concrete `TaskSpec`. This keeps the decision
coherent without turning the document into an exemption for future tasks.
