# Shared package boundaries

`huahuo_api` is the shared remote boundary. It parses approved envelopes and
DTOs, constructs requests and carries explicit idempotency metadata. It does
not persist tokens, own routes or contain application controllers.

`huahuo_product` owns platform-neutral product vocabulary, repositories' ports
and immutable workflow state. It does not know about Flutter application
providers, local paths, native bridges or presentation.

`huahuo_editor` owns canonical structured document snapshots and editor-session
values. Persistence and platform UI remain outside the package.

`huahuo_foundation` owns semantic tokens and pure presentation helpers. Shared
packages must not import an application root.
