# Onboarding offline baseline repair

## Scope and evidence

Repair the 18 pre-existing offline widget failures reproduced before and after
the composition extraction, plus two non-exhaustive integration-test switches.
Do not change application behavior, API contracts, native code or server data.
Graphify is unavailable; inspect source imports, provider overrides, current
state-machine contracts and focused tests instead.

## Steps and acceptance

- [x] Constrain mandatory-device-setup integration assertions to blocking phases.
- [x] Align page and app-root fixtures with current composition and startup flow;
  preserve meaningful navigation and lifecycle assertions.
- [x] Format, analyze and run the four affected suites plus relevant boundaries.
- [x] Review diff and record results before continuing provider extraction.

Expected changes are test fixtures and integration test assertions only. Live
tests will only be analyzed, never executed. Existing staged cleanup and native
work remain intact. Rollback only this batch's test edits if needed.

## Results (2026-10-02)

- Added exhaustive `chatRequired` handling to the offline live-journey test; chat-guide accounts are explicitly excluded from device-setup evidence.
- Repaired page fixtures with an explicit positioning lifecycle override and aligned AppRoot navigation fixtures with the current device-setup state machine.
- Isolated onboarding goldens in a dedicated test file and settled animation frames before comparison; re-rendered baselines match the settled pre-refactor output.
- All 18 previously failing cases now pass. Onboarding, navigation, positioning-report and chat-guide suites: 45 passed; the combined final run including billing controllers and composition boundaries: 86 passed. Integration analysis reports no issues.
- No application behavior, API, native or server code changed in this batch.

The 12 PNG references remain executable golden-test fixtures. Failure screenshots
and comparison sheets are moved to temporary storage; no diagnostic snapshots
are retained alongside source. The test count remains unchanged by separating
visual and behavioral suites.
