# Mobile V5 to Flutter migration execution record

> Superseded visual conclusion (2026-08-24): the phase journal below remains a
> record of route, controller, and behavioral-test work, but it is not evidence
> of Figma parity. The Mobile V5 targets were reopened in
> `visual_acceptance_matrix.md`; as of the current pass, all 315 ledger rows
> (314 independent V5 targets plus the recorded profile-drawer duplicate) have
> evidence: 307 are `GAP`, six are `MATCH`, and two use canonical evidence.
> No row remains `UNREVIEWED`. A target is complete only after a 402 x 874
> screenshot comparison, its entry/exit actions, and the related visual test
> are recorded there.

## Frozen inputs

- Figma file: `cB9ops5llz7DvBJ1QTvCu9`
- Mobile V5 page: `2659:76`
- Mobile V5 Registry: `2660:76`
- Registry snapshot: 435 candidates, 317 COPY, 118 SKIP, 0 unresolved GATE,
  338 actions (100 baseline + 27 M05 + 211 Family), 57 Flutter mappings, and
  544 valid V5 prototype reactions.
- Original planning baseline: `178fd247ac56c50ce117a239dd9cdc3ffb906241`
- Implementation baseline: `389d0ba45883a8b5e74fd73ae8360a0f204e1146`
- Branch: `codex/figma-mobile-v5-migration`

The implementation baseline is a direct descendant of the planning baseline.
It includes the cache update, the first note-detail Figma migration, and the
feed preparation pass. These changes are retained and revalidated; the working
tree must not be reset to the older planning baseline.

The complete governing plan remains at
`archive/docs/figma_flutter_backend_preserving_migration_plan_v2.md` (repository-relative). This document
records the concrete repository baseline and execution order.

## Invariants

1. Figma replaces presentation only. Routes, route parameters, Provider scopes,
   controllers, ports, repositories, API clients, idempotency, revision/ETag,
   cache, lifecycle recovery, and workspace/account isolation remain intact.
2. Production code never loads temporary Figma asset URLs.
3. M01-M11 original Figma pages remain read-only. Mobile V5 is the curated
   implementation source.
4. Cross-module canonical screens are implemented once. Other modules navigate
   to or compose that owner instead of creating a second screen.
5. No visible control may be inert. Unsupported server behavior is represented
   by an explicit unavailable state recorded in `api_gate_register.md`.
6. Before editing `Flutter/src`, update the corresponding SCM document first.

## Phase order

| Phase | Scope | Exit condition |
|---|---|---|
| 0 | Baseline, manifests, binding matrix, M05 characterization | Documentation is complete and no ownership is ambiguous |
| 1 | M05 chat entry | Exact entry UI, real thread/send/history/voice flows, widget and golden coverage |
| 2 | M01 feed and M02 note detail | Existing migrated work revalidated; remaining states implemented |
| 3 | M03 creation | Canvas state machine and overlays preserve draft/history controllers |
| 4 | M04 assets and M07 knowledge | Canonical asset/note ownership and server-backed mutations preserved |
| 5 | M06, M08, M09, M10, M11 | Every retained state has a concrete owner, action path and current/target evidence; remaining visual differences stay `GAP` |
| 6 | Global verification | Analyze, unit/widget/golden/integration tests and iPhone 17 Pro simulation pass |

## Rollback boundary

Each phase must be independently reviewable. Presentation extraction may use a
temporary compile-time feature switch while a family is being migrated, but it
must not duplicate controller or repository state. The old rendering path is
removed only after the corresponding family exits verification.

## Phase journal

| Phase | Git commit | Evidence |
|---|---|---|
| 0 | `127d9d5e` | Baseline, manifest, backend matrix, API gates and M05 characterization committed |
| 1 | `dbd1383d` | M05 target analysis clean; 67 tests and SCM check pass; 402 x 874 golden reviewed; iOS simulator build succeeds |
| 2 | `1f3fee9a` | M01 canonical implementation revalidated; continuous graph tests use bounded frames; M02 pure surface extracted; controller, golden and route regressions pass |
| 3 | `aaba80df` | M03 home and canvas calibrated to canonical nodes; flat toolbar and exact blank states covered; creation history swipe/delete state added through the existing scoped history port |
| 4 | `0771083a` | M04 two-level asset navigation and canonical command row implemented; M07 external-world chrome calibrated; Folder, Search, Subscription and save-as-note boundary regressions pass |
| 5 | `f05c8423` | M06/M09/M10/M11 existing state owners revalidated; M08 canonical header overlap removed while Book/Work remains reachable from the information sheet; profile/masterpiece/calendar, recording-card, auth and onboarding regressions pass |
| 6 | Current verification gate | 2,101 unit/widget/Golden tests pass; analyze has zero errors/warnings (306 existing info lints); SCM passes for 1,108 active files. iPhone 17 Pro Xcode build succeeds, but the iOS 26 integration Runner emits no test events and the installed native host reports a missing JS bundle when launched directly, so simulator visual acceptance remains open rather than being reported as passed. |

## 2026-08-25 verification result

- `flutter test --reporter compact`: 2,101 tests passed.
- `flutter analyze --no-fatal-infos`: zero errors and warnings; 306 existing
  info-level style lints remain outside this visual migration.
- `git diff --check -- Flutter`: passed.
- iPhone 17 Pro simulator `DC53F410-8577-4601-BC10-70A7BB931E04` completed the
  Xcode build for `v5_feed_navigation_smoke_test.dart`. The integration Runner
  then produced no test events and was terminated cleanly. Direct launch of
  the installed native host showed `No script URL provided`, proving the
  remaining simulator blocker is the host JS-bundle/Runner configuration, not
  a passing Flutter visual comparison.

## Phase 5 implementation notes

- M06 keeps `V3ProfileSidePanel` as the sole profile overlay owner. Settings,
  account, membership and voiceprint continue through their existing
  controllers and explicit unavailable capability ports; no duplicate M03 or
  M10 destination was introduced. The daily-reminder card is a functional local
  Settings preference and remains visibly unscheduled until a typed native
  notification contract exists. 花火商学院 remains an explicit unavailable gate.
- M08 follows canonical reader node `2059:21631` and state nodes
  `2082:23746`-`2082:23751`. The shared shell owns the top-left menu/title, so
  the independent Book/Work capability is available from the fixed three-dot
  information sheet instead of overlapping that header. Directory, reader,
  editor, lock and cadence state remain in the existing page owner.
- M09 follows canonical disconnected node `2059:21671`, connected nodes
  `2082:23752`/`2082:23759`, and the existing connection/transfer/file state
  owners. Simulator tests cover presentation and state projection only; BLE,
  Wi-Fi, firmware file transfer, background recovery and device commands still
  require physical-device acceptance.
- M10 retains Auth, the 4-step business questionnaire, 7-step non-business
  questionnaire, durable positioning progress and first-device setup owners.
  UI timers do not synthesize backend completion. M10 voiceprint and recording
  card endpoints reuse the M06 and M09 canonical routes.
- M11 owns only top-level profile/calendar/positioning entry behavior. M01
  home, M03 workbench, M06 profile and M07 knowledge copies remain references,
  not second implementations.

## Phase 6 verification notes

The notes in this section describe historical engineering verification. They do
not mark any Mobile V5 screen as a visual match. Current visual truth lives in
`visual_acceptance_matrix.md`.

- The 2026-08-24 evidence refresh covers every M01-M11 ledger row. It does not
  relabel the 307 remaining differences as complete; those rows stay `GAP`
  until their current screenshot satisfies the target overlay tolerance.

- The complete Flutter unit/widget suite passes with 1,914 tests and no
  failures. Four stale tests were corrected to match current production
  contracts: incoming document hashes use valid hexadecimal SHA-256 values,
  recording upload assertions follow the V2 request fingerprint, missing-Agent
  coverage uses a genuinely unmapped public Profile, and graph zoom interaction
  resolves live scene coordinates from the painter.
- Whole-project `flutter analyze --no-fatal-infos` is the migration gate. The
  2026-08-24 remediation removed all warning/error diagnostics; existing
  repository-wide style infos remain non-blocking and are not mass-rewritten as
  part of the presentation migration.
- The iPhone 17 Pro simulator V5 navigation suite passes all eight scenarios,
  including Feed modes, workbench entry, Agent chat, graph search, fail-closed
  aggregation, import actions, profile destinations, and return navigation.
- The iPhone 17 Pro simulator V6 product-flow suite passes all five scenarios:
  Persona, lead generation, enabled video analysis, initial-positioning
  recovery, and graph-to-context-chat.
- iOS integration execution must set
  `HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=1`; the Xcode scheme guard otherwise
  resets the requested integration-test target to the formal app target. This
  is a test-runner requirement and does not change application behavior.
- M09 simulator coverage validates presentation and state projection only.
  BLE connection, Wi-Fi transfer, firmware/file transfer, background recovery,
  and physical recording-card commands remain physical-device acceptance work,
  not a Flutter migration implementation gap.
- The deterministic M01 aggregation target now owns local deposited fixtures
  and no longer waits on an account or server. Its iOS build succeeds, but the
  current Flutter 3.35/iOS 26 simulator runner can stall before exposing the
  integration-test extension. A stalled extension is recorded as runner
  infrastructure failure, never as passed visual evidence.
