# Chat repository boundary migration

## Scope

Continue Page → Controller → Repository → API Client → foundation.
This slice extracts the existing chat repository capabilities and submission
outcome classification from data into the feature contract layer. Relocating
the shared chat facade client remains a follow-up after this contract boundary
is stable. Preserve all request,
parser, stream, lease, retry and idempotency behavior. No server or native edits.

## Evidence and risks

Graphify finds ChatThreadMetadataClient and SharedChatFacadeClient referenced
by mobile chat data; the facade also serves script drafts. Source search finds
Controller, Run Tracker and the progress poller importing the complete remote
implementation solely to obtain capabilities and outcome semantics. Bootstrap
and chat DI create the concrete clients. Desktop uses a separate adapter.
Graph queries omit dynamic capability checks; source and compiler tests remain
required. A rejected submission differs from an unknown outcome; preserve its
metadata key and classification exactly.

## Steps and acceptance

- Extract ChatRepository and optional capabilities without broadening contracts.
- Move failure classification without altering its result/status semantics.
- Make application consumers import the contract and remove the old data-level
  compatibility names after all source consumers migrate.
- Relocate SharedChatFacadeClient, preserving the old barrel and its consumers.
- Run analyzer, shared client tests, chat adapter/controller/tracker/poller/image
  tests and a post-change Graphify review.
- Roll back only this slice's edits if verification fails; preserve previous
  account usage migration and unrelated dirty worktree files.

## Remaining migration

The contract still exposes ApiResult, idempotency metadata, and Agent Run wire
types. These remain explicit migration debt, not a completed pure domain layer.
RemoteChatRepository naming, app parsing, generic result isolation, attachment
upload and image download adapters are separate follow-up slices. No new
Controller dependency on the concrete remote chat implementation is allowed.

## Progress

- Extracted `ChatRepository`, optional metadata/history/progress/Agent Run
  capabilities and submission outcome classification into
  `features/chat/domain/chat_repository.dart`.
- `ChatController`, `ChatRunTracker`, the progress poller, onboarding agent and
  positioning update repository now import the contract layer. The concrete
  adapter is named `RemoteProjectChatRepository`; legacy `ChatApi` and
  `ChatApiPort` names have been removed.
- Targeted analyzer reports no errors. The complete chat suite has one clock
  injection test that fails under parallel execution and passes when isolated;
  this is existing test scheduling behavior, not a contract migration failure.
- Post-change Graphify refresh: 45,247 nodes, 67,039 edges and 1,078 source
  files. The `ChatRepository` node is referenced by the Controller, DI,
  onboarding and positioning adapters; the `ChatController` node has no edge to
  `data/chat_api.dart`.
- Removed the `ChatApi` and `ChatApiPort` names and the data barrel export;
  consumers now import the domain contract explicitly. Chat adapter,
  progress-poller, neutral-runtime and positioning repository tests pass.
