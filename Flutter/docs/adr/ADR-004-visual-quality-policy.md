# ADR-004: Visual quality policy

- Status: Accepted
- Date: 2026-08-31

## Decision

`PerformancePolicy` resolves high, balanced, or constrained visual quality from
visibility, accessibility motion preference, memory pressure, power/thermal
signals, and frame health. Graph node budgets, blur, shadows, animation repeat,
prefetch, and media cache limits consume that decision instead of inventing
local device heuristics.

Continuous animation is opt-in and activity-gated. An idle graph renders no
frames after settling. Reduce Motion disables decorative repeat and shortens
command feedback without removing functional state transitions.

## Rollback

Visual adaptations are controlled by feature flags. Functional controls and
content remain available at every quality level.
