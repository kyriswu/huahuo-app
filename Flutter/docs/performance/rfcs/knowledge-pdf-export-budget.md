# Performance RFC: Knowledge PDF export budget

- Owner: Knowledge document export service
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Construct the file service without an orchestrator

## Work introduced

- Stable key: `knowledge:pdf-export:<sha256Prefix>` from document identity,
  revision, and A4 width; source text is never included in diagnostics.
- Policy: user-blocking, foreground only, one CPU and one media permit, one
  minute deadline.
- Cancellation: checked around font load, isolate rendering, and atomic file
  publication. Route/tab consumer disposal cancels the task and clears the
  revision Future cache.

An already-running isolate cannot be preempted. Its late result fails the token
check and the cache generation prevents it from being retained or staged.
