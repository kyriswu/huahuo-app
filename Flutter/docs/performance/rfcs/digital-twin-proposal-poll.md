# Performance RFC: Digital Twin Proposal observation

- Owner: Digital Twin
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable automatic Proposal refresh

## Work introduced

Material lifecycle observation (2026-09-05) uses the same route/foreground
policy with a `digital-twin:material:<redactedStableId>` key. It reads the public
distillation task and source-Note-filtered, paginated Proposal snapshots every
three seconds, with a 30-second request deadline/backoff. Observation pauses
after 200 attempts with an explicit refresh action; it never declares backend
failure merely because client observation ended. Route hide, scope replacement,
mutations and disposal cancel its network work. No first-frame work is added.

- Stable key: `digital-twin:proposal:<redactedStableId>` per Proposal.
- Owner: `DigitalTwinController`, activated by the current workspace route.
- Policy: foreground/current-route only; terminal Proposal, generation or
  workspace replacement, route hide, and dispose cancel each poller.
- Retry: 30 second request deadline, one second base interval, 30 second
  maximum exponential backoff, 15 percent jitter, shared retry metrics.
- Budget: one shared network permit per Proposal GET and none while waiting.

Proposal snapshots remain server truth and multiple restored Proposals retain
independent keys. Metrics expose redacted owners. Focused controller/page tests
cover parallel lifecycle, pause/resume, terminal cleanup, and retry accounting.
