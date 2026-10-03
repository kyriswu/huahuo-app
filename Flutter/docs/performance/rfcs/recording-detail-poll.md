# Performance RFC: Recording detail observation

- Owner: Recording detail route
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable automatic detail refresh and require manual reopen

## Work introduced

- Stable key: `recording:detail:<redactedStableId>`.
- Owner: `RecordingDetailController`, activated by the transcription route.
- Policy: foreground/current-route only; account change, route hide,
  200-attempt exhaustion, terminal state, replacement, and dispose cancel it.
- Retry: 30 second request deadline, three second base interval, 30 second
  maximum exponential backoff, 15 percent jitter, shared retry metrics.
- Budget: one network permit per GET; no permit is held between attempts.

Backend recording detail is truth. Controller state is a page projection and
does not create a second recording or a local terminal result. Metrics expose
only the redacted stable key. Focused controller and transcription-page tests
cover pause/resume and terminal cleanup.
