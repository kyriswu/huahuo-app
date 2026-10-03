# API gate register

No presentation migration may create a fake server mutation to make a Figma
control appear functional. A gated control must either use an existing backend
contract or render an explicit unavailable state.

| Gate | UI intent | Existing evidence | Implementation decision |
|---|---|---|---|
| `CHAT_NOTE_PICKER` | Pick a note and generate a topic | Existing knowledge-library picker and typed HNote references | Reuse the existing picker and `ChatController`; do not embed note text in hidden prompts |
| `CHAT_LIBRARY_TOPIC` | Pick from the note library | Same backend boundary as note picker | Reuse the canonical picker; distinguish copy only if product semantics require it |
| `CHAT_DAILY_TOPIC` | Generate from today's hotspot | `DailyTopicController` and daily-topic route data exist | Wire only through the existing daily-topic contract; show unavailable/retry for missing workspace/data |
| `CHAT_REFRESH_SUGGESTIONS` | Rotate three entry prompts | Presentation-only set | Local deterministic rotation is permitted; it must not claim server personalization |
| `CHAT_NEW_THREAD` | Create a blank conversation window | Existing route-scoped window and `ChatController` behavior | Reuse `_openNewChatWindow`; no local-only thread |
| `CHAT_HISTORY` | Open and select server-loaded history | Existing `_showThreadList` and `ChatController.loadThreads` | Preserve server history, local alias behavior and error states |
| `VOICE_INPUT` | Live speech-to-text in composer | Existing `VoiceMessageController` path | Reuse live PCM transcription; never auto-send transcript |
| `PROFILE_SPARK_ACADEMY` | Open 花火商学院 from profile | No approved Flutter route or backend capability contract exists | Render the existing explicit `功能尚未开发` destination; do not redirect to another profile page or report success |
| `DAILY_REMINDER_SCHEDULING` | Schedule a daily or weekday reminder | Settings has local presentation state; no approved native/backend scheduling contract exists | Keep the preference visibly local and unscheduled until the notification owner supplies a typed scheduling port |

## Gate policy

1. `VERIFY` is blocking for a mutation, not for displaying an honest unavailable
   state.
2. Backend changes require reading the matching backend implementation first.
3. Widgets cannot construct private model/runtime/agent fields or app-private
   file URIs.
4. IDs, revisions, ETags and idempotency keys remain opaque and controller-owned.
