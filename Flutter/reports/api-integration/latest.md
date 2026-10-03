# API Integration Test Report

> Historical output from the retired metadata reporter. Despite the title and
> PASS labels, this file does not record executed API requests or test cases.
> Current validation: `src/tool/api_contract_consistency_check.dart`.

- APP baseline: `0e4e58a7133a95ad22c2530fcf8665c49b803b5e`
- APP working tree: `DIRTY_UNCOMMITTED (186 paths)`
- Docs baseline: `97e510c8b7e2a2e33cc4bbf809fa666e26983bd3`
- Docs working tree: `codex/membership-payments-v1 @ 97e510c8 + uncommitted 15 tracked / 1 untracked (API 07/27/28 + membership design)`
- Operations: `198` (117 formal, 81 retained)
- Result: `PASS=198`, `FAIL=0`
- Live smoke: `SKIPPED_NO_ENV`

| Operation | Owner | Consumer | Disposition | Test | Result | Live | Blocker |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `GET /api/v1/agent/meta-workspaces` | API 19 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/agent/runs` | API 19 | Mobile+Desktop | `wiredBoth` | domain_clients_test: AgentRun request/create response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent/runs/{agentRunId}` | API 19 | Mobile+Desktop | `wiredBoth` | domain_clients_test: AgentRun lifecycle/result/usage/tool output | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent/runs/{agentRunId}/events` | API 19 | Contract only | `contractOnly` | domain_clients_test: AgentRun sequence/gap recovery | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent/runs/{agentRunId}/events/stream` | API 19 | Contract only | `contractOnly` | domain_clients_test: AgentRun SSE event/gap/capacity recovery | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/agent/runs/{agentRunId}/cancel` | API 19 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/media/upload-token` | API 19 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/media/uploads/{uploadId}/complete` | API 19 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/chat/threads/{threadId}/messages` | API 19 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent-profiles` | API 23 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent-profiles/{agentProfileId}/skills` | API 23 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/agent-profiles/{agentProfileId}/models` | API 23 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/skill-installations` | API 23 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/skill-installations` | API 23 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}` | API 23 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}` | API 23 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/set-default` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/disable` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/restore` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/storage-usage` | API 21 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/content-snapshot` | API 21 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/content-changes` | API 21 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/folders` | API 20 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/folders` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/folders/{folderId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/move` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/restore` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes` | API 20 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes` | API 20 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/notes/{noteId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}` | API 20 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/restore` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/export` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/note-imports` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/positioning` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/positioning` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/positioning/revisions` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/profile-visual-assets` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/profile-visual-assets` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/fixed-assets/{assetKind}/revisions` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/creations` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/creations` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/creations/{creationId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/creations/{creationId}/restore` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}/revisions` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/content-navigation/{map}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/search` | API 22 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations` | API 22 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/note-relations/{relationId}` | API 22 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/note-relations/{relationId}` | API 22 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/book` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/revisions` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/revisions/{bookRevisionId}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/book/import` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/imports/{bookImportId}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/book/sections` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/restore` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/move` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}/revisions` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/book/export` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/work` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/work` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/work/{workId}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/restore` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/complete` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}/revisions` | API 24 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/work/{workId}/promotions` | API 24 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/publications` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/publications/{publicationId}` | API 25 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/publications/{publicationId}/sections` | API 25 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/articles` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/articles/{articleId}` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/articles/{articleId}/revisions` | API 25 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}` | API 25 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/subscription-library/publications` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/subscription-articles/{articleId}/save-as-note` | API 25 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/membership` | API 27 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/account/credits` | API 27 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/runs/{runId}/usage` | API 27 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/billing/catalog` | API 28 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/billing/android/orders` | API 28 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/billing/orders/{orderId}` | API 28 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/billing/ios/purchases/verify` | API 28 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/billing/transactions` | API 28 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/billing/wechat/notify` | API 28 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/billing/alipay/notify` | API 28 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/billing/apple/notifications/v2` | API 28 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/agent/runs/{agentRunId}/confirm` | API 14 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/analytics/events` | API 11 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/app/config` | API 11 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/asr-tasks/{asrTaskId}` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/asr-tasks/{asrTaskId}/retry` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/assets/{assetType}/{assetId}` | API 07 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/assets/{assetType}/{assetId}` | API 07 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/assets/markdown` | API 07 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/assets/overview` | API 07 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/assets/recordings/{recordingId}` | API 07 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/assets/sync` | API 07 | Desktop | `wiredDesktop` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/auth/login` | API 03 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/auth/refresh` | API 03 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/auth/sms-code` | API 03 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/chat/threads` | API 06 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/chat/threads` | API 06 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/chat/threads/{threadId}` | API 06 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/chat/threads/{threadId}/voice-messages` | API 06 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/chat/threads/{threadId}/workspace-switch` | API 14 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/feed-ai/messages/{messageId}/deposit-summary` | API 06 | None | `prohibited` | api_contract_manifest_test: prohibited/no_transport | **PASS** | `SKIPPED_NO_ENV` | PROHIBITED_WORK_OR_FEED_AI |
| `POST /api/v1/feed-ai/messages/{messageId}/retry-deposit` | API 06 | None | `prohibited` | api_contract_manifest_test: prohibited/no_transport | **PASS** | `SKIPPED_NO_ENV` | PROHIBITED_WORK_OR_FEED_AI |
| `GET /api/v1/home` | API 04 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/home/hotspot-suggestions/{suggestionId}/viewed` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/me/status` | API 03 | Mobile+Desktop | `wiredBoth` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/notification-devices` | API 07 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/notification-devices/{deviceId}` | API 07 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/notifications` | API 07 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/notifications/{notificationId}/read` | API 07 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/onboarding/creative-positioning` | API 04 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/profile` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/profile` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/profile/{creativePositioningId}` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/profile/{creativePositioningId}/deactivate` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/profile/{creativePositioningId}/set-default` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recording-card/devices/bind` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/recording-card/files` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recording-card/files/{cardFileId}/link-upload` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recording-card/files/sync` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/recordings` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recordings` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/recordings/{recordingId}` | API 05 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recordings/{recordingId}/retry` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recordings/{recordingId}/speaker-label-draft` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/recordings/{recordingId}/speaker-label-panel` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/recordings/{recordingId}/speaker-labels` | API 05 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/red-dots/clear` | API 07 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/tasks/{taskId}` | API 06 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/tasks/{taskId}/regenerate` | API 06 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/tasks/{taskId}/retry` | API 06 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/tasks/running` | API 04 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/work-ai/material-candidates` | API 06 | None | `prohibited` | api_contract_manifest_test: prohibited/no_transport | **PASS** | `SKIPPED_NO_ENV` | PROHIBITED_WORK_OR_FEED_AI |
| `GET /api/v1/work-ai/topic-generation/options` | API 06 | None | `prohibited` | api_contract_manifest_test: prohibited/no_transport | **PASS** | `SKIPPED_NO_ENV` | PROHIBITED_WORK_OR_FEED_AI |
| `POST /api/v1/work-ai/topic-generations` | API 06 | None | `prohibited` | api_contract_manifest_test: prohibited/no_transport | **PASS** | `SKIPPED_NO_ENV` | PROHIBITED_WORK_OR_FEED_AI |
| `POST /api/v1/workspace/retry-create` | API 04 | Mobile | `wiredMobile` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/materials` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}/retry` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}/revisions` | API 15 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/note-folders` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/note-folders` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/note-folders/{folderId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/note-folders/{folderId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/note-ingestions` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `DELETE /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}/promote` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/generate` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `PUT /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: runtime request/response/damaged response | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}/revisions` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/apply` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/reject` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/batch-move` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/chat-excerpts` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/notes/manual` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/note-types` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `POST /api/v1/workspaces/{workspaceId}/note-types` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `PATCH /api/v1/workspaces/{workspaceId}/note-types/{noteTypeId}` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
| `GET /api/v1/workspaces/{workspaceId}/profile` | API 20 | Contract only | `contractOnly` | api_contract_manifest_test: unique manifest record | **PASS** | `SKIPPED_NO_ENV` |  |
