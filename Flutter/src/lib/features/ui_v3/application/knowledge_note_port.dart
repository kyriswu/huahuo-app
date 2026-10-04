import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';

export 'package:huahuo_api/huahuo_api.dart'
    show
        WorkspaceHNotePartReader,
        hydrateWorkspaceHNoteParts,
        hasEmbeddedWorkspaceHNoteParts;

enum KnowledgeNotePortStatus { success, conflict, unavailable, failure }

@immutable
final class KnowledgeNoteUpdateRequest {
  const KnowledgeNoteUpdateRequest({
    required this.noteId,
    required this.baseRevision,
    required this.localRevision,
    required this.draft,
    this.remoteNoteId,
    this.noteRevisionId,
    this.rawPartRevisionId,
    this.etag,
    this.contentCursor,
    this.localNote,
    this.mutationIdentity,
  });

  final String noteId;
  final int? baseRevision;
  final int localRevision;
  final V3NoteDraft draft;
  final String? remoteNoteId;
  final String? noteRevisionId;
  final String? rawPartRevisionId;
  final String? etag;
  final String? contentCursor;
  final V3FeedItem? localNote;
  final String? mutationIdentity;
}

@immutable
final class KnowledgeNotePortResult {
  const KnowledgeNotePortResult._({
    required this.status,
    this.remoteNote,
    this.errorCode,
  });

  const KnowledgeNotePortResult.success(V3FeedItem remoteNote)
    : this._(status: KnowledgeNotePortStatus.success, remoteNote: remoteNote);

  const KnowledgeNotePortResult.conflict(V3FeedItem remoteNote)
    : this._(
        status: KnowledgeNotePortStatus.conflict,
        remoteNote: remoteNote,
        errorCode: 'KNOWLEDGE_NOTE_REVISION_CONFLICT',
      );

  const KnowledgeNotePortResult.unavailable([
    String errorCode = 'KNOWLEDGE_NOTE_UPDATE_UNAVAILABLE',
  ]) : this._(
         status: KnowledgeNotePortStatus.unavailable,
         errorCode: errorCode,
       );

  const KnowledgeNotePortResult.failure(String errorCode)
    : this._(status: KnowledgeNotePortStatus.failure, errorCode: errorCode);

  final KnowledgeNotePortStatus status;
  final V3FeedItem? remoteNote;
  final String? errorCode;
}

abstract interface class KnowledgeNotePort {
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  );
}

enum KnowledgeNoteRemoteLoadStatus { success, unavailable, failure }

@immutable
final class KnowledgeNoteRemoteLoadResult {
  const KnowledgeNoteRemoteLoadResult._({
    required this.status,
    this.notes = const <V3FeedItem>[],
    this.errorCode,
  });

  const KnowledgeNoteRemoteLoadResult.success(List<V3FeedItem> notes)
    : this._(status: KnowledgeNoteRemoteLoadStatus.success, notes: notes);

  const KnowledgeNoteRemoteLoadResult.unavailable(String errorCode)
    : this._(
        status: KnowledgeNoteRemoteLoadStatus.unavailable,
        errorCode: errorCode,
      );

  const KnowledgeNoteRemoteLoadResult.failure(String errorCode)
    : this._(
        status: KnowledgeNoteRemoteLoadStatus.failure,
        errorCode: errorCode,
      );

  final KnowledgeNoteRemoteLoadStatus status;
  final List<V3FeedItem> notes;
  final String? errorCode;
}

abstract interface class KnowledgeNoteRemoteListPort {
  Future<KnowledgeNoteRemoteLoadResult> loadNotes();
}

/// Reads one already-bound owned HNote without creating or retrying a task.
abstract interface class KnowledgeNoteRemoteDetailPort {
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  });
}

enum KnowledgeNoteLifecycleStatus { success, unavailable, failure }

@immutable
final class KnowledgeNoteLifecycleResult {
  const KnowledgeNoteLifecycleResult.success({
    this.note,
    this.noteRevisionId,
    this.rawPartRevisionId,
    this.etag,
    this.contentCursor,
  }) : status = KnowledgeNoteLifecycleStatus.success,
       errorCode = null;

  const KnowledgeNoteLifecycleResult.unavailable(String errorCode)
    : status = KnowledgeNoteLifecycleStatus.unavailable,
      note = null,
      noteRevisionId = null,
      rawPartRevisionId = null,
      etag = null,
      contentCursor = null,
      errorCode = errorCode;

  const KnowledgeNoteLifecycleResult.failure(String errorCode)
    : status = KnowledgeNoteLifecycleStatus.failure,
      note = null,
      noteRevisionId = null,
      rawPartRevisionId = null,
      etag = null,
      contentCursor = null,
      errorCode = errorCode;

  final KnowledgeNoteLifecycleStatus status;
  final V3FeedItem? note;
  final String? noteRevisionId;
  final String? rawPartRevisionId;
  final String? etag;
  final String? contentCursor;
  final String? errorCode;

  bool get isSuccess => status == KnowledgeNoteLifecycleStatus.success;
}

/// Authoritative lifecycle boundary for HNotes that already have a remote ID.
abstract interface class KnowledgeNoteLifecyclePort {
  Future<KnowledgeNoteLifecycleResult> tombstoneNote({
    required V3FeedItem note,
    required String idempotencyKey,
  });

  Future<KnowledgeNoteLifecycleResult> restoreNote({
    required V3FeedItem note,
    required String idempotencyKey,
  });
}

final class UnavailableKnowledgeNotePort implements KnowledgeNotePort {
  const UnavailableKnowledgeNotePort();

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    return const KnowledgeNotePortResult.unavailable();
  }
}

final class RemoteKnowledgeNotePort
    implements
        KnowledgeNotePort,
        KnowledgeNoteRemoteListPort,
        KnowledgeNoteRemoteDetailPort,
        KnowledgeNoteLifecyclePort {
  factory RemoteKnowledgeNotePort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) {
    return RemoteKnowledgeNotePort._(
      client: WorkspaceContentClient(apiClient),
      workspaceId: workspaceId,
    );
  }

  const RemoteKnowledgeNotePort._({
    required this._client,
    required this._workspaceId,
  });

  final WorkspaceContentClient _client;
  final String? Function() _workspaceId;

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return const KnowledgeNotePortResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }

    try {
      final remoteNoteId = _nonEmpty(request.remoteNoteId);
      if (remoteNoteId == null) {
        return await _createManualNote(workspaceId, request);
      }
      return await _updateManualNote(workspaceId, remoteNoteId, request);
    } on ArgumentError {
      _debugRemoteNoteWrite(
        'remote-hnotes failure code=KNOWLEDGE_NOTE_REQUEST_INVALID',
      );
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_REQUEST_INVALID',
      );
    } on FormatException {
      _debugRemoteNoteWrite(
        'remote-hnotes failure code=KNOWLEDGE_NOTE_RESPONSE_INVALID',
      );
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_RESPONSE_INVALID',
      );
    } on Object {
      _debugRemoteNoteWrite(
        'remote-hnotes failure code=KNOWLEDGE_NOTE_UPDATE_FAILED',
      );
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_UPDATE_FAILED',
      );
    }
  }

  @override
  Future<KnowledgeNoteLifecycleResult> tombstoneNote({
    required V3FeedItem note,
    required String idempotencyKey,
  }) async {
    final workspaceId = _activeWorkspaceId();
    final noteId = _nonEmpty(note.remoteNoteId);
    final etag = _nonEmpty(note.etag);
    if (workspaceId == null) {
      return const KnowledgeNoteLifecycleResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (noteId == null || etag == null || idempotencyKey.trim().isEmpty) {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_REQUEST_INVALID',
      );
    }
    try {
      _debugRemoteNoteWrite('remote-hnotes tombstone request');
      final response = await _client.deleteNote(
        workspaceId,
        noteId,
        etag: etag,
        idempotencyKey: idempotencyKey,
      );
      if (!response.ok || response.data == null) {
        return _lifecycleFailure(response);
      }
      final event = response.data!;
      final revisionId = _nonEmpty(event.revisionId);
      if (event.workspaceId != workspaceId ||
          event.objectKind != 'hnote' ||
          event.objectId != noteId ||
          event.changeType != 'tombstoned' ||
          !event.tombstone ||
          revisionId == null) {
        return const KnowledgeNoteLifecycleResult.failure(
          'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
        );
      }
      final exact = await _client.note(
        workspaceId,
        noteId,
        revisionId: revisionId,
      );
      final tombstoned = exact.data;
      if (!exact.ok || tombstoned == null) {
        return _lifecycleFailure(exact);
      }
      if (tombstoned.workspaceId != workspaceId ||
          tombstoned.noteId != noteId ||
          tombstoned.state != 'tombstoned' ||
          tombstoned.noteRevisionId != revisionId ||
          tombstoned.contentCursor != event.cursor ||
          _nonEmpty(tombstoned.etag) == null) {
        return const KnowledgeNoteLifecycleResult.failure(
          'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
        );
      }
      _debugRemoteNoteWrite('remote-hnotes tombstone success');
      return KnowledgeNoteLifecycleResult.success(
        noteRevisionId: tombstoned.noteRevisionId,
        rawPartRevisionId: tombstoned.raw.partRevisionId,
        etag: tombstoned.etag,
        contentCursor: tombstoned.contentCursor,
      );
    } on ArgumentError {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_REQUEST_INVALID',
      );
    } on FormatException {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
      );
    } on Object {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_TOMBSTONE_FAILED',
      );
    }
  }

  @override
  Future<KnowledgeNoteLifecycleResult> restoreNote({
    required V3FeedItem note,
    required String idempotencyKey,
  }) async {
    final workspaceId = _activeWorkspaceId();
    final noteId = _nonEmpty(note.remoteNoteId);
    final etag = _nonEmpty(note.etag);
    if (workspaceId == null) {
      return const KnowledgeNoteLifecycleResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (noteId == null || etag == null || idempotencyKey.trim().isEmpty) {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_REQUEST_INVALID',
      );
    }
    try {
      _debugRemoteNoteWrite('remote-hnotes restore request');
      final response = await _client.restoreNote(
        workspaceId,
        noteId,
        etag: etag,
        idempotencyKey: idempotencyKey,
      );
      if (!response.ok || response.data == null) {
        return _lifecycleFailure(response);
      }
      final restored = response.data!;
      if (restored.noteId != noteId || !_isReadableHNoteState(restored.state)) {
        return const KnowledgeNoteLifecycleResult.failure(
          'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
        );
      }
      late final V3FeedItem mapped;
      if (_hasEmbeddedHNoteParts(restored)) {
        mapped = mapRemoteHNoteToFeedItem(
          restored,
          localId: note.id,
          fallback: note,
          legacyRemoteRevision: note.remoteRevision ?? 0,
        );
      } else {
        final loaded = await _loadCurrentNoteBinding(
          workspaceId,
          noteId,
          localId: note.id,
          fallback: note,
        );
        if (loaded.status != KnowledgeNotePortStatus.success ||
            loaded.remoteNote == null) {
          return _lifecycleFailureFromNoteResult(loaded);
        }
        mapped = loaded.remoteNote!;
      }
      _debugRemoteNoteWrite('remote-hnotes restore success');
      return KnowledgeNoteLifecycleResult.success(
        note: mapped,
        noteRevisionId: mapped.noteRevisionId,
        rawPartRevisionId: mapped.rawPartRevisionId,
        etag: mapped.etag,
        contentCursor: mapped.contentCursor,
      );
    } on ArgumentError {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_REQUEST_INVALID',
      );
    } on FormatException {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_LIFECYCLE_RESPONSE_INVALID',
      );
    } on Object {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_RESTORE_FAILED',
      );
    }
  }

  Future<KnowledgeNotePortResult> _createManualNote(
    String workspaceId,
    KnowledgeNoteUpdateRequest request,
  ) async {
    const operation = 'create';
    _debugRemoteNoteWrite('remote-hnotes $operation request');
    final created = await _client.createManualNote(
      workspaceId,
      title: request.draft.title,
      contentMarkdown: request.draft.rawBody,
      idempotencyKey: _mutationKey(
        workspaceId: workspaceId,
        request: request,
        operation: 'manual-create',
      ),
    );
    if (!created.ok || created.data == null) {
      return _writeFailureAndLog(operation, created);
    }

    final noteId = _legacyRequiredText(
      _legacyWorkspaceNote(created.data!.fields),
      'noteId',
    );
    final accepted = await _loadCurrentNoteBinding(
      workspaceId,
      noteId,
      localId: request.noteId,
      fallback: request.localNote,
    );
    if (accepted.status != KnowledgeNotePortStatus.success) {
      return _logSnapshotFailure(operation, accepted);
    }
    _debugRemoteNoteWrite('remote-hnotes $operation success');
    return accepted;
  }

  Future<KnowledgeNotePortResult> _updateManualNote(
    String workspaceId,
    String remoteNoteId,
    KnowledgeNoteUpdateRequest request,
  ) async {
    const operation = 'update';
    _debugRemoteNoteWrite('remote-hnotes $operation request');
    final current = await _loadLegacySnapshot(workspaceId, remoteNoteId);
    if (current.failure != null) {
      return _logSnapshotFailure(operation, current.failure!);
    }
    final snapshot = current.value!;
    final rawOnly = request.localNote?.pendingRawOnlyUpdate == true;
    if (rawOnly &&
        snapshot.rawMarkdown != request.draft.rawBody &&
        (_nonEmpty(request.rawPartRevisionId) == null ||
            snapshot.rawPartRevisionId != request.rawPartRevisionId)) {
      return _loadLegacyConflict(workspaceId, remoteNoteId, request);
    }

    if (!rawOnly &&
        _legacyRequiredText(snapshot.note, 'title') != request.draft.title) {
      final etag = _nonEmpty(snapshot.metadataEtag);
      if (etag == null) {
        return const KnowledgeNotePortResult.failure(
          'KNOWLEDGE_NOTE_REMOTE_BINDING_INVALID',
        );
      }
      final metadata = await _client.updateLegacyNoteMetadata(
        workspaceId,
        remoteNoteId,
        title: request.draft.title,
        etag: etag,
        idempotencyKey: _mutationKey(
          workspaceId: workspaceId,
          request: request,
          operation: 'update-metadata',
        ),
      );
      if (!metadata.ok || metadata.data == null) {
        if (_isPreconditionFailure(metadata)) {
          return _loadLegacyConflict(workspaceId, remoteNoteId, request);
        }
        return _writeFailureAndLog(operation, metadata);
      }
    }

    if (snapshot.rawMarkdown != request.draft.rawBody) {
      final etag = _nonEmpty(snapshot.rawPartEtag);
      if (etag == null) {
        return const KnowledgeNotePortResult.failure(
          'KNOWLEDGE_NOTE_REMOTE_BINDING_INVALID',
        );
      }
      final raw = await _client.updateLegacyRawNotePart(
        workspaceId,
        remoteNoteId,
        contentMarkdown: request.draft.rawBody,
        basePartRevisionId: snapshot.rawPartRevisionId,
        etag: etag,
        idempotencyKey: _mutationKey(
          workspaceId: workspaceId,
          request: request,
          operation: 'update-raw',
        ),
      );
      if (!raw.ok || raw.data == null) {
        if (_isPreconditionFailure(raw)) {
          return _loadLegacyConflict(workspaceId, remoteNoteId, request);
        }
        return _writeFailureAndLog(operation, raw);
      }
    }

    final accepted = await _loadCurrentNoteBinding(
      workspaceId,
      remoteNoteId,
      localId: request.noteId,
      fallback: request.localNote,
    );
    if (accepted.status != KnowledgeNotePortStatus.success) {
      return _logSnapshotFailure(operation, accepted);
    }
    _debugRemoteNoteWrite('remote-hnotes $operation success');
    return accepted;
  }

  KnowledgeNotePortResult _writeFailureAndLog(
    String operation,
    ApiResult<Object?> result,
  ) {
    final failure = _writeFailure(result);
    _debugRemoteNoteWrite(
      'remote-hnotes $operation ${failure.status.name} '
      'code=${failure.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED'}',
    );
    return failure;
  }

  KnowledgeNotePortResult _logSnapshotFailure(
    String operation,
    KnowledgeNotePortResult failure,
  ) {
    _debugRemoteNoteWrite(
      'remote-hnotes $operation ${failure.status.name} '
      'code=${failure.errorCode ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED'}',
    );
    return failure;
  }

  Future<_LegacyWorkspaceNoteSnapshotResult> _loadLegacySnapshot(
    String workspaceId,
    String noteId, {
    Map<String, Object?>? note,
    String? metadataEtag,
  }) async {
    var resolvedNote = note;
    if (resolvedNote == null) {
      final detail = await _client.legacyNote(workspaceId, noteId);
      if (!detail.ok || detail.data == null) {
        return _LegacyWorkspaceNoteSnapshotResult.failure(
          _writeFailure(detail),
        );
      }
      final fields = detail.data!.fields;
      if (_isSparseRemoteHNote(fields)) {
        if (!_isReadableHNoteState(_legacyRequiredText(fields, 'state'))) {
          return const _LegacyWorkspaceNoteSnapshotResult.failure(
            KnowledgeNotePortResult.failure('KNOWLEDGE_NOTE_RESPONSE_INVALID'),
          );
        }
        resolvedNote = fields;
      } else if (_isLegacyWorkspaceNote(fields)) {
        resolvedNote = _legacyWorkspaceNote(fields);
      } else {
        return const _LegacyWorkspaceNoteSnapshotResult.failure(
          KnowledgeNotePortResult.failure('KNOWLEDGE_NOTE_RESPONSE_INVALID'),
        );
      }
      metadataEtag ??=
          _headerValue(detail.responseHeaders, 'ETag') ??
          _legacyOptionalText(resolvedNote, 'etag');
    }
    final raw = _isSparseRemoteHNote(resolvedNote)
        ? await _loadHNotePart(
            workspaceId,
            noteId,
            'raw',
            partRevisionId: _legacyRequiredText(
              resolvedNote,
              'rawPartRevisionId',
            ),
          )
        : await _loadRawNotePart(workspaceId, noteId);
    if (raw.failure != null) {
      return _LegacyWorkspaceNoteSnapshotResult.failure(raw.failure!);
    }
    if (_isSparseRemoteHNote(resolvedNote) &&
        raw.value!.partRevisionId !=
            _legacyRequiredText(resolvedNote, 'rawPartRevisionId')) {
      return const _LegacyWorkspaceNoteSnapshotResult.failure(
        KnowledgeNotePortResult.failure('KNOWLEDGE_NOTE_PART_VERSION_STALE'),
      );
    }
    return _LegacyWorkspaceNoteSnapshotResult.success(
      _LegacyWorkspaceNoteSnapshot(
        note: resolvedNote,
        rawMarkdown: raw.value!.markdown,
        rawPartRevisionId: raw.value!.partRevisionId,
        metadataEtag: metadataEtag,
        rawPartEtag: raw.value!.etag,
      ),
    );
  }

  Future<_RemoteRawNotePartResult> _loadRawNotePart(
    String workspaceId,
    String noteId, {
    String? requestedPartRevisionId,
  }) async {
    final raw = await _client.legacyRawNotePart(
      workspaceId,
      noteId,
      partRevisionId: requestedPartRevisionId,
    );
    if (!raw.ok || raw.data == null) {
      return _RemoteRawNotePartResult.failure(_writeFailure(raw));
    }
    final fields = raw.data!.fields;
    final part = fields['part'] is Map ? _requiredObject(fields, 'part') : null;
    final markdown = fields['markdown'] is String
        ? _legacyText(fields, 'markdown')
        : _legacyText(fields, 'contentMarkdown');
    final partRevisionId = fields['partRevisionId'] is String
        ? _legacyRequiredText(fields, 'partRevisionId')
        : _legacyRequiredText(part!, 'currentPartRevisionId');
    return _RemoteRawNotePartResult.success(
      _RemoteRawNotePart(
        markdown: markdown,
        partRevisionId: partRevisionId,
        etag:
            _headerValue(raw.responseHeaders, 'ETag') ??
            _legacyOptionalText(fields, 'etag'),
      ),
    );
  }

  Future<KnowledgeNotePortResult> _loadLegacyConflict(
    String workspaceId,
    String remoteNoteId,
    KnowledgeNoteUpdateRequest request,
  ) async {
    final current = await _loadCurrentNoteBinding(
      workspaceId,
      remoteNoteId,
      localId: request.noteId,
      fallback: request.localNote,
    );
    final remote = current.remoteNote;
    return current.status == KnowledgeNotePortStatus.success && remote != null
        ? KnowledgeNotePortResult.conflict(remote)
        : current;
  }

  Future<KnowledgeNotePortResult> _loadCurrentNoteBinding(
    String workspaceId,
    String noteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async {
    final detail = await _client.legacyNote(workspaceId, noteId);
    if (!detail.ok || detail.data == null) return _writeFailure(detail);
    final fields = detail.data!.fields;
    if (_isSparseRemoteHNote(fields)) {
      if (!_isReadableHNoteState(_legacyRequiredText(fields, 'state'))) {
        return const KnowledgeNotePortResult.failure(
          'KNOWLEDGE_NOTE_RESPONSE_INVALID',
        );
      }
      final parts = await _loadSparseHNoteParts(
        workspaceId,
        noteId,
        rawPartRevisionId: _legacyRequiredText(fields, 'rawPartRevisionId'),
        outlinePartRevisionId: _legacyOptionalText(
          fields,
          'outlinePartRevisionId',
        ),
        germinationPartRevisionId: _legacyOptionalText(
          fields,
          'germinationPartRevisionId',
        ),
      );
      if (parts.failure != null) return parts.failure!;
      return KnowledgeNotePortResult.success(
        _mapSparseRemoteHNoteToFeedItem(
          fields,
          raw: parts.value!.raw,
          outline: parts.value!.outline,
          germination: parts.value!.germination,
          localId: localId,
          fallback: fallback,
        ),
      );
    }
    if (_isLegacyWorkspaceNote(fields)) {
      final note = _legacyWorkspaceNote(fields);
      final snapshot = await _loadLegacySnapshot(
        workspaceId,
        noteId,
        note: note,
        metadataEtag:
            _headerValue(detail.responseHeaders, 'ETag') ??
            _legacyOptionalText(note, 'etag'),
      );
      if (snapshot.failure != null) return snapshot.failure!;
      return KnowledgeNotePortResult.success(
        _mapLegacyWorkspaceNoteToFeedItem(
          snapshot.value!,
          localId: localId,
          fallback: fallback,
        ),
      );
    }
    return const KnowledgeNotePortResult.failure(
      'KNOWLEDGE_NOTE_RESPONSE_INVALID',
    );
  }

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async {
    final workspaceId = _activeWorkspaceId();
    final noteId = _nonEmpty(remoteNoteId);
    if (workspaceId == null) {
      return const KnowledgeNotePortResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    if (noteId == null || localId.trim().isEmpty) {
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_REQUEST_INVALID',
      );
    }

    try {
      final detail = await _client.note(workspaceId, noteId);
      if (detail.ok &&
          detail.data != null &&
          _hasEmbeddedHNoteParts(detail.data!)) {
        final remote = detail.data!;
        if (remote.noteId != noteId || !_isReadableHNoteState(remote.state)) {
          return const KnowledgeNotePortResult.failure(
            'KNOWLEDGE_NOTE_RESPONSE_INVALID',
          );
        }
        return KnowledgeNotePortResult.success(
          mapRemoteHNoteToFeedItem(
            remote,
            localId: localId.trim(),
            fallback: fallback,
            legacyRemoteRevision: fallback?.remoteRevision ?? 0,
          ),
        );
      }

      // The deployed production contract may return a sparse HNote head.
      return _loadCurrentNoteBinding(
        workspaceId,
        noteId,
        localId: localId.trim(),
        fallback: fallback,
      );
    } on FormatException {
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_RESPONSE_INVALID',
      );
    } on Object {
      return const KnowledgeNotePortResult.failure(
        'KNOWLEDGE_NOTE_LOAD_FAILED',
      );
    }
  }

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      _debugRemoteNoteLoad(
        'remote-hnotes skipped code=WORKSPACE_CONTEXT_UNAVAILABLE',
      );
      return const KnowledgeNoteRemoteLoadResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }

    try {
      _debugRemoteNoteLoad('remote-hnotes request');
      final notes = <V3FeedItem>[];
      final observedCursors = <String>{};
      String? cursor;
      do {
        final page = await _client.notes(workspaceId, cursor: cursor);
        if (!page.ok || page.data == null) {
          final failure = _loadFailure(page);
          _debugRemoteNoteLoad(
            'remote-hnotes ${failure.status.name} '
            'code=${failure.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED'}',
          );
          return failure;
        }
        for (final item in page.data!.items) {
          if (_isSparseRemoteHNote(item.fields)) {
            if (!_isReadableHNoteState(
              _legacyRequiredText(item.fields, 'state'),
            )) {
              return const KnowledgeNoteRemoteLoadResult.failure(
                'KNOWLEDGE_NOTE_RESPONSE_INVALID',
              );
            }
            final noteId = _legacyRequiredText(item.fields, 'noteId');
            final parts = await _loadSparseHNoteParts(
              workspaceId,
              noteId,
              rawPartRevisionId: _legacyRequiredText(
                item.fields,
                'rawPartRevisionId',
              ),
              outlinePartRevisionId: _legacyOptionalText(
                item.fields,
                'outlinePartRevisionId',
              ),
              germinationPartRevisionId: _legacyOptionalText(
                item.fields,
                'germinationPartRevisionId',
              ),
            );
            if (parts.failure != null) {
              return _remoteLoadFromWriteFailure(parts.failure!);
            }
            notes.add(
              _mapSparseRemoteHNoteToFeedItem(
                item.fields,
                raw: parts.value!.raw,
                outline: parts.value!.outline,
                germination: parts.value!.germination,
                localId: noteId,
              ),
            );
            continue;
          }
          if (_isLegacyWorkspaceNote(item.fields)) {
            final note = _legacyWorkspaceNote(item.fields);
            final noteId = _legacyRequiredText(note, 'noteId');
            final snapshot = await _loadLegacySnapshot(
              workspaceId,
              noteId,
              note: note,
            );
            if (snapshot.failure != null) {
              final failure = snapshot.failure!;
              return failure.status == KnowledgeNotePortStatus.unavailable
                  ? KnowledgeNoteRemoteLoadResult.unavailable(
                      failure.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED',
                    )
                  : KnowledgeNoteRemoteLoadResult.failure(
                      failure.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED',
                    );
            }
            notes.add(
              _mapLegacyWorkspaceNoteToFeedItem(
                snapshot.value!,
                localId: noteId,
              ),
            );
            continue;
          }
          final note = SharedHNote.fromJson(item.fields);
          if (!_isReadableHNoteState(note.state)) {
            return const KnowledgeNoteRemoteLoadResult.failure(
              'KNOWLEDGE_NOTE_RESPONSE_INVALID',
            );
          }
          notes.add(
            mapRemoteHNoteToFeedItem(
              note,
              localId: note.noteId,
              legacyRemoteRevision: 0,
            ),
          );
        }
        final nextCursor = _nonEmpty(page.data!.nextCursor);
        if (nextCursor == null) break;
        if (!observedCursors.add(nextCursor)) {
          return const KnowledgeNoteRemoteLoadResult.failure(
            'KNOWLEDGE_NOTE_CURSOR_INVALID',
          );
        }
        cursor = nextCursor;
      } while (true);
      _debugRemoteNoteLoad('remote-hnotes success count=${notes.length}');
      return KnowledgeNoteRemoteLoadResult.success(
        List<V3FeedItem>.unmodifiable(notes),
      );
    } on FormatException {
      _debugRemoteNoteLoad(
        'remote-hnotes failure code=KNOWLEDGE_NOTE_RESPONSE_INVALID',
      );
      return const KnowledgeNoteRemoteLoadResult.failure(
        'KNOWLEDGE_NOTE_RESPONSE_INVALID',
      );
    } on Object {
      _debugRemoteNoteLoad(
        'remote-hnotes failure code=KNOWLEDGE_NOTE_LOAD_FAILED',
      );
      return const KnowledgeNoteRemoteLoadResult.failure(
        'KNOWLEDGE_NOTE_LOAD_FAILED',
      );
    }
  }

  Future<_SparseHNotePartsResult> _loadSparseHNoteParts(
    String workspaceId,
    String noteId, {
    required String rawPartRevisionId,
    required String? outlinePartRevisionId,
    required String? germinationPartRevisionId,
  }) async {
    final raw = await _loadHNotePart(
      workspaceId,
      noteId,
      'raw',
      partRevisionId: rawPartRevisionId,
    );
    if (raw.failure != null) {
      return _SparseHNotePartsResult.failure(raw.failure!);
    }
    final outline = await _loadOptionalHNotePart(
      workspaceId,
      noteId,
      'outline',
      partRevisionId: outlinePartRevisionId,
    );
    if (outline.failure != null) {
      return _SparseHNotePartsResult.failure(outline.failure!);
    }
    final germination = await _loadOptionalHNotePart(
      workspaceId,
      noteId,
      'germination',
      partRevisionId: germinationPartRevisionId,
    );
    if (germination.failure != null) {
      return _SparseHNotePartsResult.failure(germination.failure!);
    }
    if (raw.value!.partRevisionId != rawPartRevisionId ||
        (outlinePartRevisionId != null &&
            outline.value!.partRevisionId != outlinePartRevisionId) ||
        (germinationPartRevisionId != null &&
            germination.value!.partRevisionId != germinationPartRevisionId)) {
      return const _SparseHNotePartsResult.failure(
        KnowledgeNotePortResult.failure('KNOWLEDGE_NOTE_PART_VERSION_STALE'),
      );
    }
    return _SparseHNotePartsResult.success(
      _SparseHNoteParts(
        raw: raw.value!,
        outline: outline.value!,
        germination: germination.value!,
      ),
    );
  }

  Future<_RemoteRawNotePartResult> _loadOptionalHNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String? partRevisionId,
  }) {
    final revisionId = _nonEmpty(partRevisionId);
    if (revisionId == null) {
      return Future<_RemoteRawNotePartResult>.value(
        const _RemoteRawNotePartResult.success(
          _RemoteRawNotePart(markdown: '', partRevisionId: '', etag: null),
        ),
      );
    }
    return _loadHNotePart(
      workspaceId,
      noteId,
      part,
      partRevisionId: revisionId,
    );
  }

  Future<_RemoteRawNotePartResult> _loadHNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async {
    final response = await _client.notePart(
      workspaceId,
      noteId,
      part,
      partRevisionId: partRevisionId,
    );
    if (!response.ok || response.data == null) {
      return _RemoteRawNotePartResult.failure(_writeFailure(response));
    }
    final data = response.data!;
    return _RemoteRawNotePartResult.success(
      _RemoteRawNotePart(
        markdown: data.markdown,
        partRevisionId: data.partRevisionId,
        etag: data.etag,
      ),
    );
  }

  KnowledgeNoteRemoteLoadResult _remoteLoadFromWriteFailure(
    KnowledgeNotePortResult failure,
  ) => failure.status == KnowledgeNotePortStatus.unavailable
      ? KnowledgeNoteRemoteLoadResult.unavailable(
          failure.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED',
        )
      : KnowledgeNoteRemoteLoadResult.failure(
          failure.errorCode ?? 'KNOWLEDGE_NOTE_LOAD_FAILED',
        );

  String? _activeWorkspaceId() {
    final value = _nonEmpty(_workspaceId());
    if (value == null || !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
      return null;
    }
    return value;
  }
}

void _debugRemoteNoteLoad(String message) {
  if (kDebugMode) debugPrint('[KnowledgeAssets] $message');
}

void _debugRemoteNoteWrite(String message) {
  if (kDebugMode) debugPrint('[KnowledgeAssets] $message');
}

KnowledgeNotePortResult _writeFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'KNOWLEDGE_NOTE_UPDATE_FAILED';
  return _isUnavailableCode(code)
      ? KnowledgeNotePortResult.unavailable(code)
      : KnowledgeNotePortResult.failure(code);
}

KnowledgeNoteLifecycleResult _lifecycleFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'WORKSPACE_NOTE_LIFECYCLE_FAILED';
  return _isUnavailableCode(code)
      ? KnowledgeNoteLifecycleResult.unavailable(code)
      : KnowledgeNoteLifecycleResult.failure(code);
}

KnowledgeNoteLifecycleResult _lifecycleFailureFromNoteResult(
  KnowledgeNotePortResult result,
) {
  final code = result.errorCode ?? 'WORKSPACE_NOTE_LIFECYCLE_FAILED';
  return result.status == KnowledgeNotePortStatus.unavailable
      ? KnowledgeNoteLifecycleResult.unavailable(code)
      : KnowledgeNoteLifecycleResult.failure(code);
}

KnowledgeNoteRemoteLoadResult _loadFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'KNOWLEDGE_NOTE_LOAD_FAILED';
  return _isUnavailableCode(code)
      ? KnowledgeNoteRemoteLoadResult.unavailable(code)
      : KnowledgeNoteRemoteLoadResult.failure(code);
}

bool _isPreconditionFailure(ApiResult<Object?> result) =>
    result.status == 412 || result.error?.code == 'PRECONDITION_FAILED';

bool _isUnavailableCode(String code) =>
    code == 'WORKSPACE_CONTEXT_UNAVAILABLE' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code == 'API_ENDPOINT_RETIRED' ||
    code == 'API_ENDPOINT_PROHIBITED' ||
    code.endsWith('_UNAVAILABLE');

bool _hasEmbeddedHNoteParts(SharedHNote note) =>
    hasEmbeddedWorkspaceHNoteParts(note);

bool _isReadableHNoteState(String state) =>
    state == 'active' || state == 'live';

String _mutationKey({
  required String workspaceId,
  required KnowledgeNoteUpdateRequest request,
  required String operation,
}) {
  final durableIdentity = _nonEmpty(request.mutationIdentity);
  final source = <String>[
    'mobile-hnote',
    operation,
    workspaceId,
    if (durableIdentity != null)
      durableIdentity
    else ...<String>[
      request.noteId,
      request.remoteNoteId ?? '',
      request.localRevision.toString(),
    ],
  ].join(':');
  return 'mobile-hnote-${sha256.convert(utf8.encode(source))}';
}

V3FeedItem mapRemoteHNoteToFeedItem(
  SharedHNote note, {
  required String localId,
  V3FeedItem? fallback,
  required int legacyRemoteRevision,
}) {
  final createdAt = note.createdAt ?? fallback?.createdAt;
  final updatedAt = note.updatedAt ?? fallback?.updatedAt ?? createdAt;
  if (createdAt == null || updatedAt == null) {
    throw const FormatException('HNote timestamps are required');
  }
  final summary = _nonEmpty(note.outline.markdown);
  final germination = _nonEmpty(note.germination.markdown);
  final keepLocalFayaReport =
      germination == null &&
      fallback?.sproutReport != null &&
      fallback?.rawPartRevisionId == note.raw.partRevisionId;
  final activeDerivedTasks = note.activeDerivedTasks;
  final sourceKind =
      _nonEmpty(note.sourceKind) ??
      _nonEmpty(note.sourceRef?.kind) ??
      _nonEmpty(fallback?.remoteSourceKind);
  final recordingId = _recordingIdFromRemoteProvenance(
    sourceKind: sourceKind,
    sourceRefKind: note.sourceRef?.kind,
    sourceRefId: note.sourceRef?.id,
    fallback: fallback,
  );
  return V3FeedItem(
    id: localId,
    title: note.title,
    source: _materialSourceForHNote(sourceKind, fallback?.source),
    createdAt: createdAt,
    updatedAt: updatedAt,
    rawBody: note.raw.markdown,
    summaryBody: summary,
    recordingId: recordingId,
    minutesStatus: fallback?.minutesStatus,
    summaryStatus: fallback?.summaryStatus,
    linkedMaterials: fallback?.linkedMaterials ?? const <V3LinkedMaterialRef>[],
    sproutStatus: keepLocalFayaReport
        ? fallback!.sproutStatus
        : germination == null
        ? V3SproutTaskStatus.notStarted
        : V3SproutTaskStatus.succeeded,
    sproutReport: keepLocalFayaReport
        ? fallback!.sproutReport
        : germination == null
        ? null
        : V3SproutReport(
            id: 'remote-${note.noteId}-${note.germination.partRevisionId}',
            noteId: localId,
            title: note.title,
            markdown: germination,
            generatedAt: updatedAt,
          ),
    mediaAttachments: fallback?.mediaAttachments ?? const <V3MediaAttachment>[],
    remoteMediaAttachments: _remoteImageAttachments(note.resourceRefs),
    ownership: V3NoteOwnership.mine,
    contentLineId: fallback?.contentLineId,
    contentLineName: fallback?.contentLineName,
    folderId: note.folderId,
    folderName: fallback?.folderId == note.folderId
        ? fallback?.folderName
        : null,
    copiedFromContentId: fallback?.copiedFromContentId,
    publicUrl: _remoteNotePublicUrl(
      sourceKind: sourceKind,
      rawMarkdown: note.raw.markdown,
      fallback: fallback,
      structuredSourceUrl: note.sourceRef?.kind.trim() == 'url_import'
          ? note.sourceRef?.id
          : null,
    ),
    topics: fallback?.topics ?? const <String>[],
    localRevision: fallback?.localRevision ?? 0,
    remoteRevision: legacyRemoteRevision,
    remoteNoteId: note.noteId,
    remoteSourceKind: sourceKind,
    noteRevisionId: note.noteRevisionId,
    rawPartRevisionId: note.raw.partRevisionId,
    outlinePartRevisionId: _nonEmpty(note.outline.partRevisionId),
    germinationPartRevisionId: keepLocalFayaReport
        ? fallback!.germinationPartRevisionId
        : _nonEmpty(note.germination.partRevisionId),
    etag: note.etag,
    contentCursor: note.contentCursor,
    activeDerivedTasks: activeDerivedTasks == null
        ? fallback?.activeDerivedTasks ?? const <V3ActiveDerivedTask>[]
        : List<V3ActiveDerivedTask>.unmodifiable(
            activeDerivedTasks
                .where((task) => !task.isTerminal)
                .map(
                  (task) => V3ActiveDerivedTask(
                    fileAgentRunId: task.fileAgentRunId,
                    agentRunId: task.agentRunId,
                    stage: switch (task.stage) {
                      'outline' => V3DerivedTaskStage.outline,
                      'sprout' => V3DerivedTaskStage.sprout,
                      _ => throw const FormatException(
                        'unsupported active derived task stage',
                      ),
                    },
                    status: task.status,
                  ),
                )
                .toList(growable: false),
          ),
    activeDerivedTasksAuthoritative: activeDerivedTasks != null,
    syncState: NoteSyncState.synced,
    publicationId: fallback?.publicationId,
    articleId: fallback?.articleId,
    articleRevisionId: fallback?.articleRevisionId,
    subscriptionArticleAssets:
        fallback?.subscriptionArticleAssets ??
        const <V3SubscriptionArticleAssetRef>[],
    author: fallback?.author,
    contentOrigin: fallback?.contentOrigin ?? V3ContentOrigin.standard,
  );
}

V3MaterialSource _materialSourceForHNote(
  String? sourceKind,
  V3MaterialSource? fallback,
) => switch (sourceKind?.trim()) {
  'manual' => V3MaterialSource.note,
  'chat_excerpt' => V3MaterialSource.chatExcerpt,
  'recording' => V3MaterialSource.recordingCard,
  'url_import' => V3MaterialSource.link,
  'note_import' => V3MaterialSource.documentImport,
  'material_migration' => V3MaterialSource.materialMigration,
  'subscription_article' => V3MaterialSource.subscription,
  'topic_collision' => V3MaterialSource.topicCollision,
  null || '' => fallback ?? V3MaterialSource.note,
  _ => V3MaterialSource.other,
};

String? _remoteNotePublicUrl({
  required String? sourceKind,
  required String rawMarkdown,
  required V3FeedItem? fallback,
  String? structuredSourceUrl,
}) {
  final normalizedSourceKind = _nonEmpty(sourceKind);
  final isUrlImport =
      normalizedSourceKind == 'url_import' ||
      (normalizedSourceKind == null && fallback?.isLinkImportSource == true);
  if (!isUrlImport) return fallback?.publicUrl;
  return normalizeV3PublicSourceUrl(structuredSourceUrl) ??
      normalizeV3PublicSourceUrl(fallback?.publicUrl) ??
      projectV3UrlImportRawContent(rawMarkdown).sourceUrl;
}

({String kind, String id})? _legacyHNoteSourceRef(Map<String, Object?> note) {
  final sourceRefValue = note['sourceRef'];
  if (sourceRefValue == null) return null;
  final sourceRef = _requiredObject(note, 'sourceRef');
  return (
    kind: _legacyRequiredText(sourceRef, 'kind'),
    id: _legacyRequiredText(sourceRef, 'id'),
  );
}

String? _recordingIdFromRemoteProvenance({
  required String? sourceKind,
  required String? sourceRefKind,
  required String? sourceRefId,
  required V3FeedItem? fallback,
  String? legacySourceObjectId,
}) {
  final fallbackId = _nonEmpty(fallback?.recordingId);
  if (_nonEmpty(sourceKind) != 'recording') return fallbackId;
  final normalizedSourceRefKind = _nonEmpty(sourceRefKind);
  if (normalizedSourceRefKind != null) {
    return normalizedSourceRefKind == 'recording'
        ? _safeRecordingSourceId(sourceRefId) ?? fallbackId
        : fallbackId;
  }
  return _safeRecordingSourceId(legacySourceObjectId) ?? fallbackId;
}

String? _safeRecordingSourceId(String? value) {
  final normalized = _nonEmpty(value);
  if (normalized == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

List<V3RemoteMediaAttachment> _remoteImageAttachments(
  Iterable<SharedHNoteResourceRef> refs,
) {
  return List<V3RemoteMediaAttachment>.unmodifiable(<V3RemoteMediaAttachment>[
    for (final ref in refs)
      if (ref.usage == 'inline_image' &&
          ref.mimeType.toLowerCase().startsWith('image/'))
        V3RemoteMediaAttachment(
          resourceId: ref.resourceId,
          displayName: ref.alt?.trim().isNotEmpty == true
              ? ref.alt!.trim()
              : '图片',
          mimeType: ref.mimeType,
          usage: ref.usage,
          anchor: ref.anchor,
        ),
  ]);
}

final class _LegacyWorkspaceNoteSnapshot {
  const _LegacyWorkspaceNoteSnapshot({
    required this.note,
    required this.rawMarkdown,
    required this.rawPartRevisionId,
    required this.metadataEtag,
    required this.rawPartEtag,
  });

  final Map<String, Object?> note;
  final String rawMarkdown;
  final String rawPartRevisionId;
  final String? metadataEtag;
  final String? rawPartEtag;
}

final class _LegacyWorkspaceNoteSnapshotResult {
  const _LegacyWorkspaceNoteSnapshotResult.success(this.value) : failure = null;

  const _LegacyWorkspaceNoteSnapshotResult.failure(this.failure) : value = null;

  final _LegacyWorkspaceNoteSnapshot? value;
  final KnowledgeNotePortResult? failure;
}

final class _RemoteRawNotePart {
  const _RemoteRawNotePart({
    required this.markdown,
    required this.partRevisionId,
    required this.etag,
  });

  final String markdown;
  final String partRevisionId;
  final String? etag;
}

final class _RemoteRawNotePartResult {
  const _RemoteRawNotePartResult.success(this.value) : failure = null;

  const _RemoteRawNotePartResult.failure(this.failure) : value = null;

  final _RemoteRawNotePart? value;
  final KnowledgeNotePortResult? failure;
}

final class _SparseHNoteParts {
  const _SparseHNoteParts({
    required this.raw,
    required this.outline,
    required this.germination,
  });

  final _RemoteRawNotePart raw;
  final _RemoteRawNotePart outline;
  final _RemoteRawNotePart germination;
}

final class _SparseHNotePartsResult {
  const _SparseHNotePartsResult.success(this.value) : failure = null;

  const _SparseHNotePartsResult.failure(this.failure) : value = null;

  final _SparseHNoteParts? value;
  final KnowledgeNotePortResult? failure;
}

V3FeedItem _mapLegacyWorkspaceNoteToFeedItem(
  _LegacyWorkspaceNoteSnapshot snapshot, {
  required String localId,
  V3FeedItem? fallback,
}) {
  final note = snapshot.note;
  final createdAt = _legacyDate(note['createdAt']) ?? fallback?.createdAt;
  final updatedAt =
      _legacyDate(note['updatedAt']) ?? fallback?.updatedAt ?? createdAt;
  if (createdAt == null || updatedAt == null) {
    throw const FormatException('Workspace Note timestamps are required');
  }
  final folderId = _legacyOptionalText(note, 'folderId');
  final sourceRef = _legacyHNoteSourceRef(note);
  final sourceKind =
      _legacyOptionalText(note, 'sourceKind') ??
      sourceRef?.kind ??
      fallback?.remoteSourceKind;
  final structuredSourceUrl =
      normalizeV3PublicSourceUrl(_legacyOptionalText(note, 'sourceObjectId')) ??
      (sourceRef?.kind == 'url_import' ? sourceRef?.id : null);
  final recordingId = _recordingIdFromRemoteProvenance(
    sourceKind: sourceKind,
    sourceRefKind: sourceRef?.kind,
    sourceRefId: sourceRef?.id,
    legacySourceObjectId: _legacyOptionalText(note, 'sourceObjectId'),
    fallback: fallback,
  );
  return V3FeedItem(
    id: localId,
    title: _legacyRequiredText(note, 'title'),
    source: _materialSourceForHNote(sourceKind, fallback?.source),
    createdAt: createdAt,
    updatedAt: updatedAt,
    rawBody: snapshot.rawMarkdown,
    summaryBody: fallback?.summaryBody,
    recordingId: recordingId,
    minutesStatus: fallback?.minutesStatus,
    summaryStatus: fallback?.summaryStatus,
    linkedMaterials: fallback?.linkedMaterials ?? const <V3LinkedMaterialRef>[],
    sproutStatus: fallback?.sproutStatus ?? V3SproutTaskStatus.notStarted,
    sproutReport: fallback?.sproutReport,
    mediaAttachments: fallback?.mediaAttachments ?? const <V3MediaAttachment>[],
    remoteMediaAttachments:
        fallback?.remoteMediaAttachments ?? const <V3RemoteMediaAttachment>[],
    ownership: V3NoteOwnership.mine,
    contentLineId: fallback?.contentLineId,
    contentLineName: fallback?.contentLineName,
    folderId: folderId,
    folderName: fallback?.folderId == folderId ? fallback?.folderName : null,
    copiedFromContentId: fallback?.copiedFromContentId,
    publicUrl: _remoteNotePublicUrl(
      sourceKind: sourceKind,
      rawMarkdown: snapshot.rawMarkdown,
      fallback: fallback,
      structuredSourceUrl: structuredSourceUrl,
    ),
    topics: fallback?.topics ?? const <String>[],
    localRevision: fallback?.localRevision ?? 0,
    remoteRevision: _legacyInteger(note['metadataVersion']) ?? 0,
    remoteNoteId: _legacyRequiredText(note, 'noteId'),
    remoteSourceKind: sourceKind,
    noteRevisionId: snapshot.rawPartRevisionId,
    rawPartRevisionId: snapshot.rawPartRevisionId,
    outlinePartRevisionId: fallback?.outlinePartRevisionId,
    germinationPartRevisionId: fallback?.germinationPartRevisionId,
    etag: snapshot.metadataEtag,
    contentCursor: _legacyBindingCursor(note, snapshot.rawPartRevisionId),
    syncState: NoteSyncState.synced,
    contentOrigin: fallback?.contentOrigin ?? V3ContentOrigin.standard,
  );
}

String _legacyBindingCursor(
  Map<String, Object?> note,
  String rawPartRevisionId,
) {
  final metadataVersion = _legacyInteger(note['metadataVersion']);
  if (metadataVersion == null || metadataVersion < 1) {
    throw const FormatException('metadataVersion must be a positive integer');
  }
  return <String>[
    'legacy-note',
    _legacyRequiredText(note, 'noteId'),
    metadataVersion.toString(),
    rawPartRevisionId,
  ].join(':');
}

V3FeedItem _mapSparseRemoteHNoteToFeedItem(
  Map<String, Object?> note, {
  required _RemoteRawNotePart raw,
  required _RemoteRawNotePart outline,
  required _RemoteRawNotePart germination,
  required String localId,
  V3FeedItem? fallback,
}) {
  final createdAt = _legacyDate(note['createdAt']) ?? fallback?.createdAt;
  final updatedAt =
      _legacyDate(note['updatedAt']) ?? fallback?.updatedAt ?? createdAt;
  if (createdAt == null || updatedAt == null) {
    throw const FormatException('HNote timestamps are required');
  }
  final folderId = _legacyOptionalText(note, 'folderId');
  final sourceRef = _legacyHNoteSourceRef(note);
  final sourceKind =
      _legacyOptionalText(note, 'sourceKind') ??
      sourceRef?.kind ??
      fallback?.remoteSourceKind;
  final structuredSourceUrl =
      normalizeV3PublicSourceUrl(_legacyOptionalText(note, 'sourceObjectId')) ??
      (sourceRef?.kind == 'url_import' ? sourceRef?.id : null);
  final recordingId = _recordingIdFromRemoteProvenance(
    sourceKind: sourceKind,
    sourceRefKind: sourceRef?.kind,
    sourceRefId: sourceRef?.id,
    legacySourceObjectId: _legacyOptionalText(note, 'sourceObjectId'),
    fallback: fallback,
  );
  return V3FeedItem(
    id: localId,
    title: _legacyRequiredText(note, 'title'),
    source: _materialSourceForHNote(sourceKind, fallback?.source),
    createdAt: createdAt,
    updatedAt: updatedAt,
    rawBody: raw.markdown,
    summaryBody: _nonEmpty(outline.markdown),
    recordingId: recordingId,
    minutesStatus: fallback?.minutesStatus,
    summaryStatus: fallback?.summaryStatus,
    linkedMaterials: fallback?.linkedMaterials ?? const <V3LinkedMaterialRef>[],
    sproutStatus: _nonEmpty(germination.markdown) == null
        ? V3SproutTaskStatus.notStarted
        : V3SproutTaskStatus.succeeded,
    sproutReport: _nonEmpty(germination.markdown) == null
        ? null
        : V3SproutReport(
            id: 'remote-${_legacyRequiredText(note, 'noteId')}-${germination.partRevisionId}',
            noteId: localId,
            title: _legacyRequiredText(note, 'title'),
            markdown: germination.markdown,
            generatedAt: updatedAt,
          ),
    mediaAttachments: fallback?.mediaAttachments ?? const <V3MediaAttachment>[],
    remoteMediaAttachments:
        fallback?.remoteMediaAttachments ?? const <V3RemoteMediaAttachment>[],
    ownership: V3NoteOwnership.mine,
    contentLineId: fallback?.contentLineId,
    contentLineName: fallback?.contentLineName,
    folderId: folderId,
    folderName: fallback?.folderId == folderId ? fallback?.folderName : null,
    copiedFromContentId: fallback?.copiedFromContentId,
    publicUrl: _remoteNotePublicUrl(
      sourceKind: sourceKind,
      rawMarkdown: raw.markdown,
      fallback: fallback,
      structuredSourceUrl: structuredSourceUrl,
    ),
    topics: fallback?.topics ?? const <String>[],
    localRevision: fallback?.localRevision ?? 0,
    remoteRevision: fallback?.remoteRevision ?? 0,
    remoteNoteId: _legacyRequiredText(note, 'noteId'),
    remoteSourceKind: sourceKind,
    noteRevisionId: _legacyRequiredText(note, 'noteRevisionId'),
    rawPartRevisionId: raw.partRevisionId,
    outlinePartRevisionId: _nonEmpty(outline.partRevisionId),
    germinationPartRevisionId: _nonEmpty(germination.partRevisionId),
    etag: _legacyOptionalText(note, 'etag') ?? raw.etag,
    contentCursor: _legacyOptionalText(note, 'contentCursor'),
    syncState: NoteSyncState.synced,
    publicationId: fallback?.publicationId,
    articleId: fallback?.articleId,
    articleRevisionId: fallback?.articleRevisionId,
    subscriptionArticleAssets:
        fallback?.subscriptionArticleAssets ??
        const <V3SubscriptionArticleAssetRef>[],
    author: fallback?.author,
    contentOrigin: fallback?.contentOrigin ?? V3ContentOrigin.standard,
  );
}

bool _isSparseRemoteHNote(Map<String, Object?> fields) =>
    fields['noteId'] is String &&
    fields['noteRevisionId'] is String &&
    fields['rawPartRevisionId'] is String &&
    fields['state'] is String;

bool _isLegacyWorkspaceNote(Map<String, Object?> fields) {
  final note = fields['note'];
  if (note is Map) {
    return note['noteId'] is String && note['metadataVersion'] is num;
  }
  return fields['noteId'] is String && fields['metadataVersion'] is num;
}

Map<String, Object?> _legacyWorkspaceNote(Map<String, Object?> fields) {
  final nested = fields['note'];
  return nested == null ? fields : _requiredObject(fields, 'note');
}

Map<String, Object?> _requiredObject(Map<String, Object?> fields, String key) {
  final value = fields[key];
  if (value is! Map) throw FormatException('$key must be an object');
  final object = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$key must use string keys');
    }
    object[entry.key as String] = entry.value;
  }
  return object;
}

String _legacyText(Map<String, Object?> fields, String key) {
  final value = fields[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String _legacyRequiredText(Map<String, Object?> fields, String key) {
  final value = _legacyText(fields, key).trim();
  if (value.isEmpty) throw FormatException('$key must be non-empty');
  return value;
}

String? _legacyOptionalText(Map<String, Object?> fields, String key) {
  final value = fields[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return _nonEmpty(value);
}

int? _legacyInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

DateTime? _legacyDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? _headerValue(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

enum KnowledgeNoteSyncOutcome {
  synced,
  conflict,
  unavailable,
  failed,
  notEditable,
  superseded,
}

@immutable
final class KnowledgeNoteConflictSnapshot {
  const KnowledgeNoteConflictSnapshot({
    required this.noteId,
    required this.localNote,
    required this.remoteNote,
    required this.baseRevision,
    required this.observedAt,
  });

  final String noteId;
  final V3FeedItem localNote;
  final V3FeedItem remoteNote;
  final int? baseRevision;
  final DateTime observedAt;
}

@immutable
final class KnowledgeNoteSyncResult {
  const KnowledgeNoteSyncResult({
    required this.outcome,
    this.note,
    this.conflict,
    this.errorCode,
  });

  final KnowledgeNoteSyncOutcome outcome;
  final V3FeedItem? note;
  final KnowledgeNoteConflictSnapshot? conflict;
  final String? errorCode;
}

enum KnowledgeNoteConflictResolution { useRemote, keepLocal }

enum KnowledgeNoteDeleteOutcome { deleted, notEditable, persistenceFailed }

@immutable
final class KnowledgeNoteDeleteResult {
  const KnowledgeNoteDeleteResult({
    required this.outcome,
    this.note,
    this.errorCode,
  });

  final KnowledgeNoteDeleteOutcome outcome;
  final V3FeedItem? note;
  final String? errorCode;
}
