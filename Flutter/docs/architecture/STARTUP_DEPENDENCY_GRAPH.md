# Flutter startup dependency graph

This graph is the review boundary for `BOOT-002` and `BOOT-008`. A new edge in
the pre-first-frame path requires a performance RFC and Profile evidence.

```text
native launch
  -> Flutter binding / orientation
  -> AppProviders bootstrap
       -> device identity (required, bounded timeout)
       -> local snapshot store (required, bounded timeout)
       -> runtime metadata (required, bounded fallback)
  -> ProviderScope
  -> router / AppRoot
  -> first Flutter frame
       -> DatabaseWorkerActivation (SQLite only)
       -> runtime push/chat bindings
       -> staggered foreground recovery
       -> on-demand Liquid Glass initialization
  -> first interactive marker
```

Before first frame, code may only establish Flutter bindings, required identity,
the local snapshot authority, runtime metadata, root providers, and the first
route. Network synchronization, worker isolates, cache refresh, media prewarm,
upload recovery, Chat recovery, graph layout, and visual effects start after
the first frame or on demand.

Review rules:

- Every required await has a bounded timeout and a safe visible failure state.
- A post-frame task has a stable owner/key, cancellation, and lifecycle policy.
- Account and Workspace recovery uses `TaskOrchestrator`; it cannot fan out
  directly from a Widget build.
- Hidden PageView/KeepAlive pages retain user state, not active tickers,
  polling, decoder buffers, or database work.
- `AppActivityCoordinator` remains the only `WidgetsBindingObserver`.
- Startup dependencies never include user payload logging or remote feature
  configuration needed merely to paint the first route.
