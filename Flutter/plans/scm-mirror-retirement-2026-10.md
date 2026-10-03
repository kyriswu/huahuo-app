# ExecPlan: retire the source-mirror SCM mechanism

## Goal

Switch the repository from source<->Markdown mirrors to source/tests, durable
architecture docs, Graphify, Codex planning and Git/PR collaboration without
changing runtime behavior.

## Scope

Delete `Flutter/scm` source mirrors and indexes, remove the mirror checker and
its quality-gate/test coupling, migrate durable state-machine and boundary
knowledge, rewrite instructions and workflow docs, and verify no active mirror
references remain.

## Non-goals

No Flutter UI, runtime behavior, backend contract, database schema, native
protocol or dependency upgrade changes. Do not split recording-card God files.

## Baseline and safety

Branch `main`, original HEAD `599315cce7e803be63d24d01d1bd973a844862cc`, tag
`pre-scm-retirement-2026-10`. Existing uncommitted work is preserved in the
working tree and copied under the migration backup directory. The migration
branch is `chore/retire-scm-mirror`.

## Durable knowledge extraction

Retain recording-card ownership/cancellation/persistence/file-boundary rules;
digital-twin proposal/version/account/Workspace/recovery rules; shared-package
and application boundaries; API identity/idempotency boundaries; physical
hardware debugging procedure. Drop per-file descriptions, generated indexes,
implementation histories and test-count logs.

## Implementation steps

1. Create concise architecture, invariant, ADR and runbook docs.
2. Rewrite root and Flutter `AGENTS.md` and add development workflow.
3. Remove the quality-gate mirror step, mirror checker tests and handoff index
   generation.
4. Delete `Flutter/scm` and residual source-mirror files.
5. Search all active files for legacy terms, then inspect the remaining history
   references and remove or label any that still prescribe the old workflow.
6. Compare runtime fingerprints and run lightweight tooling validation.

## Acceptance

- No `Flutter/scm` directory or source mirror remains.
- No `SOURCE_TREE`, `scm_check` or mirror-first active instruction remains.
- Quality gate contains formatting/analyze/tests/architecture/secret checks only.
- New docs explain architecture, invariants, plans, Graphify and Git isolation.
- Runtime source fingerprint is unchanged except for tooling-only references.
- Tag and backup evidence are recorded.

## Validation

Run repository residual-reference searches, `git diff --check`, targeted Dart
analyzer/tests for changed tooling, Graphify code-only refresh and a runtime
fingerprint comparison. Skip full application and hardware suites unless a
mechanism change requires them.

## Rollback

Revert this branch or restore `pre-scm-retirement-2026-10`; restore the copied
worktree archive only if needed, without resetting unrelated user changes.
