# Figma to Flutter backend binding matrix

## 2026-08-25 backend-preservation audit

The Mobile V5 presentation checkpoint is `8c300150`. The audit compares the
current Flutter owners with reference revision
`4093f23a02a736e3a092e6145b079bbbc773d87c` and the current backend source at
`/Users/run/huahuo-ai-backend/huahuoai-all`. A route or Controller existing is
not sufficient evidence: each row records the production Port/Client and the
backend contract it reaches.

The executable gate now scans both `Flutter/src/lib` and
`Flutter/packages/huahuo_api/lib`. It proves parity with the reference
revision's 194 catalog definitions and 161 literal production adapter calls.
Two retained definitions that had never had an adapter in either revision are
now classified honestly as `contractReady`: `markHotspotSuggestionViewed` and
the superseded direct `bindRecordingCardDevice` mutation. The audited totals
are therefore 67 `connected`, 115 `contractReady`, and 12 `deferred`; no
definition or adapter call from the reference revision is missing.

| Capability | Flutter owner and production boundary | Backend contract | Audit result |
|---|---|---|---|
| Daily recommendations | `DailyTopicController` -> `RemoteDailyTopicPort` -> `DailyTopicRecommendationClient` | list/get/read under Workspace topic recommendations | Connected; detail reads and marks read. The typed `/use` operation remains intentionally unbound to visible V5 actions because it reuses one deterministic `work_ai` thread, while V5 chooses a concrete Agent and starts a fresh grounded conversation. Reference `4093f23a` also did not call `/use`. |
| General Chat | `V3ChatPage` -> route-scoped `ChatController` -> `ChatRepository` -> `RemoteProjectChatRepository` | Chat thread create/list/read, message submit, assistant runtime polling | Connected. The deployed list currently caps pages at 50 rows but omits `nextCursor`; Flutter follows a returned cursor when available and otherwise resumes from the oldest `updatedAt`, with bounded metadata hydration for assistant-scoped history. |
| Personal IP | public Profile `renshe_content`, feature `workbench.persona` | Work AI renshe content plan and Chat/Run projection | Connected; V5 entry plus explicit first-send Profile and `persona` Context are covered. |
| Lead marketing | public Profile `huoke_content`, feature `workbench.lead_content` | Work AI huoke content plan and Chat/Run projection | Connected; V5 entry plus explicit first-send Profile and `lead` Context are covered. |
| Visual design | public Profile `visual_chat`, feature `visual.chat` | visual Meta Workspace, Chat/Run and image tools | Connected; catalog gating plus explicit Profile and `visualDesign` Context are covered. |
| Video analysis | public Profile and feature `video_analysis` | video-analysis Agent Run and media tool contract | Connected; catalog gating, attachments, explicit Profile and `videoAnalysis` Context are covered. |
| Masterpiece chat | `V3MasterpiecePage` -> `V3ChatPage` -> public Profile `book_writing` | Chat thread/message/Run with bounded canonical text input | Connected; the current representative-work Markdown is validated as a local draft snapshot and emitted as a separate labelled text part beside the user's prompt. Local paths, token-bearing URLs, oversized drafts and other unsafe snapshots are rejected before transport. |
| Transcription follow-up | `V3TranscriptionDonePage` -> stable `transcription-preview` HNote -> `V3ChatPage` | HNote revision sync plus Chat thread/message/Run | Connected; “继续追问” now carries the exact generated Note route context instead of opening an ungrounded general chat. The same Chat page then freezes the server Note ID and raw-part revision before sending. |
| Deep positioning | Profile `positioning_lv2`, `DeepPositioningController`, `WorkspaceProfileDeepPositioningRemote` | Workspace profile snapshot/progress plus `deep_positioning` Chat/Run | Connected; history, send, refresh, and report persistence remain required. |
| Basic positioning | `ContentLineOnboardingController`, `InitialPositioningTaskCoordinator`, `InitialPositioningAgent` | initial-positioning attempts/current/retry, Agent Run, Workspace positioning progress | Connected; accepted-Run recovery and progress retry remain required. |
| Feed aggregation | `FeedAggregationController` -> `RemoteTopicCollisionRunPort` -> `TopicCollisionClient` | topic-collision submit/get | Connected; production accepts the server-frozen four-source result and polls terminal state. |
| Recording-card unbind | `RecordingCardController` plus `RecordingCardCloudBindingController` | FW920 `0x02` ownership check, `0x03` all-zero unbind identity plus preserve/delete flag, then `POST /api/v1/recording-card/devices/{deviceId}/unbind` | Corrected on 2026-08-26 from the rejected token-bearing payload. Both file choices use the same firmware unbind path; the flag alone controls card-file cleanup. Native accepts the documented `0x03/0x00` ACK or the protocol-required active disconnect after a proven command dispatch, matching observed firmware `1.0.6`; native success still precedes cloud unbind, and offline cloud-only cleanup remains supported. |
| Link import | Home plus -> `V3LinkImportPage` -> `MaterialIngestionCoordinator` | URL Note Ingestion create/poll/promote | Connected; cancellation, durable retry/recovery and exact promoted Note navigation stay owned by the existing coordinator. |
| Document import | Home plus -> `V3DocumentImportPage(document)` -> `V3DocumentImportController` | upload-token/object upload/complete, Note Ingestion or File Agent, promote | Connected; supported-file rejection and resumable durable task state remain in the existing controller. |
| Recording audio import | Home plus -> `V3DocumentImportPage(media)` -> `V3MaterialUploadController` -> `RecordingUploadController` | upload-token/object upload/complete, `POST /api/v1/recordings`, ASR detail/retry | Connected; exactly one MP3/M4A/WAV is imported into private storage, then the server-created ASR task is shown by transcription detail. Video remains owned by the video-analysis Agent. |
| Daily recommendation note chat | `V3WorkbenchRecommendationPage` -> idempotent HNote deposit/sync -> shared `showV3NoteChatSheet` / Agent picker | HNote sync plus Chat thread/message/Run APIs | Connected; the brand Chat entry uses the same compact sheet and exact Note context as M02. The separate assisted action uses the existing grounded Agent picker; neither action invokes Daily Topic `/use`. |

This matrix protects backend behavior while presentation is replaced. It lists
the existing owner that must remain in the widget tree. Exact endpoints remain
owned by repositories/API clients and are not duplicated in widgets.

Final preservation evidence on 2026-08-25: all 65 V5 Chat page tests, all 166
recording-card tests, the 109 Daily Topic/Aggregation/Deep Positioning/
Onboarding tests, and the complete 2,109-test Flutter suite pass after the
restoration. Widget tests and Goldens cover presentation and command ordering;
real BLE discovery, card-file deletion, transfer, and firmware unbind still
require physical-card acceptance.

| Family | Page/surface | Controller or state owner | Port/repository boundary | Preservation requirement |
|---|---|---|---|---|
| `APP_SHELL` / `HOME_FEED` | `V3AppShell`, `V3FeedPage` | `UiV3Controller`, feed/graph controllers | graph, hotspot, aggregation repositories | Preserve shell mode, account/workspace state, cache and interactive graph |
| `NOTE_DETAIL` | `V3FeedItemDetailPage`, `V3NotePage` | `FeedItemDetailController`, knowledge/note controllers | outline, sprout, note metrics and sync repositories | Preserve HNote IDs, raw Part revision, errors and retry |
| `CHAT_ENTRY` / `CHAT_THREAD` | `V3ChatPage` and extracted pure surface | `ChatController`, `ChatRunTracker`, `VoiceMessageController` | `ChatRepository`, `RemoteProjectChatRepository`, attachment uploader, thread alias repository | Preserve route-scoped Provider overrides, purpose/profile, thread restoration, public IDs and real send/history/voice flows |
| `CREATION_*` | workbench/canvas/history pages | canvas AI, proposal, generation controllers | canvas draft/history/AI transform repositories | Preserve draft recovery, history ID and document revisions |
| `ASSET_*` | assets pages | `AssetsController`, `KnowledgeLibraryController`, photo album controller | workspace content sync, asset/media repositories | Preserve workspace scope, server resource IDs and deletion semantics |
| `KNOWLEDGE_*` | knowledge pages | `KnowledgeLibraryController` and subscription owner | subscription, metadata, workspace sync repositories | Preserve subscription and article/save server mutations |
| `PROFILE_*` | profile/settings pages | profile, account usage, billing, settings, voiceprint controllers | profile capability, billing and voiceprint repositories | Preserve active account, entitlement and unavailable states |
| `MASTERPIECE_*` | `V3MasterpiecePage` | profile workspace/book-work owners | profile workspace and book-work repositories | Preserve lock/entitlement and collaboration actions |
| `RECORDING_*` | recording-card/transcription pages | recording card, recording library/detail/upload, transcript controllers | recording-card, recording and ASR APIs | Preserve BLE lifecycle, transfer recovery, recording/content-line identity and ASR polling |
| `ONBOARDING_*` | onboarding pages | auth, positioning and first-device controllers | auth/profile/device setup ports | Preserve auth gating, progress persistence and first-launch recovery |

## M05 route contract

`/v3/feed/chat` may carry `threadId`, `window`, `contentLineId`, `itemId`,
`dailyTopicTitle`, `prompt`, `autoSend`, `purpose`, `skill`, `materialIds`,
`analyzeAssets`, and `agentProfileId`. Existing parsing, safety validation,
`ProviderScope` overrides, and `NoTransitionPage` ownership must remain exactly
where they are. The extracted entry surface receives callbacks and view data;
it does not read repositories or create a second controller.

## Validation probes

- Route with no context reuses the existing general chat controller.
- Route-scoped window/context/purpose/skill/profile creates the existing scoped
  controller and voice owner.
- A successful send carries only safe public identifiers and clears local input
  according to existing controller behavior.
- Failure restores input and exposes retry; no assistant reply is fabricated.
- Foreground refresh, push completion, cached thread restore, history selection,
voice transcription, uploads and lifecycle callbacks continue to work.

## M01 and M02 preservation probes

- M01 remains backed by the existing feed, graph, aggregation and material
  ingestion owners. The 1D/2D/3D graph modes, search, notification projection,
  capture/import routes, retry, idempotency and lifecycle recovery are not
  recreated inside presentation widgets.
- M02's extracted surface accepts state and callbacks only. The page retains
  HNote/public identifiers, exact raw Part revision, sync/binding errors,
  recording-specific outline polling, outline and sprout operation IDs, retry,
  RouteAware refresh and visible-result acknowledgement.
- M02 chat opens with the exact note item/thread context; Agent assisted and
  free-creation actions continue through their existing route methods.

## M03 preservation probes

- Workbench entry continues to use the existing material picker and generation
  owners; upload, generation, success and failure are not simulated in the
  presentation layer.
- Canvas load, autosave and recovery continue through the existing scoped draft
  repository. The editor preserves document identity, revision state, undo/redo
  state and pending proposal state when formatting rows or the keyboard toggle
  are opened and closed.
- AI transforms continue through the existing transform port. Apply and reject
  actions target the current proposal and document revision; presentation code
  does not synthesize transformed content.
- Creation history remains scoped by the active user. Open, duplicate and
  delete use the existing history port; cancelling the confirmation performs no
  mutation and a confirmed swipe deletes exactly the selected history ID.

## M04 and M07 preservation probes

- My Assets search sends only the normalized keyword through the existing
  Workspace search controller, then hydrates exact HNote revisions. Remote
  loading, unavailable, empty and failure states do not fall back to invented
  global results.
- Folder create, rename, recursive tombstone and restore continue through the
  existing Workspace Folder port with ETag and idempotency. Note movement uses
  the existing batch-move contract; local presentation state does not create a
  second note.
- Asset operation actions continue to use the canonical note dispatcher for
  share, edit/copy, export, tags, move, sync, conflict, rename and durable
  delete. M02 remains the sole detail owner.
- Knowledge catalog loading preserves the fast first screen and complete cursor
  pagination. Follow/unfollow remains guarded and rolls back on failure.
- Opening a remote Article loads its exact revision and keeps the author copy
  read-only. Saving uses the existing idempotent save-as-note operation and
  reports success only after the owned HNote projects into local assets.

## M06, M08, M09, M10 and M11 preservation probes

- Profile overlay navigation closes the overlay before pushing the existing
  route. Profile, membership and voiceprint operations retain account scope;
  unsupported binding/password/support mutations stay visibly unavailable.
- Representative-work lock is derived from eligible deposited notes. Reader,
  directory, editor and cadence share one workspace document owner. Cloud
  Book/Work remains a separate sheet backed by its existing controller; the
  Figma cadence choices do not invent a server mutation.
- Recording-card UI consumes the full native/controller state, including
  provisional authorization, permissions, Bluetooth-off, scan, command,
  transfer, recovery and cloud-binding constraints. A simulator pass is not
  evidence for hardware BLE, Wi-Fi or file-transfer acceptance.
- Auth and onboarding retain SMS request identity, legal versions, token and
  workspace validation, durable questionnaire drafts, accepted-Run recovery,
  formal positioning completion and retry semantics. No presentation timer
  advances a server-owned task.
- M11 top-level actions navigate to M01/M06/M07/M09 owners and the calendar
  keeps date selection as query/page state. Reused Figma screens do not create
  duplicate routes or controllers.
