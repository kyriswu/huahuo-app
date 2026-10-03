# Flutter architecture overview

The workspace has two application roots and shared packages:

- `src/` is the mobile application root for iOS and Android.
- `desktop/` is the desktop application root for macOS and Windows.
- `packages/huahuo_api` owns transport construction, endpoint metadata, envelopes,
  idempotency and contract DTOs.
- `packages/huahuo_product` owns platform-neutral product capabilities and
  immutable product workflows.
- `packages/huahuo_editor` owns structured editor state and snapshots.
- `packages/huahuo_foundation` owns tokens and platform-neutral presentation
  primitives.

Mobile and desktop do not import each other. Shared packages do not import an
application root or presentation layer. Platform lifecycle, storage, navigation,
native bridges and UI state stay in their application root.

Within a feature, the intended direction is:

```text
presentation -> application -> domain
       data -> application/domain ports
```

Code relationships are discovered from source with Graphify, Dart analysis and
source search. This document records boundaries and reasons; it does not list
files or reproduce source structure.

The current high-coupling areas are recording-card, native bridges, long-running
workflows and the editor. Future extraction should follow measured dependency
communities and ownership boundaries rather than file size alone.
