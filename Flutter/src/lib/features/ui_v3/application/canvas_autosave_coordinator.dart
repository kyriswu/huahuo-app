import 'dart:async';

import '../domain/creation_canvas_draft.dart';
import '../domain/feed_item_models.dart';
import '../domain/script_draft_models.dart';

abstract interface class CreationCanvasDraftStore {
  String get userScope;

  CreationCanvasDraft? load();

  void upsert(CreationCanvasDraft draft);

  Future<void> upsertDeferred(CreationCanvasDraft draft);

  bool clear();

  Future<bool> clearDeferred();
}

final class CanvasDraftPersistenceCoordinator {
  factory CanvasDraftPersistenceCoordinator(CreationCanvasDraftStore store) =>
      _instances[store] ??= CanvasDraftPersistenceCoordinator._(store);

  CanvasDraftPersistenceCoordinator._(this._store);

  static final _instances = Expando<CanvasDraftPersistenceCoordinator>();
  final CreationCanvasDraftStore _store;
  Future<void> _tail = Future<void>.value();

  Future<void> persist(CreationCanvasDraft? draft) {
    final operation = _tail.then((_) async {
      if (draft == null) {
        await _store.clearDeferred();
      } else {
        await _store.upsertDeferred(draft);
      }
    });
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> drain() async {
    while (true) {
      final pending = _tail;
      await pending;
      if (identical(pending, _tail)) return;
    }
  }
}

CreationCanvasDraft? buildCanvasAutosaveDraft({
  required String title,
  required String markdown,
  required String? documentJson,
  required int documentFormatVersion,
  required Iterable<V3LinkedMaterialRef> linkedMaterials,
  required String? sourceTopicId,
  required String? sourceTitle,
  required String? synchronizedNoteId,
  String? sessionId,
  String? entryIdentity,
  ScriptDraftGenerationReceipt? scriptDraftReceipt,
  String? boundNoteId,
  String? boundAssetFingerprint,
  bool savedDraftCleanupPending = false,
  String? chatThreadId,
  CreationCanvasHistoryCommitReceipt? historyCommitReceipt,
  Iterable<CreationCanvasChatRewriteReceipt> chatRewriteReceipts =
      const <CreationCanvasChatRewriteReceipt>[],
  required int revision,
  required DateTime createdAt,
  required DateTime now,
}) {
  if (title.trim().isEmpty &&
      markdown.trim().isEmpty &&
      sourceTopicId == null &&
      linkedMaterials.isEmpty) {
    return null;
  }
  return CreationCanvasDraft(
    title: title,
    markdown: markdown,
    documentJson: documentJson,
    documentFormatVersion: documentFormatVersion,
    linkedMaterials: linkedMaterials,
    sourceTopicId: sourceTopicId,
    sourceTitle: sourceTitle,
    sessionId: sessionId,
    entryIdentity: entryIdentity,
    scriptDraftReceipt: scriptDraftReceipt,
    boundNoteId: boundNoteId,
    boundAssetFingerprint: boundAssetFingerprint,
    savedDraftCleanupPending: savedDraftCleanupPending,
    chatThreadId: chatThreadId,
    historyCommitReceipt: historyCommitReceipt,
    chatRewriteReceipts: chatRewriteReceipts,
    synchronizedNoteId: synchronizedNoteId,
    revision: revision,
    createdAt: createdAt,
    updatedAt: now.isBefore(createdAt) ? createdAt : now,
  );
}

final class CanvasAutosaveCoordinator {
  CanvasAutosaveCoordinator({
    required this.canSchedulePersist,
    required this.canScheduleCloudSync,
    required this.canRunCloudSync,
    required this.persist,
    required this.synchronize,
    this.persistDelay = const Duration(milliseconds: 800),
    required this.cloudSyncDelay,
  });

  final bool Function() canSchedulePersist;
  final bool Function() canScheduleCloudSync;
  final bool Function() canRunCloudSync;
  final FutureOr<bool> Function() persist;
  final Future<void> Function() synchronize;
  final Duration persistDelay;
  final Duration cloudSyncDelay;

  Timer? _persistTimer;
  Timer? _cloudSyncTimer;
  Future<void> _persistQueue = Future<void>.value();
  bool _disposed = false;

  bool get hasPendingPersist => _persistTimer?.isActive ?? false;
  bool get hasPendingCloudSync => _cloudSyncTimer?.isActive ?? false;

  void schedule() {
    if (_disposed || !canSchedulePersist()) return;
    cancelPersist();
    _persistTimer = Timer(persistDelay, () {
      _persistTimer = null;
      if (!_disposed) _enqueuePersist();
    });
    scheduleCloudSync();
  }

  void _enqueuePersist() {
    _persistQueue = _persistQueue.then((_) async {
      if (_disposed) return;
      try {
        await persist();
      } catch (_) {
        // Autosave is best-effort. Callers observe durable failures through
        // their explicit save path, while this queue must remain usable.
      }
    });
  }

  Future<void> drainPersist() async {
    while (true) {
      final pending = _persistQueue;
      await pending;
      if (identical(pending, _persistQueue)) return;
    }
  }

  Future<void> cancelPersistAndDrain() {
    cancelPersist();
    return drainPersist();
  }

  void scheduleCloudSync() {
    if (_disposed || !canScheduleCloudSync()) return;
    cancelCloudSync();
    _cloudSyncTimer = Timer(cloudSyncDelay, () {
      _cloudSyncTimer = null;
      if (_disposed || !canRunCloudSync()) return;
      unawaited(synchronize());
    });
  }

  void cancelPersist() {
    _persistTimer?.cancel();
    _persistTimer = null;
  }

  void cancelCloudSync() {
    _cloudSyncTimer?.cancel();
    _cloudSyncTimer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelPersist();
    cancelCloudSync();
  }
}
