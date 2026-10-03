# Performance RFC: Workspace and positioning status polling

- Owner: App navigation and onboarding
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Route removal or server status endpoint disablement

## Work introduced

- Stable task or animation key: `workspace:create-status-poll` and
  `onboarding:positioning-progress-poll`.
- Creation, cancellation, and resume owner: the visible route state owns its
  poller; the shared route/activity hooks start and stop it.
- Foreground/background policy: foreground and current route only; background,
  covered route, and dispose cancel the timer and in-flight request immediately.
- Deadline, retry, backoff, and jitter: 15 second request deadline, two/three
  second base intervals, 30 second bounded exponential backoff, 15 percent
  jitter on normal and retry delays.
- Network, database, CPU, media, and memory budget: one shared network permit per
  active read; interval waits retain no permit and no response cache is added.

## State and rendering

- Smallest rebuilding subtree: the owning Workspace/progress route state.
- Visibility/activity lease: `AppActivityRouteAware` active/inactive callbacks.
- Reduce Motion and constrained-quality behavior: no animation is introduced.
- Cache ownership and eviction: positioning retains its existing scoped read
  fallback; Workspace creation adds no cache.

## Persistence and privacy

- Truth, checkpoint, projection, or diagnostic data: backend state remains
  truth; existing positioning fallback is an account/Workspace scoped cache.
- Write coalescing and flush points: unchanged.
- Logged fields and redaction: only sanitized task owner, duration, outcome,
  retry count, and active-poller count are observed.

## Evidence

- Unit/widget tests: `test/core/task_orchestrator_test.dart` and
  `test/features/onboarding/v3_initial_positioning_progress_page_test.dart`.
- Profile scenario and device: existing Workspace bootstrap and onboarding
  navigation scenarios.
- Frame P50/P95/P99 and jank: no build-triggered request; one state update per
  response.
- CPU, memory, database, network, thermal, battery: route/background work is
  zero; timers are one-shot and do not own network permits.
- Comparison baseline: replaces two feature-local periodic timers.

## Decision

Accept one shared poller primitive with route-owned lifetimes. Roll back either
route integration if status freshness or recovery behavior regresses.
