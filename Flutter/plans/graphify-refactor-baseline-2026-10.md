# Graphify refactor baseline

Install the project-pinned graphifyy 0.9.73 in a project-scoped uv environment,
generate a code-only graph before the next refactor, and verify exact-symbol
queries against source. Keep generated graphs, logs and provenance outside
tracked source. No model-backed extraction or server access is in scope.

The initial Python 3.9 environment cannot install this package (requires
Python >=3.10). Homebrew provides uv; uv manages the user-level Python 3.13
interpreter. Graphify dependencies belong to the project, in tool/graphify,
with pyproject.toml and uv.lock tracked and the local .venv ignored. No global
Graphify installation is required. Python interpreter management stays user-level.

- [x] Install and verify pinned CLI; read its actual extraction/query options.
- [x] Extract mobile, desktop, shared packages, tests and native code; exclude
  build outputs, generated caches, vendor, assets and historical material.
- [x] Record worktree source hashes and graph hash; verify coverage and query
  billing/API symbols, consumers, tests and native boundaries.
- [x] Provide one repeatable refresh entry point and document limitations.

Graphify's Dart heuristics cannot prove dependency completeness. Source search,
analyzer and tests remain mandatory. Start target-architecture batch 0 with
this graph; do not wait for perfect graph coverage or change runtime behavior
as part of this tooling batch. Rollback is limited to the new tooling/docs.


Environment: Homebrew manages uv; uv manages the user-level Python 3.13 and Graphify tool. System, Android NDK and Codex bundled Python runtimes were retained because they are host-managed runtimes, not project versions. The project `.graphify-venv` was removed.

## Results (2026-10-02)

- Homebrew `uv 0.12.21` manages user Python 3.13.15 and Graphify 0.9.73;
  Homebrew `python@3.13` and the failed project venv were removed. Shell
  configuration backups are under `~/.config/uv/migration-backups/`.
- The code-only baseline represents 1,062 source files across mobile, desktop,
  shared packages, tests and native code; all checked Dart source groups are
  represented. It contains 44,924 nodes and 66,896 edges.
- `graphify-out/provenance.json` records the dirty worktree, HEAD, source and
  graph hashes, interpreter and CLI versions. Graphify limitations remain:
  heuristic Dart extraction is not compiler or call-graph proof.
- `tool/graphify_refresh.py` is the repeatable local refresh entry point. It
  resolves the user-level `graphify` and records the actual uv tool environment.

## Project isolation correction

The user clarified that only Python version management is system-level.
Replace the global Graphify dependency with a dedicated uv project, lock its
transitive dependencies, and route refresh and queries through graphify.sh.
Verify with global Graphify absent, re-extract the graph and update provenance.
The previous user-level installation results above describe the intermediate
state, not the final development setup.


Final project isolation verified: `tool/graphify/pyproject.toml` and `uv.lock`
replace the old requirements-only pin. `sh tool/graphify.sh refresh` uses
`uv run --locked` and an ignored project-specific environment. Global
Graphify was uninstalled before refresh; refresh and exact billing-symbol
query succeed. Python remains uv-managed outside the repository. Final graph:
44,927 nodes, 66,898 edges, 1,064 represented files; provenance includes tool
lock hash and installed dependency versions.
