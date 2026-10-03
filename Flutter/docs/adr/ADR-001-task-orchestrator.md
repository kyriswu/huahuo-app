# ADR-001: TaskOrchestrator

- Status: Accepted
- Date: 2026-08-31

## Decision

Mobile background and recovery work is submitted through one keyed
`TaskOrchestrator`. A task declares its owner, priority, resource classes,
foreground policy, deadline, and replacement policy. The orchestrator provides
single-flight execution, cooperative cancellation, bounded resource permits,
and aggregate metrics that never contain user payloads or identifiers.

UI code may trigger a command, but must not own a permanent retry loop. A task
that loses all consumers is cancelled unless it is explicitly durable. Resume
work uses the current foreground generation and rejects stale generations.

## Consequences

Existing feature controllers may migrate incrementally. Any new timer, poller,
upload recovery loop, or foreground-resume task needs a stable task key and a
performance RFC. Platform callbacks remain adapters; they do not become a
second scheduler.
