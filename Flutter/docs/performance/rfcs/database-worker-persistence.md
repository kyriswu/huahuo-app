# Database worker persistence

## Decision

`AppDatabase` keeps single-row incremental snapshot-store upsert and delete
fallbacks for tests, migration tooling, and callers that intentionally do not
install the worker runtime. Production composition injects one long-lived
database worker plus one serialized `DatabaseWriteQueue`; multi-row mutations
remain atomic and no synchronous write is added to a Widget build path.

## Budget and ownership

- Stable queue keys identify table/key mutations and latest-wins writes.
- The database owner flushes or disposes the queue at its existing lifecycle
  boundary.
- Operation count, elapsed time, rows, bytes, queue depth, reason, and outcome
  remain observable through `DatabaseMetrics`.
- The fallback performs exactly one incremental store mutation for a one-row
  write and is covered by repository and database tests.

## Rollback

Removing the worker injection restores the bounded incremental fallback. The
legacy full-snapshot path remains restricted to stores without incremental
record support and to explicit migration/rollback recovery.
