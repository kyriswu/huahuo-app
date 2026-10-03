# Flutter performance governance

An RFC using `RFC_TEMPLATE.md` is required before adding or materially changing
a permanent provider, periodic timer, polling loop, continuous animation,
database writer, media worker, cache, or foreground/background task.
Production `TaskSpec(...)` registrations must also include a standalone
`// performance-rfc: <id>` source marker, where `<id>` resolves to
`docs/performance/rfcs/<id>.md`; the architecture gate rejects missing or stale
approvals.

PR checks cover formatting, analysis, tests, architecture rules, source
reachability, secret scanning, and dependency review. Nightly checks add fixed
profile scenarios, size tracking, navigation memory loops, database migration,
network recovery, and golden tests. Release acceptance requires iOS and Android
physical-device runs, 15-30 minute power/thermal evidence, weak-network and
background recovery, large-media/export scenarios, and a rollback exercise.

Evidence is stored under `Flutter/reports/performance/`; reports must contain
aggregate identifiers only and pass recursive redaction before export.

The executable budgets are enforced by `Flutter/src/tool/performance_gate.dart`.
Nightly and release summaries use
`Flutter/reports/performance/profile-summary-template.json`; missing physical
device, frame, idle-work, memory, or release scenario evidence fails closed.
