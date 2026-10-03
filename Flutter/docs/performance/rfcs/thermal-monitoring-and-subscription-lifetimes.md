# Performance RFC: monitoring and subscription lifetimes

- Owner: Flutter mobile runtime
- Date: 2026-09-08
- Status: Accepted for implementation; physical-device measurements pending
- Rollback: independently revert a change if its focused lifecycle regression fails.

## Work removed

- Frame notifications must not recreate the resident performance runtime, reset
  its boot clock/first-frame markers, or reattach lifecycle/task observers.
- Policy evaluation needs total-frame P95, not an allocated export snapshot with
  three sorted distributions. Cache total percentiles for the current bounded
  sample buffer and invalidate only on frame mutation/reset.
- Policy consumers react only to effective changes, including the original
  17/24 ms quality thresholds. Route/tab/network metadata and frame jitter inside
  one quality band do not alter a policy and must not notify its consumers.
- A mapped EventChannel stream remains broadcast without a second broadcast
  wrapper; cancellation of its last consumer must reach the native event channel.
- Recording-card elapsed display timers are cancelled while TickerMode is
  disabled or another route covers the view. Return renders the current timestamp.

## Ownership and budgets

- No new provider, recurring timer, backend request, audio worker or database writer.
- The existing frame collector owns one immutable total-percentile cache entry;
  the existing runtime owns its boot clock and observer registration lifetime.
- All threshold values, graph rendering/motion behavior, network/CPU admission,
  memory/thermal gating and native recording/ASR protocols remain unchanged.
- Event unsubscription must not stop the native recording or clear a recoverable
  session. Native capture completion and safety watchdogs retain their owners.
- Hidden display clocks do not poll or control recording devices.

## Evidence and privacy

- Static source and focused fake-clock/EventChannel tests; no private device data,
  recording payloads, tokens or backend production access is needed.
- Tests cover runtime identity/startup markers, cache invalidation and exact
  percentile semantics, policy transitions, final-consumer cancel/relisten, and
  hidden/covered/resumed display clocks.
- Thermal, energy and real-device Profile CPU/frame metrics: **Not measured**.
- Keep the previous cleanup report as historical evidence; regenerated local
  build directories are not evidence of dead source or a larger shipped bundle.
