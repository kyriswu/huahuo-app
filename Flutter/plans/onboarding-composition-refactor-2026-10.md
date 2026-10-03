# Onboarding composition boundary

## Scope and evidence

Separate onboarding application objects from Riverpod application composition.
The confirmed cycle is app_providers -> content_line_onboarding_controller ->
app_providers. Initial-positioning and first-launch controllers also contain
provider factories. Graphify is unavailable; use source import graph, analyzer,
existing behavioral tests and the architecture check. Read ADR-003 and ADR-005;
keep state ownership, pending submission retention and recovery unchanged.

## Implementation

- [x] Move provider factories from three onboarding application files and the
  positioning lifecycle factory from app_providers to app/di/onboarding_providers.
- [x] Migrate all provider consumers to explicit composition imports; do not
  re-export the new module from controllers or app_providers (would recreate
  the dependency cycle).
- [x] Verify provider bodies and application logic are unchanged, analyze all
  consumers, run onboarding/navigation/positioning tests, review import impact.

## Non-goals and acceptance

No request/schema/protocol changes, no new provider scope or runtime lifecycle,
no native changes, no general ui_v3 or chat rewrite. Existing staged cleanup and
other work remain intact on refactor/onboarding-composition.

The three application files must no longer import app composition or Riverpod.
The global app_providers file must no longer import onboarding application
code. Existing provider overrides must retain their identity and behavior.
Do not silence unrelated architecture debt to claim a green full gate.

## Results (2026-10-02)

- Moved 14 provider declarations in six blocks to the onboarding composition
  module and migrated 24 consumers, including test overrides and integration
  test imports. Provider bodies are equivalent after whitespace/comment
  normalization. The three application implementations are unchanged after
  extraction. Other production edits are imports/formatting only.
- Removed onboarding and now-unused chat-provider imports from global
  app_providers. Transitive source checks show no app dependencies from any
  onboarding application file and no reverse dependency from global providers
  to onboarding composition. Added two executable boundary regression tests.
- Architecture checker: 441/441 reachable files; findings decrease from 91 to
  88. The cycle disappears; three formerly undocumented resident factories
  now state their existing lifecycle. No budgets or rules were changed. Two
  already-oversized files gain one explicit import line; global app_providers
  shrinks by 102 lines. Other debt remains.
- `dart analyze lib test` exits 0: no errors/warnings, 420 existing/style infos.
  Integration analysis has two non-exhaustive switches in the existing
  live_first_positioning_setup_simulator_test for chatRequired. Its test body
  is identical to the captured pre-refactor source; only import migration was
  performed. No live test ran.
- Application/boundary tests: 74 passed. Four additional suites (first-launch
  page, progress page, positioning lifecycle, digital twin): 111 passed.
- The remaining four suites (onboarding page, chat guide, positioning report,
  app-root navigation): 27 passed / 18 failed. Reconstructed the pre-refactor
  source in an isolated temporary directory, using the same SDK/dependencies
  and read-only assets, and ran these suites: also 27 passed / 18 failed, with
  exactly the same failing test names. Failures include missing device identity
  injection and positioning state expectations. They are baseline debt, not
  fixed by weakening assertions or changing application behavior.
- Total current focused results: 212 passed / 18 pre-existing failures. The
  full repository gate is not green. No native, protocol, data or server edits.

## Evidence and follow-up

Local logs and pre-refactor source snapshot are under
`/private/tmp/huahuo-onboarding-refactor/`. Durable boundary rules are recorded
in `docs/architecture/onboarding-composition.md`.

Next work should repair the stale offline fixtures and integration switch
coverage, then continue capability/provider extraction. Do not mix changes to
the onboarding state machine into this composition-only refactor.
