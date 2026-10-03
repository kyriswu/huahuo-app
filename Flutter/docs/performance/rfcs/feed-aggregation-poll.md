# Performance RFC: Feed aggregation Run polling

- Owner: Feed aggregation
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable remote Topic Collision Run port

## Work introduced

- Stable task or animation key: `feed-aggregation:production-run-poll`
- Creation, cancellation, and resume owner: `PushRuntimeActivation` injects the
  shared runtime; `FeedAggregationController` starts, pauses, and disposes it.
- Foreground/background policy: foreground-only; pause cancels both waiting and
  in-flight work, resume continues the persisted server Run.
- Deadline, retry, backoff, and jitter: 15 second attempt deadline, two second
  base interval, 30 second maximum exponential backoff, 15 percent jitter.
- Network, database, CPU, media, and memory budget: one shared network permit;
  interval waits hold no permit; no payload cache is added.

## State and rendering

- Smallest rebuilding subtree: existing Feed aggregation controller listeners.
- Visibility/activity lease: app foreground activation owns pause/resume.
- Reduce Motion and constrained-quality behavior: no animation is introduced.
- Cache ownership and eviction: existing account and Workspace scoped durable
  Run identity is retained and cleared at terminal completion.

## Persistence and privacy

- Truth, checkpoint, projection, or diagnostic data: backend Run is truth;
  existing local record is a restart checkpoint.
- Write coalescing and flush points: unchanged, on accepted/status transitions.
- Logged fields and redaction: metrics contain only sanitized owner category,
  outcome, duration, retry count, and active-poller count.

## Evidence

- Unit/widget tests: `test/core/task_orchestrator_test.dart` and
  `test/features/ui_v3/feed_aggregation_controller_test.dart`.
- Profile scenario and device: covered by the existing aggregation release
  scenario; no new persistent background work.
- Frame P50/P95/P99 and jank: no build-loop work; controller notifications are
  unchanged.
- CPU, memory, database, network, thermal, battery: bounded shared network task;
  one-shot wait timer; no interval resource permit.
- Comparison baseline: replaces an unbounded feature-local periodic timer.

## Decision

Accept the shared keyed poller. Roll back by disabling the production Topic
Collision port if status load, retry volume, or power evidence regresses.
