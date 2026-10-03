# ADR-002: SQLite worker and write serialization

- Status: Accepted, staged rollout
- Date: 2026-08-31

## Decision

Database evolution is staged: measure writes, serialize them through a single
queue, coalesce replaceable checkpoints, then move SQLite ownership to one
long-lived worker isolate. Strong user commands keep acknowledged semantics;
diagnostics and reconstructable projections may batch or use latest-wins.

The worker protocol contains typed operations and bounded result objects, not
closures. Database diagnostics record operation category, elapsed time, queue
depth, and row/byte counts only. SQL text, keys, content, and credentials are
never included.

## Rollout

The worker stays behind `databaseWorkerEnabled` until migration fault tests,
process-restart recovery, and profile-mode equivalence pass on iOS and Android.
The synchronous implementation remains the rollback path during that window.
