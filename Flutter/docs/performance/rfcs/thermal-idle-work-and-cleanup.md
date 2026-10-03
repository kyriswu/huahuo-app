# Performance RFC: bounded idle work and proven-dead file cleanup

- Owner: Flutter mobile runtime
- Status: Accepted for implementation; physical-device measurement pending
- Rollback: revert individual implementation changes if their focused regression fails.

## Work introduced

### 2026-09-20 high-risk follow-up

- Sphere automatic motion has an eight-second wall-clock budget after entry or
  touch cooldown; idle schedules no frames. All graph nodes and links remain.
- Knowledge-cache ordinary saves coalesce into at most one queued latest-state
  save behind an in-flight write. Explicit Workspace cursor commits and exact
  rollback snapshots remain ordered durability barriers. Snapshot encoding and
  file I/O run in a bounded, awaited isolate; no server contract changes.
- Android screen recording gates frames before encoding using the existing
  recorder worker for GL. Thermal/power state is rechecked on pending frames at most once per
  second, with immediate downgrade and delayed recovery; no idle polling or
  second MediaProjection display. Audio and MP4 timestamps remain continuous.
- Focused fake-clock, cache ordering/recovery and native frame-budget tests are
  required. Physical-device energy, temperature and video capture are not
  inferred from those tests; revert the affected change if capture fidelity or
  persistence ordering regresses.

- Task cancellation is notification-driven; remove the recording projection's
  25 ms cancellation watchdog without cancelling the shared source Future.
- The existing account-scoped diagnostic logger batches asynchronous events for
  at most one second, or until its 20-event threshold. Its provider owns disposal
  and an inactive-state flush. Idle applications schedule no diagnostic timer.
- Digital-twin pulse frames repaint without widget build/layout. Each mounted
  person retains only its most recent depth-sorted projection (at most 964
  particles); gesture/viewport/merge changes invalidate that entry.
- No new polling loops, permanent providers, platform channels, API calls or
  background jobs. Existing recording, ASR, upload and retry budgets are preserved.

## State and rendering

- Keep both narrow and wide UI, live graph interaction, orbit/zoom/reset gestures,
  warning visibility and merge/pulse visual formulas.
- Keep route activity, TickerMode, app foreground and Reduce Motion behavior.
- The cache belongs to the particle widget; disposal makes it collectible.
- No global frame-rate or visual-quality reduction is used to hide work.

## Persistence and privacy

- Diagnostic overlay records remain immediately queryable and redacted.
- Explicit terminal flush, capacity protection, pruning and disposal still flush.
- Failed writes retain the pending batch and last error; no busy retry timer.
- A failed deferred flush never schedules another idle callback by itself;
  only successful writes with newer staged events schedule the next batch.
- Read-only backend review: `source/internal/api/routes/recording_routes.go`,
  `source/internal/services/recording_service.go`, and the corresponding recording
  route SCM protocol. Server detail remains the authority; wait cancellation
  neither aborts nor resubmits server work.
- Delete only source proven unreachable from mobile entrypoints (including
  parts), its exclusive tests, unreferenced images and reproducible artifacts.
- Keep diagnostic infrastructure, current reference/golden images, help images,
  fonts, native SDKs, SQLite source and physical-device evidence.

## Evidence

- Static high risk: periodic 25 ms cancellation checks; per-frame projection and
  sorting of the same particle coordinates; microtask-only production log flush.
- Focused tests: cancellation, batched logging, particle geometry/cache and Dart
  part reachability, plus the existing recording tracker tests.
- CPU, thermal, battery and real-device before/after: **Not measured**. Static
  reductions and simulator tests must not be presented as measured cooling.

## Decision

Prefer removing redundant work over changing recording safety behavior, network
contracts or interactive visuals. Preserve unrelated local edits. Cleanup affects
the worktree, not Git history; rebuilding regenerates build/cache artifacts.
