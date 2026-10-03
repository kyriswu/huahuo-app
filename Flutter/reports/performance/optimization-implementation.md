# Flutter optimization implementation matrix

- Baseline reviewed: `78005b99` (`4093f23a` was not used as the architecture
  baseline for this performance program).
- Scope: `Flutter/` only.
- Date: 2026-08-31.
- `Verified`: the cited production mechanism is covered by focused automated
  evidence in the named scope. It does not, by itself, claim repository-wide
  migration or physical-device performance acceptance.
- `Implemented`: the production mechanism exists, but focused coverage, full
  consumer migration, or numeric acceptance is still incomplete as stated in
  the row.
- `In progress`: migration or debt required by that row's named acceptance
  scope remains. A separately tracked, decreasing legacy-file ratchet does not
  by itself make a staged acceptance `In progress` under plan section 10.6.
- `External`: completion requires repository-owner, credential-owner,
  device-farm, or connected physical-device authority and is not claimed from
  local code.
- Final local status: 81 `Verified`, 9 `Implemented`, 0 `In progress`, and 5
  `External` requirements.

## Claim boundaries

| Claim dimension | Required evidence | Current interpretation |
|---|---|---|
| Mechanism complete | Production path plus focused unit/widget/structure evidence | Reported as `Verified` or `Implemented` only for the scope named in the row |
| Full migration | Repository-wide audit or a zero-debt executable gate, stated explicitly in the row | Not inferred from a mechanism, a sampled search, or a nonzero ratchet |
| Physical acceptance | Dated Profile evidence from physical iOS and Android devices for the required scenario and budget | Not available; every numeric/device conclusion remains `External` / pending physical-device verification |

The seven matrices below retain all 95 requirement IDs (15 performance, 12
state, 15 task, 15 database, 14 media, 8 startup, and 16 architecture/governance
items). Status is assessed per ID; an evidence-bundle label is not an aggregate
completion claim.

Cancellation in this report is conservative. Repository-wide HTTP cancellation
means logical consumer cancellation and late-result suppression unless a row
explicitly identifies an abort-capable transport; focused `HttpApiTransport`
abort tests do not prove that every HTTP client or plugin request is physically
stopped. `Isolate.run` work cannot be killed by the current API: disposal and
task cancellation only prevent a late result from being cached or published.

## Evidence bundles

| Key | Primary evidence |
|---|---|
| P-OBS | `src/lib/core/performance/`, native runtime bridges, `performance_metrics_test.dart`, `performance_policy_test.dart`, `performance_gate_test.dart` |
| P-GRAPH | `v3_interactive_graph.dart`, graph budget/quality/physics/cache libraries and directed graph tests |
| P-GLASS | `v3_glass_foundations.dart`, `v3_glass_blur_tokens.dart`, `v3_glass_painters.dart`, `v3_liquid_glass.dart`, glass/repeat-animation tests |
| S-STATE | Chat run-family projection, Knowledge read model/index, Pending reducer/badge, Home Widget revision service, build-side-effect architecture tests |
| T-RUNTIME | `app_activity_coordinator.dart`, `page_activity_lease.dart`, `task_orchestrator.dart`, `orchestrated_poller.dart`, resume/push/recovery activation and tests |
| T-API | `huahuo_api` GET/refresh single-flight, request leases, retry policy, opaque cache keys and API foundation tests |
| D-WORKER | database worker/schema/write queue/runtime, DAO adapters, migration/fault/queue tests |
| D-SYNC | Knowledge Note outbox/inbox journal, workspace sync/controller restart, retry, tombstone and inbox dedupe tests |
| M-MEDIA | sized image decode/cache, streaming upload limiter, playback/waveform throttling, Markdown reveal and document worker tests |
| B-BOOT | App runtime activation, AppRoot/foreground coordinators, startup graph and lifecycle tests |
| A-GATE | ADRs, dependency rules, source reachability/RFC/KeepAlive/Timer/SCM/secret/quality/performance gates |

These bundles primarily prove wiring, ownership, policy, and deterministic
behavior. Widget, unit, source-structure, and architecture tests do not replace
physical Profile evidence for Raster P95/P99, actual layer-tree counts, cold
startup, recording smoothness, export responsiveness, memory/thermal behavior,
or soak stability.

## Rendering and animation

| ID | Status | Evidence |
|---|---|---|
| PERF-001 | Verified | P-GRAPH: physics ticker sleeps after settle and hidden/inactive state reports zero |
| PERF-002 | Verified | P-GRAPH: sphere auto-rotation defaults off and is policy bounded |
| PERF-003 | Verified | P-GRAPH: 120/72/32 node and 220/120/48 edge tiers |
| PERF-004 | Verified | P-GRAPH, T-RUNTIME: page activity immediately releases ticker work |
| PERF-005 | Verified | P-GRAPH: large layouts cross to `Isolate.run` at tested thresholds |
| PERF-006 | Verified | P-GRAPH: 200 ms graph-search debounce |
| PERF-007 | Verified | P-GRAPH: geometry/render plans cached; painter repaint predicates tested |
| PERF-008 | Implemented | P-GLASS, P-OBS: native thermal/low-power/lifecycle signals and frame-pressure policy are wired and focused tests cover quality transitions; continuous real-device auto-downgrade behavior and its visual result remain External / pending physical-device Profile evidence |
| PERF-009 | Implemented | P-GLASS: all identified repeated scrolling-row surfaces explicitly use static material through `allowBackdrop: false`, with an opt-out widget test; Raster P95 reduction remains External / pending physical-device Profile evidence |
| PERF-010 | Verified | P-GLASS: remaining blur is clipped and quality bounded |
| PERF-011 | Implemented | P-GLASS: redundant own-layer composition was removed in the targeted glass path; structure tests cannot measure the runtime layer tree, so layer-count acceptance is External / pending physical-device inspection |
| PERF-012 | Verified | P-GLASS, T-RUNTIME: repeat animations stop when invisible/inactive |
| PERF-013 | Verified | P-OBS, P-GLASS: Reduce Motion flows into shared motion policy |
| PERF-014 | Verified | P-GLASS: route transitions use opacity/transform-only motion |
| PERF-015 | Verified | P-GLASS, A-GATE: a zero-debt executable gate covers effect-consuming presentation/widgets/shared-UI files; blur and motion parameters are owned by the shared foundations/tokens, including `v3_glass_blur_tokens.dart`, with no accepted page-local duration/sigma debt in that scope |

## State and rebuild scope

| ID | Status | Evidence |
|---|---|---|
| STATE-001 | Verified | P-OBS: bounded owner rebuild counters on root and hot Chat subtrees |
| STATE-002 | Verified | S-STATE: AppRoot observes low-frequency projections only |
| STATE-003 | Verified | S-STATE: Home Widget publishes debounced content-hash revisions outside build |
| STATE-004 | Verified | S-STATE: event-style incremental Pending reducer with full-rebuild rollback |
| STATE-005 | Verified | S-STATE: badge provider selects an integer projection |
| STATE-006 | Verified | S-STATE: Chat run-family/current-run providers localize stream updates |
| STATE-007 | Verified | S-STATE: graph consumes immutable Knowledge graph revision/read model |
| STATE-008 | Verified | S-STATE: Knowledge derived lists use revision memoization |
| STATE-009 | Verified | S-STATE: normalized note index and per-ID provider |
| STATE-010 | Verified | S-STATE: token deltas use a dedicated reveal channel, not global cold state |
| STATE-011 | Verified | S-STATE, A-GATE: providers default to `autoDispose` where consumer ownership applies; every intentionally resident provider requires a concrete lifecycle reason, and the executable resident-provider debt set is empty |
| STATE-012 | Verified | A-GATE: the zero-debt lexical build-side-effect gate covers direct commands plus deferred closures, IIFEs, switch branches, and related invocation forms; this is explicit static-syntax coverage, not a claim of semantic-program-analysis completeness |

## Network and background work

| ID | Status | Evidence |
|---|---|---|
| TASK-001 | Verified | SSE health cancels Chat fallback polling; rollback flag tested |
| TASK-002 | Verified | Chat reveal buffer coalesces to 50 ms; immediate rollback mode tested |
| TASK-003 | Verified | per-run checkpoint latest-wins at 750 ms with terminal/pause flush |
| TASK-004 | Verified | T-RUNTIME: one process lifecycle observer and typed activity projection |
| TASK-005 | Verified | T-RUNTIME: keyed join/replace/cancel/deadline/resource budgets/projections/metrics |
| TASK-006 | Verified | T-RUNTIME: generation-owned, tiered foreground resume with stagger |
| TASK-007 | Implemented | T-RUNTIME: recording processing now uses keyed `OrchestratedPoller` ownership and activity gating; end-to-end background recording behavior remains External / pending physical-device recording evidence |
| TASK-008 | Verified | Feed aggregation uses a stable orchestrated poll key and no feature periodic timer |
| TASK-009 | Verified | recording-card foreground recovery is keyed, replaceable and background gated |
| TASK-010 | Verified | recovery activation and upload recovery are single-flight by stable key |
| TASK-011 | Verified | T-RUNTIME, T-API: bounded exponential backoff plus success/failure jitter |
| TASK-012 | Implemented | T-API: consumer leases cancel ownership and suppress late publication; an abort-capable HTTP transport is covered, but universal physical socket/plugin cancellation is not claimed |
| TASK-013 | Verified | T-API: identical GETs join one in-flight transport |
| TASK-014 | Verified | T-API: token refresh is single-flight |
| TASK-015 | Verified | push activation is primary; ordinary background pollers suspend at once |

## Database and files

| ID | Status | Evidence |
|---|---|---|
| DB-001 | Verified | P-OBS, D-WORKER: bounded operation/queue/execute/row/byte/reason metrics |
| DB-002 | Verified | D-WORKER: one serialized write queue |
| DB-003 | Verified | D-WORKER: replace-pending latest-wins semantics |
| DB-004 | Verified | D-WORKER: diagnostic append batching and bounded retention |
| DB-005 | Verified | D-WORKER: default SQLite writes and schema work run in the worker; startup read is read-only |
| DB-006 | Verified | D-WORKER: one long-lived SQLite connection per worker |
| DB-007 | Verified | D-WORKER: record mutations and checkpoint deltas use incremental SQL |
| DB-008 | Verified | D-WORKER: prepared hot-path statements |
| DB-009 | Verified | D-WORKER: WAL/index health inspection and tests |
| DB-010 | Verified | Canvas autosave debounce/delta coordinator and tests |
| DB-011 | Verified | normalized per-run Chat checkpoint table and atomic diff |
| DB-012 | Verified | diagnostic capacity/expiry pruning |
| DB-013 | Verified | large outbox payload and mutable delivery state are separated |
| DB-014 | Verified | migration interruption/rollback/reopen fault tests |
| DB-015 | Verified | D-SYNC: production upsert/delete outbox and remote-revision inbox dedupe |

## Images, audio, video and documents

| ID | Status | Evidence |
|---|---|---|
| MEDIA-001 | Verified | M-MEDIA: list/chat/feed images provide physical display decode bounds |
| MEDIA-002 | Implemented | M-MEDIA: decoded cache budgets are tiered at 48/32/20 MiB, memory-pressure release and policy fallback are focused-test covered; actual memory recovery after 20 core-page navigation loops remains External / pending physical-device Profile evidence |
| MEDIA-003 | Verified | M-MEDIA: compressed cache uses quality-tiered bounded LRU storage |
| MEDIA-004 | Verified | M-MEDIA: atomic disk index replaces per-write directory scans |
| MEDIA-005 | Verified | M-MEDIA: memory pressure clears decoded/live/compressed/export caches |
| MEDIA-006 | Verified | M-MEDIA: avatar transform/re-encode runs in an isolate with input/output limits |
| MEDIA-007 | Verified | M-MEDIA: playback progress is throttled to the 4-10 Hz budget |
| MEDIA-008 | Implemented | M-MEDIA: native metering runs off the platform main loop (Android `HandlerThread`, iOS `DispatchSourceTimer`) and level snapshots are throttled to 20 Hz before Dart publication; recording-page smoothness remains External / pending physical-device Profile evidence |
| MEDIA-009 | Verified | M-MEDIA: object uploads consume file streams, not whole-file byte arrays |
| MEDIA-010 | Verified | M-MEDIA: shared FIFO upload limit is two |
| MEDIA-011 | Verified | M-MEDIA: streaming text reveals at 50 ms and delays full Markdown parsing |
| MEDIA-012 | Implemented | M-MEDIA: PDF rendering runs through `Isolate.run`; ZIP bytes are server-built and Flutter only stages them. Isolate cancellation is logical late-result suppression, and export responsiveness remains External / pending physical-device Profile evidence |
| MEDIA-013 | Verified | M-MEDIA: revision-keyed preview/render future cache |
| MEDIA-014 | Verified | M-MEDIA: thumbnail-first progressive authenticated images |

## Startup and lifecycle

| ID | Status | Evidence |
|---|---|---|
| BOOT-001 | Implemented | P-OBS: first-frame and first-interactive instrumentation exists and its semantics are tested; no stable startup baseline exists without repeated cold-start Profile runs on physical devices |
| BOOT-002 | Verified | B-BOOT: worker, glass and noncritical synchronization activate post-frame |
| BOOT-003 | Verified | B-BOOT: bounded, failure-tolerant visual warm-up |
| BOOT-004 | Verified | T-RUNTIME: AppActivityCoordinator is the sole binding observer |
| BOOT-005 | Verified | T-RUNTIME: foreground/current-route activity lease |
| BOOT-006 | Verified | A-GATE: heavy KeepAlive resources require activity/ticker gates |
| BOOT-007 | Verified | T-RUNTIME: foreground generation token prevents duplicate resume storms |
| BOOT-008 | Verified | `docs/architecture/STARTUP_DEPENDENCY_GRAPH.md` plus provider boundary gate |

## Architecture and governance

| ID | Status | Evidence |
|---|---|---|
| ARCH-001 | Verified | providers split into runtime/core/activation modules with a 2000-line ratchet |
| ARCH-002 | Verified | AppRoot delegates visual composition, foreground, push and recovery coordination; the executable gate holds `AppRoot` below 650 lines and its visual root below 500 lines |
| ARCH-003 | Verified | Knowledge query and subscription responsibilities are independently extracted and tested in 501-line and 483-line controllers; the 4,962-line compatibility facade remains explicit decreasing debt under the staged acceptance in plan section 10.6, not a completed whole-file size claim |
| ARCH-004 | Verified | Chat execution/streaming/progress libraries and run-family projections localize token updates to the hot subtree, with focused rebuild acceptance coverage; the independent 6k+ line page and 2k+ line controller extraction debt remains tracked without weakening this scoped acceptance |
| ARCH-005 | Verified | Canvas autosave and document export services are independent from page rendering |
| ARCH-006 | Verified | glass foundations, tokens/components and production painter boundary are separate |
| ARCH-007 | Verified | A-GATE: public feature `widgets` APIs and zero-debt gates cover presentation/widgets-to-data reversals, lower-layer-to-UI imports, private/cross-feature presentation or widget imports, widgets-to-app imports, application exports of data implementations, cycles, and mobile/desktop/shared boundaries |
| ARCH-008 | Verified | T-RUNTIME: sealed task state and shared immutable notification/recovery projection |
| ARCH-009 | Verified | ADR-001 through ADR-006 |
| ARCH-010 | Verified | new TaskSpec registrations require a checked-in RFC marker and document |
| GOV-001 | External | Flutter-scope scanning and diagnostic/export redaction are implemented, but the tracked repository-root `AGENTS.md` still contains infrastructure credentials; no repository-wide clean claim is made, and removal, credential rotation, history rewrite, and push protection require the responsible owners |
| GOV-002 | External | owner checklist exists; hosted main protection/CODEOWNERS cannot be asserted locally |
| GOV-003 | External | The local PR quality-gate mechanism covers format/analyze/test/architecture/SCM/secrets/dependencies; making it a required hosted PR check needs repository-owner evidence |
| GOV-004 | Verified | SCM mappings, SOURCE_TREE and changed-file pairing are executable gates; the latest focused SCM check passed all 1,198 active files, while guaranteed hosted execution on every PR remains the External GOV-003 control |
| GOV-005 | External | nightly gate fails closed without physical Profile evidence; schedule/device farm requires owner access |
| GOV-006 | External | release gate requires iOS+Android, 15-minute soak, recovery/media coverage; evidence is not fabricated |

## Physical-device acceptance

No dated physical-device Profile acceptance was produced. A wireless iOS
device was discoverable during the final inventory but was not used as release
or Profile evidence, and no Android physical device was attached. The
checked-in performance summary intentionally remains unmeasured and fails the
nightly/release gate. The following acceptance work is therefore `External` /
pending controlled physical-device verification:

- scrolling Build/Raster P95/P99 and the runtime layer tree/count for
  PERF-009/PERF-011;
- continuous thermal/frame-pressure quality downgrade and resulting visuals for
  PERF-008;
- repeated cold-start first-frame/first-interactive distributions for BOOT-001;
- decoded-image memory recovery after 20 core-page navigation loops for
  MEDIA-002;
- real microphone recording, waveform smoothness, background/foreground
  recovery, and Android/iOS parity for TASK-007/MEDIA-008;
- PDF export responsiveness and late-cancellation behavior under load for
  MEDIA-012; and
- CPU, thermal, battery, memory-loop, recovery/media coverage, and the required
  15-30 minute soak for GOV-005/GOV-006.

An iOS Simulator run is functional evidence only. Unit, widget, structure, and
architecture tests are not substitutes for any of the physical measurements
above.

## Final local verification

- The final `dart run tool/quality_gate.dart pr` run passed end to end: 2,417
  mobile tests, 265 desktop tests, 124 `huahuo_api` tests, and 14 editor tests,
  together with format, analyze, dependency, architecture, performance-policy,
  SCM, reachability, and secret checks.
- The M08 deterministic-clock and fixture-image pre-cache correction passed its
  focused 11/11 suite and all four formerly failing comparisons in the complete
  PR gate. Its directory baseline update is limited to the two brand images
  that are now deterministically decoded before capture.
- The source reachability gate passed 382/382 Dart files, and the SCM gate
  passed all 1,198 active files.
- `flutter build apk --debug --no-pub` produced
  `build/app/outputs/flutter-apk/app-debug.apk`.
- `flutter build ios --simulator --debug --no-pub` produced
  `build/ios/iphonesimulator/Runner.app`.
- Existing iPhone 17 Pro Simulator `DC53F410-8577-4601-BC10-70A7BB931E04`
  passed the sphere interaction and feed aggregation screenshot drives. The
  eight visually inspected, hash-distinct 1206x2622 captures are under
  `/tmp/huahuo-optimization-sphere-final-20260831` and
  `/tmp/huahuo-optimization-aggregation-final-20260831`.
- The three graph golden baselines affected only by the aggregation-action
  clearance adjustment were rebaselined, then passed an ordinary comparison
  run. Generated golden failure artifacts were removed.
