# API foundation refactor — 2026-10

## Goal

Make the application API path explicit and enforceable:

```text
Page → Controller → Repository → API Client → transport/contract foundation
```

The first migration slice keeps request, response, authentication, retry,
timeout, cancellation and idempotency behavior unchanged while making the
shared API package easier to evolve by responsibility and domain.

## Non-goals

- Do not change backend request fields, endpoint paths, auth audiences or
  response semantics.
- Do not replace `HttpClient` with Dio or introduce generated clients without a
  verified versioned backend contract.
- Do not remove compatibility exports before all consumers are migrated.
- Do not move feature behavior, local persistence or native device protocols in
  this slice.

## Current state

- `packages/huahuo_api/lib/src/api/api_client.dart` already provides the shared
  transport and request mechanism, including auth refresh, tracing, timeout,
  cancellation, constrained retry and API result mapping.
- `client_runtime.dart` provides the platform-neutral client factory.
- `endpoint_catalog.dart` is the endpoint policy/catalog boundary.
- `domain_clients.dart` contains several unrelated protocol clients and shared
  parsing helpers in one large file.
- `contract_models.dart` contains auth, workspace, recording-card, billing,
  chat, subscription and document/workspace models in one large file.
- `huahuo_api.dart` currently exports both foundation and all domain details
  through broad barrels.
- The billing feature already has a useful controller-to-port seam; its remote
  port is the first candidate for a repository/API-client migration.

## Target boundaries

1. **Foundation**: transport, request options, result/error mapping, auth
   hooks, endpoint policy and idempotency.
2. **Domain API clients**: one public client file per protocol domain. A domain
   client owns endpoint IDs, request construction and wire DTO parsing only.
3. **Repositories**: application-facing ports and composition of remote/local
   data. Controllers depend on these ports, never on `ApiClient`.
4. **Controllers**: state and workflow transitions; no endpoint IDs or wire
   maps.
5. **Pages**: presentation and user intent dispatch only.

## Graph and evidence

- Project Graphify baseline: 44,927 nodes, 66,898 edges, 1,064 source files.
- The fully qualified `ApiClient` node is
  `packages_huahuo_api_lib_src_api_api_client_apiclient`; short-name queries are
  ambiguous because many consumers contain fields named `ApiClient`.
- Source search and Graphify must be repeated after each migration slice.

## Implementation steps

1. Add this plan and record the API architecture/protocol constraints.
2. Query the fully qualified foundation symbols and inspect direct `HttpClient`
   construction and current feature seams.
3. Split `domain_clients.dart` into domain files without changing public class
   names or method behavior; keep a temporary compatibility export.
4. Split `contract_models.dart` by protocol domain, keeping compatibility
   exports while consumers migrate.
5. Add one repository-backed feature slice (billing/account usage) so the
   Page → Controller → Repository → API Client path is real, not only a file
   reorganization.
6. Update consumers and remove compatibility paths only after analyzer and
   focused tests prove no remaining imports.
7. Run formatting, analyzer, package tests, affected feature tests, API
   contract consistency checks and a post-change Graphify impact review.

## Risks and rollback

- Large model files may contain cross-domain helper dependencies. Move complete
  declaration groups and preserve import order before deleting old declarations.
- Barrel changes can create accidental public API breaks. Keep compatibility
  exports until source search proves migration completeness.
- Roll back a slice by restoring the moved file/export and its focused tests;
  do not reset unrelated worktree changes.

## Acceptance

- No Page or Controller in the migrated slice imports or constructs `ApiClient`.
- Repository ports expose domain/application values rather than endpoint IDs or
  raw request maps.
- Existing API package tests and affected feature tests pass.
- Graphify and source search show the intended dependency direction and no new
  direct `HttpClient` construction in feature code.

## Progress

- Completed the first vertical slice for account usage. The feature now uses
  `Page → AccountUsageController → AccountUsageRepository →
  AccountUsageClient/WorkspaceLifecycleClient → ApiClient`.
- Split shared account usage and workspace protocol clients from
  `domain_clients.dart`, and split the account usage wire models from
  `contract_models.dart`, while keeping the broad `huahuo_api.dart` barrel
  compatible.
- Extracted shared JSON readers and generic API contract object parsing into
  dedicated foundation files. Runtime behavior and endpoint metadata remain
  unchanged.
- Added dependency boundary tests for the migrated Controller and domain layer.
- Validation: shared API package tests passed (179 tests); the account usage
  Controller and architecture boundary tests passed (20 tests); offline API
  contract consistency passed (215 declarations, 0 issues); post-change
  Graphify refresh produced 45,176 nodes and 67,002 edges.
- Known pre-existing failures remain outside this slice: seven membership-page
  UI assertions fail identically against the pre-migration baseline, and the
  desktop topics cache has an existing `DailyTopicSourceRef.hotspotId`
  analyzer error.
