# Flutter Backend Integration Matrix

Audited on 2026-08-07 against APP HEAD
`0e4e58a7133a95ad22c2530fcf8665c49b803b5e` plus the uncommitted
`Flutter/` integration working tree, and Docs HEAD
`97e510c8b7e2a2e33cc4bbf809fa666e26983bd3` plus the uncommitted
`codex/membership-payments-v1` working tree (15 tracked changes and one new
API 28 file).

The fixed endpoint authority remains
`products/huahuo-ai/05-api/02-endpoint-catalog.md`. The accepted Docs working
tree expands the App audit inventory to 198 operations: 117 formal and 81
retained. Until those Docs changes are reviewed and committed, API 28 is an
integration candidate rather than a published production contract.

## Runtime Status

- Shared runtime: authenticated transport, strict/legacy envelopes, 202/204,
  cursor pagination, `ETag`/`If-Match`, endpoint-specific idempotency headers,
  binary responses, SSE, 401 recovery, 409/412 conflicts, and 429 retry
  metadata. Three Provider callbacks remain Manifest-only server contracts and
  cannot be resolved through the App runtime `EndpointCatalog`.
- Mobile connected: Auth, Home and onboarding; managed upload; recording card,
  recording and notifications/JPush; HNote list/create/read/update; Workspace
  search; active Subscription flows; API 27 membership/credits/Run usage;
  API 28 catalog/order/verification/transaction flows; catalog-gated AgentRun;
  and the visible API 24 Book/Work read, exact-part, completion and promotion
  flow.
- Desktop connected: Auth; asset overview/detail/Markdown/sync; account-scoped
  HNote snapshot/delta, create/read/update and exact-part pull; Workspace search
  and visible relation reads/deletes; active Subscription flows; API 27 reads;
  catalog-gated AgentRun; and the same visible API 24 Book/Work subset through
  injectable Remote/Unavailable Ports.
- Desktop has no purchase entry. Mobile never trusts a payment SDK result to
  grant membership; membership becomes active only after server verification
  and projection.
- The thought graph remains a real local interactive graph. Remote
  `content-navigation` is deliberately `contractOnly` for this test phase and
  no Feed AI fallback is permitted.
- Operations without a current product consumer remain typed contract records;
  merely having an EndpointDefinition or unused Port method does not make an
  operation wired.

## Docs Working-Tree Gaps

- API 27 still freezes `pilot_paid/active/expiresAt=null`, while API 28 adds
  `pro/max`, expiry and entitlement states. The client accepts the new paid
  projection fail-closed, but 39 Backend needs one authoritative DTO.
- API 28 does not yet freeze complete PaymentOrder, Provider launch, iOS verify,
  transaction-item or callback acknowledgement wire shapes.
- `cancelled` is described both as usable until period end and as excluded from
  the resolver. The client currently follows the narrower active/grace-period
  rule until Docs resolves the conflict.
- Published PRO/MAX chat, ASR and storage limits have no remaining-usage
  projection in API 27, so clients cannot truthfully display or contract-test
  those balances.
- API 07 Push Secret errors are not yet registered in the global error-code
  registry. Push Secret Ref, encryption, rotation and delivery remain 39
  Backend responsibilities.

## Prohibited

These five operations are audit-only. They are absent from `EndpointCatalog`,
and `ApiClient` rejects them before authentication or Transport:

- `GET /api/v1/work-ai/topic-generation/options`
- `GET /api/v1/work-ai/material-candidates`
- `POST /api/v1/work-ai/topic-generations`
- `GET /api/v1/feed-ai/messages/{messageId}/deposit-summary`
- `POST /api/v1/feed-ai/messages/{messageId}/retry-deposit`

Membership purchase must not lift this gate. Production code never silently
falls back to a Fake; Demo implementations require explicit test/Demo
configuration.

## Platform Boundaries

- 101 service: recording upload/ASR, voiceprint and realtime transcription.
- 39 service: Auth, Workspace/HNote, Chat/Agent, Subscription, Book/Work,
  membership projection, payment Providers/callbacks/reconciliation and Push.
- Mobile-only: recording hardware, microphone, StoreKit and Android payment
  bridge.
- Desktop-only: windowed workspace, multi-pane document workflow and local
  document outbox.
- Shared: public DTOs, codecs, endpoint metadata and platform-free contract
  clients only.

## Evidence

- `Flutter/reports/api-integration/API_INTEGRATION_INDEX.md`
- `Flutter/reports/api-integration/latest.md`
- `Flutter/reports/api-integration/latest.json`
- `Flutter/reports/api-integration/docs-working-tree-sync-2026-08-07-zh.md`
- `Flutter/reports/chat-integration/latest-zh.md`
- `Flutter/packages/huahuo_api/test/api_contract_manifest_test.dart`
- `Flutter/packages/huahuo_api/test/domain_clients_test.dart`
