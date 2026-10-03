# Performance RFC: Knowledge ZIP export budget

- Owner: Knowledge document export service
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Construct the file service without an orchestrator

## Work introduced

- Stable key: `knowledge:zip-export:<sha256Prefix>` from the immutable archive
  label and byte length; the label is not exposed in diagnostics.
- Policy: user-blocking, foreground only, one media permit, 30 second deadline.
- Cancellation: checked before and after directory cleanup, byte staging, and
  atomic rename. Route/tab consumer disposal cancels the active task.

The server supplies the ZIP bytes, so Flutter performs no compression on the
UI isolate. The permit covers bounded asynchronous staging and is never held
across a retry or polling delay.
