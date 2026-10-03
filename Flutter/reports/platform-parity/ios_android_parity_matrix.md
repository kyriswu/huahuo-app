# iOS-Baseline Android Parity Matrix

## Scope and status

iOS is the product baseline. This matrix tracks behavioral alignment, not
visual similarity. `Code aligned` means the shared or native implementation
has been inspected and changed against the iOS behavior. It is not a substitute
for the required device evidence in the last section.

| Area | iOS entry and expected state | Native bridge | Server contract | Android state |
| --- | --- | --- | --- | --- |
| Login and Workspace recovery | Launch restores the authenticated account and selected Workspace before gated work begins. | Platform permissions and app lifecycle | Auth/session and Workspace APIs | Pending device audit |
| Route and deep link | A validated route opens its intended screen; malformed identifiers fail closed. | App delegate / MainActivity intents | No route-only API | Pending device audit |
| Microphone permission | First grant, deny, permanent deny, and settings return resolve to a typed UI state. | `huahuoai/platform_permissions` | None | Pending Android 13-15+ device audit |
| Live transcription | Start captures PCM before SDK handoff; stop and release occur in a stable order; typed failure remains retryable. | Tencent AAI bridge and recorder bridge | `api/v1/realtime-asr/sessions` | Code aligned; device audit required |
| Audio import | Picker/share creates a private copy and awaits explicit confirmation before import/transcription. | `huahuoai/native_file` | Existing Resource and recording APIs | Code aligned; device audit required |
| Document import | TXT, MD, CSV, JSON, PDF, DOCX, PPTX, XLSX use private copies; cancel is neutral; invalid/oversize/read failure is visible. | `huahuoai/native_file` | Existing Resource/Note ingestion APIs | Code aligned; device audit required |
| External open/share | One or many supported files survive cold start in a manifest-backed queue; confirmation acknowledges opaque refs only after success. | incoming Material EventChannel | None before confirmation | Code aligned; device audit required |
| Chat history | Re-entering ordinary chat preserves account/Workspace/purpose cache; remote failure or empty detail does not erase visible messages. | Shared Dart controller | `GET /api/v1/chat/threads` and detail | Code aligned; iOS/Android regression required |
| Chat attachments and voice reply | Attachment, voice reply, and Agent readback remain attached to the selected thread. | Native file/voice bridge | Existing Chat APIs | Shared-code regression required |
| Content generation and Agent Runs | Accepted Run remains visible across return/resume and terminal readback. | Push/lifecycle bridge | Existing Agent Run APIs | Pending device audit |
| Knowledge library and graph | Material confirmation, library recovery, and interactive graph actions work after navigation. | Native file bridge where needed | Existing Resource/HNote APIs | Pending device audit |
| Notifications | Foreground and cold-start notification route only after current-screen leave handling. | JPush/platform notification bridge | Notification APIs | Pending device audit |
| Payment | Product purchase/restore resolves to controlled status without losing current navigation. | StoreKit / Android provider bridge | Billing APIs | Blocked: Android bridge intentionally has no provider SDK; backend has no Android order contract |
| Export and recording card | User-controlled export and recording card state survive activity recreation. | Native file and recording card bridges | Existing export/card APIs | Pending device audit |

## Native Inventory

This inventory was read from the iOS Runner sources and matched against the
Android host and Flutter port, rather than inferred from visible UI.

| iOS capability | Android counterpart | Code result | Remaining evidence |
| --- | --- | --- | --- |
| Scene file-open ingress | `MainActivity` `ACTION_VIEW` / `ACTION_SEND` / `ACTION_SEND_MULTIPLE` | Android accepts the iOS-supported audio and eight document MIME families, persists accepted items, and adds warm/cold share support. | Android 13-15+ open/share/cold-start device run |
| Deep-link scheme | `huahuoai` activity intent filter and Flutter router | Code-aligned route ingress; Android has the same custom scheme plus explicit non-file intent filtering. | Valid/malformed link device run |
| Platform permissions | `huahuoai/platform_permissions` in `MainActivity` | Microphone, notification, Bluetooth/nearby device, local-network/Wi-Fi and settings states return typed Android values. iOS-only unavailable kinds remain unavailable rather than fabricated. | Grant, deny, blocked and Settings-return device run |
| System audio/document/media picker | `huahuoai/native_file` in `MainActivity` | Matching MethodChannel operations, private copies, cancellation, typed failure, export and gallery-save behavior. Android additionally supports external share. | Audio/document/image/video picker device run |
| Incoming material queue | Android manifest-backed incoming queue | Cache, `consume`, `acknowledge`, error drain and Flutter wake event are implemented on both hosts. | Multi-file partial failure and app restart device run |
| Voice recorder | `VoiceRecorderAndroidBridge` | Matching recorder methods, private output, level/PCM events and foreground microphone service. | Android 13-15+ permission, interruption, pause/resume and background run |
| Tencent realtime ASR | `TencentLiveAsrAndroidBridge` | Matching start/stop/release channel and shared PCM lifecycle. Release AAR class verification and R8 retention are in place. | Device session using real credentials and microphone |
| Screen capture | `ScreenCaptureAndroidBridge` and foreground service | Matching capability/state/start/stop/extract-audio contract; each platform uses its required system consent flow. | Consent reject/grant, background and extracted-audio device run |
| Recording card | `RecordingCardAndroidBridge` | All public recording-card method names match the iOS bridge, including BLE, file transfer, Wi-Fi handoff, binding and unbind. | Real device BLE/Wi-Fi regression |
| Home widget | `HomeWidgetBridge` and Android widgets | Shared snapshot schema, strict validation and widget refresh are implemented on both platforms. | Widget update after login/logout and recording-card change |
| Link clipboard prefill | Flutter system clipboard on Android | iOS uses a privacy-specific native reader; Android uses Flutter's platform clipboard. Both return plain text only and feed the same URL validation. | Android clipboard prefill device run |
| Transparency accessibility | Android Material rendering | iOS supplies a Reduce Transparency bridge; Android has no equivalent system setting and does not depend on the iOS channel. | Visual accessibility review |
| Notifications | JPush/Android notification channels and Flutter ingress | Platform transport differs, while the shared foreground/cold-start routing guard is common. | Android notification permission and cold-start device run |
| Membership purchase | `PaymentBridge` | Not usable: the bridge deliberately returns `PAYMENT_PROVIDER_NOT_CONFIGURED`; it does not launch an SDK or emit provider results. | Blocked by provider SDK, merchant config, and backend API authority |

## Known Contract Gaps

- Android provider payment cannot be aligned in Flutter alone. The inspected
  backend currently registers only `GET /api/v1/membership`; it does not expose
  the mobile catalog, Android order creation, order read, confirmation, or
  payment callback routes that the Flutter billing client expects. Enabling
  WeChat/Alipay also requires a reviewed fixed-version SDK and merchant
  configuration. This remains an external-authority blocker, not a test gap.
- The public media contract accepts only MP4, MOV and WebM video attachments.
  iOS native staging recognizes M4V, but the shared Flutter boundary rejects it
  before import/upload; AVI is likewise rejected. Android is therefore not
  missing a usable iOS product capability, but the native staging vocabulary
  should be normalized in a future contract cleanup after server policy is
  confirmed.
- No Android device was attached during this audit. Every device-evidence row
  remains pending even when static source, Android unit tests, and APK build
  passed.

## P0 acceptance evidence

| Device target | Required scenarios | Evidence status |
| --- | --- | --- |
| Android 13 | Microphone grant/deny/permanent deny; transcription start/stop; chat leave/return; document/audio multi-select. | Not yet run in this workspace |
| Android 14 | Foreground-service microphone restrictions; system share/open, cancel, malformed, oversize and unreadable material; cold-start restore. | Not yet run in this workspace |
| Android 15+ | Repeat Android 14 flows with current background/permission behavior; restart after chat and pending incoming handoff. | Not yet run in this workspace |
| iOS regression | Chat cache/detail failure/empty response, transcription, normal picker, external open/share and confirmation. | Not yet run in this workspace |

## Implementation evidence

- Chat request generation and cache-first reconciliation are covered by Dart
  controller tests; ordinary general chat now uses the app-scoped controller.
- Android selected and externally delivered documents use a bounded private-copy
  writer. Android and iOS expose only allow-listed material preparation codes
  to Flutter.
- Android release builds validate the checked-in Tencent AAR before the release
  build and preserve its reflection targets through R8.

No backend request, authentication, or synchronization contract changed in
this P0 pass. The 2026-08-18 audit likewise made no backend change.
