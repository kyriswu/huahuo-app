# Canonical Chat Run terminal reconciliation

- Date: 2026-09-10
- Status: Implemented; focused regression verified; physical-device retest pending
- Scope: shared Run usage contract and Flutter account-owned Chat lifecycle

## Evidence

The physical-device incident reached succeeded at event sequence 77. Server
assistant persistence was complete, but 36.734 video seconds failed the Flutter
integer parser. The device retained an active succeeded checkpoint, rejected the
next turn, and repeatedly fetched the same HTTP 200 result. Decimal duration is
permitted by the backend AgentRunUsage json.Number and provider receipt contract.

## Design

1. Retain fractional video duration; keep integer-only token/count/credit fields
   and all mandatory canonical assistant checks. Do not round source facts.
2. Separate execution status from terminal-result reconciliation in a passive
   state machine. Terminal SSE stops execution UI but is not durable reply proof.
3. Join all simultaneous reads of one exact Run, and fence reads across lifecycle
   generations. Preserve ordered SSE state and complete public Tool enrichment.
4. Use the existing account poller only for healthy nonterminal SSE enrichment.
   The existing per-Run fallback exclusively owns terminal/unhealthy readback.
   Four consecutive failed terminal reads exhaust automatic recovery; no timer,
   reconnect, or account poller may bypass that state. Existing bounded jitter
   supplies retry spacing; there is no new periodic timer or polling owner.
5. Persist recoveryRequired, failure code, attempt count and retry deadline with
   the existing active checkpoint. Do not drop it or manufacture a ledger entry.
   Old succeeded active checkpoints without this metadata start a normal read.
6. A user send may request recovery under the existing Thread admission lease.
   It joins current readback or starts one bounded recovery cycle. Only valid
   canonical completion permits the next POST. A still-running Run stays blocked.
7. Queue a single checkpoint with the settled ledger and completion handoff before
   notifying observers. Never persist an intermediate removed-active checkpoint
   without the handoff. If the existing write queue has not committed at restart,
   the prior active checkpoint remains safe to reconcile again. Recovery failure
   has explicit user copy and safe diagnostics; raw links, text, credentials and
   response bodies must never be recorded.

## Compatibility and validation

No backend mutation, task replay, cancellation, database migration, account-wide
lock bypass, or removal of successful-result validation is allowed. Retain the
original ASR/recording/derived task behavior, notification handoff and draft
restoration. Focus regression on shared numeric parsing, persisted terminal
recovery, single-flight, bounded retries, lifecycle fencing and text/voice
admission. Do not claim a true-device fix until the new build is installed and
retested; never modify the copied or physical diagnostic database to simulate it.

## Verification results

- Eight focused tracker/controller/presentation cases pass, including legacy
  terminal recovery, exhausted-checkpoint restart without reads or SSE, joined
  explicit recovery, lifecycle fencing and text/voice admission protection.
- All 46 shared API contract tests pass, including fractional video duration and
  rejection of missing, negative, non-finite and incorrectly typed usage values.
- The broader tracker/controller run reports 169 passes and one existing clock
  fixture failure. An isolated copy of the unmodified HEAD source/test reproduces
  that same RangeError: the fixture supplies two timestamps for three clock reads.
  Neither the unrelated fixture nor message-ID time handling is changed here.
- Focused analysis has no errors or warnings; four pre-existing brace-style infos
  remain in unrelated app_providers branches. Changed Dart files are formatted.
- SCM passes for 1351 active files. Source reachability is 426/426. The combined
  architecture gate remains blocked by its existing findings; edited oversized
  controller/provider/page line counts increase with this feature. No thresholds,
  performance-risk allowances, or unrelated source modules were changed.
- Physical-device diagnostics established the incident, but this source change
  has not been installed onto the iPhone. A new build must verify link analysis
  followed by a second message and recovery across foreground/restart. Neither
  server state nor the physical application container was modified.
