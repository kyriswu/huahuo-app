# Performance RFC: Recording processing status polling

- Owner: Recording processing
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable automatic recording recovery activation

## Work introduced

- Stable task or animation key: `recording:processing:<redactedStableId>`.
- Creation, cancellation, and resume owner: application-scoped recording
  tracker, injected and resumed by `RecoveryRuntimeActivation`.
- Foreground/background policy: foreground-only; background, account/Workspace
  replacement, terminal status, and disposal cancel each recording poller.
- Deadline, retry, backoff, and jitter: 30 second attempt deadline, three second
  interval, 30 second maximum exponential backoff, 15 percent jitter, and a
  twelve-hour total enrollment window. Expiry retains the durable checkpoint
  for a later authenticated foreground recovery.
- Network, database, CPU, media, and memory budget: one shared network permit
  per active GET; interval waits retain no permit; existing draft writes remain
  terminal checkpoints only.

## State and rendering

- Smallest rebuilding subtree: existing tracker listeners.
- Visibility/activity lease: app foreground through the shared orchestrator.
- Reduce Motion and constrained-quality behavior: no animation is introduced.
- Cache ownership and eviction: no response cache; terminal draft checkpoints
  use existing account/Workspace ownership.

## Persistence and privacy

- Truth, checkpoint, projection, or diagnostic data: backend detail is truth;
  upload draft stage is the restart checkpoint.
- Write coalescing and flush points: only terminal or retry-reenrollment stages.
- Logged fields and redaction: metrics expose sanitized owner/outcome/duration,
  retry count, and aggregate active pollers; recording IDs are not exported.

## Evidence

- Unit/widget tests: `test/core/task_orchestrator_test.dart` and
  `test/features/recordings/recording_processing_tracker_test.dart`.
- Profile scenario and device: recording upload/recovery release scenario.
- Frame P50/P95/P99 and jank: tracker is application state, not a build loop.
- CPU, memory, database, network, thermal, battery: no background GET and no
  permit held during intervals.
- Comparison baseline: replaces a resident while/delay loop outside budgets.

## Decision

Adopt per-recording keyed pollers at the recovery boundary. Roll back automatic
recovery if terminal latency, request volume, or device power evidence
regresses.
