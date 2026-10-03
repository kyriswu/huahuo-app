# ADR-003: Feature state boundaries

- Status: Accepted
- Date: 2026-08-31

## Decision

Feature state is separated into commands, durable truth, read models, and
ephemeral presentation state. Hot values such as chat deltas, recording levels,
elapsed seconds, and animation frames stay in the smallest owning subtree.
Global providers expose low-frequency immutable projections or scalar
revisions. Large collections are normalized by ID and sorted views are memoized
by revision.

Presentation code depends on application/domain ports, not concrete data
implementations. Cross-feature use goes through an application contract and
must not import another feature's presentation layer.

## Enforcement

Architecture checks prevent dependency debt from growing. Existing exceptions
are extraction debt with non-increasing budgets, not examples for new code.
