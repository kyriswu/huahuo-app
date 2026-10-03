# Performance RFC: Feed recording Outline observation

- Owner: Feed item detail
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable live recording Outline refresh

## Work introduced

- Stable key: `feed:recording-outline:<redactedStableId>`.
- Owner: `FeedItemDetailController`, activated by its current detail route.
- Policy: foreground/current-route only; generation replacement, terminal
  server evidence, route hide, 300-attempt exhaustion, and disposal cancel it.
- Retry: 30 second request deadline, two second base interval, 30 second
  maximum exponential backoff, 15 percent jitter, shared retry metrics.
- Budget: one network permit per recording detail GET and none while waiting.

The recording endpoint and canonical HNote read model remain authoritative;
this poller never submits a generic Outline command. Metrics contain only a
redacted key. Focused controller/page tests cover lifecycle and cleanup.
