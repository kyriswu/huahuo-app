import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../ui_v3/application/knowledge_library_controller.dart';
import '../../ui_v3/domain/feed_item_models.dart';
import '../data/material_ingestion_api.dart';
import '../data/material_ingestion_store.dart';
import '../domain/material_ingestion.dart';

typedef MaterialIngestionDelay = Future<void> Function(Duration duration);

final class MaterialIngestionCoordinator extends ChangeNotifier {
  factory MaterialIngestionCoordinator({
    required MaterialIngestionApiPort api,
    required MaterialIngestionStore store,
    required KnowledgeLibraryController knowledgeLibrary,
    required DiagnosticLogger logger,
    DateTime Function()? now,
    MaterialIngestionDelay? delay,
    int maxPollAttempts = 90,
  }) => MaterialIngestionCoordinator._(
    api,
    store,
    knowledgeLibrary,
    logger,
    now ?? DateTime.now,
    delay ?? ((duration) => Future<void>.delayed(duration)),
    maxPollAttempts,
  );

  MaterialIngestionCoordinator._(
    this._api,
    this._store,
    this._knowledgeLibrary,
    this._logger,
    this._now,
    this._delay,
    this.maxPollAttempts,
  );

  final MaterialIngestionApiPort _api;
  final MaterialIngestionStore _store;
  final KnowledgeLibraryController _knowledgeLibrary;
  final DiagnosticLogger _logger;
  final DateTime Function() _now;
  final MaterialIngestionDelay _delay;
  final int maxPollAttempts;
  final Set<String> _inFlight = <String>{};
  final Set<String> _refreshingLinkTasks = <String>{};
  final Set<String> _completionCommits = <String>{};
  final Map<String, Future<bool>> _outlineOwnershipRefreshes =
      <String, Future<bool>>{};
  final Map<String, GeneratedMemoryNote> _completedNotes =
      <String, GeneratedMemoryNote>{};
  String? _activeDraftId;
  bool _disposed = false;

  List<MaterialIngestionDraft> get drafts => _store.listAll();
  MaterialIngestionDraft? get activeDraft =>
      _activeDraftId == null ? null : _store.get(_activeDraftId!);
  GeneratedMemoryNote? completedNoteFor(String draftId) =>
      _completedNotes[draftId];
  bool isRefreshingLinkTask(String draftId) =>
      _refreshingLinkTasks.contains(draftId);

  Future<bool> refreshLinkOutlineOwnershipForNote(String noteId) {
    final normalizedNoteId = noteId.trim();
    if (_disposed || normalizedNoteId.isEmpty) {
      return Future<bool>.value(false);
    }
    for (final draft in _store.listAll()) {
      if (draft.source != MaterialIngestionSource.link ||
          draft.status != MaterialIngestionStatus.completed ||
          draft.noteId?.trim() != normalizedNoteId ||
          draft.remoteTaskId == null) {
        continue;
      }
      if (draft.linkOutlineOwner != null) return Future<bool>.value(true);
      return _refreshLinkOutlineOwnership(draft);
    }
    return Future<bool>.value(false);
  }

  Future<MaterialIngestionDraft?> submitLink(String value) async {
    final uri = normalizeMaterialUrl(value);
    if (uri == null) return null;
    for (final existing in _store.listRecoverable()) {
      if (existing.source == MaterialIngestionSource.link &&
          existing.normalizedUrl == uri.toString()) {
        _activeDraftId = existing.id;
        unawaited(_execute(existing.id));
        _notify();
        return existing;
      }
    }
    final now = _now().toUtc();
    final id = _draftId(MaterialIngestionSource.link, now);
    final draft = MaterialIngestionDraft(
      id: id,
      source: MaterialIngestionSource.link,
      status: MaterialIngestionStatus.draft,
      checkpoint: MaterialIngestionCheckpoint.created,
      title: uri.host,
      normalizedUrl: uri.toString(),
      createdAt: now,
      updatedAt: now,
      submitKey: 'ingestion-submit-$id',
    );
    if (!_persist(draft)) return null;
    unawaited(_execute(id));
    return draft;
  }

  Future<bool> retry(String draftId) async {
    if (_disposed) return false;
    final draft = _store.get(draftId);
    if (draft == null ||
        draft.source != MaterialIngestionSource.link ||
        draft.status != MaterialIngestionStatus.failed ||
        _inFlight.contains(draftId)) {
      return false;
    }
    if (draft.remoteTaskId != null) {
      _refreshingLinkTasks.add(draftId);
      unawaited(_execute(draftId, refreshFailedTask: true));
      return true;
    }
    final reset = draft.copyWith(
      status: draft.checkpoint == MaterialIngestionCheckpoint.created
          ? MaterialIngestionStatus.draft
          : MaterialIngestionStatus.queued,
      updatedAt: _now().toUtc(),
      clearError: true,
    );
    if (!_persist(reset)) return false;
    unawaited(_execute(draftId));
    return true;
  }

  Future<void> recoverPending() async {
    for (final draft in _store.listAll()) {
      if (_disposed) return;
      if (draft.source == MaterialIngestionSource.link &&
          draft.status == MaterialIngestionStatus.completed &&
          draft.linkOutlineOwner == null &&
          draft.remoteTaskId != null) {
        await _refreshLinkOutlineOwnership(draft);
      }
    }
    for (final draft in _store.listRecoverable()) {
      if (_disposed) return;
      if (draft.source != MaterialIngestionSource.link) continue;
      unawaited(_execute(draft.id));
    }
  }

  Future<bool> refreshMemoryNotes() async {
    String? cursor;
    var pageCount = 0;
    do {
      final result = await _api.listMemoryNotes(cursor: cursor);
      if (_disposed) return false;
      if (!result.ok || result.data == null) return false;
      for (final note in result.data!.items) {
        _deposit(note);
      }
      cursor = result.data!.nextCursor;
      pageCount += 1;
    } while (cursor != null && pageCount < 20 && !_disposed);
    return _knowledgeLibrary.flushPersistenceResult();
  }

  Future<bool> cancel(String draftId) async {
    final draft = _store.get(draftId);
    if (draft == null ||
        draft.source != MaterialIngestionSource.link ||
        draft.isTerminal ||
        _completionCommits.contains(draftId)) {
      return false;
    }
    _inFlight.remove(draftId);
    return _persist(
      draft.copyWith(
        status: MaterialIngestionStatus.cancelled,
        updatedAt: _now().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<void> _execute(
    String draftId, {
    bool refreshFailedTask = false,
  }) async {
    if (_disposed || !_inFlight.add(draftId)) return;
    _activeDraftId = draftId;
    _notify();
    final correlationId = _logger.createCorrelationId('ingestion');
    _log(
      correlationId,
      refreshFailedTask
          ? 'ingestion_status_refresh_started'
          : 'ingestion_started',
      draftId: draftId,
    );
    try {
      var draft = _store.get(draftId);
      if (draft == null ||
          (draft.isTerminal &&
              !(refreshFailedTask &&
                  draft.status == MaterialIngestionStatus.failed)) ||
          draft.source != MaterialIngestionSource.link) {
        return;
      }
      if (draft.source == MaterialIngestionSource.link) {
        await _ingestLink(draft, correlationId);
      }
    } finally {
      _inFlight.remove(draftId);
      _refreshingLinkTasks.remove(draftId);
      _notify();
    }
  }

  Future<void> _ingestLink(
    MaterialIngestionDraft draft,
    String correlationId,
  ) async {
    var current = draft;
    MaterialTaskSnapshot? snapshot;
    if (current.remoteTaskId == null) {
      final url = normalizeMaterialUrl(current.normalizedUrl ?? '');
      if (url == null) {
        _fail(current, 'LINK_IMPORT_URL_INVALID', correlationId);
        return;
      }
      current = _saveStatus(current, MaterialIngestionStatus.submitting);
      final created = await _api.createLinkImport(
        url: url,
        idempotencyKey: current.submitKey,
      );
      if (!_isDraftActive(draft.id)) return;
      snapshot = created.data;
      if (!created.ok || snapshot == null) {
        _fail(
          current,
          created.error?.code ?? 'LINK_IMPORT_CREATE_FAILED',
          correlationId,
        );
        return;
      }
      current = _save(
        current.copyWith(
          status: _linkDraftStatus(snapshot.status),
          checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
          remoteTaskId: snapshot.taskId,
          updatedAt: _now().toUtc(),
          clearError: true,
        ),
      );
      _log(
        correlationId,
        'ingestion_task_accepted',
        draftId: current.id,
        remoteStatus: snapshot.status.name,
      );
    }
    await _pollLinkIngestion(current, correlationId, initial: snapshot);
  }

  Future<void> _pollLinkIngestion(
    MaterialIngestionDraft draft,
    String correlationId, {
    MaterialTaskSnapshot? initial,
  }) async {
    var current = draft;
    var snapshot = initial;
    MaterialRemoteTaskStatus? lastRemoteStatus;
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      if (!_isDraftActive(draft.id)) return;
      if (snapshot == null) {
        if (attempt > 0) await _delay(_pollDelay(attempt));
        if (!_isDraftActive(draft.id)) return;
        final taskId = current.remoteTaskId;
        if (taskId == null) {
          _fail(current, 'LINK_IMPORT_INGESTION_ID_MISSING', correlationId);
          return;
        }
        final polled = await _api.getLinkImport(taskId);
        if (!_isDraftActive(draft.id)) return;
        snapshot = polled.data;
        if (!polled.ok || snapshot == null) {
          if (polled.error?.isRetryable == true &&
              attempt + 1 < maxPollAttempts) {
            snapshot = null;
            continue;
          }
          _fail(
            current,
            polled.error?.code ?? 'LINK_IMPORT_POLL_FAILED',
            correlationId,
          );
          return;
        }
        if (snapshot.taskId != taskId) {
          _fail(current, 'LINK_IMPORT_INGESTION_MISMATCH', correlationId);
          return;
        }
      }
      final remote = snapshot;
      _refreshingLinkTasks.remove(draft.id);
      if (remote.status != lastRemoteStatus) {
        _log(
          correlationId,
          'ingestion_remote_status',
          draftId: current.id,
          remoteStatus: remote.status.name,
          errorCode: remote.errorCode,
        );
        lastRemoteStatus = remote.status;
      }
      if (remote.status == MaterialRemoteTaskStatus.failed) {
        _fail(
          current,
          remote.errorCode ?? 'LINK_IMPORT_REMOTE_FAILED',
          correlationId,
          failureOrigin: 'remote_task',
        );
        return;
      }
      if (remote.status == MaterialRemoteTaskStatus.completed) {
        final noteId = remote.promotedNoteId;
        if (noteId == null) {
          _fail(current, 'LINK_IMPORT_NOTE_ID_MISSING', correlationId);
          return;
        }
        final cloudNote = await _api.getMemoryNote(noteId);
        if (!_isDraftActive(draft.id)) return;
        final note = cloudNote.data;
        if (!cloudNote.ok || note == null) {
          if (_isProjectionConvergenceFailure(cloudNote.error) &&
              attempt + 1 < maxPollAttempts) {
            await _delay(_pollDelay(attempt + 1));
            snapshot = remote;
            continue;
          }
          _fail(
            current,
            cloudNote.error?.code ?? 'LINK_IMPORT_NOTE_READ_FAILED',
            correlationId,
          );
          return;
        }
        if (note.remoteNoteId != noteId) {
          _fail(current, 'LINK_IMPORT_NOTE_ID_MISMATCH', correlationId);
          return;
        }
        if (note.markdown.trim().isEmpty) {
          if (attempt + 1 < maxPollAttempts) {
            await _delay(_pollDelay(attempt + 1));
            snapshot = remote;
            continue;
          }
          _fail(current, 'LINK_IMPORT_NOTE_READ_FAILED', correlationId);
          return;
        }
        final linkedNote = GeneratedMemoryNote(
          id: noteId,
          title: note.title,
          markdown: note.markdown,
          source: MaterialIngestionSource.link,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
          summary: note.summary,
          contentLineId: note.contentLineId,
          contentLineName: note.contentLineName,
          folderId: note.folderId,
          folderName: note.folderName,
          tags: note.tags,
          remoteNoteId: note.remoteNoteId,
          noteRevisionId: note.noteRevisionId,
          rawPartRevisionId: note.rawPartRevisionId,
          etag: note.etag,
          contentCursor: note.contentCursor,
          publicUrl: current.normalizedUrl,
        );
        final completed = await _complete(current, linkedNote, correlationId);
        if (completed != null && completed.linkOutlineOwner == null) {
          await _refreshLinkOutlineOwnership(completed);
        }
        return;
      }
      current = _saveStatus(current, _linkDraftStatus(remote.status));
      snapshot = null;
    }
    _fail(current, 'LINK_IMPORT_TIMEOUT', correlationId);
  }

  Future<MaterialIngestionDraft?> _complete(
    MaterialIngestionDraft draft,
    GeneratedMemoryNote note,
    String correlationId,
  ) async {
    if (!_isDraftActive(draft.id) || !_completionCommits.add(draft.id)) {
      return null;
    }
    try {
      var committingDraft = draft;
      if (draft.source == MaterialIngestionSource.link &&
          draft.noteId != note.id) {
        committingDraft = _save(
          draft.copyWith(noteId: note.id, updatedAt: _now().toUtc()),
        );
      }
      _deposit(
        note,
        publicUrl: committingDraft.source == MaterialIngestionSource.link
            ? normalizeV3PublicSourceUrl(
                note.publicUrl ?? committingDraft.normalizedUrl,
              )
            : null,
      );
      final persisted = await _knowledgeLibrary.flushPersistenceResult();
      if (!_isDraftActive(draft.id)) return null;
      if (!persisted) {
        _fail(draft, 'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED', correlationId);
        return null;
      }
      _completedNotes[draft.id] = note;
      final completed = _save(
        committingDraft.copyWith(
          status: MaterialIngestionStatus.completed,
          checkpoint: MaterialIngestionCheckpoint.noteDeposited,
          noteId: note.id,
          updatedAt: _now().toUtc(),
          clearError: true,
        ),
      );
      _log(correlationId, 'ingestion_completed', draftId: draft.id);
      return completed;
    } finally {
      _completionCommits.remove(draft.id);
    }
  }

  Future<bool> _refreshLinkOutlineOwnership(MaterialIngestionDraft draft) {
    final existing = _outlineOwnershipRefreshes[draft.id];
    if (existing != null) return existing;
    final operation = _backfillLinkOutlineOwnership(draft);
    _outlineOwnershipRefreshes[draft.id] = operation;
    return operation.whenComplete(() {
      if (identical(_outlineOwnershipRefreshes[draft.id], operation)) {
        _outlineOwnershipRefreshes.remove(draft.id);
      }
    });
  }

  Future<bool> _backfillLinkOutlineOwnership(
    MaterialIngestionDraft draft,
  ) async {
    final taskId = draft.remoteTaskId;
    if (taskId == null) return false;
    for (var attempt = 0; attempt < 3 && !_disposed; attempt++) {
      final current = _store.get(draft.id);
      if (current == null ||
          current.source != MaterialIngestionSource.link ||
          current.status != MaterialIngestionStatus.completed ||
          current.remoteTaskId != taskId) {
        return false;
      }
      if (current.linkOutlineOwner != null) return true;
      final result = await _api.getLinkOutlineOwnership(taskId);
      if (_disposed) return false;
      final ownership = result.data;
      if (result.ok && ownership != null && ownership.ingestionId == taskId) {
        final error = _store.save(
          current.copyWith(
            linkOutlineOwner: ownership.owner,
            updatedAt: _now().toUtc(),
          ),
        );
        if (error == null) _notify();
        return error == null;
      }
      if (result.error?.isRetryable != true || attempt == 2) return false;
      await _delay(_pollDelay(attempt + 1));
    }
    return false;
  }

  void _deposit(GeneratedMemoryNote note, {String? publicUrl}) {
    final existing = _knowledgeLibrary.noteForId(note.id);
    _knowledgeLibrary.updateNote(
      V3FeedItem(
        id: note.id,
        title: note.title,
        source: switch (note.source) {
          MaterialIngestionSource.link => V3MaterialSource.link,
          MaterialIngestionSource.internalRecording =>
            V3MaterialSource.internalRecording,
          MaterialIngestionSource.meeting => V3MaterialSource.meeting,
        },
        createdAt: note.createdAt,
        rawBody: note.markdown,
        summaryBody: note.summary,
        recordingId: existing?.recordingId,
        minutesStatus: existing?.minutesStatus,
        summaryStatus: existing?.summaryStatus,
        contentLineId: note.contentLineId,
        contentLineName: note.contentLineName,
        folderId: note.folderId,
        folderName: note.folderName,
        publicUrl: publicUrl,
        topics: note.tags,
        remoteNoteId: note.remoteNoteId,
        noteRevisionId: note.noteRevisionId,
        rawPartRevisionId: note.rawPartRevisionId,
        etag: note.etag,
        contentCursor: note.contentCursor,
        syncState: note.remoteNoteId == null
            ? note.source == MaterialIngestionSource.link
                  ? NoteSyncState.localOnly
                  : NoteSyncState.pending
            : NoteSyncState.synced,
        updatedAt: note.updatedAt,
      ),
    );
  }

  void _fail(
    MaterialIngestionDraft draft,
    String errorCode,
    String correlationId, {
    String failureOrigin = 'request_or_local',
  }) {
    _save(
      draft.copyWith(
        status: MaterialIngestionStatus.failed,
        lastErrorCode: _safeErrorCode(errorCode),
        updatedAt: _now().toUtc(),
      ),
    );
    _log(
      correlationId,
      'ingestion_failed',
      draftId: draft.id,
      severity: DiagnosticSeverity.error,
      errorCode: _safeErrorCode(errorCode),
      failureOrigin: failureOrigin,
    );
  }

  MaterialIngestionDraft _saveStatus(
    MaterialIngestionDraft draft,
    MaterialIngestionStatus status,
  ) {
    return _save(
      draft.copyWith(
        status: status,
        updatedAt: _now().toUtc(),
        clearError: true,
      ),
    );
  }

  MaterialIngestionDraft _save(MaterialIngestionDraft draft) {
    final error = _store.save(draft);
    if (error != null) {
      throw StateError(error.code);
    }
    _notify();
    return draft;
  }

  bool _persist(MaterialIngestionDraft draft) {
    final error = _store.save(draft);
    if (error != null) return false;
    _activeDraftId = draft.id;
    _notify();
    return true;
  }

  void _log(
    String correlationId,
    String summary, {
    required String draftId,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? errorCode,
    String? remoteStatus,
    String? failureOrigin,
  }) {
    final draft = _store.get(draftId);
    _logger.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.upload,
        severity: severity,
        safeSummary: summary,
        correlationId: correlationId,
        metadata: <String, Object?>{
          'draftId': draftId,
          if (draft != null) ...<String, Object?>{
            'checkpoint': draft.checkpoint.name,
            'status': draft.status.name,
            if (draft.remoteTaskId != null) 'remoteTaskId': draft.remoteTaskId,
          },
          if (errorCode != null) 'errorCode': _safeErrorCode(errorCode),
          if (remoteStatus != null) 'remoteStatus': remoteStatus,
          if (failureOrigin != null) 'failureOrigin': failureOrigin,
        },
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _isDraftActive(String draftId) =>
      !_disposed && _inFlight.contains(draftId);

  @override
  void dispose() {
    _disposed = true;
    _inFlight.clear();
    _refreshingLinkTasks.clear();
    _completionCommits.clear();
    _outlineOwnershipRefreshes.clear();
    super.dispose();
  }
}

Uri? normalizeMaterialUrl(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      (parsed.port != 0 && parsed.port != 80 && parsed.port != 443)) {
    return null;
  }
  return parsed.removeFragment();
}

Duration _pollDelay(int attempt) => Duration(
  seconds: attempt < 5
      ? 2
      : attempt < 15
      ? 4
      : 8,
);

bool _isProjectionConvergenceFailure(AppFailure? failure) {
  if (failure == null || failure.isRetryable) return true;
  return switch (failure.code) {
    'NOTE_NOT_FOUND' ||
    'NOTE_PART_NOT_FOUND' ||
    'REVISION_NOT_FOUND' ||
    'WORKSPACE_NOT_READY' ||
    'WORKSPACE_NOTE_NOT_FOUND' ||
    'WORKSPACE_NOTE_PART_INVALID' ||
    'WORKSPACE_NOTE_READ_FAILED' => true,
    _ => false,
  };
}

MaterialIngestionStatus _linkDraftStatus(MaterialRemoteTaskStatus status) =>
    switch (status) {
      MaterialRemoteTaskStatus.queued => MaterialIngestionStatus.queued,
      MaterialRemoteTaskStatus.analyzing ||
      MaterialRemoteTaskStatus.completed => MaterialIngestionStatus.analyzing,
      MaterialRemoteTaskStatus.failed => MaterialIngestionStatus.failed,
    };

String _draftId(MaterialIngestionSource source, DateTime now) =>
    '${source.wireName}-${now.microsecondsSinceEpoch}';

String _safeErrorCode(String value) =>
    RegExp(r'^[A-Z0-9_]{2,80}$').hasMatch(value)
    ? value
    : 'MATERIAL_INGESTION_FAILED';
