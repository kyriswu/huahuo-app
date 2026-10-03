# Performance RFC: Profile avatar transform budget

- Owner: User profile application service
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Construct the port without a task orchestrator

## Work introduced

- Stable key: `profile:avatar-transform:<sha256Prefix>`, derived from source
  metadata without exposing its private path.
- Policy: user-blocking, foreground only, one CPU and one media permit, 30
  second deadline.
- Work: existing isolate decode, resize, and bounded JPEG quality encoding.
- Cancellation: checked before dispatch and after the isolate result; a
  canceled transform retains the existing prepare-failed result contract.

The controller already rejects overlapping avatar selection, so no artificial
delay or polling interval holds either permit.
