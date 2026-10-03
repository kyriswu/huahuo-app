# Performance RFC: Large graph layout CPU budget

- Owner: Interactive graph presentation
- Date: 2026-08-31
- Status: Accepted
- Feature flag / rollback: Keep the retained local physics settle only

## Work introduced

- Stable key: `graph:large-layout:<instanceScope>`; it contains no node IDs.
- Owner: `V3GraphPhysicsSimulation`, requested only for a large visible 2D
  topology.
- Policy: one shared CPU permit, foreground only, 15 second deadline, replace
  a stale request from the same simulation instance.
- Cancellation: invalidation, backgrounding, or disposal cancels queued work;
  the token is checked before and after the isolate result.

The isolate cannot be preempted after dispatch, so a late canceled result is
discarded by both token and topology-generation checks. The retained local
world remains the unchanged fallback and no permit is held between jobs.
