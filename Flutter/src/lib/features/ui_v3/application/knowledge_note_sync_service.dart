import 'package:flutter/foundation.dart';

import '../data/workspace_content_sync_store.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import 'knowledge_note_port.dart';

typedef KnowledgeNoteReader = V3FeedItem? Function(String noteId);
typedef KnowledgeNotePersistenceFlush = Future<bool> Function();
typedef KnowledgeNoteUpsertDelivery =
    Future<KnowledgeNoteSyncResult> Function(
      V3FeedItem note,
      String mutationIdentity,
    );
typedef KnowledgeNoteTombstoneDelivery =
    Future<KnowledgeNoteDeleteResult> Function(
      V3FeedItem note,
      String idempotencyKey,
    );
typedef KnowledgeNoteSyncFailureRecorder =
    KnowledgeNoteSyncResult Function(V3FeedItem note, String errorCode);

/// Durable command and event-receipt orchestration for Workspace Notes.
final class KnowledgeNoteSyncService {
  const KnowledgeNoteSyncService(this._journal);

  final KnowledgeNoteSyncJournal _journal;

  Future<KnowledgeNoteSyncResult> synchronize({
    required V3FeedItem? local,
    required KnowledgeNoteReader readCurrent,
    required KnowledgeNotePersistenceFlush flushPersistence,
    required KnowledgeNoteUpsertDelivery deliver,
    required KnowledgeNoteSyncFailureRecorder recordFailure,
  }) async {
    if (local == null || local.isReadOnly) {
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.notEditable,
        note: local,
        errorCode: 'KNOWLEDGE_NOTE_SYNC_NOT_ALLOWED',
      );
    }
    if (local.syncState == NoteSyncState.synced) {
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.synced,
        note: local,
      );
    }
    if (!await flushPersistence()) {
      return recordFailure(local, 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED');
    }
    try {
      final command = await _journal.enqueueUpsert(
        localNoteId: local.id,
        localRevision: local.localRevision,
      );
      final claimed = await _journal.claim(operationId: command.operationId);
      if (claimed.isEmpty) {
        return recordFailure(local, 'KNOWLEDGE_NOTE_OUTBOX_LEASED');
      }
      return _deliverUpsert(
        claimed.single,
        readCurrent: readCurrent,
        flushPersistence: flushPersistence,
        deliver: deliver,
        recordFailure: recordFailure,
      );
    } on Object {
      return recordFailure(local, 'KNOWLEDGE_NOTE_OUTBOX_FAILED');
    }
  }

  Future<KnowledgeNoteDeleteResult> tombstone({
    required String localNoteId,
    required V3FeedItem? local,
    required KnowledgeNoteReader readCurrent,
    required KnowledgeNotePersistenceFlush flushPersistence,
    required Future<KnowledgeNoteDeleteResult> Function(String noteId)
    fallbackDelete,
    required String Function(String subject) idempotencyKeyFor,
    required KnowledgeNoteTombstoneDelivery deliver,
    required void Function(String remoteNoteId, String etag) completeMutation,
  }) async {
    if (local == null) return fallbackDelete(localNoteId);
    if (!await flushPersistence()) {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: local,
        errorCode: 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
      );
    }
    final remoteNoteId = _nonEmpty(local.remoteNoteId);
    final etag = _nonEmpty(local.etag);
    if (remoteNoteId == null || etag == null) {
      return fallbackDelete(localNoteId);
    }
    try {
      final command = await _journal.enqueueTombstone(
        localNoteId: local.id,
        localRevision: local.localRevision,
        remoteNoteId: remoteNoteId,
        etag: etag,
        idempotencyKey: idempotencyKeyFor('$remoteNoteId|$etag'),
      );
      final claimed = await _journal.claim(operationId: command.operationId);
      if (claimed.isEmpty) {
        return KnowledgeNoteDeleteResult(
          outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
          note: local,
          errorCode: 'KNOWLEDGE_NOTE_OUTBOX_LEASED',
        );
      }
      return _deliverTombstone(
        claimed.single,
        readCurrent: readCurrent,
        deliver: deliver,
        completeMutation: completeMutation,
      );
    } on Object {
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
        note: local,
        errorCode: 'KNOWLEDGE_NOTE_OUTBOX_FAILED',
      );
    }
  }

  Future<bool> recover({
    required Iterable<V3FeedItem> notes,
    required KnowledgeNoteReader readCurrent,
    required KnowledgeNotePersistenceFlush flushPersistence,
    required KnowledgeNoteUpsertDelivery deliverUpsert,
    required KnowledgeNoteTombstoneDelivery deliverTombstone,
    required KnowledgeNoteSyncFailureRecorder recordFailure,
    required void Function(String noteId, String errorCode) recordCommandError,
    required void Function(String remoteNoteId, String etag) completeMutation,
    required bool Function() isDisposed,
  }) async {
    if (isDisposed() || !await flushPersistence()) return false;
    for (final note in List<V3FeedItem>.of(notes)) {
      if (note.isReadOnly || note.syncState != NoteSyncState.pending) continue;
      try {
        await _journal.enqueueUpsert(
          localNoteId: note.id,
          localRevision: note.localRevision,
        );
      } on Object {
        recordCommandError(note.id, 'KNOWLEDGE_NOTE_OUTBOX_FAILED');
      }
    }
    List<KnowledgeNoteOutboxCommand> commands;
    try {
      commands = await _journal.claim(limit: 100);
    } on Object {
      return false;
    }
    for (final command in commands) {
      if (isDisposed()) return false;
      try {
        switch (command.kind) {
          case KnowledgeNoteOutboxCommandKind.upsert:
            await _deliverUpsert(
              command,
              readCurrent: readCurrent,
              flushPersistence: flushPersistence,
              deliver: deliverUpsert,
              recordFailure: recordFailure,
            );
            break;
          case KnowledgeNoteOutboxCommandKind.tombstone:
            await _deliverTombstone(
              command,
              readCurrent: readCurrent,
              deliver: deliverTombstone,
              completeMutation: completeMutation,
            );
            break;
        }
      } on Object {
        recordCommandError(command.localNoteId, 'KNOWLEDGE_NOTE_OUTBOX_FAILED');
      }
    }
    return true;
  }

  Future<bool> admitEvent({
    required String eventId,
    required DateTime occurredAt,
  }) async {
    final disposition = await _journal.beginEvent(
      eventId: eventId,
      occurredAt: occurredAt,
    );
    return disposition != KnowledgeNoteInboxDisposition.alreadyProcessed;
  }

  Future<void> markEventsProcessed(Iterable<String> eventIds) async {
    for (final eventId in eventIds.toSet()) {
      await _journal.markEventProcessed(eventId);
    }
  }

  Future<KnowledgeNoteSyncResult> _deliverUpsert(
    KnowledgeNoteOutboxCommand command, {
    required KnowledgeNoteReader readCurrent,
    required KnowledgeNotePersistenceFlush flushPersistence,
    required KnowledgeNoteUpsertDelivery deliver,
    required KnowledgeNoteSyncFailureRecorder recordFailure,
  }) async {
    final current = readCurrent(command.localNoteId);
    if (current == null || current.isReadOnly) {
      await _journal.markSucceeded(command);
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.notEditable,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_SYNC_NOT_ALLOWED',
      );
    }
    if (current.localRevision != command.localRevision) {
      await _enqueuePendingReplacement(current, flushPersistence);
      await _journal.markSucceeded(command);
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.superseded,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_SYNC_SUPERSEDED',
      );
    }
    if (current.syncState == NoteSyncState.synced) {
      await _journal.markSucceeded(command);
      return KnowledgeNoteSyncResult(
        outcome: KnowledgeNoteSyncOutcome.synced,
        note: current,
      );
    }

    final result = await deliver(current, command.operationId);
    switch (result.outcome) {
      case KnowledgeNoteSyncOutcome.synced:
      case KnowledgeNoteSyncOutcome.conflict:
        if (!await flushPersistence()) {
          await _journal.markRetry(
            command,
            errorCode: 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
          );
          return recordFailure(
            readCurrent(current.id) ?? current,
            'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
          );
        }
        await _journal.markSucceeded(command);
        break;
      case KnowledgeNoteSyncOutcome.notEditable:
        await _journal.markSucceeded(command);
        break;
      case KnowledgeNoteSyncOutcome.superseded:
        final latest = readCurrent(current.id);
        if (latest != null) {
          await _enqueuePendingReplacement(latest, flushPersistence);
        }
        await _journal.markSucceeded(command);
        break;
      case KnowledgeNoteSyncOutcome.unavailable:
      case KnowledgeNoteSyncOutcome.failed:
        await _journal.markRetry(
          command,
          errorCode: result.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED',
        );
        break;
    }
    return result;
  }

  Future<void> _enqueuePendingReplacement(
    V3FeedItem note,
    KnowledgeNotePersistenceFlush flushPersistence,
  ) async {
    if (note.isReadOnly || note.syncState != NoteSyncState.pending) return;
    if (!await flushPersistence()) {
      throw StateError('KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED');
    }
    await _journal.enqueueUpsert(
      localNoteId: note.id,
      localRevision: note.localRevision,
    );
  }

  Future<KnowledgeNoteDeleteResult> _deliverTombstone(
    KnowledgeNoteOutboxCommand command, {
    required KnowledgeNoteReader readCurrent,
    required KnowledgeNoteTombstoneDelivery deliver,
    required void Function(String remoteNoteId, String etag) completeMutation,
  }) async {
    final current = readCurrent(command.localNoteId);
    final remoteNoteId = command.remoteNoteId!;
    final etag = command.etag!;
    if (current == null) {
      await _journal.markSucceeded(command);
      return const KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.deleted,
      );
    }
    if (current.isReadOnly ||
        current.localRevision != command.localRevision ||
        _nonEmpty(current.remoteNoteId) != remoteNoteId ||
        _nonEmpty(current.etag) != etag) {
      completeMutation(remoteNoteId, etag);
      await _journal.markSucceeded(command);
      return KnowledgeNoteDeleteResult(
        outcome: KnowledgeNoteDeleteOutcome.notEditable,
        note: current,
        errorCode: 'KNOWLEDGE_NOTE_DELETE_SUPERSEDED',
      );
    }
    final result = await deliver(current, command.idempotencyKey!);
    if (result.outcome == KnowledgeNoteDeleteOutcome.deleted) {
      await _journal.markSucceeded(command);
      return result;
    }
    final latest = readCurrent(current.id);
    final unchanged =
        latest != null &&
        latest.localRevision == command.localRevision &&
        _nonEmpty(latest.remoteNoteId) == remoteNoteId &&
        _nonEmpty(latest.etag) == etag;
    if (unchanged && !_terminalTombstoneErrors.contains(result.errorCode)) {
      await _journal.markRetry(
        command,
        errorCode: result.errorCode ?? 'WORKSPACE_NOTE_TOMBSTONE_FAILED',
      );
    } else {
      completeMutation(remoteNoteId, etag);
      await _journal.markSucceeded(command);
    }
    return result;
  }
}

const _terminalTombstoneErrors = <String>{
  'INVALID_ARGUMENT',
  'PRECONDITION_FAILED',
  'NOTE_TOMBSTONED',
  'REVISION_NOT_FOUND',
  'WORKSPACE_NOTE_LIFECYCLE_REQUEST_INVALID',
  'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
};

V3NoteDraft knowledgeNoteDraftFor(V3FeedItem note) => V3NoteDraft(
  title: note.title,
  rawBody: note.rawBody,
  topics: note.topics,
  contentLineId: note.contentLineId,
  contentLineName: note.contentLineName,
  folderId: note.folderId,
  folderName: note.folderName,
  linkedMaterials: note.linkedMaterials,
);

V3FeedItem retainKnowledgeRemoteBinding(
  V3FeedItem current,
  V3FeedItem remote,
) => current.copyWith(
  remoteRevision: remote.remoteRevision,
  remoteNoteId: remote.remoteNoteId,
  noteRevisionId: remote.noteRevisionId,
  rawPartRevisionId: remote.rawPartRevisionId,
  etag: remote.etag,
  contentCursor: remote.contentCursor,
  syncState: NoteSyncState.pending,
);

bool isValidKnowledgeRemoteNote(
  V3FeedItem? note,
  String expectedId, {
  V3FeedItem? localBinding,
}) {
  if (note == null || note.id != expectedId) return false;
  final formalValues = <String?>[
    note.remoteNoteId,
    note.noteRevisionId,
    note.rawPartRevisionId,
    note.etag,
    note.contentCursor,
  ];
  final hasFormalBinding = formalValues.any(
    (value) => _nonEmpty(value) != null,
  );
  final formalBindingValid = formalValues.every(
    (value) => _nonEmpty(value) != null,
  );
  final expectedRemoteId = _nonEmpty(localBinding?.remoteNoteId);
  if (hasFormalBinding) {
    return formalBindingValid &&
        (expectedRemoteId == null || note.remoteNoteId == expectedRemoteId);
  }
  return note.remoteRevision != null && note.remoteRevision! >= 0;
}

bool hasExactKnowledgeRemoteBinding(V3FeedItem? note) =>
    note != null &&
    <String?>[
      note.remoteNoteId,
      note.noteRevisionId,
      note.rawPartRevisionId,
      note.etag,
      note.contentCursor,
    ].every((value) => _nonEmpty(value) != null);

bool wouldDiscardKnowledgeRemoteBinding(
  V3FeedItem existing,
  V3FeedItem incoming,
) =>
    existing.syncState == NoteSyncState.synced &&
    hasExactKnowledgeRemoteBinding(existing) &&
    !hasExactKnowledgeRemoteBinding(incoming) &&
    sameKnowledgeEditableRevision(existing, incoming);

bool hasUnsyncedKnowledgeChanges(V3FeedItem note) =>
    note.syncState == NoteSyncState.localOnly ||
    note.syncState == NoteSyncState.pending ||
    note.syncState == NoteSyncState.conflict;

void debugKnowledgeSync(String message) {
  if (kDebugMode) debugPrint('[KnowledgeAssets] sync $message');
}

bool sameKnowledgeEditableRevision(V3FeedItem left, V3FeedItem right) =>
    left.pendingRawOnlyUpdate == right.pendingRawOnlyUpdate &&
    left.id == right.id &&
    left.localRevision == right.localRevision &&
    left.title == right.title &&
    left.rawBody == right.rawBody &&
    left.contentLineId == right.contentLineId &&
    left.contentLineName == right.contentLineName &&
    left.folderId == right.folderId &&
    left.folderName == right.folderName &&
    left.copiedFromContentId == right.copiedFromContentId &&
    left.publicUrl == right.publicUrl &&
    left.contentOrigin == right.contentOrigin &&
    listEquals(left.topics, right.topics) &&
    sameKnowledgeLinkedMaterials(left.linkedMaterials, right.linkedMaterials);

bool sameKnowledgeLinkedMaterials(
  List<V3LinkedMaterialRef> left,
  List<V3LinkedMaterialRef> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.id != b.id ||
        a.source != b.source ||
        a.title != b.title ||
        a.summary != b.summary) {
      return false;
    }
  }
  return true;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
