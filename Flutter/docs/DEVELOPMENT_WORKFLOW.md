# Development workflow

## Source of truth

Implementation truth is source code, tests, API contracts and database
schema/migrations. Long-lived reasons and rules belong only in concise
`docs/architecture`, `docs/invariants`, `docs/adr` and `docs/runbooks`. Never
create a Markdown mirror for a source file or a generated source index.

Keep decisions in `docs/adr`, including the imported `ADR-001` through
`ADR-006` and the separately numbered `ADR-0001` SCM retirement decision;
their original IDs remain unchanged. Dated audits, platform parity evidence,
and historical API reports belong in `reports/`. Historical
deployment references belong in `docs/archive/`; debugging procedures belong
in `docs/runbooks/`. Separate validation history from ongoing invariants.

## Simple task

Inspect -> edit -> focused validation -> review the impact.

## Complex task

Inspect -> query Graphify -> read relevant architecture/invariants -> write a
Plan/ExecPlan -> implement -> run focused validation -> query Graphify again for
impact -> open a PR.

Plans cover goal, non-goals, current behavior, symbols/modules, graph findings,
expected files, excluded files, state/data/API/native impact, risks, steps,
tests, acceptance and rollback. Keep a persistent plan under `plans/` only when
the task spans modules, multiple turns or parallel contributors.

## Graphify

Use the project-pinned Graphify CLI/skill when available. Query target symbols,
incoming/outgoing dependencies, related tests and platform boundaries. Treat
edges as discovery evidence, not compiler proof. Verify dynamic injection,
callbacks, generated code, string routes and native channels with source search,
LSP/analyzer and tests. A stale or missing graph never blocks source inspection.

## Parallel work

Each task uses one branch and preferably one worktree. Each agent works in its
own worktree and graph. Share interfaces before implementation, assign one
owner to shared hot files, keep PRs single-purpose and rebase or merge-check
against the actual target branch before integration. Git/PR review/CI replace
manual source coordination.

## Validation

Run formatting, analyzer, focused tests and impact review appropriate to the
change. Hardware, server and physical-device claims require their own evidence;
passing a mock or Simulator test does not claim physical-device behavior.

Use the SDK pinned in `.fvmrc`. From the Flutter workspace, bootstrap with
`fvm flutter pub get --enforce-lockfile` (add `--offline` when the cache is
already populated). From `src`, inspect the local gate with
`fvm dart run tool/quality_gate.dart pr --list` before running it.

The offline API check is `fvm dart run tool/api_contract_consistency_check.dart`.
It compares contract declarations with endpoint definitions; it does not
execute requests or test cases. To retain CI output, supply
`--json <artifact-path>`. It writes no files by default and does not regenerate
historical API indexes or matrices. Never interpret metadata consistency or
literal endpoint references as live integration coverage. The backend checker
uses current source, not a fixed historical Git revision; Mock/Demo text matches
are review hints, not proof of production reachability or debug-only safety.
