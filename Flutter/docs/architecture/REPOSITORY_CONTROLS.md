# Repository controls requiring owner access

The local quality gate is necessary but cannot configure the Git hosting
service, rotate infrastructure credentials, or rewrite shared history. A
repository owner must apply and record these controls outside the source tree.

## Integration branch

- Block direct and force pushes to the actual integration branch.
- Require a pull request, one reviewer, and an up-to-date branch.
- Require the `quality_gate pr` status and linear-history policy.
- Add CODEOWNERS for `Flutter/src`, native bridges, schemas, CI, and release
  configuration.
- Protect signed release tags; introduce signed commits separately if needed.

## CI schedules

- PR: fetch the protected base branch and run
  `dart run tool/quality_gate.dart pr` against the actual PR target revision.
- Nightly: collect a physical-device Profile summary, then run
  `dart run tool/quality_gate.dart nightly --performance-snapshot <path>`.
- Release: collect the full iOS/Android evidence matrix, then run the same
  command in `release` mode. Missing evidence fails closed.

On macOS, nightly/release gates analyze an unsigned iOS arm64 release build in
addition to the Android arm64 artifact. Signing and IPA distribution remain in
the protected release job.

## Credentials and history

1. Inventory exposed credentials without pasting values into an issue or log.
2. Revoke and rotate them at the owning service before changing documentation.
3. Replace broad/root access with least-privilege accounts and local SSH aliases.
4. Remove plaintext from the current tree and use CI Secret/Secret Manager.
5. Coordinate a reviewed history rewrite; invalidate old clones and caches.
6. Enable hosted secret scanning and push protection.
7. Run `dart run tool/secret_scan.dart` and inspect the hosted scanner result.

The owner should attach dated evidence for each setting. A local file claiming a
branch is protected is not accepted as proof.

## 2026-10-01 read-only audit

- Remote: `Xieyangzai/Flutter`; GitHub default branch is `master`, while the
  current local branch is `main`. The target must come from the PR, not a guess.
- The GitHub branch API reports `master.protected = false`. This is evidence
  for `master` only, not every branch.
- Ruleset inspection returns HTTP 403 with a private-repository plan restriction
  (upgrade to GitHub Pro or change visibility). Keep this repository private;
  account/plan decisions belong to the owner. The connector lacks admin access.
- No remote protection, workflow, default-branch, or access setting was changed.
  Local scripts alone cannot prevent direct pushes.

## Parallel collaboration

Each developer/agent should use a separate branch and worktree. Agree on shared
interfaces first and assign a single editor to shared hot files. Review against
the actual target revision, then recheck the integrated revision before merge.
A dependency graph helps locate callers but neither locks files nor schedules
writers. Pair architecture and invariant decisions with targeted behavior
checks and review.
