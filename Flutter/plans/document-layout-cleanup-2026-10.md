# Plan: Flutter document layout cleanup

## Scope and boundaries

Consolidate ADRs in `docs/adr`, move API integration outputs into
`reports/api-integration`, place dated audits and parity evidence under
`reports`, and separate durable lifecycle/navigation rules from past validation.
Move the FW920 debugging guide to `docs/runbooks` and the legacy URL Reader
deployment reference to `docs/archive`. Preserve existing uncommitted edits.

Keep application, platform, asset, dependency and package paths unchanged.
The only executable change is the API report generator's index output path;
do not regenerate or overwrite the historical reports during validation.

## Impact review

The local Graphify environment/output was removed during the earlier cache
cleanup. Use source search and focused validation here: the affected producer is
`src/tool/api_integration_report.dart`; consumers are integration reports,
handoff notes and the recording-card evidence archive. Performance RFCs are
read by the source-reachability gate and must remain in place.

ADRs retain their existing filenames and IDs, including the two historical
numbering styles. Consolidation does not renumber accepted decisions.

## Steps and acceptance

1. Snapshot current document bytes and application fingerprints.
2. Move documents and ADRs, split rules from historical evidence, update links.
3. Change the generator output path; validate in an isolated temporary fixture.
4. Verify document content preservation, relative links, residual old paths,
   unchanged application fingerprints, Dart formatting/analyzer and Git diffs.
5. Stage only this cleanup; do not commit or touch pre-existing native edits.

Rollback uses the reverse moves and restores only this task's edits. Git
history retains the original material; temporary validation output stays
outside the workspace.

## Completion evidence

- Relocated 16 documents, including six ADRs; removed empty `src/docs` and
  `docs/architecture/adr` directories. Added three invariant documents by
  extracting rules from historical audit records and linking both directions.
- All original non-heading content remains in the reports/invariants except
  three corrected path lines and one report-to-history wording adjustment.
- Protected application/platform/assets/dependency files match the starting
  fingerprint; only the reporter's output path changed in executable code.
- Dart analyzer: no issues. Dart formatter: no changes.
- Ran the before/after reporter in `/private/tmp` using cached pinned packages:
  215 operations, zero failures in each. Markdown/index bytes match; JSON
  matches after removing `generatedAt`. The new root-level index is absent.
- Moved/new document links and Git whitespace checks pass. No server, device
  or application runtime validation was performed for this document migration.
