# Billing composition extraction

## Scope and impact

Move six purchase/payment providers from global bootstrap into app/di. Keep
factories, account scope, disposal, purchase-stream startup and native channel
selection identical. No request, response, receipt, payment or native behavior
changes. Account usage still has a bootstrap override and is separate work.

Graphify is unavailable. Source inspection identifies app-root recovery,
profile-side-panel membership navigation and four test consumers. Billing
application/data imports do not depend on app composition. The extracted
module may import global service providers; the global module must not import
it back. Shared huahuo_api BillingClient and native payment port boundaries
are unchanged. Existing staged/native work must remain untouched.

## Implementation and verification

- [x] Move the six provider definitions without changing their bodies; migrate
  every consumer with explicit imports and remove obsolete bootstrap imports.
- [x] Assert transitive composition boundaries, compare moved blocks, run
  formatter, analyzer, billing and app-root tests and architecture impact check.
- [x] Record results without claiming the full repository gate is green.

Rollback only this extraction's module/import edits. No live purchases, live
API tests or native device checks are in scope.

## Results (2026-10-02)

- Moved `billingApiProvider`, payment ports, pending-order store, platform selector and controller into `lib/app/di/billing_providers.dart`; provider bodies are whitespace-equivalent to the original block.
- Migrated AppRoot, profile membership and billing/profile fixtures to explicit composition imports. Added boundary checks for billing application independence and the absence of a reverse global-provider edge.
- Static analysis has no errors or warnings (existing informational lint output remains). Architecture reachability remains complete and the finding count remains 88; the global provider module shrank without introducing a cycle.
- Final focused suites: 86 passed. Expanded payment UI/AppRoot suites: initial run 69 passed / 11 failed; repeat 72 passed / 8 failed, identical to the reconstructed pre-extraction run (same 8 failing names). The first run additionally emitted 3 asynchronous MissingPluginException failures, not reproduced on repeat; fixture lifecycle isolation remains follow-up work. No live payment or native run was performed.
- `dart analyze lib test integration_test`: 421 informational lints, no errors/warnings. Targeted analysis including integration tests is clean. Global providers shrink from 2964 to 2903 lines (governed lines 2854 to 2799); 442/442 source files reachable.

## Next batch

Repair the eight reproduced membership/appearance assertions and isolate AppRoot native-port fixtures before extracting account usage composition. Then remove the account-usage override from the global bootstrap layer without introducing a reverse import. Logs are local under `/private/tmp/huahuo-*`; they are not source or integration receipts.
