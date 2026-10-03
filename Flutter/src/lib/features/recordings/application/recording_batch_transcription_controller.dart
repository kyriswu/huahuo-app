// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../data/local_recording_repository.dart';
import '../data/recording_api.dart';
import '../domain/recording_batch_transcription.dart';
import '../domain/recording_library.dart';
import '../domain/recording_transcription_receipt.dart';
import 'recording_processing_tracker.dart';
import 'recording_upload_controller.dart';

enum RecordingBatchAuthoritativeState {
  processing,
  transcriptReady,
  assetReady,
  failed,
  timedOut,
  temporarilyUnavailable,
}

final class RecordingBatchAuthoritativeUpdate {
  const RecordingBatchAuthoritativeUpdate({
    required this.state,
    required this.checkedAt,
    this.remoteRecordingId,
    this.noteId,
    this.progress,
    this.transcriptCompletedAt,
    this.assetReadyAt,
    this.phase,
    this.errorCode,
    this.failureCategory,
    this.retryable = false,
    this.waitingReason,
  });

  final RecordingBatchAuthoritativeState state;
  final DateTime checkedAt;
  final String? remoteRecordingId;
  final String? noteId;
  final int? progress;
  final DateTime? transcriptCompletedAt;
  final DateTime? assetReadyAt;
  final RecordingBatchTranscriptionPhase? phase;
  final String? errorCode;
  final RecordingBatchFailureCategory? failureCategory;
  final bool retryable;
  final RecordingBatchWaitingReason? waitingReason;
}

final class RecordingBatchSubmissionResult {
  const RecordingBatchSubmissionResult.accepted({
    required this.remoteRecordingId,
    this.serverAcceptedNewAttempt = true,
  }) : accepted = true,
       errorCode = null,
       failureCategory = null,
       retryable = false;

  const RecordingBatchSubmissionResult.failed({
    required this.errorCode,
    required this.failureCategory,
    required this.retryable,
  }) : accepted = false,
       remoteRecordingId = null,
       serverAcceptedNewAttempt = false;

  final bool accepted;
  final String? remoteRecordingId;
  final String? errorCode;
  final RecordingBatchFailureCategory? failureCategory;
  final bool retryable;
  final bool serverAcceptedNewAttempt;
}

/// Mutation boundary for existing single-recording APIs.
///
/// Implementations must keep `jobId` idempotent. `verifyExisting` is a
/// read-only authority check and must never create a second remote recording.
abstract interface class RecordingBatchTranscriptionExecutionPort {
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  );

  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  );

  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  );
}

/// Keeps the durable batch projection aligned with a retry initiated from the
/// recording-backed Note detail without moving the retry command into messages.
abstract interface class RecordingOutlineRetryLifecyclePort {
  Future<void> acceptOutlineRetry({
    required String recordingId,
    required String retryTaskId,
    required String retryStage,
    String? supersededOutlineTaskId,
  });

  Future<void> rejectOutlineRetry({
    required String recordingId,
    required String errorCode,
  });
}

/// Builds frozen candidates from the existing durable upload and processing
/// authorities. Presentation only supplies the selected library item.
final class RecordingTranscriptionCandidateFactory {
  const RecordingTranscriptionCandidateFactory({
    required UploadDraftStore draftStore,
    required RecordingProcessingDetailObservationPort processing,
  }) : _draftStore = draftStore,
       _processing = processing;

  final UploadDraftStore _draftStore;
  final RecordingProcessingDetailObservationPort _processing;

  RecordingTranscriptionCandidate fromLibraryItem(RecordingLibraryItem item) {
    final jobId = recordingFileJobId(item);
    final draft = _draftStore.getDraft(jobId);
    final remoteRecordingId = _firstText(
      item.remoteRecordingId,
      draft?.recordingId,
    );
    final task = remoteRecordingId == null
        ? null
        : _processing.processingTaskFor(remoteRecordingId);
    final detail = task?.detail;
    final fact = _remoteFact(detail: detail, task: task, draft: draft);
    final observedAt = task?.updatedAt.toUtc();
    return RecordingTranscriptionCandidate(
      itemId: item.recordingId,
      title: item.displayName,
      fileIdentity: _firstText(item.contentHash, 'local:${item.recordingId}')!,
      localRecordingId: item.recordingId,
      jobId: jobId,
      deviceFilename: item.deviceFilename ?? item.originalFilename,
      contentHash: _nonEmpty(item.contentHash),
      remoteRecordingId: remoteRecordingId,
      remoteFact: fact,
      remoteProgress: detail?.asrTask?.progress,
      noteId: detail?.canonicalNoteId,
      transcriptCompletedAt: detail?.hasFinalTranscriptFact == true
          ? observedAt
          : null,
      assetReadyAt: detail?.hasCloudAsset == true ? observedAt : null,
      transcriptionNotRequired: isMonologueRecordingHistoryItem(item),
      localFileAvailable:
          item.status != RecordingLibraryStatus.recycled &&
          item.localFileState == RecordingLocalFileState.ready &&
          _nonEmpty(item.appPrivateUri) != null,
      formatSupported: item.format != RecordingLibraryFormat.unknown,
      retryable:
          detail?.effectiveRetryActions.any(
            (action) => action.stage.trim() == 'asr',
          ) ==
          true,
      errorCode: task?.errorCode ?? draft?.lastErrorCode,
    );
  }

  RecordingTranscriptionRemoteFact _remoteFact({
    required RecordingDetail? detail,
    required RecordingProcessingTask? task,
    required UploadDraft? draft,
  }) {
    if (detail?.hasCloudAsset == true) {
      return RecordingTranscriptionRemoteFact.assetReady;
    }
    if (detail?.hasFinalTranscriptFact == true) {
      return RecordingTranscriptionRemoteFact.transcriptReady;
    }
    final remoteStatus = detail?.asrTask?.status ?? detail?.recording.status;
    if (remoteStatus == RecordingRemoteStatus.timeout) {
      return RecordingTranscriptionRemoteFact.timedOut;
    }
    if (remoteStatus == RecordingRemoteStatus.failed ||
        remoteStatus == RecordingRemoteStatus.cancelled ||
        task?.phase == RecordingProcessingPhase.failed ||
        draft?.stage == UploadDraftStage.asrFailed) {
      return detail?.effectiveRetryActions.any(
                (action) => action.stage.trim() == 'asr',
              ) ==
              true
          ? RecordingTranscriptionRemoteFact.retryableFailure
          : RecordingTranscriptionRemoteFact.terminalFailure;
    }
    if (detail != null ||
        task?.isActive == true ||
        draft?.stage == UploadDraftStage.asrQueued ||
        draft?.stage == UploadDraftStage.uploaded) {
      return RecordingTranscriptionRemoteFact.processing;
    }
    return RecordingTranscriptionRemoteFact.unknown;
  }
}

/// Concrete bridge to the existing one-file upload and Recording APIs.
final class RecordingBatchTranscriptionExecutionAdapter
    implements RecordingBatchTranscriptionExecutionPort {
  const RecordingBatchTranscriptionExecutionAdapter({
    required RecordingUploadController uploadController,
    required LocalRecordingRepository localRecordingRepository,
    required RecordingApiPort recordingApi,
    required RecordingProcessingRetryPort processingRetryPort,
    RecordingSpeakerAutoAdvancePort? speakerAutoAdvancePort,
    DateTime Function()? now,
  }) : _uploadController = uploadController,
       _localRecordingRepository = localRecordingRepository,
       _recordingApi = recordingApi,
       _processingRetryPort = processingRetryPort,
       _speakerAutoAdvancePort = speakerAutoAdvancePort,
       _now = now ?? DateTime.now;

  final RecordingUploadController _uploadController;
  final LocalRecordingRepository _localRecordingRepository;
  final RecordingApiPort _recordingApi;
  final RecordingProcessingRetryPort _processingRetryPort;
  final RecordingSpeakerAutoAdvancePort? _speakerAutoAdvancePort;
  final DateTime Function() _now;

  @override
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  ) async {
    final local = _localRecordingRepository.findById(item.localRecordingId);
    if (local == null ||
        local.localFileState != RecordingLocalFileState.ready ||
        local.status == RecordingLibraryStatus.recycled) {
      return const RecordingBatchSubmissionResult.failed(
        errorCode: 'RECORDING_FILE_UNAVAILABLE',
        failureCategory: RecordingBatchFailureCategory.unavailable,
        retryable: false,
      );
    }
    final response = await _uploadController.uploadLocalRecording(
      item: local,
      sourceScene: 'raw_material',
      title: local.displayName,
    );
    final remoteRecordingId = _firstText(
      response?.recording.recordingId,
      _uploadController.draftForJob(item.jobId)?.recordingId,
    );
    if (remoteRecordingId != null) {
      return RecordingBatchSubmissionResult.accepted(
        remoteRecordingId: remoteRecordingId,
      );
    }
    final draft = _uploadController.draftForJob(item.jobId);
    return RecordingBatchSubmissionResult.failed(
      errorCode:
          draft?.lastErrorCode ??
          _uploadController.state.lastErrorCode ??
          'RECORDING_BATCH_SUBMISSION_FAILED',
      failureCategory: RecordingBatchFailureCategory.upload,
      retryable: draft?.stage != UploadDraftStage.asrFailed,
    );
  }

  @override
  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  ) async {
    final remoteRecordingId = _nonEmpty(item.remoteRecordingId);
    final checkedAt = _now().toUtc();
    if (remoteRecordingId == null) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
        checkedAt: checkedAt,
        errorCode: 'RECORDING_ID_MISSING',
        waitingReason: RecordingBatchWaitingReason.remoteVerificationRequired,
      );
    }
    final handoff = _uploadController.handoffQueuedProcessingForLocalRecording(
      localRecordingId: item.localRecordingId,
      recordingId: remoteRecordingId,
    );
    final trackerOwnsObservation =
        handoff.status == RecordingProcessingHandoffStatus.enqueued ||
        handoff.status == RecordingProcessingHandoffStatus.alreadyEnrolled;
    final response = await _recordingApi.getRecordingDetail(remoteRecordingId);
    final detail = response.data;
    if (!response.ok || detail == null) {
      return _verificationFailure(
        failure: response.error,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
      );
    }
    if (detail.recording.recordingId != remoteRecordingId) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.failed,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        errorCode: 'RECORDING_DETAIL_ID_MISMATCH',
        failureCategory: RecordingBatchFailureCategory.remote,
      );
    }
    final speakerAdvance = await _advanceSpeakerStage(detail);
    if (speakerAdvance.status !=
        RecordingSpeakerAutoAdvanceStatus.notRequired) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.processing,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        progress: detail.asrTask?.progress,
        phase: RecordingBatchTranscriptionPhase.transcribing,
        waitingReason: RecordingBatchWaitingReason.remoteVerificationRequired,
      );
    }
    if (detail.hasCloudAsset) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.assetReady,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        noteId: detail.canonicalNoteId,
        progress: 100,
        transcriptCompletedAt: item.transcriptCompletedAt ?? checkedAt,
        assetReadyAt: checkedAt,
        phase: RecordingBatchTranscriptionPhase.assetReady,
      );
    }
    if (detail.hasFinalTranscriptFact) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.transcriptReady,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        noteId: detail.canonicalNoteId,
        progress: detail.asrTask?.progress,
        transcriptCompletedAt: item.transcriptCompletedAt ?? checkedAt,
        phase: RecordingBatchTranscriptionPhase.storingAsset,
      );
    }
    final status = detail.asrTask?.status ?? detail.recording.status;
    if (status == RecordingRemoteStatus.timeout) {
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.timedOut,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        errorCode: 'RECORDING_TRANSCRIPTION_REMOTE_TIMEOUT',
      );
    }
    if (status == RecordingRemoteStatus.failed ||
        status == RecordingRemoteStatus.cancelled) {
      final retryable = detail.effectiveRetryActions.any(
        (action) => action.stage.trim() == 'asr',
      );
      return RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.failed,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        errorCode: status == RecordingRemoteStatus.cancelled
            ? 'RECORDING_TRANSCRIPTION_CANCELLED'
            : 'RECORDING_TRANSCRIPTION_FAILED',
        failureCategory: RecordingBatchFailureCategory.transcription,
        retryable: retryable,
      );
    }
    return RecordingBatchAuthoritativeUpdate(
      state: RecordingBatchAuthoritativeState.processing,
      checkedAt: checkedAt,
      remoteRecordingId: remoteRecordingId,
      progress: detail.asrTask?.progress,
      phase: RecordingBatchTranscriptionPhase.transcribing,
      waitingReason: trackerOwnsObservation
          ? null
          : RecordingBatchWaitingReason.remoteVerificationRequired,
    );
  }

  @override
  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  ) async {
    final remoteRecordingId = _nonEmpty(item.remoteRecordingId);
    if (remoteRecordingId == null) {
      return const RecordingBatchSubmissionResult.failed(
        errorCode: 'RECORDING_ID_MISSING',
        failureCategory: RecordingBatchFailureCategory.remote,
        retryable: false,
      );
    }
    final detailResult = await _recordingApi.getRecordingDetail(
      remoteRecordingId,
    );
    final detail = detailResult.data;
    final canRetry =
        detailResult.ok &&
        detail != null &&
        detail.effectiveRetryActions.any(
          (action) => action.stage.trim() == 'asr',
        );
    if (!canRetry) {
      return _submissionFailure(
        failure: detailResult.error,
        fallbackCode: 'RECORDING_RETRY_NOT_ALLOWED',
      );
    }
    final result = await _recordingApi.retryRecording(
      recordingId: remoteRecordingId,
      stage: 'asr',
      idempotencyKey: '${item.jobId}-retry-${item.attemptCount + 1}',
    );
    final retried = result.data;
    if (!result.ok || retried == null) {
      return _submissionFailure(
        failure: result.error,
        fallbackCode: 'RECORDING_RETRY_FAILED',
      );
    }
    if (_nonEmpty(retried.recordingId) != remoteRecordingId ||
        retried.stage != 'asr' ||
        !retried.status.isAccepted) {
      return const RecordingBatchSubmissionResult.failed(
        errorCode: 'RECORDING_TRANSCRIPTION_RETRY_IDENTITY_MISMATCH',
        failureCategory: RecordingBatchFailureCategory.remote,
        retryable: false,
      );
    }
    try {
      await _processingRetryPort.reenrollAfterRetry(remoteRecordingId);
    } on Object {
      // Server acceptance is durable; the controller's authority read owns
      // recovery when tracker re-enrollment is unavailable.
    }
    return RecordingBatchSubmissionResult.accepted(
      remoteRecordingId: remoteRecordingId,
    );
  }

  Future<RecordingSpeakerAutoAdvanceOutcome> _advanceSpeakerStage(
    RecordingDetail detail,
  ) async {
    final port = _speakerAutoAdvancePort;
    if (port == null) {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.notRequired,
      );
    }
    try {
      return await port.advanceSpeakerStageIfNeeded(detail);
    } on Object {
      return const RecordingSpeakerAutoAdvanceOutcome(
        RecordingSpeakerAutoAdvanceStatus.retryWaiting,
        errorCode: 'RECORDING_SPEAKER_AUTO_ADVANCE_FAILED',
      );
    }
  }
}

RecordingBatchAuthoritativeUpdate _verificationFailure({
  required AppFailure? failure,
  required DateTime checkedAt,
  required String remoteRecordingId,
}) {
  final code = failure?.code ?? 'RECORDING_DETAIL_UNAVAILABLE';
  if (failure?.category == AppFailureCategory.auth ||
      failure?.category == AppFailureCategory.permission) {
    return RecordingBatchAuthoritativeUpdate(
      state: RecordingBatchAuthoritativeState.failed,
      checkedAt: checkedAt,
      remoteRecordingId: remoteRecordingId,
      errorCode: code,
      failureCategory: RecordingBatchFailureCategory.authorization,
      retryable: false,
    );
  }
  if (failure?.category == AppFailureCategory.network) {
    return RecordingBatchAuthoritativeUpdate(
      state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
      checkedAt: checkedAt,
      remoteRecordingId: remoteRecordingId,
      errorCode: code,
      waitingReason: RecordingBatchWaitingReason.networkRequired,
    );
  }
  if (failure?.isRetryable == true) {
    return RecordingBatchAuthoritativeUpdate(
      state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
      checkedAt: checkedAt,
      remoteRecordingId: remoteRecordingId,
      errorCode: code,
      waitingReason: RecordingBatchWaitingReason.remoteVerificationRequired,
    );
  }
  return RecordingBatchAuthoritativeUpdate(
    state: RecordingBatchAuthoritativeState.failed,
    checkedAt: checkedAt,
    remoteRecordingId: remoteRecordingId,
    errorCode: code,
    failureCategory: RecordingBatchFailureCategory.remote,
    retryable: false,
  );
}

RecordingBatchSubmissionResult _submissionFailure({
  required AppFailure? failure,
  required String fallbackCode,
}) {
  final authorization =
      failure?.category == AppFailureCategory.auth ||
      failure?.category == AppFailureCategory.permission;
  return RecordingBatchSubmissionResult.failed(
    errorCode: failure?.code ?? fallbackCode,
    failureCategory: authorization
        ? RecordingBatchFailureCategory.authorization
        : RecordingBatchFailureCategory.remote,
    retryable:
        !authorization &&
        (failure?.category == AppFailureCategory.network ||
            failure?.isRetryable == true),
  );
}

final class RecordingBatchTranscriptionState {
  RecordingBatchTranscriptionState({
    required List<RecordingBatchTranscriptionSnapshot> batches,
    this.isCreating = false,
    this.lastErrorCode,
  }) : batches = List<RecordingBatchTranscriptionSnapshot>.unmodifiable(
         batches,
       );

  factory RecordingBatchTranscriptionState.initial() =>
      RecordingBatchTranscriptionState(
        batches: const <RecordingBatchTranscriptionSnapshot>[],
      );

  final List<RecordingBatchTranscriptionSnapshot> batches;
  final bool isCreating;
  final String? lastErrorCode;

  RecordingBatchTranscriptionSnapshot? batchFor(String batchId) {
    for (final batch in batches) {
      if (batch.batchId == batchId) return batch;
    }
    return null;
  }

  RecordingBatchTranscriptionState copyWith({
    List<RecordingBatchTranscriptionSnapshot>? batches,
    bool? isCreating,
    String? lastErrorCode,
    bool clearError = false,
  }) {
    return RecordingBatchTranscriptionState(
      batches: batches ?? this.batches,
      isCreating: isCreating ?? this.isCreating,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

final class RecordingBatchTranscriptionException implements Exception {
  const RecordingBatchTranscriptionException(this.code);

  final String code;

  @override
  String toString() => 'RecordingBatchTranscriptionException($code)';
}

typedef RecordingActiveBatchContext = ({String batchId, String itemId});

RecordingActiveBatchContext? recordingNotificationBatchContext(
  Iterable<RecordingBatchTranscriptionSnapshot> batches,
  String remoteRecordingId,
) {
  final normalized = _nonEmpty(remoteRecordingId);
  if (normalized == null) return null;
  for (final batch in batches) {
    for (final item in batch.items) {
      if (item.remoteRecordingId != normalized) continue;
      if (batch.status == RecordingBatchTranscriptionStatus.active ||
          item.status == RecordingBatchTranscriptionItemStatus.failed ||
          item.status == RecordingBatchTranscriptionItemStatus.timedOut) {
        return (batchId: batch.batchId, itemId: item.itemId);
      }
    }
  }
  return null;
}

final class RecordingBatchTranscriptionController extends ChangeNotifier
    implements RecordingOutlineRetryLifecyclePort {
  RecordingBatchTranscriptionController({
    required RecordingBatchTranscriptionStorePort store,
    required RecordingTranscriptionReceiptStorePort receiptStore,
    required RecordingBatchTranscriptionExecutionPort executionPort,
    required String accountScope,
    required String workspaceScope,
    RecordingTranscriptionCandidateFactory? candidateFactory,
    DateTime Function()? now,
    String Function()? createBatchId,
    this.observationWindow = recordingBatchObservationWindow,
    this.remoteVerificationInterval = const Duration(seconds: 3),
    this.maxConcurrentSubmissions = 2,
  }) : _store = store,
       _receiptStore = receiptStore,
       _executionPort = executionPort,
       _accountScope = _requiredScope(accountScope, 'accountScope'),
       _workspaceScope = _requiredScope(workspaceScope, 'workspaceScope'),
       _candidateFactory = candidateFactory,
       _now = now ?? DateTime.now,
       _createBatchId = createBatchId {
    if (maxConcurrentSubmissions < 1) {
      throw ArgumentError.value(
        maxConcurrentSubmissions,
        'maxConcurrentSubmissions',
      );
    }
    if (observationWindow <= Duration.zero) {
      throw ArgumentError.value(observationWindow, 'observationWindow');
    }
    if (remoteVerificationInterval <= Duration.zero) {
      throw ArgumentError.value(
        remoteVerificationInterval,
        'remoteVerificationInterval',
      );
    }
  }

  final RecordingBatchTranscriptionStorePort _store;
  final RecordingTranscriptionReceiptStorePort _receiptStore;
  final RecordingBatchTranscriptionExecutionPort _executionPort;
  final String _accountScope;
  final String _workspaceScope;
  final RecordingTranscriptionCandidateFactory? _candidateFactory;
  final DateTime Function() _now;
  final String Function()? _createBatchId;
  final Duration observationWindow;
  final Duration remoteVerificationInterval;
  final int maxConcurrentSubmissions;
  final Set<String> _runningBatchIds = <String>{};
  final Set<String> _consumedPreviewIds = <String>{};
  final Map<String, Timer> _remoteVerificationTimers = <String, Timer>{};
  final Map<String, Future<void>> _inFlightVerifications =
      <String, Future<void>>{};
  final Map<String, Completer<void>> _idleCompleters =
      <String, Completer<void>>{};
  Future<void>? _restoreFuture;
  Future<int>? _pendingVerificationRecovery;
  Future<void> _mutationTail = Future<void>.value();
  var _batchSequence = 0;
  var _previewSequence = 0;
  var _disposed = false;
  var _scopeDeactivated = false;
  var _creationInFlight = false;

  RecordingBatchTranscriptionState _state =
      RecordingBatchTranscriptionState.initial();

  RecordingBatchTranscriptionState get state => _state;

  Future<void> get ready => restore();

  RecordingActiveBatchContext? activeBatchContextForRemoteRecording(
    String remoteRecordingId,
  ) {
    final normalized = _nonEmpty(remoteRecordingId);
    if (normalized == null) return null;
    for (final batch in _state.batches) {
      if (batch.status != RecordingBatchTranscriptionStatus.active) continue;
      for (final item in batch.items) {
        if (item.remoteRecordingId == normalized) {
          return (batchId: batch.batchId, itemId: item.itemId);
        }
      }
    }
    return null;
  }

  RecordingActiveBatchContext? notificationBatchContextForRemoteRecording(
    String remoteRecordingId,
  ) => recordingNotificationBatchContext(_state.batches, remoteRecordingId);

  RecordingTranscriptionCandidate candidateForLibraryItem(
    RecordingLibraryItem item,
  ) {
    final factory = _candidateFactory;
    if (factory == null) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_BATCH_CANDIDATE_FACTORY_UNAVAILABLE',
      );
    }
    return factory.fromLibraryItem(item);
  }

  Future<void> restore() {
    final existing = _restoreFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    final shared = completer.future;
    _restoreFuture = shared;
    unawaited(_completeRestore(completer, shared));
    return shared;
  }

  Future<void> _completeRestore(
    Completer<void> completer,
    Future<void> shared,
  ) async {
    try {
      await _restoreOnce();
      completer.complete();
    } on Object catch (error, stackTrace) {
      if (identical(_restoreFuture, shared)) {
        _restoreFuture = null;
      }
      completer.completeError(error, stackTrace);
    }
  }

  Future<void> _restoreOnce() async {
    if (_scopeDeactivated) return;
    var restored = _store.loadBatches();
    var normalizedScopeChange = false;
    final resumedAt = _now().toUtc();
    restored = <RecordingBatchTranscriptionSnapshot>[
      for (final batch in restored)
        _normalizeRestoredScopeChange(batch, resumedAt, () {
          normalizedScopeChange = true;
        }),
    ];
    if (normalizedScopeChange) {
      for (final batch in restored) {
        _store.saveBatch(batch);
      }
      if (!await _store.flush()) {
        throw const RecordingBatchTranscriptionException(
          'RECORDING_BATCH_PERSISTENCE_FAILED',
        );
      }
    }
    for (final batch in restored) {
      for (final item in batch.items) {
        await _persistReceiptFor(item);
      }
    }
    if (_disposed || _scopeDeactivated) return;
    _state = RecordingBatchTranscriptionState(batches: restored);
    _publish();
    for (final batch in restored) {
      if (batch.status == RecordingBatchTranscriptionStatus.active) {
        unawaited(processBatch(batch.batchId));
      }
    }
  }

  RecordingBatchTranscriptionSnapshot _normalizeRestoredScopeChange(
    RecordingBatchTranscriptionSnapshot batch,
    DateTime resumedAt,
    VoidCallback onChanged,
  ) {
    var next = batch;
    for (final item in batch.items) {
      if (item.waitingReason !=
              RecordingBatchWaitingReason.accountScopeChanged ||
          !item.status.isActive) {
        continue;
      }
      onChanged();
      final hasRemote = _nonEmpty(item.remoteRecordingId) != null;
      next = next.replaceItem(
        item.copyWith(
          status: hasRemote
              ? RecordingBatchTranscriptionItemStatus.processing
              : RecordingBatchTranscriptionItemStatus.pending,
          retryable: false,
          clearError: true,
          clearFailureCategory: true,
          waitingReason: hasRemote
              ? RecordingBatchWaitingReason.remoteVerificationRequired
              : null,
          clearWaitingReason: !hasRemote,
          updatedAt: resumedAt,
        ),
      );
    }
    return next;
  }

  /// Rechecks recoverable remote items after foreground or network recovery.
  ///
  /// This path never submits local media. Concurrent activations share one
  /// serial pass, and each item also coalesces with timer/restore verification.
  Future<int> resumePendingRemoteVerifications() {
    if (_disposed) return Future<int>.value(0);
    final existing = _pendingVerificationRecovery;
    if (existing != null) return existing;
    late final Future<int> shared;
    shared = _resumePendingRemoteVerificationsOnce().whenComplete(() {
      if (identical(_pendingVerificationRecovery, shared)) {
        _pendingVerificationRecovery = null;
      }
    });
    _pendingVerificationRecovery = shared;
    return shared;
  }

  Future<int> _resumePendingRemoteVerificationsOnce() async {
    await restore();
    final targets = <(String, String)>[
      for (final batch in _state.batches)
        if (batch.status == RecordingBatchTranscriptionStatus.active)
          for (final item in batch.items)
            if (item.status.isActive &&
                item.remoteRecordingId != null &&
                (item.waitingReason ==
                        RecordingBatchWaitingReason.networkRequired ||
                    item.waitingReason ==
                        RecordingBatchWaitingReason.remoteVerificationRequired))
              (batch.batchId, item.itemId),
    ];
    var checked = 0;
    for (final target in targets) {
      if (_disposed) break;
      await _verify(target.$1, target.$2);
      checked += 1;
    }
    return checked;
  }

  Future<RecordingTranscriptionDispatch> startSelection(
    Iterable<RecordingTranscriptionCandidate> selection,
  ) async {
    final preview = await previewSelection(selection);
    return startPreview(preview);
  }

  Future<RecordingTranscriptionSelectionPreview> previewSelection(
    Iterable<RecordingTranscriptionCandidate> selection,
  ) async {
    await restore();
    final candidates = _freezeUnique(selection);
    try {
      final preflights = <RecordingTranscriptionPreflight>[];
      for (final candidate in candidates) {
        preflights.add(await _classify(candidate));
      }
      final now = _now().toUtc();
      return RecordingTranscriptionSelectionPreview(
        previewId: _nextPreviewId(now),
        accountScope: _accountScope,
        workspaceScope: _workspaceScope,
        createdAt: now,
        candidates: candidates,
        items: preflights,
      );
    } on RecordingBatchTranscriptionException catch (error) {
      _setError(error.code);
      rethrow;
    } on Object {
      const code = 'RECORDING_TRANSCRIPTION_PREVIEW_FAILED';
      _setError(code);
      throw const RecordingBatchTranscriptionException(code);
    }
  }

  Future<RecordingTranscriptionDispatch> startPreview(
    RecordingTranscriptionSelectionPreview preview,
  ) async {
    await restore();
    _validatePreview(preview);
    if (preview.items.isEmpty) {
      return const RecordingTranscriptionDispatch.disabled();
    }
    if (_creationInFlight) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_START_IN_PROGRESS',
      );
    }
    _creationInFlight = true;
    if (!_consumedPreviewIds.add(preview.previewId)) {
      _creationInFlight = false;
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_PREVIEW_ALREADY_STARTED',
      );
    }

    _state = _state.copyWith(isCreating: true, clearError: true);
    _publish();
    try {
      await _persistPreviewReceipts(preview.items);
      if (preview.items.length == 1) {
        final preflight = preview.items.single;
        if (preflight.classification ==
            RecordingTranscriptionClassification.retryExisting) {
          final item = _itemFromPreflight(preflight, _now().toUtc());
          final originalRemoteRecordingId = _nonEmpty(item.remoteRecordingId);
          if (originalRemoteRecordingId == null) {
            throw const RecordingBatchTranscriptionException(
              'RECORDING_TRANSCRIPTION_RETRY_IDENTITY_MISSING',
            );
          }
          late final RecordingBatchSubmissionResult result;
          try {
            result = await _executionPort.retryExisting(item);
          } on Object {
            result = const RecordingBatchSubmissionResult.failed(
              errorCode: 'RECORDING_BATCH_RETRY_UNAVAILABLE',
              failureCategory: RecordingBatchFailureCategory.remote,
              retryable: true,
            );
          }
          if (!result.accepted) {
            throw RecordingBatchTranscriptionException(
              result.errorCode ?? 'RECORDING_BATCH_RETRY_UNAVAILABLE',
            );
          }
          if (_nonEmpty(result.remoteRecordingId) !=
              originalRemoteRecordingId) {
            throw const RecordingBatchTranscriptionException(
              'RECORDING_TRANSCRIPTION_RETRY_IDENTITY_MISMATCH',
            );
          }
        }
        return RecordingTranscriptionDispatch.single(preflight);
      }

      final now = _now().toUtc();
      final items = <RecordingBatchTranscriptionItem>[
        for (final preflight in preview.items)
          _itemFromPreflight(preflight, now),
      ];
      final primary = items.firstWhere(
        (item) =>
            item.status != RecordingBatchTranscriptionItemStatus.skipped &&
            !item.isUnavailable,
        orElse: () => items.first,
      );
      final batch = RecordingBatchTranscriptionSnapshot(
        batchId: _nextBatchId(now),
        accountScope: _accountScope,
        workspaceScope: _workspaceScope,
        primaryItemId: primary.itemId,
        items: items,
        createdAt: now,
        updatedAt: now,
      );
      await _insertBatch(batch);
      if (batch.status == RecordingBatchTranscriptionStatus.active) {
        unawaited(processBatch(batch.batchId));
      }
      return RecordingTranscriptionDispatch.batch(batch);
    } on RecordingBatchTranscriptionException catch (error) {
      _setError(error.code);
      _consumedPreviewIds.remove(preview.previewId);
      rethrow;
    } on Object {
      const code = 'RECORDING_BATCH_CREATE_FAILED';
      _setError(code);
      _consumedPreviewIds.remove(preview.previewId);
      throw const RecordingBatchTranscriptionException(code);
    } finally {
      _creationInFlight = false;
      if (!_disposed) {
        _state = _state.copyWith(isCreating: false);
        _publish();
      }
    }
  }

  Future<void> processBatch(String batchId) async {
    if (_disposed || !_runningBatchIds.add(batchId)) return;
    final idle = _idleCompleters.putIfAbsent(batchId, Completer<void>.new);
    try {
      while (!_disposed) {
        final batch = _state.batchFor(batchId);
        if (batch == null ||
            batch.status != RecordingBatchTranscriptionStatus.active) {
          break;
        }
        final work = batch.items
            .where(
              (item) =>
                  ((item.status ==
                              RecordingBatchTranscriptionItemStatus.pending &&
                          (item.waitingReason == null ||
                              item.waitingReason ==
                                  RecordingBatchWaitingReason
                                      .remoteVerificationRequired)) ||
                      (item.status ==
                              RecordingBatchTranscriptionItemStatus
                                  .processing &&
                          item.waitingReason ==
                              RecordingBatchWaitingReason
                                  .remoteVerificationRequired)) &&
                  item.waitingReason !=
                      RecordingBatchWaitingReason.accountScopeChanged &&
                  !_hasScheduledRemoteVerification(batchId, item.itemId),
            )
            .toList(growable: false);
        if (work.isEmpty) break;
        var cursor = 0;
        Future<void> worker() async {
          while (!_disposed) {
            if (cursor >= work.length) return;
            final item = work[cursor];
            cursor += 1;
            if (item.waitingReason ==
                    RecordingBatchWaitingReason.remoteVerificationRequired ||
                item.status ==
                    RecordingBatchTranscriptionItemStatus.processing) {
              await _verify(batchId, item.itemId);
            } else if (item.remoteRecordingId != null) {
              await _retryQueuedExisting(batchId, item.itemId);
            } else {
              await _submit(batchId, item.itemId);
            }
          }
        }

        final workerCount = work.length < maxConcurrentSubmissions
            ? work.length
            : maxConcurrentSubmissions;
        await Future.wait(<Future<void>>[
          for (var index = 0; index < workerCount; index += 1) worker(),
        ]);
      }
    } on RecordingBatchTranscriptionException catch (error) {
      _setError(error.code);
    } on Object {
      _setError('RECORDING_BATCH_PROCESSING_FAILED');
    } finally {
      _runningBatchIds.remove(batchId);
      if (!idle.isCompleted) idle.complete();
      _idleCompleters.remove(batchId);
    }
  }

  Future<void> waitUntilIdle(String batchId) async {
    final current = _idleCompleters[batchId];
    if (current != null) await current.future;
  }

  Future<bool> applyAuthoritativeUpdate({
    required String batchId,
    required String itemId,
    required RecordingBatchAuthoritativeUpdate update,
  }) async {
    final changed = await _mutateItem(batchId, itemId, (item) async {
      return _applyAuthoritative(item, update);
    });
    if (changed != null) {
      _reconcileRemoteVerification(batchId, changed);
    }
    return changed != null;
  }

  /// Feeds the shared tracker's latest authoritative detail into every batch
  /// item that references the same backend Recording.
  Future<int> applyProcessingTask(RecordingProcessingTask task) async {
    await restore();
    final remoteRecordingId = _nonEmpty(task.draft.recordingId);
    if (remoteRecordingId == null) return 0;
    final checkedAt = task.updatedAt.toUtc();
    final detail = task.detail;
    final update = switch ((task.phase, detail)) {
      (_, final RecordingDetail value) when value.hasCloudAsset =>
        RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.assetReady,
          checkedAt: checkedAt,
          remoteRecordingId: remoteRecordingId,
          noteId: value.canonicalNoteId,
          progress: 100,
          transcriptCompletedAt: checkedAt,
          assetReadyAt: checkedAt,
          phase: RecordingBatchTranscriptionPhase.assetReady,
        ),
      (_, final RecordingDetail value) when value.hasFinalTranscriptFact =>
        RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.transcriptReady,
          checkedAt: checkedAt,
          remoteRecordingId: remoteRecordingId,
          noteId: value.canonicalNoteId,
          progress: value.asrTask?.progress,
          transcriptCompletedAt: checkedAt,
          phase: RecordingBatchTranscriptionPhase.storingAsset,
        ),
      (RecordingProcessingPhase.failed, _) => RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.failed,
        checkedAt: checkedAt,
        remoteRecordingId: remoteRecordingId,
        errorCode: task.errorCode ?? 'RECORDING_TRANSCRIPTION_FAILED',
        failureCategory: RecordingBatchFailureCategory.transcription,
        retryable:
            detail?.effectiveRetryActions.any(
              (action) => action.stage.trim() == 'asr',
            ) ==
            true,
      ),
      (RecordingProcessingPhase.transcribing, _) =>
        RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.processing,
          checkedAt: checkedAt,
          remoteRecordingId: remoteRecordingId,
          progress: detail?.asrTask?.progress,
          phase: RecordingBatchTranscriptionPhase.transcribing,
        ),
      (RecordingProcessingPhase.storingCloudNote, _) =>
        RecordingBatchAuthoritativeUpdate(
          state: RecordingBatchAuthoritativeState.transcriptReady,
          checkedAt: checkedAt,
          remoteRecordingId: remoteRecordingId,
          noteId: detail?.canonicalNoteId,
          progress: detail?.asrTask?.progress,
          transcriptCompletedAt: checkedAt,
          phase: RecordingBatchTranscriptionPhase.storingAsset,
        ),
      (RecordingProcessingPhase.completed, _) => null,
    };
    if (update == null) return 0;
    final targets = <(String, String)>[
      for (final batch in _state.batches)
        for (final item in batch.items)
          if (item.remoteRecordingId == remoteRecordingId)
            (batch.batchId, item.itemId),
    ];
    var applied = 0;
    for (final target in targets) {
      final current = _state.batchFor(target.$1)?.itemFor(target.$2);
      final deadline = current?.observationDeadlineAt;
      final requiresFinalAuthorityRead =
          task.isActive &&
          detail?.hasCloudAsset != true &&
          current?.status.isActive == true &&
          deadline != null &&
          !checkedAt.isBefore(deadline);
      if (requiresFinalAuthorityRead) {
        await _verify(target.$1, target.$2);
        applied += 1;
        continue;
      }
      if (await applyAuthoritativeUpdate(
        batchId: target.$1,
        itemId: target.$2,
        update: update,
      )) {
        applied += 1;
      }
    }
    return applied;
  }

  /// Applies one tracker revision without making the tracker depend on batch
  /// state. Tasks unrelated to retained batches are ignored.
  Future<int> applyProcessingState(RecordingProcessingState processing) async {
    final retainedRemoteIds = <String>{
      for (final batch in _state.batches)
        for (final item in batch.items)
          if (_nonEmpty(item.remoteRecordingId) case final remoteId?) remoteId,
    };
    var applied = 0;
    for (final task in processing.tasks) {
      final remoteRecordingId = _nonEmpty(task.draft.recordingId);
      if (remoteRecordingId == null ||
          !retainedRemoteIds.contains(remoteRecordingId)) {
        continue;
      }
      applied += await applyProcessingTask(task);
    }
    return applied;
  }

  Future<bool> retryItem({
    required String batchId,
    required String itemId,
  }) async {
    final batch = _state.batchFor(batchId);
    final item = batch?.itemFor(itemId);
    if (item == null ||
        (item.status != RecordingBatchTranscriptionItemStatus.failed &&
            item.status != RecordingBatchTranscriptionItemStatus.timedOut) ||
        (item.status == RecordingBatchTranscriptionItemStatus.failed &&
            !item.retryable)) {
      return false;
    }
    if (item.status == RecordingBatchTranscriptionItemStatus.timedOut) {
      return resumeObservation(batchId: batchId, itemId: itemId);
    }
    if (item.remoteRecordingId == null) {
      await _mutateItem(batchId, itemId, (current) async {
        return current.copyWith(
          status: RecordingBatchTranscriptionItemStatus.pending,
          phase: RecordingBatchTranscriptionPhase.uploading,
          clearError: true,
          clearFailureCategory: true,
          clearWaitingReason: true,
          updatedAt: _now().toUtc(),
        );
      });
      unawaited(processBatch(batchId));
      return true;
    }
    await _mutateItem(batchId, itemId, (current) async {
      return current.copyWith(
        status: RecordingBatchTranscriptionItemStatus.pending,
        phase: RecordingBatchTranscriptionPhase.transcribing,
        clearError: true,
        clearFailureCategory: true,
        clearWaitingReason: true,
        updatedAt: _now().toUtc(),
      );
    });
    return _retryQueuedExisting(batchId, itemId);
  }

  Future<bool> resumeObservation({
    required String batchId,
    required String itemId,
  }) async {
    final batch = _state.batchFor(batchId);
    final item = batch?.itemFor(itemId);
    if (item == null ||
        item.status != RecordingBatchTranscriptionItemStatus.timedOut ||
        item.remoteRecordingId == null) {
      return false;
    }
    final resumedAt = _now().toUtc();
    await _mutateItem(batchId, itemId, (current) async {
      return current.copyWith(
        status: RecordingBatchTranscriptionItemStatus.processing,
        retryable: false,
        clearError: true,
        clearFailureCategory: true,
        clearWaitingReason: true,
        observationStartedAt: resumedAt,
        lastAuthoritativeProgressAt: resumedAt,
        observationDeadlineAt: resumedAt.add(observationWindow),
        updatedAt: resumedAt,
      );
    });
    await _verify(batchId, itemId);
    return true;
  }

  Future<void> markNetworkUnavailable({
    required String batchId,
    required String itemId,
  }) async {
    await _mutateItem(batchId, itemId, (item) async {
      if (item.status.isTerminal) return item;
      return item.copyWith(
        waitingReason: RecordingBatchWaitingReason.networkRequired,
        updatedAt: _now().toUtc(),
      );
    });
  }

  @override
  Future<void> acceptOutlineRetry({
    required String recordingId,
    required String retryTaskId,
    required String retryStage,
    String? supersededOutlineTaskId,
  }) async {
    await restore();
    final normalizedRecordingId = _nonEmpty(recordingId);
    final normalizedRetryTaskId = _safeOutlineTaskId(retryTaskId);
    final normalizedRetryStage = _nonEmpty(retryStage);
    final normalizedSupersededTaskId = supersededOutlineTaskId == null
        ? null
        : _safeOutlineTaskId(supersededOutlineTaskId);
    if (normalizedRecordingId == null ||
        normalizedRetryTaskId == null ||
        normalizedRetryStage == null ||
        (supersededOutlineTaskId != null &&
            normalizedSupersededTaskId == null)) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_OUTLINE_RETRY_RECEIPT_INVALID',
      );
    }
    final directOutlineRetry = normalizedRetryStage == 'recording_note_outline';
    final targets = <(String, String)>[
      for (final batch in _state.batches)
        for (final item in batch.items)
          if (item.remoteRecordingId?.trim() == normalizedRecordingId)
            (batch.batchId, item.itemId),
    ];
    for (final target in targets) {
      await _mutateItem(target.$1, target.$2, (current) async {
        if (current.outlineStatus == RecordingBatchOutlineStatus.completed) {
          return current;
        }
        final currentTaskId = _safeOutlineTaskId(current.outlineTaskId);
        if (normalizedSupersededTaskId != null &&
            currentTaskId != null &&
            normalizedSupersededTaskId != currentTaskId) {
          return current;
        }
        final effectiveSupersededTaskId =
            normalizedSupersededTaskId ??
            currentTaskId ??
            (directOutlineRetry ? null : normalizedRetryTaskId);
        final expectedTaskId = directOutlineRetry
            ? normalizedRetryTaskId
            : null;
        if (expectedTaskId != null &&
            expectedTaskId == effectiveSupersededTaskId) {
          return current;
        }
        return current.copyWith(
          outlineStatus: RecordingBatchOutlineStatus.generating,
          outlineTaskId: expectedTaskId,
          clearOutlineTaskId: expectedTaskId == null,
          supersededOutlineTaskId: effectiveSupersededTaskId,
          clearSupersededOutlineTaskId: effectiveSupersededTaskId == null,
          clearOutlineError: true,
          updatedAt: _now().toUtc(),
        );
      });
    }
  }

  @override
  Future<void> rejectOutlineRetry({
    required String recordingId,
    required String errorCode,
  }) async {
    await applyOutlineStatusForRecording(
      recordingId: recordingId,
      status: RecordingBatchOutlineStatus.failed,
      errorCode: errorCode,
    );
  }

  Future<int> applyOutlineStatusForRecording({
    required String recordingId,
    required RecordingBatchOutlineStatus status,
    String? errorCode,
    String? taskId,
    DateTime? observedAt,
  }) async {
    await restore();
    final normalized = _nonEmpty(recordingId);
    if (normalized == null) {
      throw ArgumentError.value(recordingId, 'recordingId');
    }
    final targets = <(String, String)>[
      for (final batch in _state.batches)
        for (final item in batch.items)
          if (item.remoteRecordingId?.trim() == normalized)
            (batch.batchId, item.itemId),
    ];
    var applied = 0;
    for (final target in targets) {
      if (await updateOutline(
        batchId: target.$1,
        itemId: target.$2,
        status: status,
        errorCode: errorCode,
        taskId: taskId,
        observedAt: observedAt,
      )) {
        applied += 1;
      }
    }
    return applied;
  }

  Future<int> applyOutlineStatusForNote({
    required String noteId,
    required RecordingBatchOutlineStatus status,
    String? errorCode,
    String? taskId,
    DateTime? observedAt,
  }) async {
    await restore();
    final normalized = _nonEmpty(noteId);
    if (normalized == null) {
      throw ArgumentError.value(noteId, 'noteId');
    }
    final targets = <(String, String)>[
      for (final batch in _state.batches)
        for (final item in batch.items)
          if (item.noteId == normalized) (batch.batchId, item.itemId),
    ];
    var applied = 0;
    for (final target in targets) {
      if (await updateOutline(
        batchId: target.$1,
        itemId: target.$2,
        status: status,
        errorCode: errorCode,
        taskId: taskId,
        observedAt: observedAt,
      )) {
        applied += 1;
      }
    }
    return applied;
  }

  Future<bool> updateOutline({
    required String batchId,
    required String itemId,
    required RecordingBatchOutlineStatus status,
    String? errorCode,
    String? taskId,
    DateTime? observedAt,
  }) async {
    await restore();
    final normalizedTaskId = taskId == null ? null : _safeOutlineTaskId(taskId);
    if (taskId != null && normalizedTaskId == null) {
      return false;
    }
    var changed = false;
    final item = await _mutateItem(batchId, itemId, (current) async {
      final statusChanged = current.outlineStatus != status;
      final currentTaskId = _safeOutlineTaskId(current.outlineTaskId);
      final supersededTaskId = _safeOutlineTaskId(
        current.supersededOutlineTaskId,
      );
      if (normalizedTaskId != null &&
          supersededTaskId != null &&
          normalizedTaskId == supersededTaskId) {
        return current;
      }
      final terminal =
          status == RecordingBatchOutlineStatus.completed ||
          status == RecordingBatchOutlineStatus.failed;
      if (terminal && supersededTaskId != null && normalizedTaskId == null) {
        return current;
      }
      if ((statusChanged || normalizedTaskId != null) &&
          terminal &&
          currentTaskId != null &&
          normalizedTaskId != currentTaskId) {
        return current;
      }
      if (current.outlineStatus == RecordingBatchOutlineStatus.failed &&
          status == RecordingBatchOutlineStatus.generating &&
          (normalizedTaskId == null || normalizedTaskId == currentTaskId)) {
        return current;
      }
      if (statusChanged &&
          !_acceptOutlineTransition(current.outlineStatus, status)) {
        return current;
      }
      final nextErrorCode = status == RecordingBatchOutlineStatus.failed
          ? _safeOutlineErrorCode(errorCode) ??
                current.outlineErrorCode ??
                'RECORDING_OUTLINE_FAILED'
          : null;
      final nextTaskId = normalizedTaskId ?? currentTaskId;
      final clearSuperseded =
          terminal ||
          (normalizedTaskId != null &&
              supersededTaskId != null &&
              normalizedTaskId != supersededTaskId);
      if (!statusChanged &&
          current.outlineErrorCode == nextErrorCode &&
          current.outlineTaskId == nextTaskId &&
          (!clearSuperseded || current.supersededOutlineTaskId == null)) {
        return current;
      }
      changed = true;
      return current.copyWith(
        outlineStatus: status,
        outlineErrorCode: nextErrorCode,
        clearOutlineError: nextErrorCode == null,
        outlineTaskId: nextTaskId,
        clearOutlineTaskId: nextTaskId == null,
        clearSupersededOutlineTaskId: clearSuperseded,
        updatedAt: (observedAt ?? _now()).toUtc(),
      );
    });
    return item != null && changed;
  }

  Future<void> deactivateForAccountScopeChange() async {
    if (_scopeDeactivated) return;
    _scopeDeactivated = true;
    _cancelAllRemoteVerificationTimers();
    final deactivatedAt = _now().toUtc();
    final nextBatches = <RecordingBatchTranscriptionSnapshot>[];
    for (final batch in _state.batches) {
      var next = batch;
      if (batch.status == RecordingBatchTranscriptionStatus.active) {
        for (final item in batch.items.where((item) => item.status.isActive)) {
          next = next.replaceItem(
            item.copyWith(
              status:
                  item.status ==
                      RecordingBatchTranscriptionItemStatus.submitting
                  ? RecordingBatchTranscriptionItemStatus.pending
                  : item.status,
              waitingReason: RecordingBatchWaitingReason.accountScopeChanged,
              updatedAt: deactivatedAt,
            ),
          );
        }
      }
      if (!identical(next, batch)) _store.saveBatch(next);
      nextBatches.add(next);
    }
    _state = _state.copyWith(batches: nextBatches);
    if (!await _store.flush()) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_BATCH_PERSISTENCE_FAILED',
      );
    }
  }

  Future<void> _submit(String batchId, String itemId) async {
    final submitting = await _mutateItem(batchId, itemId, (item) async {
      if (item.status != RecordingBatchTranscriptionItemStatus.pending ||
          item.waitingReason != null) {
        return item;
      }
      return item.copyWith(
        status: RecordingBatchTranscriptionItemStatus.submitting,
        phase: RecordingBatchTranscriptionPhase.uploading,
        attemptCount: item.attemptCount + 1,
        clearError: true,
        clearFailureCategory: true,
        updatedAt: _now().toUtc(),
      );
    });
    if (submitting == null ||
        submitting.status != RecordingBatchTranscriptionItemStatus.submitting) {
      return;
    }
    late final RecordingBatchSubmissionResult result;
    try {
      result = await _executionPort.submitNew(submitting);
    } on Object {
      result = const RecordingBatchSubmissionResult.failed(
        errorCode: 'RECORDING_BATCH_SUBMISSION_UNAVAILABLE',
        failureCategory: RecordingBatchFailureCategory.upload,
        retryable: true,
      );
    }
    if (!result.accepted || result.remoteRecordingId?.trim().isEmpty != false) {
      await _recordSubmissionFailure(batchId, itemId, result);
      return;
    }
    final acceptedAt = _now().toUtc();
    await _mutateItem(batchId, itemId, (item) async {
      return item.copyWith(
        remoteRecordingId: result.remoteRecordingId,
        status: RecordingBatchTranscriptionItemStatus.processing,
        phase: RecordingBatchTranscriptionPhase.transcribing,
        progress: 0,
        retryable: false,
        clearError: true,
        clearFailureCategory: true,
        clearWaitingReason: true,
        observationStartedAt: acceptedAt,
        lastAuthoritativeProgressAt: acceptedAt,
        observationDeadlineAt: acceptedAt.add(observationWindow),
        updatedAt: acceptedAt,
      );
    });
  }

  Future<bool> _retryQueuedExisting(String batchId, String itemId) async {
    final submitting = await _mutateItem(batchId, itemId, (item) async {
      if (item.status != RecordingBatchTranscriptionItemStatus.pending ||
          item.waitingReason != null ||
          item.remoteRecordingId == null ||
          !item.retryable) {
        return item;
      }
      return item.copyWith(
        status: RecordingBatchTranscriptionItemStatus.submitting,
        phase: RecordingBatchTranscriptionPhase.transcribing,
        clearError: true,
        clearFailureCategory: true,
        updatedAt: _now().toUtc(),
      );
    });
    if (submitting == null ||
        submitting.status != RecordingBatchTranscriptionItemStatus.submitting) {
      return false;
    }

    late final RecordingBatchSubmissionResult result;
    try {
      result = await _executionPort.retryExisting(submitting);
    } on Object {
      result = const RecordingBatchSubmissionResult.failed(
        errorCode: 'RECORDING_BATCH_RETRY_UNAVAILABLE',
        failureCategory: RecordingBatchFailureCategory.remote,
        retryable: true,
      );
    }
    final originalRemoteRecordingId = _nonEmpty(submitting.remoteRecordingId);
    if (!result.accepted) {
      await _recordSubmissionFailure(batchId, itemId, result);
      return false;
    }
    final remoteRecordingId = _nonEmpty(result.remoteRecordingId);
    if (originalRemoteRecordingId == null ||
        remoteRecordingId != originalRemoteRecordingId) {
      await _recordSubmissionFailure(
        batchId,
        itemId,
        const RecordingBatchSubmissionResult.failed(
          errorCode: 'RECORDING_TRANSCRIPTION_RETRY_IDENTITY_MISMATCH',
          failureCategory: RecordingBatchFailureCategory.remote,
          retryable: false,
        ),
      );
      return false;
    }

    final acceptedAt = _now().toUtc();
    await _mutateItem(batchId, itemId, (item) async {
      return item.copyWith(
        remoteRecordingId: remoteRecordingId,
        status: RecordingBatchTranscriptionItemStatus.processing,
        phase: RecordingBatchTranscriptionPhase.transcribing,
        retryable: false,
        attemptCount: item.attemptCount + 1,
        clearError: true,
        clearFailureCategory: true,
        waitingReason: RecordingBatchWaitingReason.remoteVerificationRequired,
        observationStartedAt: result.serverAcceptedNewAttempt
            ? acceptedAt
            : item.observationStartedAt,
        lastAuthoritativeProgressAt: result.serverAcceptedNewAttempt
            ? acceptedAt
            : item.lastAuthoritativeProgressAt,
        observationDeadlineAt: result.serverAcceptedNewAttempt
            ? acceptedAt.add(observationWindow)
            : item.observationDeadlineAt,
        updatedAt: acceptedAt,
      );
    });
    await _verify(batchId, itemId);
    return true;
  }

  Future<void> _verify(String batchId, String itemId) {
    final key = _verificationKey(batchId, itemId);
    final existing = _inFlightVerifications[key];
    if (existing != null) return existing;
    late final Future<void> shared;
    shared = _verifyOnce(batchId, itemId).whenComplete(() {
      if (identical(_inFlightVerifications[key], shared)) {
        _inFlightVerifications.remove(key);
      }
    });
    _inFlightVerifications[key] = shared;
    return shared;
  }

  Future<void> _verifyOnce(String batchId, String itemId) async {
    final item = _state.batchFor(batchId)?.itemFor(itemId);
    if (item == null || item.remoteRecordingId == null) return;
    late final RecordingBatchAuthoritativeUpdate update;
    try {
      update = await _executionPort.verifyExisting(item);
    } on Object {
      update = RecordingBatchAuthoritativeUpdate(
        state: RecordingBatchAuthoritativeState.temporarilyUnavailable,
        checkedAt: _now().toUtc(),
        remoteRecordingId: item.remoteRecordingId,
        errorCode: 'RECORDING_BATCH_VERIFICATION_UNAVAILABLE',
        waitingReason: RecordingBatchWaitingReason.networkRequired,
      );
    }
    await applyAuthoritativeUpdate(
      batchId: batchId,
      itemId: itemId,
      update: update,
    );
  }

  Future<void> _recordSubmissionFailure(
    String batchId,
    String itemId,
    RecordingBatchSubmissionResult result,
  ) async {
    await _mutateItem(batchId, itemId, (item) async {
      return item.copyWith(
        status: RecordingBatchTranscriptionItemStatus.failed,
        retryable: result.retryable,
        errorCode: result.errorCode ?? 'RECORDING_BATCH_SUBMISSION_FAILED',
        failureCategory:
            result.failureCategory ?? RecordingBatchFailureCategory.upload,
        clearWaitingReason: true,
        updatedAt: _now().toUtc(),
      );
    });
  }

  RecordingBatchTranscriptionItem _applyAuthoritative(
    RecordingBatchTranscriptionItem item,
    RecordingBatchAuthoritativeUpdate update,
  ) {
    final checkedAt = update.checkedAt.toUtc();
    if ((item.status == RecordingBatchTranscriptionItemStatus.completed ||
            item.status == RecordingBatchTranscriptionItemStatus.skipped) ||
        (item.status == RecordingBatchTranscriptionItemStatus.failed &&
            update.state != RecordingBatchAuthoritativeState.assetReady)) {
      return item;
    }
    final lastProgressAt = item.lastAuthoritativeProgressAt;
    if (lastProgressAt != null &&
        checkedAt.isBefore(lastProgressAt) &&
        update.state != RecordingBatchAuthoritativeState.assetReady) {
      return item;
    }
    final suppliedRemoteId = update.remoteRecordingId?.trim();
    if (suppliedRemoteId != null &&
        suppliedRemoteId.isNotEmpty &&
        item.remoteRecordingId != null &&
        item.remoteRecordingId != suppliedRemoteId) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_BATCH_REMOTE_ID_MISMATCH',
      );
    }
    final remoteId = suppliedRemoteId?.isNotEmpty == true
        ? suppliedRemoteId
        : item.remoteRecordingId;
    final startedAt = item.observationStartedAt ?? checkedAt;
    final deadlineAt =
        item.observationDeadlineAt ?? startedAt.add(observationWindow);

    switch (update.state) {
      case RecordingBatchAuthoritativeState.temporarilyUnavailable:
        return item.copyWith(
          remoteRecordingId: remoteId,
          waitingReason:
              update.waitingReason ??
              RecordingBatchWaitingReason.networkRequired,
          observationStartedAt: startedAt,
          observationDeadlineAt: deadlineAt,
          updatedAt: checkedAt,
        );
      case RecordingBatchAuthoritativeState.processing:
      case RecordingBatchAuthoritativeState.transcriptReady:
        final proposedPhase =
            update.state == RecordingBatchAuthoritativeState.transcriptReady
            ? RecordingBatchTranscriptionPhase.storingAsset
            : update.phase ?? RecordingBatchTranscriptionPhase.transcribing;
        final phase = _furthestPhase(item.phase, proposedPhase);
        final progress = _greatestProgress(item.progress, update.progress);
        if (!checkedAt.isBefore(deadlineAt)) {
          return item.copyWith(
            remoteRecordingId: remoteId,
            status: RecordingBatchTranscriptionItemStatus.timedOut,
            phase: phase,
            progress: progress,
            retryable: true,
            errorCode: 'RECORDING_TRANSCRIPTION_OBSERVATION_TIMEOUT',
            failureCategory: RecordingBatchFailureCategory.remote,
            clearWaitingReason: true,
            observationStartedAt: startedAt,
            lastAuthoritativeProgressAt: checkedAt,
            observationDeadlineAt: deadlineAt,
            transcriptCompletedAt: update.transcriptCompletedAt,
            updatedAt: checkedAt,
          );
        }
        return item.copyWith(
          remoteRecordingId: remoteId,
          noteId: update.noteId,
          status: RecordingBatchTranscriptionItemStatus.processing,
          phase: phase,
          progress: progress,
          retryable: false,
          clearError: true,
          clearFailureCategory: true,
          waitingReason: update.waitingReason,
          clearWaitingReason: update.waitingReason == null,
          observationStartedAt: startedAt,
          lastAuthoritativeProgressAt: checkedAt,
          observationDeadlineAt: deadlineAt,
          transcriptCompletedAt: update.transcriptCompletedAt,
          updatedAt: checkedAt,
        );
      case RecordingBatchAuthoritativeState.assetReady:
        final transcriptAt = update.transcriptCompletedAt;
        final assetAt = update.assetReadyAt;
        final noteId = update.noteId?.trim();
        if (remoteId == null ||
            transcriptAt == null ||
            assetAt == null ||
            noteId == null ||
            noteId.isEmpty) {
          throw const RecordingBatchTranscriptionException(
            'RECORDING_BATCH_ASSET_FACT_INCOMPLETE',
          );
        }
        return item.copyWith(
          remoteRecordingId: remoteId,
          noteId: noteId,
          status: RecordingBatchTranscriptionItemStatus.completed,
          phase: RecordingBatchTranscriptionPhase.assetReady,
          progress: 100,
          retryable: false,
          clearError: true,
          clearFailureCategory: true,
          clearWaitingReason: true,
          observationStartedAt: startedAt,
          lastAuthoritativeProgressAt: checkedAt,
          observationDeadlineAt: deadlineAt,
          transcriptCompletedAt: transcriptAt.toUtc(),
          assetReadyAt: assetAt.toUtc(),
          updatedAt: checkedAt,
        );
      case RecordingBatchAuthoritativeState.failed:
        return item.copyWith(
          remoteRecordingId: remoteId,
          status: RecordingBatchTranscriptionItemStatus.failed,
          retryable: update.retryable,
          errorCode: update.errorCode ?? 'RECORDING_TRANSCRIPTION_FAILED',
          failureCategory:
              update.failureCategory ??
              RecordingBatchFailureCategory.transcription,
          clearWaitingReason: true,
          observationStartedAt: startedAt,
          lastAuthoritativeProgressAt: checkedAt,
          observationDeadlineAt: deadlineAt,
          updatedAt: checkedAt,
        );
      case RecordingBatchAuthoritativeState.timedOut:
        return item.copyWith(
          remoteRecordingId: remoteId,
          status: RecordingBatchTranscriptionItemStatus.timedOut,
          retryable: true,
          errorCode:
              update.errorCode ?? 'RECORDING_TRANSCRIPTION_REMOTE_TIMEOUT',
          failureCategory: RecordingBatchFailureCategory.remote,
          clearWaitingReason: true,
          observationStartedAt: startedAt,
          lastAuthoritativeProgressAt: checkedAt,
          observationDeadlineAt: deadlineAt,
          updatedAt: checkedAt,
        );
    }
  }

  Future<RecordingTranscriptionPreflight> _classify(
    RecordingTranscriptionCandidate candidate,
  ) async {
    final receipt = _receiptFor(candidate);
    if (candidate.transcriptionNotRequired) {
      return RecordingTranscriptionPreflight(
        classification: RecordingTranscriptionClassification.alreadyCompleted,
        candidate: candidate,
        receipt: receipt,
      );
    }
    if (receipt?.isAssetReady == true) {
      return RecordingTranscriptionPreflight(
        classification: RecordingTranscriptionClassification.alreadyCompleted,
        candidate: candidate,
        receipt: receipt,
      );
    }
    final remoteId = candidate.remoteRecordingId?.trim();
    if (receipt != null || remoteId?.isNotEmpty == true) {
      switch (candidate.remoteFact) {
        case RecordingTranscriptionRemoteFact.assetReady:
          final transcriptAt = candidate.transcriptCompletedAt;
          final assetAt = candidate.assetReadyAt;
          final noteId = candidate.noteId?.trim();
          if (remoteId == null ||
              remoteId.isEmpty ||
              transcriptAt == null ||
              assetAt == null ||
              noteId == null ||
              noteId.isEmpty) {
            return RecordingTranscriptionPreflight(
              classification:
                  RecordingTranscriptionClassification.awaitingVerification,
              candidate: candidate,
              receipt: receipt,
            );
          }
          final authoritativeReceipt = RecordingTranscriptionReceipt(
            userScope: _accountScope,
            fileIdentity: candidate.fileIdentity,
            deviceFilename: candidate.deviceFilename,
            contentHash: candidate.contentHash,
            localRecordingId: candidate.localRecordingId,
            remoteRecordingId: remoteId,
            noteId: noteId,
            transcriptCompletedAt: transcriptAt.toUtc(),
            assetReadyAt: assetAt.toUtc(),
            updatedAt: _now().toUtc(),
          );
          return RecordingTranscriptionPreflight(
            classification:
                RecordingTranscriptionClassification.existingRemoteCompleted,
            candidate: candidate,
            receipt: authoritativeReceipt,
          );
        case RecordingTranscriptionRemoteFact.processing:
        case RecordingTranscriptionRemoteFact.transcriptReady:
          return RecordingTranscriptionPreflight(
            classification:
                RecordingTranscriptionClassification.alreadyProcessing,
            candidate: candidate,
            receipt: receipt,
          );
        case RecordingTranscriptionRemoteFact.retryableFailure:
          return RecordingTranscriptionPreflight(
            classification: RecordingTranscriptionClassification.retryExisting,
            candidate: candidate,
            receipt: receipt,
          );
        case RecordingTranscriptionRemoteFact.terminalFailure:
        case RecordingTranscriptionRemoteFact.timedOut:
          return RecordingTranscriptionPreflight(
            classification: RecordingTranscriptionClassification.retryExisting,
            candidate: candidate,
            receipt: receipt,
          );
        case RecordingTranscriptionRemoteFact.none:
        case RecordingTranscriptionRemoteFact.unknown:
          return RecordingTranscriptionPreflight(
            classification:
                RecordingTranscriptionClassification.awaitingVerification,
            candidate: candidate,
            receipt: receipt,
          );
      }
    }
    if (!candidate.localFileAvailable || !candidate.formatSupported) {
      return RecordingTranscriptionPreflight(
        classification: RecordingTranscriptionClassification.unavailable,
        candidate: candidate,
        receipt: receipt,
      );
    }
    return RecordingTranscriptionPreflight(
      classification: RecordingTranscriptionClassification.eligible,
      candidate: candidate,
      receipt: receipt,
    );
  }

  RecordingBatchTranscriptionItem _itemFromPreflight(
    RecordingTranscriptionPreflight preflight,
    DateTime now,
  ) {
    final candidate = preflight.candidate;
    final receipt = preflight.receipt;
    final remoteId = candidate.remoteRecordingId ?? receipt?.remoteRecordingId;
    final transcriptAt =
        candidate.transcriptCompletedAt ?? receipt?.transcriptCompletedAt;
    final assetAt = candidate.assetReadyAt ?? receipt?.assetReadyAt;
    final noteId = candidate.noteId ?? receipt?.noteId;

    final status = switch (preflight.classification) {
      RecordingTranscriptionClassification.eligible ||
      RecordingTranscriptionClassification.awaitingVerification =>
        RecordingBatchTranscriptionItemStatus.pending,
      RecordingTranscriptionClassification.retryExisting
          when candidate.retryable =>
        RecordingBatchTranscriptionItemStatus.pending,
      RecordingTranscriptionClassification.alreadyProcessing =>
        RecordingBatchTranscriptionItemStatus.processing,
      RecordingTranscriptionClassification.alreadyCompleted ||
      RecordingTranscriptionClassification.existingRemoteCompleted =>
        RecordingBatchTranscriptionItemStatus.skipped,
      RecordingTranscriptionClassification.retryExisting ||
      RecordingTranscriptionClassification.unavailable =>
        RecordingBatchTranscriptionItemStatus.failed,
    };
    final phase = switch (preflight.classification) {
      RecordingTranscriptionClassification.eligible =>
        RecordingBatchTranscriptionPhase.uploading,
      RecordingTranscriptionClassification.retryExisting
          when candidate.retryable =>
        RecordingBatchTranscriptionPhase.transcribing,
      RecordingTranscriptionClassification.alreadyProcessing
          when transcriptAt != null =>
        RecordingBatchTranscriptionPhase.storingAsset,
      RecordingTranscriptionClassification.alreadyProcessing =>
        RecordingBatchTranscriptionPhase.transcribing,
      RecordingTranscriptionClassification.alreadyCompleted ||
      RecordingTranscriptionClassification.existingRemoteCompleted =>
        RecordingBatchTranscriptionPhase.assetReady,
      _ => null,
    };
    final waitingReason =
        preflight.classification ==
                RecordingTranscriptionClassification.awaitingVerification ||
            preflight.classification ==
                RecordingTranscriptionClassification.alreadyProcessing
        ? RecordingBatchWaitingReason.remoteVerificationRequired
        : null;
    final unavailable =
        preflight.classification ==
        RecordingTranscriptionClassification.unavailable;
    final retryExisting =
        preflight.classification ==
        RecordingTranscriptionClassification.retryExisting;
    final observationStartedAt = remoteId != null && status.isActive
        ? now
        : null;
    return RecordingBatchTranscriptionItem(
      itemId: candidate.itemId,
      title: candidate.title,
      fileIdentity: candidate.fileIdentity,
      localRecordingId: candidate.localRecordingId,
      jobId: candidate.jobId,
      deviceFilename: candidate.deviceFilename,
      contentHash: candidate.contentHash,
      remoteRecordingId: remoteId,
      noteId: noteId,
      status: status,
      phase: phase,
      outlineStatus: receipt?.isOutlineReady == true
          ? RecordingBatchOutlineStatus.completed
          : RecordingBatchOutlineStatus.notStarted,
      progress: status == RecordingBatchTranscriptionItemStatus.skipped
          ? 100
          : candidate.remoteProgress,
      retryable: retryExisting && candidate.retryable,
      attemptCount: 0,
      errorCode: unavailable
          ? candidate.errorCode ?? 'RECORDING_FILE_UNAVAILABLE'
          : retryExisting && !candidate.retryable
          ? candidate.errorCode ?? 'RECORDING_TRANSCRIPTION_RETRY_REQUIRED'
          : null,
      failureCategory: unavailable
          ? RecordingBatchFailureCategory.unavailable
          : retryExisting && !candidate.retryable
          ? RecordingBatchFailureCategory.remote
          : null,
      waitingReason: waitingReason,
      observationStartedAt: observationStartedAt,
      lastAuthoritativeProgressAt: observationStartedAt,
      observationDeadlineAt: observationStartedAt?.add(observationWindow),
      transcriptCompletedAt: transcriptAt,
      assetReadyAt: assetAt,
      createdAt: now,
      updatedAt: now,
    );
  }

  RecordingTranscriptionReceipt? _receiptFor(
    RecordingTranscriptionCandidate candidate,
  ) {
    final candidates = <RecordingTranscriptionReceipt?>[
      _receiptStore.findByFileIdentity(candidate.fileIdentity),
      _receiptStore.findByLocalRecordingId(candidate.localRecordingId),
      if (candidate.remoteRecordingId != null)
        _receiptStore.findByRemoteRecordingId(candidate.remoteRecordingId!),
    ];
    for (final receipt in candidates) {
      if (receipt == null) continue;
      final receiptHash = _nonEmpty(receipt.contentHash);
      final candidateHash = _nonEmpty(candidate.contentHash);
      if (receiptHash != null &&
          candidateHash != null &&
          receiptHash != candidateHash) {
        continue;
      }
      return receipt;
    }
    return null;
  }

  Future<void> _insertBatch(RecordingBatchTranscriptionSnapshot batch) async {
    _store.saveBatch(batch);
    if (!await _store.flush()) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_BATCH_PERSISTENCE_FAILED',
      );
    }
    _state = _state.copyWith(
      batches: <RecordingBatchTranscriptionSnapshot>[
        batch,
        ..._state.batches.where((item) => item.batchId != batch.batchId),
      ],
      clearError: true,
    );
    _publish();
  }

  Future<void> _persistPreviewReceipts(
    Iterable<RecordingTranscriptionPreflight> preflights,
  ) async {
    var changed = false;
    for (final preflight in preflights) {
      if (preflight.classification !=
              RecordingTranscriptionClassification.existingRemoteCompleted ||
          preflight.receipt == null) {
        continue;
      }
      _receiptStore.save(preflight.receipt!);
      changed = true;
    }
    if (changed && !await _receiptStore.flush()) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_RECEIPT_WRITE_FAILED',
      );
    }
  }

  void _validatePreview(RecordingTranscriptionSelectionPreview preview) {
    if (preview.accountScope != _accountScope ||
        preview.workspaceScope != _workspaceScope) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_PREVIEW_SCOPE_MISMATCH',
      );
    }
    if (preview.previewId.trim().isEmpty ||
        preview.candidates.length != preview.items.length) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_PREVIEW_INVALID',
      );
    }
    final seen = <String>{};
    for (var index = 0; index < preview.candidates.length; index += 1) {
      final candidate = preview.candidates[index];
      final classified = preview.items[index].candidate;
      if (!seen.add(candidate.itemId) ||
          candidate.itemId != classified.itemId ||
          candidate.jobId != classified.jobId ||
          candidate.fileIdentity != classified.fileIdentity) {
        throw const RecordingBatchTranscriptionException(
          'RECORDING_TRANSCRIPTION_PREVIEW_INVALID',
        );
      }
    }
  }

  Future<RecordingBatchTranscriptionItem?> _mutateItem(
    String batchId,
    String itemId,
    Future<RecordingBatchTranscriptionItem> Function(
      RecordingBatchTranscriptionItem current,
    )
    transform,
  ) {
    final completer = Completer<RecordingBatchTranscriptionItem?>();
    _mutationTail = _mutationTail
        .then((_) async {
          if (_disposed || _scopeDeactivated) {
            completer.complete(null);
            return;
          }
          final batch = _state.batchFor(batchId);
          final item = batch?.itemFor(itemId);
          if (batch == null || item == null) {
            completer.complete(null);
            return;
          }
          try {
            final replacement = await transform(item);
            if (identical(replacement, item)) {
              completer.complete(item);
              return;
            }
            final next = batch.replaceItem(replacement);
            _store.saveBatch(next);
            if (!await _store.flush()) {
              throw const RecordingBatchTranscriptionException(
                'RECORDING_BATCH_PERSISTENCE_FAILED',
              );
            }
            await _persistReceiptFor(replacement);
            _state = _state.copyWith(
              batches: <RecordingBatchTranscriptionSnapshot>[
                for (final value in _state.batches)
                  if (value.batchId == batchId) next else value,
              ],
              clearError: true,
            );
            _publish();
            completer.complete(replacement);
          } on Object catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        })
        .catchError((Object _) {
          // The caller receives the exact mutation error; keep the serialization
          // chain alive so a later authoritative update can still be applied.
        });
    return completer.future;
  }

  Future<void> _persistReceiptFor(RecordingBatchTranscriptionItem item) async {
    if (item.status != RecordingBatchTranscriptionItemStatus.completed ||
        item.remoteRecordingId == null ||
        item.transcriptCompletedAt == null ||
        item.assetReadyAt == null ||
        item.noteId == null) {
      return;
    }
    _receiptStore.save(
      RecordingTranscriptionReceipt(
        userScope: _accountScope,
        fileIdentity: item.fileIdentity,
        deviceFilename: item.deviceFilename,
        contentHash: item.contentHash,
        localRecordingId: item.localRecordingId,
        remoteRecordingId: item.remoteRecordingId!,
        noteId: item.noteId,
        transcriptCompletedAt: item.transcriptCompletedAt!,
        assetReadyAt: item.assetReadyAt,
        outlineCompletedAt:
            item.outlineStatus == RecordingBatchOutlineStatus.completed
            ? item.updatedAt
            : null,
        updatedAt: item.updatedAt,
      ),
    );
    if (!await _receiptStore.flush()) {
      throw const RecordingBatchTranscriptionException(
        'RECORDING_TRANSCRIPTION_RECEIPT_WRITE_FAILED',
      );
    }
  }

  List<RecordingTranscriptionCandidate> _freezeUnique(
    Iterable<RecordingTranscriptionCandidate> selection,
  ) {
    final seen = <String>{};
    return List<RecordingTranscriptionCandidate>.unmodifiable(
      <RecordingTranscriptionCandidate>[
        for (final candidate in selection)
          if (seen.add(candidate.itemId)) candidate,
      ],
    );
  }

  String _nextBatchId(DateTime now) {
    final supplied = _createBatchId?.call().trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;
    _batchSequence += 1;
    return 'recording-batch-${now.microsecondsSinceEpoch}-$_batchSequence';
  }

  String _nextPreviewId(DateTime now) {
    _previewSequence += 1;
    return 'recording-preview-${now.microsecondsSinceEpoch}-$_previewSequence';
  }

  void _setError(String code) {
    if (_disposed) return;
    _state = _state.copyWith(lastErrorCode: code);
    _publish();
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  bool _hasScheduledRemoteVerification(String batchId, String itemId) {
    return _remoteVerificationTimers.containsKey(
      _verificationKey(batchId, itemId),
    );
  }

  void _reconcileRemoteVerification(
    String batchId,
    RecordingBatchTranscriptionItem item,
  ) {
    final key = _verificationKey(batchId, item.itemId);
    if (item.status.isActive &&
        item.remoteRecordingId != null &&
        (item.waitingReason ==
                RecordingBatchWaitingReason.remoteVerificationRequired ||
            item.waitingReason ==
                RecordingBatchWaitingReason.networkRequired)) {
      _remoteVerificationTimers.putIfAbsent(
        key,
        () => Timer(remoteVerificationInterval, () {
          _remoteVerificationTimers.remove(key);
          if (_disposed) return;
          final current = _state.batchFor(batchId)?.itemFor(item.itemId);
          if (current == null ||
              !current.status.isActive ||
              current.remoteRecordingId == null ||
              (current.waitingReason !=
                      RecordingBatchWaitingReason.remoteVerificationRequired &&
                  current.waitingReason !=
                      RecordingBatchWaitingReason.networkRequired)) {
            return;
          }
          unawaited(_verify(batchId, item.itemId));
        }),
      );
      return;
    }
    _remoteVerificationTimers.remove(key)?.cancel();
  }

  void _cancelAllRemoteVerificationTimers() {
    for (final timer in _remoteVerificationTimers.values) {
      timer.cancel();
    }
    _remoteVerificationTimers.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAllRemoteVerificationTimers();
    for (final completer in _idleCompleters.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _idleCompleters.clear();
    super.dispose();
  }
}

String _verificationKey(String batchId, String itemId) => '$batchId::$itemId';

String _requiredScope(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}

RecordingBatchTranscriptionPhase _furthestPhase(
  RecordingBatchTranscriptionPhase? current,
  RecordingBatchTranscriptionPhase proposed,
) {
  if (current == null) return proposed;
  return current.index >= proposed.index ? current : proposed;
}

int? _greatestProgress(int? current, int? proposed) {
  if (current == null) return proposed;
  if (proposed == null) return current;
  return current >= proposed ? current : proposed;
}

bool _acceptOutlineTransition(
  RecordingBatchOutlineStatus current,
  RecordingBatchOutlineStatus proposed,
) {
  if (current == proposed) return false;
  return switch (current) {
    RecordingBatchOutlineStatus.notStarted =>
      proposed == RecordingBatchOutlineStatus.generating ||
          proposed == RecordingBatchOutlineStatus.completed ||
          proposed == RecordingBatchOutlineStatus.failed,
    RecordingBatchOutlineStatus.generating =>
      proposed == RecordingBatchOutlineStatus.completed ||
          proposed == RecordingBatchOutlineStatus.failed,
    RecordingBatchOutlineStatus.failed =>
      proposed == RecordingBatchOutlineStatus.generating ||
          proposed == RecordingBatchOutlineStatus.completed,
    RecordingBatchOutlineStatus.completed => false,
  };
}

String? _safeOutlineErrorCode(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      !RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _safeOutlineTaskId(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _firstText(String? preferred, String? fallback) =>
    _nonEmpty(preferred) ?? _nonEmpty(fallback);
