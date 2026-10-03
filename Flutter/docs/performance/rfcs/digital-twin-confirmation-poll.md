# Performance RFC: Digital Twin confirmation observation

- Owner: Digital Twin confirmation
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Disable automatic confirmation refresh

## Work introduced

- Stable key: `digital-twin:confirmation:<sha256-prefix>`.
- Owner: `DigitalTwinController`, activated by the current route.
- Policy: foreground/current-route only; terminal state, generation
  replacement, 90-attempt exhaustion, route hide, and disposal cancel it.
- Retry: 30 second request deadline, one second base interval, 30 second
  maximum exponential backoff, 15 percent jitter, shared retry metrics.
- Budget: one shared network permit per confirmation GET and none while
  waiting. Raw confirmation task ids never enter diagnostics.

The backend confirmation report remains truth. Exhaustion retains the last
snapshot and maps to the existing `DIGITAL_TWIN_CONFIRMATION_TIMEOUT` failure.
