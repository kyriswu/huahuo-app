# ADR-006: Mobile, desktop, and shared package boundary

- Status: Accepted
- Date: 2026-08-31

## Decision

`Flutter/src` and `Flutter/desktop` are application roots and never import each
other. Reusable domain values, API contracts, and editor primitives move to the
smallest existing package under `Flutter/packages`; platform UI, lifecycle,
plugins, storage locations, and navigation stay in their application.

Shared packages cannot import an application or feature presentation layer.
Promoting code requires at least two real consumers; speculative shared
abstractions are rejected.
