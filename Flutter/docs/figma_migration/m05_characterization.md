# M05 chat entry characterization

## Sole visual acceptance source

- Figma file: `cB9ops5llz7DvBJ1QTvCu9`
- Node: `2084:22831`
- Family: `CHAT_ENTRY`
- Flutter route: `/v3/feed/chat`
- Existing page/controller: `V3ChatPage` / `ChatController`

M01 `2302:19124` and older layers inside the M05 source are not acceptance
sources. The refreshed layers in `2084:22831` define the entry state.

## Required first viewport

- Page size: 402 x 874, white background.
- Header title: `聊一聊`.
- Greeting: `Hello，我是花火 AI`.
- Supporting copy: `把你的想法整理成清晰、可执行的创作方向。`.
- Section: `猜你想问`; action: `换一批`.
- Suggestions, in order:
  1. `从我的笔记库选一篇生成选题`
  2. `去笔记库里面帮我选一篇生成选题`
  3. `帮我选一个今天的热点生成选题`
- Composer hint: `输入你的问题或想法…`.
- Disclaimer: `内容由 AI 生成，仅供参考`.
- Accent: taupe `#94632E` / `#93662E`; suggestion surface `#F6F5F3`.
- Chinese typography follows Noto Sans SC at 13-18 logical pixels with normal
  or medium weights. It must not inherit oversized or extra-bold legacy styles.

## Action table

| Source | Action | Destination/result | Failure/close path |
|---|---|---|---|
| Back | tap | Pop, then the existing fallback route | Existing scaffold fallback |
| History | tap | Existing server-backed thread list overlay | Close returns to unchanged entry/thread |
| New conversation | tap | Existing independent route window | Back returns to previous chat window |
| Refresh suggestions | tap | Rotate the local presentation set | No network or loading claim |
| Suggestion 1 | tap | Existing note picker, then prepare a typed note-backed prompt | Cancel leaves entry unchanged |
| Suggestion 2 | tap | Existing note-library picker contract | Cancel leaves entry unchanged |
| Suggestion 3 | tap | Existing Daily Topic contract | Workspace/data failure is visible and retryable |
| Plus | tap | Existing context/upload menu | Modal close returns to entry |
| Text field | input | Existing composer draft | Keyboard dismissal preserves draft |
| Microphone | tap | Existing live transcription | Cancel/failure uses existing voice states |
| Send | tap | Existing `ChatController` send/create-thread path | Existing retry/draft restoration |

## Extraction boundary

The new `ChatEntrySurface` is a pure presentation widget. It owns layout,
typography, icons and the local suggestion rotation index. `V3ChatPage` retains
all controller reads, route semantics, lifecycle listeners, uploads, voice,
thread history, context and send behavior, and passes only view data/callbacks
into the surface. The real entry composer renders the disclaimer immediately
below its shared glass input bar; it is covered by the route widget test and the
feed-to-chat device screenshot assertion, while the isolated golden remains a
content-surface characterization rather than a second composer implementation.
