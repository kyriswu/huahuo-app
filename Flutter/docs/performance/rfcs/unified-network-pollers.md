# Unified network pollers

## Decision

Repeated feature network reads use `OrchestratedPoller` with the shared
`TaskOrchestrator`. Each attempt declares a stable key and owner, a network
resource permit, a positive deadline, foreground-only execution, retryability,
and replacement semantics. Waiting intervals do not retain network permits;
failures use bounded exponential backoff with jitter.

## Scope

This registration covers Assets live projection, Profile asset metrics, WorkAI
task status, Chat derived-part status, and Chat thread-progress fallback.
Feature lifecycles stop or dispose their poller when work becomes terminal or
the owner is disposed. SSE remains authoritative for Chat Runs.

## Rollback

Each caller may stop its keyed poller independently. Chat Run SSE and explicit
user refresh actions are unchanged; disabling a poller does not fabricate a
completion state.
