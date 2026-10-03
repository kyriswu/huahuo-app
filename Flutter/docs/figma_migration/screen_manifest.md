# Mobile V5 screen manifest

> Visual audit status (2026-08-24): reopened for every independent Mobile V5
> target. The previous phase labels below proved route/controller ownership and
> behavioral regression coverage only; they did not prove visual parity. The
> authoritative visual status is now tracked in
> `visual_acceptance_matrix.md`. The current audit has no `UNREVIEWED` row;
> `GAP` remains the honest status until screenshot overlay acceptance passes.

`Family` is the stable business identity. A route/state/overlay belongs to one
family even when another module links to it. `VERIFY` means an existing Flutter
owner was not proven and must be resolved before implementation; it is not
permission to invent a route or API.

| Module | Formal Figma source | Canonical families | Existing Flutter route/surface | Flutter owner | Status |
|---|---|---|---|---|---|
| M01 | `377:1595` | `APP_SHELL`, `HOME_FEED`, `CAPTURE_ENTRY`, `IMPORT_ENTRY`, `SEARCH` | `/v3`, `/v3/search`, document/capture/import child routes | `V3AppShell`, `V3FeedPage`, `V3FeedSearchPage`, `V3MonologuePage`, `V3NotePage`, `V3LinkImportPage`, `V3DocumentImportPage`, `V3RecordSourcePage` | 1 `MATCH`, 35 `GAP`, 0 `UNREVIEWED`; all retained states have deterministic Golden/current evidence and real Controller actions |
| M02 | `438:4364` | `NOTE_DETAIL`, `NOTE_RAW`, `NOTE_OUTLINE`, `NOTE_SPROUT`, `NOTE_CHAT` | `/v3/feed/items/:itemId`, `/v3/feed/note/:itemId` | `V3FeedItemDetailPage`, `NoteDetailSurface`, `V3NotePage` | 1 `MATCH`, 17 `GAP`, 0 `UNREVIEWED`; raw/outline/ignite and note-chat states all have explicit evidence and actions |
| M03 | `377:1596` | `CREATION_HOME`, `CREATION_CANVAS`, `CREATION_HISTORY`, `CREATION_OVERLAY` | `/v3?mode=workbench`, `/v3/workbench/canvas`, `/v3/workbench/history` | `V3WorkbenchPage`, `V3CreationCanvasPage`, `V3CreationHistoryPage` | 46 `GAP`, 0 `UNREVIEWED` |
| M04 | `638:8213` | `ASSETS_HOME`, `ASSET_LIST`, `ASSET_DETAIL`, `ASSET_OPERATION` | `/v3/assets`, `/v3/profile/assets`, M02 note detail routes | `V3AssetsPage`, `V3MyAssetsPage`, `KnowledgeLibraryController` | 18 `GAP`, 0 `UNREVIEWED` |
| M05 | `2084:22831` only | `CHAT_ENTRY`, `CHAT_THREAD`, `CHAT_HISTORY`, `CHAT_CONTEXT` | `/v3/feed/chat` | `V3ChatPage`, `ChatController` | 30 `GAP`, 0 `UNREVIEWED`; the canonical chrome, history, media, voice, keyboard and response states have Golden evidence |
| M06 | `739:7557` | `PROFILE_SIDEBAR`, `SETTINGS`, `ACCOUNT`, `VOICEPRINT`, `MEMBERSHIP`, `DAILY_REMINDER` | `/v3/profile/*` and profile overlays | `V3ProfileSidePanel`, dedicated profile/settings surfaces, billing and voiceprint controllers | 52 `GAP`, 0 `UNREVIEWED`; 15 canonical 402×874 Goldens plus explicit state/action reuse, and one profile-drawer duplicate reuses M11 |
| M07 | `739:11214` | `KNOWLEDGE_HOME`, `KNOWLEDGE_SUBSCRIPTION`, `KNOWLEDGE_CHANNEL`, `KNOWLEDGE_ARTICLE` | `/v3/profile/knowledge`, channel/world routes | `V3KnowledgeLibraryPage`, `V3RemoteKnowledgeWorldDetailPage`, `V3FeedItemDetailPage`, `KnowledgeLibraryController`, `MobileSubscriptionPort` | 32 `GAP`, 0 `UNREVIEWED` |
| M08 | `1135:6808` | `MASTERPIECE_HOME`, `MASTERPIECE_READER`, `MASTERPIECE_TOC`, `MASTERPIECE_COLLAB` | `/v3?mode=masterpiece` | `V3AppShell`, `V3MasterpiecePage`, profile workspace and mobile Book/Work owners | 6 `GAP`, 1 `CANONICAL_REUSE`; all seven states have Golden evidence |
| M09 | `1360:7418` | `RECORDING_CARD_SETUP`, `RECORDING_CARD_CONTROL`, `RECORDING_TRANSFER`, `RECORDING_FILE`, `TRANSCRIPTION` | `/v3/recording-card/control` and recording routes | recording-card, native-port, binding, upload and transcription owners | 42 `GAP`, 0 `UNREVIEWED`; all retained simulator states have current/target evidence and real controller actions; BLE/Wi-Fi hardware acceptance remains device-only |
| M10 | `1360:8803` | `AUTH`, `QUESTIONNAIRE`, `POSITIONING`, `FIRST_DEVICE_SETUP` | `/auth`, `/onboarding`, `/v3/onboarding/device-setup` | Auth, onboarding, task-coordinator and first-device controllers | 1 `MATCH`, 22 `GAP`, 0 `UNREVIEWED`; all 23 retained states have current/target evidence and exercised entry/exit behavior |
| M11 | `1605:20590` | `TOP_LEVEL_PROFILE`, `CALENDAR`, `POSITIONING_ENTRY` | `/v3`, `/v3/profile/calendar`, profile overlay | `V3AppShell`, `V3ProfileSidePanel`, `V3ActivityCalendarPage`, `V3DeepPositioningPage` | 3 `MATCH`, 7 `GAP`, 0 `UNREVIEWED`; all ten states are reachable and evidenced, while avatar/card/status-bar visuals still differ; public shell ownership is shared with M01/M03 |

## Global canonical ownership

| Family | Canonical Figma node | Duplicate handling |
|---|---:|---|
| `HOME_FEED` | M01 `2053:1444` | M11 `1617:24269` links to M01 |
| `NOTE_DETAIL` | M02 `2062:1996` | M01 duplicate is skipped; M04/M07 occurrences are wrappers or fixtures |
| `CHAT_ENTRY` | M05 `2084:22831` | M01 `2302:19124` is skipped |
| `CREATION_HOME` | M03 `2062:21972` | M01 `2505:16283` is skipped |
| `CREATION_CANVAS` | M03 `2082:22683` | M04 `2363:4493` is a route reference |
| `PROFILE_SIDEBAR` | M06 `2538:260` | M03 `2538:76` is skipped |
| `VOICEPRINT` | M06 `1112:8797`, `1112:8855`, `1112:8913` | M10 endpoint copies link to M06 |
| `RECORDING_CARD_SETUP` | M09 Source nodes | M10/M11 copies link to M09 |
| `KNOWLEDGE_SUBSCRIPTION` | M07 `2059:316` | M11 reused copy links to M07 |

## State and overlay rules

- Loading must have success and failure exits.
- Every overlay must have close/back behavior and remain owned by its page
  family; shared visual components do not make a page-specific overlay global.
- Keyboard-expanded states exist only for editable text contexts.
- Content-only variants are fixtures, not separate routes.
- Prototype is an interaction aid, not the route source of truth. Route
  semantics come from `app_routes.dart` and the action register.

## Phase 2 implementation notes

- M01 keeps the existing real 1D/2D/3D interactive graph, feed, search, import,
  capture and bottom-dock owners. Its canonical state and ingestion/controller
  regressions were revalidated; no parallel V5 controller or route was added.
- M01 graph widget tests use bounded frame advancement because the product graph
  intentionally runs continuous physics. This changes test timing only.
- M02 now composes the pure `NoteDetailSurface` and
  `NoteDetailCreationDock`. `V3FeedItemDetailPage` still owns RouteAware refresh,
  pending-run acknowledgement, raw/outline/sprout controllers, recording outline
  selection, note-specific chat and both creation routes.
- M02 visual coverage is fixed at 402 x 874 using the checked-in full Noto Sans
  SC test font; production iOS continues to prefer PingFang SC.

## Phase 3 implementation notes

- M03 keeps the existing workbench, canvas draft, AI transform, proposal,
  generation, revision and history owners. No parallel draft or history state
  was introduced.
- `CREATION_HOME` follows canonical node `2062:21972`; its free-creation entry
  uses the canonical 80 dp row and 22 sp medium label while retaining all
  existing entry callbacks.
- `CREATION_CANVAS` follows canonical node `2082:22683`: exact blank-state
  placeholders, the `普通编辑` tag, a flat full-width primary toolbar, a fixed
  keyboard control and a larger chat affordance. Secondary formatting rows do
  not replace the primary toolbar.
- `CREATION_HISTORY` records both the left-swipe delete state (`1931:611`) and
  the explicit cancel/delete confirmation (`1931:656`). Cancel preserves the
  entry; confirmation deletes through the existing user-scoped history port.

## Phase 4 implementation notes

- M04 exposes the canonical `我的笔记 / 我的沉淀` primary model. The retained
  experience, knowledge, viewpoint, creation, information and media families
  are second-level states under My Deposits, so legacy deep links retain their
  exact owners without competing with the two primary destinations.
- My Notes owns search, sort, new-folder and new-note actions. Search drives the
  existing debounced Workspace keyword-search controller; Folder mutations,
  HNote movement, ETag conflict recovery and rollback stay in
  `KnowledgeLibraryController` and its typed ports. Opening a note composes the
  M02 canonical detail rather than copying it into M04.
- M07 uses canonical node `2059:316` for the `外部世界` shell and
  `我的订阅 / 知识广场` tabs. Remote catalog pagination, guarded follow/unfollow,
  exact Article reads, read-only behavior and save-as-HNote remain owned by the
  existing API 25 port and controller.
