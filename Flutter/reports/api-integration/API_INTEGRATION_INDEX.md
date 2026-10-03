# Flutter API Integration Index

> Historical declaration index. This is not evidence of executed integration
> tests and is no longer regenerated. Current declarations live in source;
> validate them with `src/tool/api_contract_consistency_check.dart`.

## Representative-work unlock/generation integration

Current product restores 100-canonical-Note unlock: API21 complete snapshots,
API20 up to 100 frozen raw Note parts, API23 book.writing catalog admission,
API19 durable Run creation/recovery, API24 explicit chapter publication/readback.
This supersedes the gate-removal note below. No dedicated backend unlock endpoint
or offline server trigger is invented.

## 2026-09-05 representative-work implementation update

Mobile representative-work now reads the canonical Workspace Book and pinned
chapter revisions, creates chapters, and saves one chapter part with its part
ETag, base revision and retained references. API24 writes use the actual Backend
`X-Idempotency-Key` header; section receipts contain opaque SectionIDs rather than
URL section keys. Local generation, 100-note gating and cadence rewrites are retired.
This is source/contract verification, not a claim of live production acceptance.
The full journey and recovery behavior is implemented in
`../../src/lib/features/book_work/` and covered by the corresponding tests under
`../../src/test/features/book_work/` (relative to this report).

Protocol authority: Docs `97e510c8b7e2a2e33cc4bbf809fa666e26983bd3` 
`products/huahuo-ai/05-api/02-endpoint-catalog.md`. This index copies no protocol body.
Accepted working-tree revision: `codex/membership-payments-v1 @ 97e510c8 + uncommitted 15 tracked / 1 untracked (API 07/27/28 + membership design)`.

| Method / Path | Owner | Scope | Consumer | Status | Response |
| --- | --- | --- | --- | --- | --- |
| `GET /api/v1/agent/meta-workspaces` | API 19 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/agent/runs` | API 19 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/agent/runs/{agentRunId}` | API 19 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/agent/runs/{agentRunId}/events` | API 19 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/agent/runs/{agentRunId}/events/stream` | API 19 | `formal` | Contract only | `contractOnly` | `sse` |
| `POST /api/v1/agent/runs/{agentRunId}/cancel` | API 19 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/media/upload-token` | API 19 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/media/uploads/{uploadId}/complete` | API 19 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/chat/threads/{threadId}/messages` | API 19 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/agent-profiles` | API 23 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/agent-profiles/{agentProfileId}/skills` | API 23 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/agent-profiles/{agentProfileId}/models` | API 23 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/skill-installations` | API 23 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/skill-installations` | API 23 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}` | API 23 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}` | API 23 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/set-default` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/disable` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/restore` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/storage-usage` | API 21 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/content-snapshot` | API 21 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/content-changes` | API 21 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/folders` | API 20 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/folders` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/move` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/restore` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes` | API 20 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes` | API 20 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}` | API 20 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/restore` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/export` | API 20 | `formal` | Contract only | `contractOnly` | `binary` |
| `POST /api/v1/workspaces/{workspaceId}/note-imports` | API 20 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/positioning` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/positioning` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/positioning/revisions` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/profile-visual-assets` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/profile-visual-assets` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}/revisions` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/creations` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/creations` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/creations/{creationId}/restore` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}/revisions` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/content-navigation/{map}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/search` | API 22 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations` | API 22 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/note-relations/{relationId}` | API 22 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/note-relations/{relationId}` | API 22 | `formal` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/book` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/revisions` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/revisions/{bookRevisionId}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/book/import` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/imports/{bookImportId}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/book/sections` | API 24 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/restore` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/move` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}` | API 24 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}/revisions` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/book/export` | API 24 | `formal` | Contract only | `contractOnly` | `binary` |
| `GET /api/v1/workspaces/{workspaceId}/work` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/work` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/restore` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/complete` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}/revisions` | API 24 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/promotions` | API 24 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/subscription/publications` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/subscription/publications/{publicationId}` | API 25 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/subscription/publications/{publicationId}/sections` | API 25 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/subscription/articles` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/subscription/articles/{articleId}` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/subscription/articles/{articleId}/revisions` | API 25 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}` | API 25 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/subscription-library/publications` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/subscription-articles/{articleId}/save-as-note` | API 25 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/membership` | API 27 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/account/credits` | API 27 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/runs/{runId}/usage` | API 27 | `formal` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/billing/catalog` | API 28 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/billing/android/orders` | API 28 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/billing/orders/{orderId}` | API 28 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/billing/ios/purchases/verify` | API 28 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/billing/transactions` | API 28 | `formal` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/billing/wechat/notify` | API 28 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/billing/alipay/notify` | API 28 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/billing/apple/notifications/v2` | API 28 | `formal` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/agent/runs/{agentRunId}/confirm` | API 14 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/analytics/events` | API 11 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/app/config` | API 11 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/asr-tasks/{asrTaskId}` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/asr-tasks/{asrTaskId}/retry` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/assets/{assetType}/{assetId}` | API 07 | `retained` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `PATCH /api/v1/assets/{assetType}/{assetId}` | API 07 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/assets/markdown` | API 07 | `retained` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `GET /api/v1/assets/overview` | API 07 | `retained` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `GET /api/v1/assets/recordings/{recordingId}` | API 07 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/assets/sync` | API 07 | `retained` | Desktop | `wiredDesktop` | `jsonEnvelope` |
| `POST /api/v1/auth/login` | API 03 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/auth/refresh` | API 03 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/auth/sms-code` | API 03 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/chat/threads` | API 06 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/chat/threads` | API 06 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `GET /api/v1/chat/threads/{threadId}` | API 06 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/chat/threads/{threadId}/voice-messages` | API 06 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/chat/threads/{threadId}/workspace-switch` | API 14 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/feed-ai/messages/{messageId}/deposit-summary` | API 06 | `retained` | None | `prohibited` | `jsonEnvelope` |
| `POST /api/v1/feed-ai/messages/{messageId}/retry-deposit` | API 06 | `retained` | None | `prohibited` | `jsonEnvelope` |
| `GET /api/v1/home` | API 04 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/home/hotspot-suggestions/{suggestionId}/viewed` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/me/status` | API 03 | `retained` | Mobile+Desktop | `wiredBoth` | `jsonEnvelope` |
| `POST /api/v1/notification-devices` | API 07 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `DELETE /api/v1/notification-devices/{deviceId}` | API 07 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/notifications` | API 07 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/notifications/{notificationId}/read` | API 07 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/onboarding/creative-positioning` | API 04 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/profile` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/profile` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/profile/{creativePositioningId}` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/profile/{creativePositioningId}/deactivate` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/profile/{creativePositioningId}/set-default` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/recording-card/devices/bind` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/recording-card/files` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/recording-card/files/{cardFileId}/link-upload` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/recording-card/files/sync` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/recordings` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/recordings` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/recordings/{recordingId}` | API 05 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `POST /api/v1/recordings/{recordingId}/retry` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/recordings/{recordingId}/speaker-label-draft` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/recordings/{recordingId}/speaker-label-panel` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/recordings/{recordingId}/speaker-labels` | API 05 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/red-dots/clear` | API 07 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/tasks/{taskId}` | API 06 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/tasks/{taskId}/regenerate` | API 06 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/tasks/{taskId}/retry` | API 06 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/tasks/running` | API 04 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/work-ai/material-candidates` | API 06 | `retained` | None | `prohibited` | `jsonEnvelope` |
| `GET /api/v1/work-ai/topic-generation/options` | API 06 | `retained` | None | `prohibited` | `jsonEnvelope` |
| `POST /api/v1/work-ai/topic-generations` | API 06 | `retained` | None | `prohibited` | `jsonEnvelope` |
| `POST /api/v1/workspace/retry-create` | API 04 | `retained` | Mobile | `wiredMobile` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/materials` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}/retry` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}/revisions` | API 15 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/note-folders` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/note-folders` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/note-folders/{folderId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/note-folders/{folderId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/note-ingestions` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `DELETE /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}/promote` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/generate` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PUT /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}/revisions` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/apply` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/reject` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/batch-move` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/chat-excerpts` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/notes/manual` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/note-types` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `POST /api/v1/workspaces/{workspaceId}/note-types` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `PATCH /api/v1/workspaces/{workspaceId}/note-types/{noteTypeId}` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |
| `GET /api/v1/workspaces/{workspaceId}/profile` | API 20 | `retained` | Contract only | `contractOnly` | `jsonEnvelope` |

## Retired Client Paths

| Retired path | Replacement |
| --- | --- |
| `/api/v1/content-lines*` | Creative Positioning / Positioning |
| `/api/v1/graphs/{graphId}` | Local interactive graph; remote content-navigation is contract-only |
| `/api/v1/link-imports*` | Managed upload + note-imports |
| `/api/v1/memory-notes*` | Workspace Notes / Parts |
| `/api/v1/video-analyses*` | Published AgentRun route (currently unavailable) |
| `/api/v1/tasks/{taskId}/events` | AgentRun Events |
| `/api/v1/me/profile` | Local-only until an active account-write contract exists |
| `/api/v1/me/voiceprint*` | Independent HTTPS Voiceprint Gateway |
