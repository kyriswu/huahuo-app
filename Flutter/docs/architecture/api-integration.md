# API integration boundary

The backend contract is defined by the deployed API route, DTO and server
implementation. Flutter transport code validates response identity and maps
protocol errors without inventing successful state from elapsed time, UI text or
an accepted queue request.

## Application call path

Feature requests follow one direction:

```text
Page → Controller → Repository → API Client → transport/contract foundation
```

Pages dispatch user intent and render state. Controllers own presentation state
and workflow transitions, but do not know endpoint IDs, wire maps or HTTP
transport. Repositories expose feature values and failure semantics; they may
compose remote clients with local storage. API clients construct endpoint
requests and parse wire contracts. The foundation owns transport, auth,
timeouts, cancellation, retry policy, tracing and common result/error mapping.

The account-usage feature is the first migrated slice. Its `AccountUsageRepository`
contract is in the feature domain layer, its remote adapter is in feature data,
and `AccountUsageClient` plus `WorkspaceLifecycleClient` are shared protocol
clients. The old `account_usage_api.dart` entry point was removed after all
known consumers migrated; new features should follow this shape instead of
placing a repository and a remote client in one file.

The chat feature keeps its `ChatRepository` and optional progress and metadata
capabilities under the feature domain layer. `RemoteProjectChatRepository` is
the project backend adapter in data; Controllers depend on the domain contract
and do not import the adapter.

For long-running operations, distinguish acceptance, ownership/attempt binding,
processing, formal persistence and readable output. Replays use the original
operation/run/idempotency identity. Readback must verify account, Workspace,
entity and version before publishing data.

API changes require contract evidence and focused client/server tests. This
architecture document records the boundary; it is not a copy of endpoint source
or a per-file request inventory.
