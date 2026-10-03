# Performance RFC: Transcription cloud asset reconciliation

- Owner: Transcription detail route
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable automatic asset navigation

## Work introduced

- Stable key: `transcription:cloud-asset:<redactedScopeAndRecordingId>`.
- Owner: the current transcription detail route.
- Policy: foreground/current-route only; canonical asset discovery, the
  existing 30-attempt budget, scope/recording replacement, navigation, and
  dispose cancel it.
- Retry: 30 second attempt deadline, two second base interval, 30 second
  maximum exponential backoff, 15 percent jitter, shared retry metrics.
- Budget: one database/network permit per reconciliation attempt, with no
  permit retained between attempts.

The Workspace HNote projection and server note reference remain truth. No
transcript-derived local asset is fabricated. Runtime metrics expose a
redacted stable owner, and widget coverage owns pause/resume/cleanup evidence.
