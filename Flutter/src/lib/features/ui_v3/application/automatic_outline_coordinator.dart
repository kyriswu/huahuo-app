import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../ingestion/domain/material_ingestion.dart';
import '../data/automatic_outline_recovery_store.dart';
import '../data/note_file_agent_client.dart';
import '../data/outline_repository.dart';
import '../domain/feed_item_models.dart';
import 'knowledge_library_controller.dart';
import 'knowledge_note_port.dart';

enum AutomaticOutlinePhase {
  waitingForSync,
  waitingForProjection,
  waitingForOwnership,
  checkingRemote,
  submitting,
  recoveringSubmission,
  registeringAccepted,
  retryWaiting,
  failed,
}

@immutable
final class AutomaticOutlineLinkHandoff {
  const AutomaticOutlineLinkHandoff.unresolved()
    : owner = null,
      operationId = null;

  const AutomaticOutlineLinkHandoff.client()
    : owner = MaterialLinkOutlineOwner.client,
      operationId = null;

  const AutomaticOutlineLinkHandoff.backendMedia(this.operationId)
    : owner = MaterialLinkOutlineOwner.backendMedia;

  final MaterialLinkOutlineOwner? owner;
  final String? operationId;

  bool get isResolved => owner != null;
}

AutomaticOutlineLinkHandoff automaticOutlineLinkHandoffForDrafts(
  V3FeedItem note,
  Iterable<MaterialIngestionDraft> drafts,
) {
  final localNoteId = note.id.trim();
  final remoteNoteId = note.remoteNoteId?.trim();
  for (final draft in drafts) {
    if (draft.source != MaterialIngestionSource.link) continue;
    final depositedNoteId = draft.noteId?.trim();
    if (depositedNoteId == null ||
        depositedNoteId.isEmpty ||
        (depositedNoteId != localNoteId && depositedNoteId != remoteNoteId)) {
      continue;
    }
    final owner = draft.linkOutlineOwner;
    if (owner == null) {
      return const AutomaticOutlineLinkHandoff.unresolved();
    }
    if (owner == MaterialLinkOutlineOwner.client) {
      return const AutomaticOutlineLinkHandoff.client();
    }
    final ingestionId = draft.remoteTaskId?.trim();
    if (ingestionId != null &&
        RegExp(r'^ingestion_[A-Za-z0-9._-]{1,128}$').hasMatch(ingestionId)) {
      return AutomaticOutlineLinkHandoff.backendMedia(
        'media-outline:$ingestionId',
      );
    }
    return const AutomaticOutlineLinkHandoff.unresolved();
  }
  return const AutomaticOutlineLinkHandoff.client();
}

@immutable
final class AutomaticOutlineTaskSnapshot {
  const AutomaticOutlineTaskSnapshot({
    required this.attemptId,
    required this.operationId,
    required this.localNoteId,
    required this.remoteNoteId,
    required this.inputRawRevisionId,
    required this.targetOutlineRevisionId,
    required this.subjectTitle,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
    this.errorCode,
    this.resumePhase,
    this.retryAt,
  });

  final String attemptId;
  final String operationId;
  final String localNoteId;
  final String? remoteNoteId;
  final String? inputRawRevisionId;
  final String? targetOutlineRevisionId;
  final String subjectTitle;
  final AutomaticOutlinePhase phase;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? errorCode;
  final AutomaticOutlinePhase? resumePhase;
  final DateTime? retryAt;

  bool get isTerminal => phase == AutomaticOutlinePhase.failed;
  bool get isPaused =>
      isTerminal || phase == AutomaticOutlinePhase.retryWaiting;

  String get statusLabel => switch (phase) {
    AutomaticOutlinePhase.waitingForSync => '纲要等待原文同步',
    AutomaticOutlinePhase.waitingForProjection => '纲要等待版本同步',
    AutomaticOutlinePhase.waitingForOwnership => '纲要确认生成方式',
    AutomaticOutlinePhase.checkingRemote => '纲要确认后台状态',
    AutomaticOutlinePhase.submitting => '纲要正在提交',
    AutomaticOutlinePhase.recoveringSubmission => '纲要确认提交结果',
    AutomaticOutlinePhase.registeringAccepted => '纲要任务正在接管',
    AutomaticOutlinePhase.retryWaiting => '纲要等待自动恢复',
    AutomaticOutlinePhase.failed => '纲要未完成',
  };

  String get statusMessage => switch (phase) {
    AutomaticOutlinePhase.waitingForSync => '原始内容已保存，正在同步后自动生成纲要。',
    AutomaticOutlinePhase.waitingForProjection =>
      '笔记已保存，正在等待原文与纲要版本同步完整，尚未提交生成。',
    AutomaticOutlinePhase.waitingForOwnership => '正在确认链接纲要由后台生成还是由应用发起，避免重复生成。',
    AutomaticOutlinePhase.checkingRemote => '正在确认是否已有后台纲要任务或已生成的纲要。',
    AutomaticOutlinePhase.submitting => '正在提交自动纲要任务，尚未确认受理，原始内容已保留。',
    AutomaticOutlinePhase.recoveringSubmission => '正在核对上次提交的受理结果，不会重复创建任务。',
    AutomaticOutlinePhase.registeringAccepted => '后台已受理，正在保存任务回执并接管进度。',
    AutomaticOutlinePhase.retryWaiting
        when resumePhase == AutomaticOutlinePhase.registeringAccepted =>
      '后台已受理，任务回执正在自动恢复，不会重新生成。',
    AutomaticOutlinePhase.retryWaiting => '原始内容已保留，当前步骤暂未就绪，将自动恢复，无需重复点击生成。',
    AutomaticOutlinePhase.failed => '原始内容已保留，可打开资产查看原因并重试。',
  };

  AutomaticOutlineTaskSnapshot advance(
    AutomaticOutlinePhase next, {
    required DateTime at,
    String? operationId,
    String? remoteNoteId,
    String? inputRawRevisionId,
    String? targetOutlineRevisionId,
    String? subjectTitle,
    String? errorCode,
    AutomaticOutlinePhase? resumePhase,
    DateTime? retryAt,
  }) => AutomaticOutlineTaskSnapshot(
    attemptId: attemptId,
    operationId: operationId ?? this.operationId,
    localNoteId: localNoteId,
    remoteNoteId: remoteNoteId ?? this.remoteNoteId,
    inputRawRevisionId: inputRawRevisionId ?? this.inputRawRevisionId,
    targetOutlineRevisionId:
        targetOutlineRevisionId ?? this.targetOutlineRevisionId,
    subjectTitle: subjectTitle ?? this.subjectTitle,
    phase: next,
    createdAt: createdAt,
    updatedAt: at,
    errorCode: errorCode,
    resumePhase: next == AutomaticOutlinePhase.retryWaiting
        ? resumePhase ?? this.resumePhase
        : null,
    retryAt: next == AutomaticOutlinePhase.retryWaiting
        ? retryAt ?? this.retryAt
        : null,
  );
}

/// The single Flutter admission owner for automatic Raw -> Outline work.
///
/// Individual import and detail routes only publish canonical Knowledge notes.
/// This coordinator observes that shared boundary and uses deterministic
/// operation identities so listener replay and process recovery cannot create
/// a second File-Agent run for the same frozen revisions.
final class AutomaticOutlineCoordinator extends ChangeNotifier {
  AutomaticOutlineCoordinator({
    required KnowledgeLibraryController library,
    required AcceptedOutlineRunRepository? repository,
    required DerivedPartRunTrackingPort tracker,
    required this.workspaceScope,
    Duration linkBackendGrace = const Duration(seconds: 3),
    Duration linkOwnershipRetryBaseDelay = const Duration(seconds: 3),
    Duration retryBaseDelay = const Duration(seconds: 15),
    Duration retryMaximumDelay = const Duration(minutes: 5),
    Duration terminalNoticeRetention = const Duration(hours: 24),
    AutomaticOutlineLinkHandoff? Function(V3FeedItem note)?
    linkImportHandoffFor,
    Future<bool> Function(V3FeedItem note)? refreshLinkImportHandoffFor,
    AutomaticOutlineRecoveryStorePort? recoveryStore,
    DateTime Function()? now,
  }) : // Public dependency names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _library = library,
       // ignore: prefer_initializing_formals
       _repository = repository,
       // ignore: prefer_initializing_formals
       _tracker = tracker,
       // ignore: prefer_initializing_formals
       _linkBackendGrace = linkBackendGrace,
       // ignore: prefer_initializing_formals
       _linkOwnershipRetryBaseDelay = linkOwnershipRetryBaseDelay,
       // ignore: prefer_initializing_formals
       _retryBaseDelay = retryBaseDelay,
       // ignore: prefer_initializing_formals
       _retryMaximumDelay = retryMaximumDelay,
       // ignore: prefer_initializing_formals
       _terminalNoticeRetention = terminalNoticeRetention,
       // ignore: prefer_initializing_formals
       _linkImportHandoffFor = linkImportHandoffFor,
       // ignore: prefer_initializing_formals
       _refreshLinkImportHandoffFor = refreshLinkImportHandoffFor,
       _recoveryStore =
           recoveryStore ??
           InMemoryAutomaticOutlineRecoveryStore(
             workspaceScope: workspaceScope?.trim().isNotEmpty == true
                 ? workspaceScope!.trim()
                 : 'workspace-unavailable',
           ),
       _now = now ?? DateTime.now;

  final KnowledgeLibraryController _library;
  final AcceptedOutlineRunRepository? _repository;
  final DerivedPartRunTrackingPort _tracker;
  final String? workspaceScope;
  final Duration _linkBackendGrace;
  final Duration _linkOwnershipRetryBaseDelay;
  final Duration _retryBaseDelay;
  final Duration _retryMaximumDelay;
  final Duration _terminalNoticeRetention;
  final AutomaticOutlineLinkHandoff? Function(V3FeedItem note)?
  _linkImportHandoffFor;
  final Future<bool> Function(V3FeedItem note)? _refreshLinkImportHandoffFor;
  final AutomaticOutlineRecoveryStorePort _recoveryStore;
  final DateTime Function() _now;

  final Map<String, AutomaticOutlineTaskSnapshot> _tasks =
      <String, AutomaticOutlineTaskSnapshot>{};
  final Set<String> _attempted = <String>{};
  final Set<String> _linkGraceSatisfied = <String>{};
  final Map<String, Timer> _linkGraceTimers = <String, Timer>{};
  final Map<String, int> _linkOwnershipFailureCounts = <String, int>{};
  final Map<String, int> _failureCounts = <String, int>{};
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  final Set<String> _retryDue = <String>{};
  final Map<String, _PendingAcceptedOutlineHandoff> _acceptedHandoffs =
      <String, _PendingAcceptedOutlineHandoff>{};

  Future<void>? _scanFuture;
  bool _scanAgain = false;
  bool _started = false;
  bool _foreground = true;
  bool _disposed = false;

  List<AutomaticOutlineTaskSnapshot> get tasks {
    final values = _tasks.values.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<AutomaticOutlineTaskSnapshot>.unmodifiable(values);
  }

  void start({bool foreground = true}) {
    if (_disposed) return;
    final shouldReconcile = !_started || (!_foreground && foreground);
    _foreground = foreground;
    if (!_started) {
      _started = true;
      _library.addListener(_handleKnowledgeChanged);
      if (_tracker case final Listenable tracker) {
        tracker.addListener(_handleTrackerChanged);
      }
    }
    if (_foreground && shouldReconcile) reconcile();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      for (final attemptId in _retryDue.toList(growable: false)) {
        unawaited(_releaseRetry(attemptId));
      }
      reconcile();
    }
  }

  void reconcile() {
    if (_disposed || !_started || !_foreground || !_isWorkspaceReady) return;
    if (_scanFuture != null) {
      _scanAgain = true;
      return;
    }
    scheduleMicrotask(() {
      if (_disposed || !_started || !_foreground || _scanFuture != null) return;
      final operation = _scanUntilSettled();
      _scanFuture = operation;
      unawaited(
        operation.whenComplete(() {
          if (identical(_scanFuture, operation)) _scanFuture = null;
        }),
      );
    });
  }

  @visibleForTesting
  Future<void> reconcileNow() async {
    if (!_started) start();
    if (!_isWorkspaceReady) return;
    if (_scanFuture case final running?) {
      _scanAgain = true;
      await running;
      return;
    }
    final operation = _scanUntilSettled();
    _scanFuture = operation;
    try {
      await operation;
    } finally {
      if (identical(_scanFuture, operation)) _scanFuture = null;
    }
  }

  bool get _isWorkspaceReady {
    final normalized = workspaceScope?.trim();
    return normalized != null && normalized.isNotEmpty;
  }

  void _handleKnowledgeChanged() => reconcile();

  void _handleTrackerChanged() => reconcile();

  Future<void> _scanUntilSettled() async {
    do {
      _scanAgain = false;
      await _scanOnce();
    } while (!_disposed && _foreground && _scanAgain);
  }

  Future<void> _scanOnce() async {
    if (_disposed || !_foreground || !_isWorkspaceReady) return;
    await _library.restore();
    if (_disposed || !_foreground || !_library.restoreComplete) return;

    final notes = _library.notes.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    await _backfillTerminalRecovery(notes);
    if (_disposed || !_foreground) return;
    _pruneTransientTasks(notes);
    for (final snapshot in notes) {
      if (_disposed || !_foreground) return;
      await _consider(snapshot.id);
    }
  }

  Future<void> _backfillTerminalRecovery(List<V3FeedItem> notes) async {
    final workspace = _nonEmpty(workspaceScope);
    if (workspace == null) return;
    final localToRemote = <String, String>{
      for (final note in notes)
        if (_nonEmpty(note.remoteNoteId) case final remote?) note.id: remote,
    };
    final terminalEntries =
        _ledger
            .where(
              (entry) =>
                  entry.kind == 'derived_part' &&
                  entry.targetPart == NoteFileAgentPart.outline &&
                  entry.isTerminal &&
                  isAutomaticOutlineOperationId(entry.operationId),
            )
            .toList(growable: false)
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    for (final entry in terminalEntries) {
      if (_disposed || !_foreground) return;
      final remoteNoteId =
          _nonEmpty(entry.remoteNoteId) ??
          (entry.localNoteId == null
              ? null
              : localToRemote[entry.localNoteId!]);
      final inputRevision = _nonEmpty(entry.inputPartRevisionId);
      final targetRevision = _nonEmpty(entry.targetPartRevisionId);
      final outputRevision = _nonEmpty(entry.outputPartRevisionId);
      final operationId = _nonEmpty(entry.operationId);
      if (remoteNoteId == null ||
          inputRevision == null ||
          targetRevision == null ||
          operationId == null ||
          (entry.status == 'succeeded' && outputRevision == null) ||
          !_recoveryStore.canReadRemoteNote(remoteNoteId)) {
        continue;
      }
      await _recoveryStore.putTerminal(
        AutomaticOutlineTerminalRecord(
          attemptId: automaticOutlineAttemptId(
            workspaceScope: workspace,
            remoteNoteId: remoteNoteId,
            inputRawRevisionId: inputRevision,
            targetOutlineRevisionId: targetRevision,
          ),
          remoteNoteId: remoteNoteId,
          operationId: operationId,
          inputRawRevisionId: inputRevision,
          targetOutlineRevisionId: targetRevision,
          status: entry.status,
          fileAgentRunId: entry.taskId,
          outputOutlineRevisionId: outputRevision,
          recordedAt: entry.createdAt,
        ),
      );
    }
  }

  Future<void> _consider(String localNoteId) async {
    var note = _library.noteForId(localNoteId);
    if (note == null) return;
    if (await _recoverPersistedAdmission(note)) return;
    if (await _recoverAcceptedHandoff(note)) return;
    if (!_hasRawOutlineIntent(note)) return;
    if (_hasPendingOutline(note)) return;
    if (_hasBlockingFailedAttempt(note)) return;

    if (!_hasExactRemoteRaw(note)) {
      final localAttempt = _localAttempt(note);
      if (_tasks[localAttempt.attemptId]?.isPaused == true) return;
      if (note.syncState == NoteSyncState.conflict) {
        _publishFailure(
          note,
          'AUTO_OUTLINE_SYNC_CONFLICT',
          frozen: localAttempt,
        );
        return;
      }
      if (note.syncState == NoteSyncState.synced) {
        await _waitForProjection(note, localAttempt);
        return;
      }
      _publishPreAdmission(
        note,
        AutomaticOutlinePhase.waitingForSync,
        frozen: localAttempt,
      );
      final result = await _library.syncNote(note.id);
      if (_disposed || !_foreground) return;
      note = _library.noteForId(localNoteId);
      if (result.outcome != KnowledgeNoteSyncOutcome.synced || note == null) {
        if (result.outcome == KnowledgeNoteSyncOutcome.superseded) {
          _scanAgain = true;
        } else {
          _publishFailure(
            note ?? result.note ?? _library.noteForId(localNoteId),
            _automaticSyncFailureCode(result),
            frozen: localAttempt,
            fallbackLocalNoteId: localNoteId,
            retryable:
                result.outcome == KnowledgeNoteSyncOutcome.unavailable ||
                result.outcome == KnowledgeNoteSyncOutcome.failed,
          );
        }
        return;
      }
      if (!_hasRawOutlineIntent(note) || !_hasExactRemoteRaw(note)) return;
      _removeTransientTask(localAttempt.attemptId);
    }

    final frozen = _frozenAttempt(note);
    if (frozen == null || _hasKnownAttempt(note, frozen)) return;
    if (_attempted.contains(frozen.attemptId)) return;
    if (_nonEmpty(note.outlinePartRevisionId) == null) {
      await _waitForProjection(note, frozen);
      return;
    }

    final waitsForLinkOwnership =
        note.isLinkImportSource && frozen.waitsForLinkOwnership;
    final waitsForBackendGrace =
        note.isLinkImportSource &&
        !_linkGraceSatisfied.contains(frozen.attemptId) &&
        _linkBackendGrace > Duration.zero;
    if (waitsForLinkOwnership || waitsForBackendGrace) {
      _publishPreAdmission(
        note,
        waitsForLinkOwnership
            ? AutomaticOutlinePhase.waitingForOwnership
            : AutomaticOutlinePhase.checkingRemote,
        frozen: frozen,
      );
      _scheduleLinkRecheck(
        frozen.attemptId,
        ownershipPending: waitsForLinkOwnership,
      );
      return;
    }

    _attempted.add(frozen.attemptId);
    _publishPreAdmission(
      note,
      AutomaticOutlinePhase.submitting,
      frozen: frozen,
    );
    final repository = _repository;
    if (repository == null) {
      _publishFailure(note, 'AUTO_OUTLINE_BACKEND_UNAVAILABLE', frozen: frozen);
      return;
    }
    try {
      final accepted = await repository.submit(
        note,
        operationId: frozen.operationId,
        allowExistingAutomaticOutline: frozen.allowExistingAutomaticOutline,
      );
      if (_disposed) return;
      final current = _library.noteForId(note.id);
      final trackedLocalNote = current?.remoteNoteId?.trim() == accepted.noteId
          ? current!
          : note;
      final handoff = _PendingAcceptedOutlineHandoff(
        frozen: frozen,
        note: trackedLocalNote,
        accepted: accepted,
      );
      _acceptedHandoffs[frozen.attemptId] = handoff;
      await _completeAcceptedHandoff(handoff);
      if (_disposed) return;
      _removeTransientTask(frozen.attemptId, resetRetry: true);
      final latest = _library.noteForId(note.id);
      if (latest == null ||
          latest.remoteNoteId?.trim() != accepted.noteId ||
          latest.rawPartRevisionId?.trim() !=
              accepted.inputPartRevisionId.trim()) {
        _scanAgain = true;
      }
    } on OutlineGenerationException catch (error) {
      if (_disposed) return;
      await _handleSubmitFailure(
        note,
        frozen,
        error.code,
        retryable: error.isRetryable,
        recoveryAdmission: error.recoveryAdmission,
      );
    } on Object {
      _publishFailure(note, 'AUTO_OUTLINE_SUBMIT_FAILED', frozen: frozen);
    }
  }

  Future<void> _waitForProjection(
    V3FeedItem note,
    _FrozenAutomaticOutline attempt,
  ) async {
    _publishPreAdmission(
      note,
      AutomaticOutlinePhase.waitingForProjection,
      frozen: attempt,
    );
    try {
      await _library.synchronizeWorkspaceContent(forceSnapshot: true);
    } on Object {
      if (_disposed) return;
    }
    if (_disposed || !_foreground) return;
    final current = _library.noteForId(note.id);
    if (current == null ||
        !_hasRawOutlineIntent(current) ||
        _hasPendingOutline(current)) {
      _removeTransientTask(attempt.attemptId, resetRetry: true);
      return;
    }
    final currentAttempt = _hasExactRemoteRaw(current)
        ? _frozenAttempt(current)
        : _localAttempt(current);
    if (currentAttempt?.attemptId != attempt.attemptId ||
        (_hasExactRemoteRaw(current) &&
            _nonEmpty(current.outlinePartRevisionId) != null)) {
      _removeTransientTask(attempt.attemptId, resetRetry: true);
      _scanAgain = true;
      return;
    }
    _publishFailure(
      current,
      'AUTO_OUTLINE_PROJECTION_PENDING',
      frozen: attempt,
      retryable: true,
    );
  }

  Future<bool> _recoverPersistedAdmission(V3FeedItem note) async {
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    if (remoteNoteId == null) return false;
    if (!_recoveryStore.canReadRemoteNote(remoteNoteId)) {
      _publishFailure(
        note,
        'AUTO_OUTLINE_CHECKPOINT_INVALID',
        frozen: _frozenAttempt(note),
      );
      return true;
    }
    final admission = _recoveryStore.admissionForRemoteNote(remoteNoteId);
    if (admission == null) return false;
    final workspace = _nonEmpty(workspaceScope);
    final expectedAttemptId = workspace == null
        ? null
        : automaticOutlineAttemptId(
            workspaceScope: workspace,
            remoteNoteId: admission.remoteNoteId,
            inputRawRevisionId: admission.inputRawRevisionId,
            targetOutlineRevisionId: admission.targetOutlineRevisionId,
          );
    if (workspace == null ||
        _recoveryStore.workspaceScope != workspace ||
        expectedAttemptId != admission.attemptId ||
        !isAutomaticOutlineOperationId(admission.operationId)) {
      _publishFailure(
        note,
        'AUTO_OUTLINE_RECOVERY_CHECKPOINT_INVALID',
        frozen: _frozenAttempt(note),
      );
      return true;
    }
    final frozen = _FrozenAutomaticOutline(
      attemptId: admission.attemptId,
      operationId: admission.operationId,
      remoteNoteId: admission.remoteNoteId,
      rawRevisionId: admission.inputRawRevisionId,
      targetOutlineRevisionId: admission.targetOutlineRevisionId,
      allowExistingAutomaticOutline: admission.allowExistingAutomaticOutline,
      waitsForLinkOwnership: false,
    );
    final exactLedgerBinding = _ledger.any(
      (entry) =>
          _isSameOutlineAsset(entry, note) &&
          entry.operationId == admission.operationId &&
          _nonEmpty(entry.inputPartRevisionId) ==
              admission.inputRawRevisionId &&
          _nullableTrim(entry.targetPartRevisionId) ==
              admission.targetOutlineRevisionId &&
          (admission.accepted == null ||
              entry.taskId == admission.accepted!.fileAgentRunId),
    );
    if (exactLedgerBinding) {
      final accepted = admission.accepted;
      if (accepted != null) {
        final removed = await _recoveryStore.removeAccepted(
          remoteNoteId: remoteNoteId,
          attemptId: admission.attemptId,
          fileAgentRunId: accepted.fileAgentRunId,
        );
        if (!removed && !_disposed) {
          _publishFailure(
            note,
            'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
            frozen: frozen,
            retryable: true,
          );
        }
      }
      return true;
    }
    if (_tasks[frozen.attemptId]?.isPaused == true &&
        !_retryDue.contains(frozen.attemptId)) {
      return true;
    }
    if (admission.accepted == null &&
        _now().toUtc().difference(admission.createdAt.toUtc()) >=
            _automaticOutlineReplayReceiptWindow) {
      await _terminalizeRecoveredAdmission(
        note: note,
        expected: admission,
        frozen: frozen,
        code: 'AUTO_OUTLINE_RECOVERY_REQUIRED',
        status: 'orphaned',
      );
      return true;
    }
    _attempted.add(frozen.attemptId);
    _publishPreAdmission(
      note,
      admission.accepted == null
          ? AutomaticOutlinePhase.recoveringSubmission
          : AutomaticOutlinePhase.registeringAccepted,
      frozen: frozen,
    );
    try {
      late final NoteFileAgentRunSnapshot accepted;
      final journaledAccepted = admission.accepted;
      if (journaledAccepted == null) {
        final repository = _repository;
        if (repository is! AutomaticOutlineAdmissionReplayPort) {
          throw const OutlineGenerationException(
            'AUTO_OUTLINE_RECOVERY_UNAVAILABLE',
            isRetryable: true,
          );
        }
        final replayRepository =
            repository as AutomaticOutlineAdmissionReplayPort;
        accepted = await replayRepository.replayAutomaticAdmission(admission);
        if (_disposed) return true;
        final latestAdmission = _recoveryStore.admissionForRemoteNote(
          remoteNoteId,
        );
        final alreadyPromoted =
            latestAdmission?.accepted?.fileAgentRunId ==
            accepted.fileAgentRunId;
        if (!alreadyPromoted &&
            (latestAdmission == null ||
                !await _recoveryStore.promoteAccepted(
                  admission: latestAdmission,
                  accepted: accepted,
                ))) {
          throw const OutlineGenerationException(
            'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
            isRetryable: true,
          );
        }
      } else {
        accepted = journaledAccepted;
      }
      final promotedAdmission = admission.withAccepted(accepted);
      if (promotedAdmission == null) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_RECOVERY_CHECKPOINT_INVALID',
        );
      }
      final current = _library.noteForId(note.id);
      final trackedLocalNote = current?.remoteNoteId?.trim() == accepted.noteId
          ? current!
          : note;
      final handoff = _PendingAcceptedOutlineHandoff(
        frozen: frozen,
        note: trackedLocalNote,
        accepted: accepted,
      );
      _acceptedHandoffs[frozen.attemptId] = handoff;
      await _completeAcceptedHandoff(handoff);
      if (_disposed) return true;
      _removeTransientTask(frozen.attemptId, resetRetry: true);
    } on OutlineGenerationException catch (error) {
      if (_disposed) return true;
      if (error.isRetryable) {
        _publishFailure(note, error.code, frozen: frozen, retryable: true);
      } else {
        final failedAdmission = error.recoveryAdmission ?? admission;
        await _terminalizeRecoveredAdmission(
          note: note,
          expected: failedAdmission,
          frozen: frozen,
          code: error.code,
          status: failedAdmission.accepted == null ? 'failed' : 'orphaned',
        );
      }
    } on Object {
      if (!_disposed) {
        _publishFailure(
          note,
          'AUTO_OUTLINE_RECOVERY_FAILED',
          frozen: frozen,
          retryable: true,
        );
      }
    }
    return true;
  }

  Future<bool> _terminalizeRecoveredAdmission({
    required V3FeedItem note,
    required AutomaticOutlinePreparedAdmission expected,
    required _FrozenAutomaticOutline frozen,
    required String code,
    required String status,
    bool publishFailure = true,
  }) async {
    final terminal = AutomaticOutlineTerminalRecord(
      attemptId: expected.attemptId,
      remoteNoteId: expected.remoteNoteId,
      operationId: expected.operationId,
      inputRawRevisionId: expected.inputRawRevisionId,
      targetOutlineRevisionId: expected.targetOutlineRevisionId,
      status: status,
      fileAgentRunId: expected.accepted?.fileAgentRunId,
      outputOutlineRevisionId: expected.accepted?.outputPartRevisionId,
      recordedAt: _now().toUtc(),
    );
    final committed = await _recoveryStore.failPrepared(
      expected: expected,
      terminal: terminal,
    );
    if (_disposed) return false;
    if (!committed) {
      final current = _recoveryStore.admissionForRemoteNote(
        expected.remoteNoteId,
      );
      if (current == null || !_sameRecoveryAdmission(current, expected)) {
        _scanAgain = true;
        return false;
      }
      _publishFailure(
        note,
        'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
        frozen: frozen,
        retryable: true,
      );
      return false;
    }
    if (publishFailure) _publishFailure(note, code, frozen: frozen);
    return true;
  }

  Future<bool> _recoverAcceptedHandoff(V3FeedItem note) async {
    if (_acceptedHandoffs.values.any((handoff) => handoff.note.id == note.id)) {
      return true;
    }
    final repository = _repository;
    if (repository is! PendingOutlineAdmissionPort) return false;
    final pending = (repository as PendingOutlineAdmissionPort)
        .pendingOutlineAdmission(note);
    final accepted = pending?.accepted;
    final workspace = _nonEmpty(workspaceScope);
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    final rawRevisionId = _nonEmpty(note.rawPartRevisionId);
    if (pending == null ||
        accepted == null ||
        workspace == null ||
        remoteNoteId == null ||
        rawRevisionId == null ||
        accepted.noteId != remoteNoteId ||
        accepted.inputPart != NoteFileAgentPart.raw ||
        accepted.inputPartRevisionId != rawRevisionId ||
        accepted.targetPart != NoteFileAgentPart.outline) {
      return false;
    }
    final targetRevisionId = _nullableTrim(accepted.targetPartRevisionId);
    final frozen = _FrozenAutomaticOutline(
      attemptId: automaticOutlineAttemptId(
        workspaceScope: workspace,
        remoteNoteId: remoteNoteId,
        inputRawRevisionId: rawRevisionId,
        targetOutlineRevisionId: targetRevisionId,
      ),
      operationId: pending.operationId,
      remoteNoteId: remoteNoteId,
      rawRevisionId: rawRevisionId,
      targetOutlineRevisionId: targetRevisionId,
      allowExistingAutomaticOutline: false,
      waitsForLinkOwnership: false,
    );
    final handoff = _PendingAcceptedOutlineHandoff(
      frozen: frozen,
      note: note,
      accepted: accepted,
    );
    _acceptedHandoffs[frozen.attemptId] = handoff;
    _attempted.add(frozen.attemptId);
    _publishPreAdmission(
      note,
      AutomaticOutlinePhase.registeringAccepted,
      frozen: frozen,
    );
    try {
      await _completeAcceptedHandoff(handoff);
      if (!_disposed) {
        _removeTransientTask(frozen.attemptId, resetRetry: true);
      }
    } on OutlineGenerationException catch (error) {
      if (!_disposed) {
        _publishFailure(
          note,
          error.code,
          frozen: frozen,
          retryable: error.isRetryable,
        );
      }
    }
    return true;
  }

  Future<void> _completeAcceptedHandoff(
    _PendingAcceptedOutlineHandoff handoff,
  ) async {
    _publishPreAdmission(
      handoff.note,
      AutomaticOutlinePhase.registeringAccepted,
      frozen: handoff.frozen,
    );
    await _bindAcceptedRun(
      handoff.note,
      handoff.accepted,
      operationId: handoff.frozen.operationId,
    );
    if (isAutomaticOutlineOperationId(handoff.frozen.operationId)) {
      final removed = await _recoveryStore.removeAccepted(
        remoteNoteId: handoff.accepted.noteId,
        attemptId: handoff.frozen.attemptId,
        fileAgentRunId: handoff.accepted.fileAgentRunId,
      );
      if (!removed) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
          isRetryable: true,
        );
      }
    }
    final repository = _repository;
    if (repository is OutlineAdmissionTrackingPort) {
      (repository as OutlineAdmissionTrackingPort).markOutlineAdmissionTracked(
        handoff.accepted,
      );
    }
    if (identical(_acceptedHandoffs[handoff.frozen.attemptId], handoff)) {
      _acceptedHandoffs.remove(handoff.frozen.attemptId);
    }
  }

  Future<void> _bindAcceptedRun(
    V3FeedItem note,
    NoteFileAgentRunSnapshot accepted, {
    required String operationId,
  }) async {
    try {
      if (_tracker case final AgentTaskSubjectMetadataPort metadata) {
        await metadata.rememberKnowledgeAssetSubject(
          localNoteId: note.id,
          subjectTitle: note.title,
        );
        if (_disposed) {
          throw const OutlineGenerationException(
            'AUTO_OUTLINE_TRACKING_FAILED',
            isRetryable: true,
          );
        }
      }
      await _tracker.trackDerivedPart(
        fileAgentRunId: accepted.fileAgentRunId,
        agentRunId: accepted.agentRunId,
        status: accepted.status,
        localNoteId: note.id,
        remoteNoteId: accepted.noteId,
        targetPart: NoteFileAgentPart.outline,
        inputPartRevisionId: accepted.inputPartRevisionId,
        targetPartRevisionId: accepted.targetPartRevisionId,
        operationId: operationId,
      );
      if (_disposed) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_TRACKING_FAILED',
          isRetryable: true,
        );
      }
    } on Object {
      throw const OutlineGenerationException(
        'AUTO_OUTLINE_TRACKING_FAILED',
        isRetryable: true,
      );
    }
    if (_tracker case final AgentTaskLedgerPort ledger) {
      final tracked = ledger.taskLedger.any(
        (task) =>
            task.taskId == accepted.fileAgentRunId &&
            task.agentRunId == accepted.agentRunId &&
            task.kind == 'derived_part' &&
            task.localNoteId == note.id &&
            task.remoteNoteId == accepted.noteId &&
            task.targetPart == NoteFileAgentPart.outline &&
            task.operationId == operationId &&
            _nonEmpty(task.inputPartRevisionId) ==
                accepted.inputPartRevisionId.trim() &&
            _nullableTrim(task.targetPartRevisionId) ==
                _nullableTrim(accepted.targetPartRevisionId),
      );
      if (!tracked) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_TRACKING_FAILED',
          isRetryable: true,
        );
      }
    }
  }

  Future<void> _refreshLinkThenReconcile(String attemptId) async {
    if (_disposed || !_foreground) return;
    final transient = _tasks[attemptId];
    var current = transient == null
        ? null
        : _library.noteForId(transient.localNoteId);
    if (current == null || _frozenAttempt(current)?.attemptId != attemptId) {
      _clearAttemptState(attemptId);
      reconcile();
      return;
    }
    final handoff = current.isLinkImportSource
        ? _resolveLinkImportHandoff(current)
        : null;
    if (handoff != null && !handoff.isResolved) {
      var refreshed = false;
      try {
        refreshed = await _refreshLinkImportHandoffFor?.call(current) ?? false;
      } on Object {
        // The persisted unresolved checkpoint remains authoritative.
      }
      if (_disposed || !_foreground) return;
      final refreshedCurrent = _library.noteForId(current.id);
      if (refreshedCurrent == null ||
          _frozenAttempt(refreshedCurrent)?.attemptId != attemptId) {
        _clearAttemptState(attemptId);
        reconcile();
        return;
      }
      current = refreshedCurrent;
      final latestHandoff = current.isLinkImportSource
          ? _resolveLinkImportHandoff(current)
          : null;
      if (!refreshed || latestHandoff == null || !latestHandoff.isResolved) {
        final failureCount = (_linkOwnershipFailureCounts[attemptId] ?? 0) + 1;
        _linkOwnershipFailureCounts[attemptId] = failureCount;
        if (failureCount >= _maximumSilentLinkOwnershipFailures) {
          _publishFailure(
            current,
            'AUTO_OUTLINE_LINK_CLASSIFICATION_UNAVAILABLE',
            frozen: _frozenAttempt(current),
            retryable: true,
          );
          return;
        }
        _scheduleLinkRecheck(attemptId, ownershipPending: true);
        return;
      }
      _linkOwnershipFailureCounts.remove(attemptId);
      reconcile();
      return;
    }

    var synchronized = false;
    try {
      synchronized = await _library.synchronizeWorkspaceContent(
        forceSnapshot: true,
      );
    } on Object {
      // Keep the grace pending; the next timer retries the authoritative read.
    }
    if (_disposed || !_foreground) return;
    final refreshedCurrent = _library.noteForId(current.id);
    if (synchronized &&
        refreshedCurrent != null &&
        _nonEmpty(refreshedCurrent.outlinePartRevisionId) != null) {
      _linkOwnershipFailureCounts.remove(attemptId);
      _linkGraceSatisfied.add(attemptId);
      final refreshedAttempt = _frozenAttempt(refreshedCurrent);
      if (refreshedAttempt != null) {
        _linkGraceSatisfied.add(refreshedAttempt.attemptId);
      }
      reconcile();
      return;
    }
    final failureCount = (_linkOwnershipFailureCounts[attemptId] ?? 0) + 1;
    _linkOwnershipFailureCounts[attemptId] = failureCount;
    if (failureCount >= _maximumSilentLinkOwnershipFailures) {
      _publishFailure(
        refreshedCurrent ?? current,
        'AUTO_OUTLINE_LINK_PROJECTION_UNAVAILABLE',
        frozen: _frozenAttempt(refreshedCurrent ?? current),
        retryable: true,
      );
      return;
    }
    _scheduleLinkRecheck(attemptId, ownershipPending: true);
  }

  Future<void> _handleSubmitFailure(
    V3FeedItem note,
    _FrozenAutomaticOutline frozen,
    String code, {
    required bool retryable,
    AutomaticOutlinePreparedAdmission? recoveryAdmission,
  }) async {
    if (_disposed) return;
    final current = _library.noteForId(note.id);
    if (!_acceptedHandoffs.containsKey(frozen.attemptId) &&
        recoveryAdmission == null &&
        (current == null ||
            !_hasRawOutlineIntent(current) ||
            _hasPendingOutline(current) ||
            _frozenAttempt(current)?.attemptId != frozen.attemptId)) {
      _removeTransientTask(frozen.attemptId, resetRetry: true);
      _scanAgain = true;
      return;
    }
    if (!retryable && recoveryAdmission != null) {
      if (!_matchesFrozenAdmission(recoveryAdmission, note, frozen)) {
        _publishFailure(
          note,
          'AUTO_OUTLINE_RECOVERY_CHECKPOINT_INVALID',
          frozen: frozen,
        );
        return;
      }
      final committed = await _terminalizeRecoveredAdmission(
        note: note,
        expected: recoveryAdmission,
        frozen: frozen,
        code: code,
        status: recoveryAdmission.accepted == null ? 'failed' : 'orphaned',
        publishFailure: false,
      );
      if (!committed || _disposed) return;
    }
    if (code == 'OUTLINE_ALREADY_EXISTS' ||
        code == 'OUTLINE_SOURCE_REVISION_CHANGED' ||
        code == 'OUTLINE_WRITE_CONFLICT') {
      _publishPreAdmission(
        note,
        AutomaticOutlinePhase.checkingRemote,
        frozen: frozen,
      );
      try {
        await _library.synchronizeWorkspaceContent(forceSnapshot: true);
      } on Object {
        // Retry below keeps the same frozen idempotency identity.
      }
      if (_disposed) return;
      final latest = _library.noteForId(note.id);
      if (latest == null ||
          !_hasRawOutlineIntent(latest) ||
          _hasPendingOutline(latest) ||
          _frozenAttempt(latest)?.attemptId != frozen.attemptId) {
        _removeTransientTask(frozen.attemptId, resetRetry: true);
        _scanAgain = true;
        return;
      }
      if (recoveryAdmission == null) {
        _publishFailure(latest, code, frozen: frozen, retryable: true);
        return;
      }
    }
    _publishFailure(
      _library.noteForId(note.id) ?? note,
      code,
      frozen: frozen,
      retryable: retryable,
    );
  }

  bool _hasRawOutlineIntent(V3FeedItem note) {
    if (note.isReadOnly ||
        note.usesBackendRecordingOutline ||
        note.rawBody.trim().isEmpty ||
        _isUnparsedPlaceholder(note)) {
      return false;
    }
    final summary = note.summaryBody?.trim();
    if (summary == null ||
        summary.isEmpty ||
        _nonEmpty(note.outlinePartRevisionId) == null ||
        _isLegacyImportDescription(note, summary)) {
      return true;
    }
    return _isProvablyStaleAutomaticOutline(note);
  }

  bool _isLegacyImportDescription(V3FeedItem note, String summary) =>
      (note.source == V3MaterialSource.documentImport &&
          (summary == '本地导入资料' || summary.startsWith('本地导入资料 · '))) ||
      (note.source == V3MaterialSource.mediaImport &&
          summary == '本地媒体导入 · 解析中');

  bool _isUnparsedPlaceholder(V3FeedItem note) {
    final raw = note.rawBody.trim();
    if (raw == '该资料正在解析中。') return true;
    return note.source == V3MaterialSource.mediaImport &&
        note.summaryBody?.trim() == '本地媒体导入 · 解析中' &&
        raw.contains('解析中：');
  }

  bool _hasExactRemoteRaw(V3FeedItem note) =>
      note.syncState == NoteSyncState.synced &&
      _nonEmpty(note.remoteNoteId) != null &&
      _nonEmpty(note.rawPartRevisionId) != null;

  bool _hasPendingOutline(V3FeedItem note) =>
      note.activeDerivedTasks.any(
        (task) => task.stage == V3DerivedTaskStage.outline && !task.isTerminal,
      ) ||
      _tracker.isDerivedPartPending(note.id, NoteFileAgentPart.outline);

  bool _hasBlockingFailedAttempt(V3FeedItem note) {
    final local = _localAttempt(note);
    if (_tasks[local.attemptId]?.isPaused == true) return true;
    final frozen = _frozenAttempt(note);
    return frozen != null && _tasks[frozen.attemptId]?.isPaused == true;
  }

  bool _isProvablyStaleAutomaticOutline(V3FeedItem note) {
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    final rawRevision = _nonEmpty(note.rawPartRevisionId);
    final outlineRevision = _nonEmpty(note.outlinePartRevisionId);
    if (remoteNoteId == null ||
        rawRevision == null ||
        outlineRevision == null ||
        !_recoveryStore.canReadRemoteNote(remoteNoteId)) {
      return false;
    }
    for (final terminal in _recoveryStore.terminalAttemptsForRemoteNote(
      remoteNoteId,
    )) {
      if (terminal.isSucceeded &&
          terminal.inputRawRevisionId != rawRevision &&
          terminal.outputOutlineRevisionId == outlineRevision &&
          isAutomaticOutlineOperationId(terminal.operationId)) {
        return true;
      }
    }
    for (final entry in _ledger.reversed) {
      if (!_isSameOutlineAsset(entry, note) ||
          entry.status != 'succeeded' ||
          !isAutomaticOutlineOperationId(entry.operationId) ||
          _nonEmpty(entry.inputPartRevisionId) == rawRevision ||
          _nonEmpty(entry.outputPartRevisionId) != outlineRevision) {
        continue;
      }
      return true;
    }
    return false;
  }

  bool _hasKnownAttempt(V3FeedItem note, _FrozenAutomaticOutline frozen) {
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    if (remoteNoteId != null) {
      for (final terminal in _recoveryStore.terminalAttemptsForRemoteNote(
        remoteNoteId,
      )) {
        final sameOperation = terminal.operationId == frozen.operationId;
        final sameRevisions =
            terminal.inputRawRevisionId == frozen.rawRevisionId &&
            terminal.targetOutlineRevisionId == frozen.targetOutlineRevisionId;
        if (sameOperation || sameRevisions && terminal.isSucceeded) {
          return true;
        }
      }
    }
    for (final entry in _ledger) {
      if (!_isSameOutlineAsset(entry, note) ||
          entry.targetPart != NoteFileAgentPart.outline) {
        continue;
      }
      final sameOperation = entry.operationId == frozen.operationId;
      final sameRevisions =
          _nonEmpty(entry.inputPartRevisionId) == frozen.rawRevisionId &&
          _nullableTrim(entry.targetPartRevisionId) ==
              frozen.targetOutlineRevisionId;
      if (sameOperation) return true;
      if (sameRevisions && (!entry.isTerminal || entry.status == 'succeeded')) {
        return true;
      }
    }
    return false;
  }

  bool _isSameOutlineAsset(AgentTaskLedgerEntry entry, V3FeedItem note) {
    final remoteId = _nonEmpty(note.remoteNoteId);
    return entry.kind == 'derived_part' &&
        entry.targetPart == NoteFileAgentPart.outline &&
        (entry.localNoteId == note.id ||
            (remoteId != null && entry.remoteNoteId == remoteId));
  }

  List<AgentTaskLedgerEntry> get _ledger => _tracker is AgentTaskLedgerPort
      ? (_tracker as AgentTaskLedgerPort).taskLedger
      : const <AgentTaskLedgerEntry>[];

  _FrozenAutomaticOutline? _frozenAttempt(V3FeedItem note) {
    final workspace = _nonEmpty(workspaceScope);
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    final rawRevisionId = _nonEmpty(note.rawPartRevisionId);
    if (workspace == null || remoteNoteId == null || rawRevisionId == null) {
      return null;
    }
    final targetRevisionId = _nullableTrim(note.outlinePartRevisionId);
    final digest = automaticOutlineAttemptId(
      workspaceScope: workspace,
      remoteNoteId: remoteNoteId,
      inputRawRevisionId: rawRevisionId,
      targetOutlineRevisionId: targetRevisionId,
    );
    final linkHandoff = note.isLinkImportSource
        ? _resolveLinkImportHandoff(note)
        : null;
    final replacesStaleAutomaticOutline = _isProvablyStaleAutomaticOutline(
      note,
    );
    final backendMediaOperationId =
        linkHandoff?.owner == MaterialLinkOutlineOwner.backendMedia
        ? linkHandoff?.operationId
        : null;
    final mayReuseInitialMediaHandoff =
        !replacesStaleAutomaticOutline &&
        backendMediaOperationId != null &&
        !_hasFailedOperation(note, backendMediaOperationId);
    final linkedOperationId = mayReuseInitialMediaHandoff
        ? backendMediaOperationId
        : null;
    return _FrozenAutomaticOutline(
      attemptId: digest,
      operationId:
          linkedOperationId ?? 'auto-outline-v1-${digest.substring(0, 48)}',
      remoteNoteId: remoteNoteId,
      rawRevisionId: rawRevisionId,
      targetOutlineRevisionId: targetRevisionId,
      allowExistingAutomaticOutline: replacesStaleAutomaticOutline,
      waitsForLinkOwnership: linkHandoff != null && !linkHandoff.isResolved,
    );
  }

  bool _hasFailedOperation(V3FeedItem note, String operationId) {
    final remoteNoteId = _nonEmpty(note.remoteNoteId);
    if (remoteNoteId != null &&
        _recoveryStore
            .terminalAttemptsForRemoteNote(remoteNoteId)
            .any(
              (terminal) =>
                  terminal.operationId == operationId && !terminal.isSucceeded,
            )) {
      return true;
    }
    return _ledger.any(
      (entry) =>
          _isSameOutlineAsset(entry, note) &&
          entry.operationId == operationId &&
          entry.isTerminal &&
          entry.status != 'succeeded',
    );
  }

  AutomaticOutlineLinkHandoff? _resolveLinkImportHandoff(V3FeedItem note) {
    try {
      final handoff = _linkImportHandoffFor?.call(note);
      if (handoff == null || !handoff.isResolved) return handoff;
      if (handoff.owner == MaterialLinkOutlineOwner.client) {
        return const AutomaticOutlineLinkHandoff.client();
      }
      final operationId = _safeLinkImportOperationId(handoff.operationId);
      return operationId == null
          ? const AutomaticOutlineLinkHandoff.unresolved()
          : AutomaticOutlineLinkHandoff.backendMedia(operationId);
    } on Object {
      return const AutomaticOutlineLinkHandoff.unresolved();
    }
  }

  void _scheduleLinkRecheck(
    String attemptId, {
    required bool ownershipPending,
  }) {
    final delay = ownershipPending
        ? _boundedLinkOwnershipRetryDelay(attemptId)
        : _linkBackendGrace;
    if (delay <= Duration.zero) return;
    _linkGraceTimers.putIfAbsent(
      attemptId,
      () => Timer(delay, () {
        _linkGraceTimers.remove(attemptId);
        unawaited(_refreshLinkThenReconcile(attemptId));
      }),
    );
  }

  Duration _boundedLinkOwnershipRetryDelay(String attemptId) {
    final failureCount = _linkOwnershipFailureCounts[attemptId] ?? 0;
    final multiplier = 1 << failureCount.clamp(0, 8).toInt();
    final proposed = _linkOwnershipRetryBaseDelay * multiplier;
    return proposed > _retryMaximumDelay ? _retryMaximumDelay : proposed;
  }

  void _publishPreAdmission(
    V3FeedItem note,
    AutomaticOutlinePhase phase, {
    _FrozenAutomaticOutline? frozen,
  }) {
    if (_disposed) return;
    final attempt = frozen ?? _frozenAttempt(note) ?? _localAttempt(note);
    final at = _now();
    final current = _tasks[attempt.attemptId];
    final subjectTitle = _subjectTitle(note);
    if (current != null &&
        current.phase == phase &&
        current.operationId == attempt.operationId &&
        current.remoteNoteId == attempt.remoteNoteId &&
        current.inputRawRevisionId == attempt.rawRevisionId &&
        current.targetOutlineRevisionId == attempt.targetOutlineRevisionId &&
        current.subjectTitle == subjectTitle &&
        current.errorCode == null) {
      return;
    }
    _tasks[attempt.attemptId] = current == null
        ? AutomaticOutlineTaskSnapshot(
            attemptId: attempt.attemptId,
            operationId: attempt.operationId,
            localNoteId: note.id,
            remoteNoteId: attempt.remoteNoteId,
            inputRawRevisionId: attempt.rawRevisionId,
            targetOutlineRevisionId: attempt.targetOutlineRevisionId,
            subjectTitle: subjectTitle,
            phase: phase,
            createdAt: at,
            updatedAt: at,
          )
        : current.advance(
            phase,
            at: at,
            operationId: attempt.operationId,
            remoteNoteId: attempt.remoteNoteId,
            inputRawRevisionId: attempt.rawRevisionId,
            targetOutlineRevisionId: attempt.targetOutlineRevisionId,
            subjectTitle: subjectTitle,
          );
    notifyListeners();
  }

  void _publishFailure(
    V3FeedItem? note,
    String code, {
    _FrozenAutomaticOutline? frozen,
    String? fallbackLocalNoteId,
    bool retryable = false,
  }) {
    if (_disposed || note == null) return;
    final attempt = frozen ?? _frozenAttempt(note) ?? _localAttempt(note);
    final at = _now();
    final current = _tasks[attempt.attemptId];
    final subjectTitle = _subjectTitle(note);
    final nextPhase = retryable
        ? AutomaticOutlinePhase.retryWaiting
        : AutomaticOutlinePhase.failed;
    final resumePhase = current?.phase == AutomaticOutlinePhase.retryWaiting
        ? current?.resumePhase
        : current?.phase;
    final retryAt = retryable ? _scheduleRetry(attempt.attemptId) : null;
    final unchanged =
        current != null &&
        current.phase == nextPhase &&
        current.operationId == attempt.operationId &&
        current.remoteNoteId == attempt.remoteNoteId &&
        current.inputRawRevisionId == attempt.rawRevisionId &&
        current.targetOutlineRevisionId == attempt.targetOutlineRevisionId &&
        current.subjectTitle == subjectTitle &&
        current.errorCode == code;
    if (!unchanged) {
      _tasks[attempt.attemptId] = current == null
          ? AutomaticOutlineTaskSnapshot(
              attemptId: attempt.attemptId,
              operationId: attempt.operationId,
              localNoteId: fallbackLocalNoteId ?? note.id,
              remoteNoteId: attempt.remoteNoteId,
              inputRawRevisionId: attempt.rawRevisionId,
              targetOutlineRevisionId: attempt.targetOutlineRevisionId,
              subjectTitle: subjectTitle,
              phase: nextPhase,
              createdAt: at,
              updatedAt: at,
              errorCode: code,
              resumePhase: resumePhase,
              retryAt: retryAt,
            )
          : current.advance(
              nextPhase,
              at: at,
              operationId: attempt.operationId,
              subjectTitle: subjectTitle,
              errorCode: code,
              resumePhase: resumePhase,
              retryAt: retryAt,
            );
      notifyListeners();
    }
  }

  DateTime? _scheduleRetry(String attemptId) {
    if (_disposed || _retryTimers.containsKey(attemptId)) {
      return _tasks[attemptId]?.retryAt;
    }
    final failureCount = (_failureCounts[attemptId] ?? 0) + 1;
    _failureCounts[attemptId] = failureCount;
    final multiplier = 1 << (failureCount - 1).clamp(0, 8).toInt();
    final proposed = _retryBaseDelay * multiplier;
    final delay = proposed > _retryMaximumDelay ? _retryMaximumDelay : proposed;
    _retryTimers[attemptId] = Timer(delay, () {
      _retryTimers.remove(attemptId);
      unawaited(_releaseRetry(attemptId));
    });
    return _now().add(delay);
  }

  Future<void> _releaseRetry(String attemptId) async {
    if (_disposed) return;
    if (!_foreground) {
      _retryDue.add(attemptId);
      return;
    }
    _retryDue.remove(attemptId);
    final waiting = _tasks[attemptId];
    if (waiting == null ||
        waiting.phase != AutomaticOutlinePhase.retryWaiting) {
      return;
    }
    final acceptedHandoff = _acceptedHandoffs[attemptId];
    if (acceptedHandoff != null) {
      try {
        await _completeAcceptedHandoff(acceptedHandoff);
        if (_disposed) return;
        _removeTransientTask(attemptId, resetRetry: true);
      } on OutlineGenerationException catch (error) {
        if (_disposed) return;
        _publishFailure(
          _library.noteForId(acceptedHandoff.note.id) ?? acceptedHandoff.note,
          error.code,
          frozen: acceptedHandoff.frozen,
          retryable: error.isRetryable,
        );
      }
      return;
    }
    if (_tasks[attemptId]?.errorCode !=
        'AUTO_OUTLINE_LINK_CLASSIFICATION_UNAVAILABLE') {
      try {
        await _library.synchronizeWorkspaceContent(forceSnapshot: true);
      } on Object {
        // The exact-revision repository remains the final admission guard.
      }
    }
    if (_disposed) return;
    if (!_foreground) {
      _retryDue.add(attemptId);
      return;
    }
    _attempted.remove(attemptId);
    _linkOwnershipFailureCounts.remove(attemptId);
    _tasks[attemptId] = waiting.advance(
      waiting.resumePhase ?? AutomaticOutlinePhase.checkingRemote,
      at: _now(),
    );
    notifyListeners();
    reconcile();
  }

  _FrozenAutomaticOutline _localAttempt(V3FeedItem note) {
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String>[
              'auto-outline-local-v1',
              workspaceScope ?? '',
              note.id,
              note.localRevision.toString(),
            ]),
          ),
        )
        .toString();
    return _FrozenAutomaticOutline(
      attemptId: digest,
      operationId: 'auto-outline-v1-${digest.substring(0, 48)}',
      remoteNoteId: _nonEmpty(note.remoteNoteId),
      rawRevisionId: _nonEmpty(note.rawPartRevisionId),
      targetOutlineRevisionId: _nullableTrim(note.outlinePartRevisionId),
      allowExistingAutomaticOutline: false,
      waitsForLinkOwnership: false,
    );
  }

  void _pruneTransientTasks(List<V3FeedItem> notes) {
    if (_disposed) return;
    final byId = <String, V3FeedItem>{for (final note in notes) note.id: note};
    final currentAttemptIds = <String>{};
    currentAttemptIds.addAll(_acceptedHandoffs.keys);
    for (final note in notes) {
      if (!_hasRawOutlineIntent(note)) continue;
      if (_hasExactRemoteRaw(note)) {
        final frozen = _frozenAttempt(note);
        if (frozen != null) currentAttemptIds.add(frozen.attemptId);
      } else {
        currentAttemptIds.add(_localAttempt(note).attemptId);
      }
    }
    final removed = <String>{};
    var changed = false;
    final now = _now();
    for (final entry in _tasks.entries) {
      final snapshot = entry.value;
      final note = byId[snapshot.localNoteId];
      if (_acceptedHandoffs.containsKey(entry.key)) continue;
      if (note == null ||
          !currentAttemptIds.contains(entry.key) ||
          !_hasRawOutlineIntent(note) ||
          _hasPendingOutline(note) ||
          (snapshot.isTerminal &&
              _terminalNoticeRetention > Duration.zero &&
              now.difference(snapshot.updatedAt) > _terminalNoticeRetention)) {
        removed.add(entry.key);
        continue;
      }
      final title = _subjectTitle(note);
      if (snapshot.subjectTitle != title) {
        _tasks[entry.key] = snapshot.advance(
          snapshot.phase,
          at: snapshot.updatedAt,
          subjectTitle: title,
          errorCode: snapshot.errorCode,
        );
        changed = true;
      }
    }

    final terminal =
        _tasks.entries
            .where(
              (entry) => entry.value.isTerminal && !removed.contains(entry.key),
            )
            .toList(growable: false)
          ..sort(
            (left, right) =>
                right.value.updatedAt.compareTo(left.value.updatedAt),
          );
    const maximumTerminalNotices = 50;
    for (final entry in terminal.skip(maximumTerminalNotices)) {
      removed.add(entry.key);
    }
    for (final key in removed) {
      _tasks.remove(key);
      _clearAttemptState(key);
    }
    _attempted.removeWhere(
      (attemptId) =>
          !currentAttemptIds.contains(attemptId) &&
          !_tasks.containsKey(attemptId),
    );
    _linkGraceSatisfied.removeWhere(
      (attemptId) => !currentAttemptIds.contains(attemptId),
    );
    if (removed.isNotEmpty || changed) notifyListeners();
  }

  void _removeTransientTask(String attemptId, {bool resetRetry = false}) {
    if (_disposed) return;
    if (_tasks.remove(attemptId) != null) notifyListeners();
    if (resetRetry) _clearAttemptState(attemptId);
  }

  void _clearAttemptState(String attemptId) {
    _attempted.remove(attemptId);
    _failureCounts.remove(attemptId);
    _retryDue.remove(attemptId);
    _retryTimers.remove(attemptId)?.cancel();
    _linkGraceSatisfied.remove(attemptId);
    _linkOwnershipFailureCounts.remove(attemptId);
    _linkGraceTimers.remove(attemptId)?.cancel();
  }

  String _subjectTitle(V3FeedItem note) {
    final normalized = note.title.trim();
    if (normalized.isEmpty) return '未命名资产';
    return String.fromCharCodes(normalized.runes.take(160));
  }

  String _automaticSyncFailureCode(KnowledgeNoteSyncResult result) =>
      switch (result.outcome) {
        KnowledgeNoteSyncOutcome.conflict => 'AUTO_OUTLINE_SYNC_CONFLICT',
        KnowledgeNoteSyncOutcome.unavailable =>
          result.errorCode ?? 'AUTO_OUTLINE_SYNC_UNAVAILABLE',
        KnowledgeNoteSyncOutcome.notEditable => 'AUTO_OUTLINE_SYNC_NOT_ALLOWED',
        KnowledgeNoteSyncOutcome.superseded => 'AUTO_OUTLINE_SYNC_SUPERSEDED',
        KnowledgeNoteSyncOutcome.failed =>
          result.errorCode ?? 'AUTO_OUTLINE_SYNC_FAILED',
        KnowledgeNoteSyncOutcome.synced => 'AUTO_OUTLINE_SYNC_FAILED',
      };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _library.removeListener(_handleKnowledgeChanged);
      if (_tracker case final Listenable tracker) {
        tracker.removeListener(_handleTrackerChanged);
      }
    }
    for (final timer in _linkGraceTimers.values) {
      timer.cancel();
    }
    _linkGraceTimers.clear();
    _linkOwnershipFailureCounts.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryDue.clear();
    _acceptedHandoffs.clear();
    super.dispose();
  }
}

// resident-provider: Serializes automatic Outline admission across all routes in one ready Workspace.
final automaticOutlineCoordinatorProvider =
    ChangeNotifierProvider<AutomaticOutlineCoordinator>((ref) {
      final workspaceId = ref.watch(
        sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
      );
      final repository = ref.watch(outlineRepositoryProvider);
      final materialIngestions = ref.watch(materialIngestionStoreProvider);
      final materialIngestionCoordinator = ref.watch(
        materialIngestionCoordinatorProvider.notifier,
      );
      final coordinator = AutomaticOutlineCoordinator(
        library: ref.watch(knowledgeLibraryControllerProvider.notifier),
        repository: repository is AcceptedOutlineRunRepository
            ? repository as AcceptedOutlineRunRepository
            : null,
        tracker: ref.watch(chatRunTrackerProvider.notifier),
        workspaceScope: workspaceId == null || workspaceId.isEmpty
            ? null
            : workspaceId,
        recoveryStore: ref.watch(automaticOutlineRecoveryStoreProvider),
        linkImportHandoffFor: (note) => automaticOutlineLinkHandoffForDrafts(
          note,
          materialIngestions.listAll(),
        ),
        refreshLinkImportHandoffFor: (note) => materialIngestionCoordinator
            .refreshLinkOutlineOwnershipForNote(note.id),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

String? _safeLinkImportOperationId(String? value) {
  final normalized = value?.trim();
  return normalized != null &&
          RegExp(
            r'^media-outline:ingestion_[A-Za-z0-9._-]{1,128}$',
          ).hasMatch(normalized) &&
          normalized.length <= 160
      ? normalized
      : null;
}

const _maximumSilentLinkOwnershipFailures = 3;
const _automaticOutlineReplayReceiptWindow = Duration(hours: 24);

final class _FrozenAutomaticOutline {
  const _FrozenAutomaticOutline({
    required this.attemptId,
    required this.operationId,
    required this.remoteNoteId,
    required this.rawRevisionId,
    required this.targetOutlineRevisionId,
    required this.allowExistingAutomaticOutline,
    required this.waitsForLinkOwnership,
  });

  final String attemptId;
  final String operationId;
  final String? remoteNoteId;
  final String? rawRevisionId;
  final String? targetOutlineRevisionId;
  final bool allowExistingAutomaticOutline;
  final bool waitsForLinkOwnership;
}

final class _PendingAcceptedOutlineHandoff {
  const _PendingAcceptedOutlineHandoff({
    required this.frozen,
    required this.note,
    required this.accepted,
  });

  final _FrozenAutomaticOutline frozen;
  final V3FeedItem note;
  final NoteFileAgentRunSnapshot accepted;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _sameRecoveryAdmission(
  AutomaticOutlinePreparedAdmission left,
  AutomaticOutlinePreparedAdmission right,
) =>
    left.attemptId == right.attemptId &&
    left.operationId == right.operationId &&
    left.backendAdmissionAttempt == right.backendAdmissionAttempt &&
    left.request.idempotencyKey == right.request.idempotencyKey &&
    left.createdAt.isAtSameMomentAs(right.createdAt) &&
    left.accepted?.fileAgentRunId == right.accepted?.fileAgentRunId;

bool _matchesFrozenAdmission(
  AutomaticOutlinePreparedAdmission admission,
  V3FeedItem note,
  _FrozenAutomaticOutline frozen,
) =>
    admission.attemptId == frozen.attemptId &&
    admission.localNoteId == note.id &&
    admission.operationId == frozen.operationId &&
    admission.remoteNoteId == frozen.remoteNoteId &&
    admission.inputRawRevisionId == frozen.rawRevisionId &&
    admission.targetOutlineRevisionId == frozen.targetOutlineRevisionId;

String? _nullableTrim(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
