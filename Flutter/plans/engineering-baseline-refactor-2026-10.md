# Engineering baseline refactor

## Scope

First implementation batch of the handover audit: replace misleading API
integration reporting with an offline contract consistency check; remove its
report-only production DTO; replace historical no-deletion gates with current
contract checks; include every workspace member's tests in the quality gate.
Preserve runtime requests, platform code, data migrations and existing work.

Graphify is unavailable. Impact review uses source import/call searches,
analyzer and focused tests. No server or live integration tests are run.

## Steps

- [x] Replace reporter and migrate active commands/documentation; preserve historical reports as dated evidence.
- [x] Remove fixed historical Git baseline from backend check, retain current endpoint policy checks and cover desktop sources.
- [x] Include foundation tests and missing formatting roots in gate; add regression tests for gate/check behavior.
- [x] Run formatting, static analysis, focused tests and offline checks; record limitations and remaining architecture work.

## Acceptance

The new check never calls the network or claims executed test coverage. It
distinguishes runtime definitions, missing definitions and non-runtime
contracts. Production API exports contain no report DTO. Backend checks work
without historical Git objects. All six workspace members appear in the
quality gate test plan. Existing protocol/runtime behavior remains unchanged.

## Changes and verification

Branch: `refactor/engineering-baseline`. Pre-existing staged cleanup and native
changes were retained; this batch was not committed together with them.

- Replaced the old reporter with `api_contract_consistency_check.dart`; no
  output files by default, explicit `--json` artifact export, no environment
  token inspection, no fictional test receipts or working-tree revision.
- Removed report-only `ApiIntegrationReportEntry` from the production API
  library. Historical Markdown reports now explain their evidentiary limits;
  historical JSON remains unchanged.
- Backend check now scans mobile, desktop, API and product sources; it no
  longer runs Git history commands. Current endpoint policies and unresolved
  reference failures remain blocking. Mock/Demo regex matches are review hints;
  file-level word matches cannot establish guarded runtime reachability. An
  AST/build-level replacement remains future work.
- Gate includes foundation tests, integration/test-driver formatting and the
  new offline consistency check. Offline bootstrap succeeded with the existing
  workspace lockfile unchanged.
- Focused tests: 4 consistency + 6 gate + 3 backend checker + 12 existing API
  contract + 13 foundation tests = 38 passed. Changed Dart files formatted;
  focused analyzer completed with no issues.
- Consistency CLI and JSON export: 215 declarations, 0 issues; 91 runtime
  definitions present, 119 contract-only, 5 prohibited and absent. No live
  request or test execution is claimed by that artifact.
- Backend CLI: 212 endpoint definitions; one heuristic review hint for the
  existing canvas Mock constructor. The file has a debug flag; this batch
  does not certify its production reachability.
- Architecture impact review: 440/440 reachable files, exactly the same 91
  findings as before, no added or removed findings. The existing cycle and
  debt remain unresolved; the full gate is not green.

## Remaining batches

Fixed-SDK enforcement/CI, opt-in integration suites, calibration of the
architecture checker, app-provider/onboarding dependency separation, feature
boundaries and storage/native refactors remain open. This first batch only
establishes truthful contract validation and fills test-plan omissions.
