# Flutter workspace guidance

The repository root `AGENTS.md` is authoritative. Flutter implementation truth
is in `src`, `desktop`, shared packages, tests and contracts. Do not create
source-file Markdown mirrors, source indexes or generated source trees.

For complex Flutter work, use the workflow in `docs/DEVELOPMENT_WORKFLOW.md`:
query the project-pinned Graphify graph, read relevant architecture/invariant
docs, write a Plan/ExecPlan, implement, validate and review impact before PR.
Keep Graphify output local and regenerable; it never replaces source, tests or
long-lived documents. Do not change business behavior during tooling work.
