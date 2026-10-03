# ADR-005: Long-running task model

- Status: Accepted
- Date: 2026-08-31

## Decision

Every long operation has a stable key, one owner, explicit cancellation and
resume rules, a deadline, and a durable checkpoint when recovery matters. Push
or SSE is authoritative while healthy; polling is a bounded fallback with
exponential backoff and jitter. Terminal, pause, gap, and dispose transitions
flush checkpoints.

Foreground-only work is suspended outside the foreground. Durable uploads and
recording finalization may continue only under an explicit platform-supported
policy. Notification and UI state observe the same task projection rather than
starting duplicate work.
