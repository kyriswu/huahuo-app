# Graphify integration evaluation

Status: pilot adopted for local code navigation

Upstream: [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify)

Pinned CLI: `graphifyy==0.9.73`. Graphify dependencies are project-scoped
under `tool/graphify/pyproject.toml` and `uv.lock`. System-level uv manages the
Python interpreter; the ignored `tool/graphify/.venv` isolates this project's
tool dependencies. No global Graphify installation is required.

## Reproduction

From `Flutter/` on macOS/Linux:

```sh
sh tool/graphify.sh refresh
```

The wrapper enforces the committed lock, code-only extraction and maintained
exclusions. Output in `graphify-out/` is local and regenerable. `provenance.json`
records worktree and graph hashes, tool lock hash, file counts and environment.
See [the runbook](../runbooks/graphify.md) for queries and dependency upgrades.

## Measured result on this worktree

- Date: 2026-10-01. HEAD: `599315cce7e803be63d24d01d1bd973a844862cc`,
  with uncommitted source changes. This is a worktree pilot, not a clean release.
- All 440 mobile `src/lib/**/*.dart` files are represented in the final graph.
  File coverage does not imply complete symbol or dependency coverage.
- Final graph: 45,000 nodes, 66,912 edges, 40.87 MiB. The initial filtered
  build took 6.39 seconds; an unchanged refresh took 4.83 seconds; correcting
  resource exclusions took 4.92 seconds. These are individual observations on
  this machine, without clustering or semantic extraction, not performance SLAs.
- The first broad scan included SQLite and reported a syntax warning there.
  The final scope excludes third-party code. An intermediate assets exclusion
  also removed the assets feature; explicit resource roots fixed that mistake.
- The official Dart extractor uses regex/heuristics, unlike the tree-sitter
  parsing used for many other languages. It handles classes, imports, several
  Riverpod/Bloc patterns and routes, but is not a Dart semantic analyzer.
- Sample: `recordingCardControllerProvider` has 52 textual
  `ref.read/watch/listen` occurrences across 11 mobile files. Graphify references
  point back to only 8 of those files. Missing files: `app_providers.dart`,
  `home_widget_snapshot_sync.dart`, `meeting_capture_controller.dart`.
  Representative omissions are Provider initialization closures at
  `app_providers.dart:2302` and `meeting_capture_controller.dart:1557`.
  This is one manually inspected sample, not a whole-project recall score.
- A relative import from `app_providers.dart` to `recording_card_controller.dart`
  points to a URI-label node with `source_file: null` in the raw graph, rather
  than the canonical file node. Do not assume all cross-file import chains are
  resolved. Dart code has only 18 `calls` edges in this scan; this is not a
  complete method call graph.
- The code-only extraction reports zero input/output model tokens. Semantic
  indexing, model cost, community clustering, and multi-agent throughput were
  not measured. CLI `explain` and `affected` worked on the generated raw graph.

- A natural-language query (`recording card synchronization`) completed in 1.47
  seconds but included generic `card`/`recording` symbols and an unrelated push
  synchronization method. Although `--budget 1500` was supplied, Graphify
  reported approximately 4,346 output tokens to preserve the returned edges.
  Prefer exact symbols first; do not assume a hard token cap or guaranteed token
  savings. The query result is saved in `pilot-query.txt`.

Local evidence: `graphify-out/pilot-provenance.json`, `pilot-build.log`,
`pilot-refresh.log`, `pilot-corrected-build.log`, and `graph.json`. A generated
`GRAPH_TREE.html` is available for inspection; browser interaction was not
validated in this evaluation.

## Value for future iteration

Graphify has high value for first-pass discovery: finding likely source locations, inspecting declared imports, locating likely callers, and narrowing the files an engineer or agent
should inspect. Its incremental update is cheap enough for a branch-local graph.
It is especially useful when a feature crosses Mobile, Desktop, and shared
packages, because the same query can expose application and package edges.

It has medium value for review preparation: `affected` and `path` can suggest
reviewers and adjacent tests, but the result must be checked against source,
Dart analysis, and the relevant architecture/invariant docs. Dynamic dependency injection, callbacks,
provider factories, native channels, generated code, and string-based routes
can be missed or generalized.

It has low value as a correctness mechanism. Graphify does not compile Dart,
prove type resolution, verify state-machine invariants, validate API contracts,
or prevent two writers from changing the same hot file. `EXTRACTED` means the
extractor saw a pattern; it does not mean the Dart compiler accepts the edge.

## Collaboration policy

- Each human or agent uses a separate branch/worktree and a local graph.
- Before editing, query the graph for a first-pass impact list, then verify that
  list with source search and the Dart analyzer.
- Use architecture and invariant docs for durable intent and constraints.
  Graphify indexes code structure; it does not decide whether a change is valid.
- A changed shared contract requires one owner for the contract and explicit
  downstream updates. Do not infer ownership from graph centrality alone.
- After source changes, run the local incremental Graphify update when the graph
  is being used for review; run the normal quality gate for merge readiness.
- A stale, missing, or incomplete graph never blocks source inspection or a
  quality check. A missing graph edge is not evidence of independence.

## Recommendation

Keep Graphify as an opt-in, project-scoped pilot now. It is worth adopting for
navigation and multi-agent context, with potential savings in dependency discovery. No human-team or multi-agent
A/B productivity measurement has been performed; no percentage gain is claimed. Do not make graph generation a required
merge check until the Dart extractor is validated against a representative set
of Riverpod factories, async callbacks, platform channels, and route bindings.
The required merge controls remain architecture checks, analyzer/tests, actual
PR-base comparison, and human review.

## Team and multi-agent adoption decision

| Use | Assessment | Boundary |
| --- | --- | --- |
| Newcomer / fresh agent orientation | High potential | Confirm returned source locations |
| Repeated codebase questions | Medium to high potential | Reuse a current scoped graph; evaluate query relevance |
| Refactor impact discovery | Medium | Supplement missed providers/import resolution with source search |
| Work decomposition | Medium | Graph suggests shared areas; a maintainer assigns ownership |
| Concurrent writes / merge conflicts | Low direct benefit | Independent worktrees and explicit hot-file ownership remain necessary |
| Behavior correctness | Low direct benefit | Invariant docs, analyzer/tests and review provide evidence |

Start with recording-card changes and a shared-package change. Compare the
same representative tasks with and without graph lookup: time to locate the
correct entry, time to enumerate affected consumers, missed consumers, wrong
paths, agent rework, and total model tokens. Do not use node count or a naive
whole-repository token comparison as a productivity result. The highest expected
benefit is orientation for unfamiliar modules; narrow edits in familiar files
may see little improvement.

Code-only graphs complement source, tests and durable architecture documents.
Graph output is regenerated locally and is never copied into the repository as a
second source tree or manually maintained index.

## Local tooling and merge checks

The official Codex skill was installed project-locally. Automatic hook guidance
is disabled (`.codex/hooks.json` has no hooks) during this pilot; `AGENTS.md`
keeps graph use optional and documents local interpreter and scope. A future
skill refresh must preserve these local constraints. Installation does not
prove every agent host discovers the skill; use explicit CLI commands as the
verified entry point.

The quality gate runs formatting, dependency policy, analysis, tests, contract
checks, architecture checks and secret scanning. Graphify remains a local review
aid; remote merge enforcement is still unavailable: see
`REPOSITORY_CONTROLS.md`.

## Local commands

```sh
sh tool/graphify.sh explain RecordingCardOperationMachine --graph graphify-out/graph.json
sh tool/graphify.sh affected recordingCardControllerProvider --graph graphify-out/graph.json --depth 1
sh tool/graphify.sh query "recording card synchronization" --graph graphify-out/graph.json --budget 1500
```

The measurements above describe the original pilot. Current local extraction
and installed dependency evidence are in graphify-out; project-level lockfile
is the reproducible dependency definition, not historical pilot output.
