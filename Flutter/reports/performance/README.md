# Flutter Performance Reports

This directory stores sanitized Profile-mode performance baselines and release
comparisons. A report is evidence, not a claim inferred from Debug builds or
static code inspection.

## Rules

- Use a physical iOS or Android device for CPU, memory, thermal, and battery
  conclusions. Simulators and emulators are functional checks only.
- Run the same scenario and build mode before comparing commits.
- Export aggregate metrics only. Never include tokens, headers, query strings,
  user text, audio paths, private filenames, signed URLs, or server credentials.
- Mark each conclusion `Measured`, `Trace-backed`, `Static high risk`, or
  `Hypothesis`.
- Store results under `<commit>/<platform>/` after runtime wiring is complete.

## Required scenarios

1. Cold start and authenticated restore.
2. Home, 2D graph, and 3D graph idle periods.
3. Feed scrolling and a long streaming AI response.
4. Canvas continuous editing and autosave.
5. Concurrent upload, ASR, and Chat work.
6. Ten foreground/background cycles and twenty main-tab navigation loops.
7. Large images, document export, offline/weak-network recovery, and constrained
   thermal or low-power operation.

Start from [baseline-template.md](baseline-template.md). Keep an unfilled field
as `Not measured`; do not replace missing evidence with an estimate.

For automated nightly/release budgets, fill `profile-summary-template.json`
with sanitized measurements and run:

```sh
dart run tool/performance_gate.dart --mode nightly --input <summary.json>
```

The checked-in template intentionally fails the gate; it is a schema example,
not fabricated evidence.
