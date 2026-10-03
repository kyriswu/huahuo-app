import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/api/upload_client.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../data/local_recording_repository.dart';
import '../data/recording_api.dart';
import '../domain/recording_library.dart';
import 'recording_processing_tracker.dart';

enum _RecordingUploadPhase {
  preparing,
  requestingToken,
  uploadingObject,
  completingUpload,
  creatingRecording,
  persistingLocalLink,
}

final class RecordingPrivateAudioInput {
  const RecordingPrivateAudioInput({
    required this.jobId,
    required this.localFileId,
    required this.appPrivateUri,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.contentHash,
    required this.recordedAt,
    required this.title,
  });

  final String jobId;
  final String localFileId;
  final String appPrivateUri;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String contentHash;
  final DateTime recordedAt;
  final String title;
}

String recordingFileJobId(RecordingLibraryItem item) =>
    'draft-${item.recordingId}';

enum RecordingProcessingHandoffStatus {
  enqueued,
  alreadyEnrolled,
  alreadyTerminal,
  unavailable,
  missingCheckpoint,
}

/// Result of handing an existing durable ASR checkpoint to the shared tracker.
///
/// This deliberately reports only local checkpoint eligibility. The tracker
/// remains the sole owner of remote status reads and terminal outcomes.
final class RecordingProcessingHandoff {
  const RecordingProcessingHandoff(this.status);

  final RecordingProcessingHandoffStatus status;

  bool get accepted =>
      status == RecordingProcessingHandoffStatus.enqueued ||
      status == RecordingProcessingHandoffStatus.alreadyEnrolled ||
      status == RecordingProcessingHandoffStatus.alreadyTerminal;

  String? get failureCode => switch (status) {
    RecordingProcessingHandoffStatus.unavailable =>
      'RECORDING_PROCESSING_HANDOFF_UNAVAILABLE',
    RecordingProcessingHandoffStatus.missingCheckpoint =>
      'RECORDING_PROCESSING_CHECKPOINT_MISSING',
    _ => null,
  };
}

final class RecordingObjectUploadProgress {
  const RecordingObjectUploadProgress({
    required this.draftId,
    required this.bytesSent,
    required this.totalBytes,
    required this.bytesPerSecond,
    this.estimatedRemainingSeconds,
  });

  final String draftId;
  final int bytesSent;
  final int totalBytes;
  final double bytesPerSecond;
  final int? estimatedRemainingSeconds;
}

final class RecordingUploadState {
  const RecordingUploadState({
    this.status,
    this.activeDraft,
    this.createdRecording,
    this.lastErrorCode,
    this.lastErrorJobId,
    this.activeJobIds = const <String>{},
    this.failureCodesByJobId = const <String, String>{},
    this.uploadProgressDraftId,
    this.uploadProgressByDraftId =
        const <String, RecordingObjectUploadProgress>{},
    this.activeUploadDraftsById = const <String, UploadDraft>{},
    this.uploadBytesSent = 0,
    this.uploadTotalBytes = 0,
    this.uploadBytesPerSecond = 0,
    this.estimatedRemainingSeconds,
  }) : assert(lastErrorJobId == null || lastErrorCode != null);

  factory RecordingUploadState.initial() => const RecordingUploadState();

  final RecordingFileJobStatus? status;
  final UploadDraft? activeDraft;
  final CreateRecordingResponse? createdRecording;
  final String? lastErrorCode;
  final String? lastErrorJobId;
  final Set<String> activeJobIds;
  final Map<String, String> failureCodesByJobId;
  final String? uploadProgressDraftId;
  final Map<String, RecordingObjectUploadProgress> uploadProgressByDraftId;
  final Map<String, UploadDraft> activeUploadDraftsById;
  final int uploadBytesSent;
  final int uploadTotalBytes;
  final double uploadBytesPerSecond;
  final int? estimatedRemainingSeconds;

  RecordingObjectUploadProgress? progressForDraft(String draftId) =>
      uploadProgressByDraftId[draftId];

  String? failureCodeForJob(String jobId) =>
      failureCodesByJobId[jobId] ??
      (lastErrorJobId == jobId ? lastErrorCode : null);

  RecordingUploadState copyWith({
    RecordingFileJobStatus? status,
    UploadDraft? activeDraft,
    bool clearActiveDraft = false,
    CreateRecordingResponse? createdRecording,
    bool clearCreatedRecording = false,
    String? lastErrorCode,
    String? lastErrorJobId,
    bool clearError = false,
    Set<String>? activeJobIds,
    Map<String, String>? failureCodesByJobId,
    int? uploadBytesSent,
    int? uploadTotalBytes,
    double? uploadBytesPerSecond,
    int? estimatedRemainingSeconds,
    bool clearEstimatedRemainingSeconds = false,
    bool clearUploadProgress = false,
    String? uploadProgressDraftId,
    bool clearUploadProgressDraftId = false,
    Map<String, RecordingObjectUploadProgress>? uploadProgressByDraftId,
    Map<String, UploadDraft>? activeUploadDraftsById,
    bool clearActiveUploadDrafts = false,
  }) {
    return RecordingUploadState(
      status: status ?? this.status,
      activeDraft: clearActiveDraft ? null : activeDraft ?? this.activeDraft,
      createdRecording: clearCreatedRecording
          ? null
          : createdRecording ?? this.createdRecording,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
      lastErrorJobId: clearError
          ? null
          : lastErrorCode != null
          ? lastErrorJobId
          : this.lastErrorJobId,
      activeJobIds: activeJobIds ?? this.activeJobIds,
      failureCodesByJobId: failureCodesByJobId ?? this.failureCodesByJobId,
      uploadProgressDraftId: clearUploadProgress || clearUploadProgressDraftId
          ? null
          : uploadProgressDraftId ?? this.uploadProgressDraftId,
      uploadProgressByDraftId:
          uploadProgressByDraftId ?? this.uploadProgressByDraftId,
      activeUploadDraftsById: clearActiveUploadDrafts
          ? const <String, UploadDraft>{}
          : activeUploadDraftsById ?? this.activeUploadDraftsById,
      uploadBytesSent: clearUploadProgress
          ? 0
          : uploadBytesSent ?? this.uploadBytesSent,
      uploadTotalBytes: clearUploadProgress
          ? 0
          : uploadTotalBytes ?? this.uploadTotalBytes,
      uploadBytesPerSecond: clearUploadProgress
          ? 0
          : uploadBytesPerSecond ?? this.uploadBytesPerSecond,
      estimatedRemainingSeconds:
          clearUploadProgress || clearEstimatedRemainingSeconds
          ? null
          : estimatedRemainingSeconds ?? this.estimatedRemainingSeconds,
    );
  }
}

final class RecordingUploadController extends ChangeNotifier {
  RecordingUploadController({
    required UploadClient uploadClient,
    required UploadDraftStore draftStore,
    required RecordingApiPort recordingApi,
    required LocalRecordingRepository localRecordingRepository,
    DiagnosticLogger? diagnosticLogger,
    String? Function()? activeWorkspaceId,
    String? accountScope,
    String? Function()? activeAccountScope,
    DateTime Function()? now,
    RecordingProcessingPort? processingPort,
    Duration localPreparationTimeout = const Duration(minutes: 2),
  }) : _uploadClient = uploadClient,
       _draftStore = draftStore,
       _recordingApi = recordingApi,
       _localRecordingRepository = localRecordingRepository,
       _diagnosticLogger = diagnosticLogger,
       _activeWorkspaceId = activeWorkspaceId,
       _accountScope = _normalizedAccountScope(accountScope),
       _activeAccountScope = activeAccountScope,
       _now = now,
       _processingPort = processingPort,
       _localPreparationTimeout = localPreparationTimeout;

  final UploadClient _uploadClient;
  final UploadDraftStore _draftStore;
  final RecordingApiPort _recordingApi;
  final LocalRecordingRepository _localRecordingRepository;
  final DiagnosticLogger? _diagnosticLogger;
  final String? Function()? _activeWorkspaceId;
  final String? _accountScope;
  final String? Function()? _activeAccountScope;
  final DateTime Function()? _now;
  final RecordingProcessingPort? _processingPort;
  final Duration _localPreparationTimeout;
  final Set<String> _scheduledProcessingHandoffDraftIds = <String>{};
  final Map<String, Future<CreateRecordingResponse?>> _inFlightUploads =
      <String, Future<CreateRecordingResponse?>>{};

  static const _objectUploadProgressInterval = Duration(milliseconds: 250);
  final Map<String, _ObjectUploadProgressSession>
  _objectUploadProgressSessions = <String, _ObjectUploadProgressSession>{};

  RecordingUploadState _state = RecordingUploadState.initial();
  var _disposed = false;

  RecordingUploadState get state => _state;

  DateTime get now => (_now ?? DateTime.now)().toUtc();

  UploadDraft? draftForJob(String jobId) => _draftStore.getDraft(jobId);

  Future<bool> retryJob(String jobId) async {
    final draft = _draftStore.getDraft(jobId);
    if (draft == null ||
        draft.stage == UploadDraftStage.asrCompleted ||
        draft.stage == UploadDraftStage.asrFailed ||
        draft.stage == UploadDraftStage.cancelled) {
      return false;
    }
    final fileSource = RecordingFileSource.fromRoute(
      draft.entrySource ?? draft.recordingSource,
    );
    if (draft.linkLocalRecording) {
      final item = _localRecordingRepository.findById(draft.localRecordingId);
      if (item == null) {
        _fail(
          recordingLibraryError('RECORDING_LOCAL_FILE_NOT_FOUND'),
          jobId: jobId,
        );
        return false;
      }
      return await uploadLocalRecording(
            item: item,
            sourceScene: draft.sourceScene,
            source: draft.recordingSource,
            fileSource: fileSource,
            title: draft.title,
            contentLineId: draft.contentLineId,
          ) !=
          null;
    }
    final hash = safeContentHash(draft.contentHash);
    if (hash == null) {
      _fail(
        recordingLibraryError('RECORDING_CONTENT_HASH_FAILED'),
        jobId: jobId,
      );
      return false;
    }
    return await uploadPrivateAudio(
          input: RecordingPrivateAudioInput(
            jobId: draft.draftId,
            localFileId: draft.localRecordingId,
            appPrivateUri: draft.appPrivateUri,
            fileName: draft.fileName,
            mimeType: draft.mimeType,
            sizeBytes: draft.sizeBytes,
            durationSeconds: draft.durationSeconds,
            contentHash: hash,
            recordedAt: draft.recordedAt ?? draft.updatedAt,
            title: draft.title ?? draft.fileName,
          ),
          fileSource: fileSource,
          sourceScene: draft.sourceScene,
          contentLineId: draft.contentLineId,
        ) !=
        null;
  }

  Future<CreateRecordingResponse?> _coalesceUpload(
    String jobId,
    Future<CreateRecordingResponse?> Function() operation,
  ) {
    final existing = _inFlightUploads[jobId];
    if (existing != null) return existing;
    final failures = Map<String, String>.of(_state.failureCodesByJobId)
      ..remove(jobId);
    _state = _state.copyWith(
      activeJobIds: Set<String>.unmodifiable({..._state.activeJobIds, jobId}),
      failureCodesByJobId: Map<String, String>.unmodifiable(failures),
    );
    late final Future<CreateRecordingResponse?> running;
    Future<CreateRecordingResponse?> execute() async {
      try {
        return await operation();
      } on _RecordingCheckpointWriteException {
        return null;
      }
    }

    running = execute().whenComplete(() {
      if (identical(_inFlightUploads[jobId], running)) {
        _inFlightUploads.remove(jobId);
        _settleActiveUpload(jobId);
      }
    });
    _inFlightUploads[jobId] = running;
    _publish();
    return running;
  }

  ({bool handled, CreateRecordingResponse? response}) _settledDraftResponse(
    UploadDraft draft,
  ) {
    final status = switch (draft.stage) {
      UploadDraftStage.asrQueued ||
      UploadDraftStage.uploaded => RecordingFileJobStatus.processing,
      UploadDraftStage.asrCompleted => RecordingFileJobStatus.ready,
      UploadDraftStage.asrFailed => RecordingFileJobStatus.failed,
      _ => null,
    };
    if (status == null) return (handled: false, response: null);
    final recordingId = draft.recordingId?.trim();
    if (status == RecordingFileJobStatus.failed ||
        recordingId == null ||
        recordingId.isEmpty) {
      _stopObjectUploadProgress(draft.draftId);
      final errorCode =
          draft.lastErrorCode ??
          (status == RecordingFileJobStatus.failed
              ? 'RECORDING_PROCESSING_FAILED'
              : 'RECORDING_ID_MISSING');
      _state = _state.copyWith(
        status: status == RecordingFileJobStatus.failed
            ? status
            : RecordingFileJobStatus.failed,
        activeDraft: draft,
        lastErrorCode: errorCode,
        lastErrorJobId: draft.draftId,
        failureCodesByJobId: Map<String, String>.unmodifiable({
          ..._state.failureCodesByJobId,
          draft.draftId: errorCode,
        }),
      );
      _publish();
      return (handled: true, response: null);
    }
    final checkpoint = draft.stage == UploadDraftStage.uploaded
        ? _saveStage(draft, UploadDraftStage.asrQueued)
        : draft;
    final recording = RecordingAsset(
      recordingId: recordingId,
      title: checkpoint.title ?? checkpoint.fileName,
      status: status == RecordingFileJobStatus.ready
          ? RecordingRemoteStatus.completed
          : RecordingRemoteStatus.queued,
      asrTaskId: checkpoint.asrTaskId,
      contentLineId: checkpoint.contentLineId,
      recordedAt: checkpoint.recordedAt,
    );
    final response = CreateRecordingResponse(
      recording: recording,
      asrTask: checkpoint.asrTaskId == null
          ? null
          : AsrTaskSnapshot(
              asrTaskId: checkpoint.asrTaskId!,
              status: status == RecordingFileJobStatus.ready
                  ? RecordingRemoteStatus.completed
                  : RecordingRemoteStatus.queued,
            ),
    );
    _stopObjectUploadProgress(checkpoint.draftId);
    _state = _state.copyWith(
      status: status,
      activeDraft: checkpoint,
      createdRecording: response,
      clearError: true,
    );
    _publish();
    if (status == RecordingFileJobStatus.processing) {
      _scheduleProcessingHandoff(checkpoint);
    }
    return (handled: true, response: response);
  }

  bool _draftMatchesLocalItem(
    UploadDraft draft,
    RecordingLibraryItem item, {
    required String? workspaceId,
  }) {
    return draft.localRecordingId == item.recordingId &&
        draft.appPrivateUri == item.appPrivateUri &&
        draft.sizeBytes == item.sizeBytes &&
        _canAdmitDraftWorkspace(draft, workspaceId);
  }

  bool _draftMatchesPrivateInput(
    UploadDraft draft,
    RecordingPrivateAudioInput input, {
    required String? workspaceId,
  }) {
    return !draft.linkLocalRecording &&
        draft.localRecordingId == input.localFileId &&
        draft.appPrivateUri == input.appPrivateUri &&
        draft.sizeBytes == input.sizeBytes &&
        draft.contentHash == input.contentHash &&
        _canAdmitDraftWorkspace(draft, workspaceId);
  }

  bool _canAdmitDraftWorkspace(UploadDraft draft, String? workspaceId) {
    if (!_hasActiveWorkspaceResolver) return true;
    if (workspaceId == null) return false;
    return switch (draft.workspaceState) {
      UploadDraftWorkspaceState.unboundLocal => true,
      UploadDraftWorkspaceState.bound => draft.workspaceId == workspaceId,
      UploadDraftWorkspaceState.unsafeUnbound => false,
    };
  }

  UploadDraft _bindDraftWorkspace(UploadDraft draft, String? workspaceId) {
    if (workspaceId == null ||
        draft.workspaceState != UploadDraftWorkspaceState.unboundLocal) {
      return draft;
    }
    final bound = createInitialUploadDraft(
      draftId: draft.draftId,
      localRecordingId: draft.localRecordingId,
      appPrivateUri: draft.appPrivateUri,
      fileName: draft.fileName,
      mimeType: draft.mimeType,
      sizeBytes: draft.sizeBytes,
      durationSeconds: draft.durationSeconds,
      sourceScene: draft.sourceScene,
      recordingSource: draft.recordingSource ?? 'local_upload',
      entrySource: draft.entrySource,
      linkLocalRecording: draft.linkLocalRecording,
      updatedAt: now,
      workspaceId: workspaceId,
      contentHash: draft.contentHash,
      contentLineId: draft.contentLineId,
      recordedAt: draft.recordedAt,
      title: draft.title,
    );
    return _saveStage(bound, UploadDraftStage.localReady);
  }

  /// Re-enrolls an already-created recording only from its persisted ASR
  /// checkpoint. It never creates a recording, polls it, or retries it.
  RecordingProcessingHandoff handoffQueuedProcessingForLocalRecording({
    required String localRecordingId,
    required String recordingId,
  }) {
    if (_disposed || _cancelIfAccountChanged()) {
      return const RecordingProcessingHandoff(
        RecordingProcessingHandoffStatus.unavailable,
      );
    }
    final normalizedLocalRecordingId = localRecordingId.trim();
    final normalizedRecordingId = recordingId.trim();
    if (normalizedLocalRecordingId.isEmpty || normalizedRecordingId.isEmpty) {
      return const RecordingProcessingHandoff(
        RecordingProcessingHandoffStatus.missingCheckpoint,
      );
    }
    final activeWorkspaceId = _activeWorkspaceIdValue();
    if (activeWorkspaceId == null) {
      return const RecordingProcessingHandoff(
        RecordingProcessingHandoffStatus.unavailable,
      );
    }
    final candidates =
        _draftStore
            .listDraftsForLocalRecording(normalizedLocalRecordingId)
            .where(
              (draft) => draft.recordingId?.trim() == normalizedRecordingId,
            )
            .where((draft) => draft.workspaceId?.trim() == activeWorkspaceId)
            .toList(growable: false)
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    final queued = candidates
        .where((draft) => draft.stage == UploadDraftStage.asrQueued)
        .firstOrNull;
    if (queued != null) {
      if (_processingPort == null) {
        return const RecordingProcessingHandoff(
          RecordingProcessingHandoffStatus.unavailable,
        );
      }
      final wasAlreadyEnrolled = _scheduleProcessingHandoff(queued);
      return RecordingProcessingHandoff(
        wasAlreadyEnrolled
            ? RecordingProcessingHandoffStatus.alreadyEnrolled
            : RecordingProcessingHandoffStatus.enqueued,
      );
    }
    final terminal = candidates.any(
      (draft) =>
          draft.stage == UploadDraftStage.asrCompleted ||
          draft.stage == UploadDraftStage.asrFailed,
    );
    return RecordingProcessingHandoff(
      terminal
          ? RecordingProcessingHandoffStatus.alreadyTerminal
          : RecordingProcessingHandoffStatus.missingCheckpoint,
    );
  }

  Future<CreateRecordingResponse?> uploadLocalRecording({
    required RecordingLibraryItem item,
    String sourceScene = 'raw_material',
    String? source,
    RecordingFileSource? fileSource,
    String? title,
    String? contentLineId,
  }) {
    final resolvedFileSource =
        fileSource ?? _recordingFileSourceFromLegacy(source, item: item);
    final backendSource =
        _normalizedRecordingSource(source) ?? resolvedFileSource.backendValue;
    final jobId = recordingFileJobId(item);
    return _coalesceUpload(
      jobId,
      () => _uploadLocalRecordingOnce(
        item: item,
        sourceScene: sourceScene,
        backendSource: backendSource,
        fileSource: resolvedFileSource,
        title: title,
        contentLineId: contentLineId,
      ),
    );
  }

  Future<CreateRecordingResponse?> uploadPrivateAudio({
    required RecordingPrivateAudioInput input,
    required RecordingFileSource fileSource,
    String sourceScene = 'raw_material',
    String? contentLineId,
  }) {
    return _coalesceUpload(
      input.jobId,
      () => _uploadPrivateAudioOnce(
        input: input,
        fileSource: fileSource,
        sourceScene: sourceScene,
        contentLineId: contentLineId,
      ),
    );
  }

  Future<CreateRecordingResponse?> _uploadLocalRecordingOnce({
    required RecordingLibraryItem item,
    required String sourceScene,
    required String backendSource,
    required RecordingFileSource fileSource,
    String? title,
    String? contentLineId,
  }) async {
    final jobId = recordingFileJobId(item);
    if (_cancelIfAccountChanged(jobId: jobId)) return null;
    if (!_localRecordingRepository.beginUploadOperation(item.recordingId)) {
      _fail(
        recordingLibraryError('RECORDING_LOCAL_DELETE_IN_PROGRESS'),
        jobId: jobId,
      );
      return null;
    }
    try {
      final workspaceId = _activeWorkspaceIdValue();
      if (_hasActiveWorkspaceResolver && workspaceId == null) {
        _fail(
          recordingLibraryError('RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE'),
          jobId: jobId,
        );
        return null;
      }
      if (contentLineId != null &&
          !isSafeRecordingLibraryIdentifier(contentLineId)) {
        _fail(
          recordingLibraryError('RECORDING_CONTENT_LINE_ID_INVALID'),
          jobId: jobId,
        );
        return null;
      }
      var draft = _draftStore.getDraft(jobId);
      if (draft != null) {
        if (!_draftMatchesLocalItem(draft, item, workspaceId: workspaceId)) {
          _fail(
            recordingLibraryError('RECORDING_UPLOAD_JOB_CONFLICT'),
            jobId: jobId,
          );
          return null;
        }
        draft = _bindDraftWorkspace(draft, workspaceId);
        if (draft.entrySource == null) {
          draft = _saveStage(
            draft.copyWith(entrySource: fileSource.routeValue),
            draft.stage,
          );
        }
        final settled = _settledDraftResponse(draft);
        if (settled.handled) return settled.response;
      } else {
        final prepared = _draftFromItem(
          item: item,
          sourceScene: sourceScene,
          backendSource: backendSource,
          fileSource: fileSource,
          title: title ?? item.displayName,
          contentLineId: contentLineId,
          workspaceId: workspaceId,
        );
        if (prepared is AppFailure) {
          _fail(prepared, jobId: jobId);
          return null;
        }
        final saved = _draftStore.saveDraft(prepared as UploadDraft);
        if (!saved.ok || saved.value == null) {
          _fail(
            saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED'),
            jobId: jobId,
          );
          return null;
        }
        draft = saved.value!;
        _set(_RecordingUploadPhase.preparing, draft);
      }

      var uploadItem = item;
      if (safeContentHash(uploadItem.contentHash) == null &&
          safeContentHash(draft.contentHash) == null) {
        _logWithoutDraft('contentHash', 'started');
        final hashed = await _ensureContentHash(uploadItem);
        if (_cancelIfScopeChanged(
          expectedWorkspaceId: workspaceId,
          jobId: jobId,
        )) {
          return null;
        }
        if (!hashed.ok || hashed.value == null) {
          final failure =
              hashed.error ??
              recordingLibraryError('RECORDING_CONTENT_HASH_FAILED');
          _logWithoutDraft('contentHash', 'failed', errorCode: failure.code);
          _fail(failure, jobId: jobId);
          return null;
        }
        uploadItem = hashed.value!;
        _logWithoutDraft('contentHash', 'succeeded');
        final rebuilt = _draftFromItem(
          item: uploadItem,
          sourceScene: draft.sourceScene,
          backendSource: draft.recordingSource ?? backendSource,
          fileSource: RecordingFileSource.fromRoute(
            draft.entrySource ?? fileSource.routeValue,
          ),
          title: draft.title ?? title ?? item.displayName,
          contentLineId: draft.contentLineId ?? contentLineId,
          workspaceId: draft.workspaceId ?? workspaceId,
        );
        if (rebuilt is AppFailure) {
          _markFailure(draft, UploadDraftStage.tokenFailed, rebuilt);
          return null;
        }
        final saved = _draftStore.saveDraft(rebuilt as UploadDraft);
        if (!saved.ok || saved.value == null) {
          _markFailure(
            draft,
            UploadDraftStage.tokenFailed,
            saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED'),
          );
          return null;
        }
        draft = saved.value!;
      }
      if (_cancelIfScopeChanged(draft: draft)) return null;
      return _runDraft(
        draft,
        fallbackSource: backendSource,
        contentLineId: contentLineId,
      );
    } finally {
      _localRecordingRepository.finishUploadOperation(item.recordingId);
    }
  }

  Future<CreateRecordingResponse?> _uploadPrivateAudioOnce({
    required RecordingPrivateAudioInput input,
    required RecordingFileSource fileSource,
    required String sourceScene,
    String? contentLineId,
  }) async {
    if (_cancelIfAccountChanged(jobId: input.jobId)) return null;
    final workspaceId = _activeWorkspaceIdValue();
    if (_hasActiveWorkspaceResolver && workspaceId == null) {
      _fail(
        recordingLibraryError('RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE'),
        jobId: input.jobId,
      );
      return null;
    }
    if (!_isSafeRecordingPrivateInput(input) ||
        (contentLineId != null &&
            !isSafeRecordingLibraryIdentifier(contentLineId))) {
      _fail(
        recordingLibraryError('RECORDING_UPLOAD_NOT_READY'),
        jobId: input.jobId,
      );
      return null;
    }
    var draft = _draftStore.getDraft(input.jobId);
    if (draft != null) {
      if (!_draftMatchesPrivateInput(draft, input, workspaceId: workspaceId)) {
        _fail(
          recordingLibraryError('RECORDING_UPLOAD_JOB_CONFLICT'),
          jobId: input.jobId,
        );
        return null;
      }
      draft = _bindDraftWorkspace(draft, workspaceId);
      final settled = _settledDraftResponse(draft);
      if (settled.handled) return settled.response;
    } else {
      draft = createInitialUploadDraft(
        draftId: input.jobId,
        localRecordingId: input.localFileId,
        appPrivateUri: input.appPrivateUri,
        fileName: input.fileName,
        mimeType: input.mimeType,
        sizeBytes: input.sizeBytes,
        durationSeconds: input.durationSeconds,
        sourceScene: sourceScene,
        workspaceId: workspaceId,
        recordingSource: fileSource.backendValue,
        entrySource: fileSource.routeValue,
        linkLocalRecording: false,
        updatedAt: now,
        contentHash: input.contentHash,
        contentLineId: contentLineId,
        recordedAt: input.recordedAt,
        title: input.title,
      );
      final saved = _draftStore.saveDraft(draft);
      if (!saved.ok || saved.value == null) {
        _fail(
          saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED'),
          jobId: input.jobId,
        );
        return null;
      }
      draft = saved.value!;
      _set(_RecordingUploadPhase.preparing, draft);
    }
    return _runDraft(
      draft,
      fallbackSource: fileSource.backendValue,
      contentLineId: contentLineId,
    );
  }

  Future<List<CreateRecordingResponse>> recoverDrafts({
    String source = 'local_upload',
    String? sourceScene,
    String? contentLineId,
  }) async {
    if (_cancelIfAccountChanged()) {
      return const <CreateRecordingResponse>[];
    }
    if (_hasActiveWorkspaceResolver && _activeWorkspaceIdValue() == null) {
      return const <CreateRecordingResponse>[];
    }
    final recovered = <CreateRecordingResponse>[];
    for (final draft in _draftStore.listRecoverableDrafts(
      sourceScene: sourceScene,
    )) {
      if (!_isDraftInActiveWorkspace(draft)) continue;
      if (draft.stage == UploadDraftStage.asrQueued) continue;
      if (_cancelIfScopeChanged(draft: draft)) {
        return List<CreateRecordingResponse>.unmodifiable(recovered);
      }
      final localLeaseId = draft.linkLocalRecording
          ? draft.localRecordingId
          : null;
      if (localLeaseId != null &&
          !_localRecordingRepository.beginUploadOperation(localLeaseId)) {
        continue;
      }
      try {
        final result = await _coalesceUpload(draft.draftId, () async {
          final effectiveDraft = await _repairLegacyDraftForRecovery(
            draft,
            fallbackSource: source,
          );
          if (_cancelIfScopeChanged(draft: draft) || effectiveDraft == null) {
            return null;
          }
          return _runDraft(
            effectiveDraft,
            fallbackSource: source,
            contentLineId: contentLineId,
          );
        });
        if (_cancelIfScopeChanged(draft: draft)) {
          return List<CreateRecordingResponse>.unmodifiable(recovered);
        }
        if (result != null) recovered.add(result);
      } finally {
        if (localLeaseId != null) {
          _localRecordingRepository.finishUploadOperation(localLeaseId);
        }
      }
    }
    return List<CreateRecordingResponse>.unmodifiable(recovered);
  }

  Future<UploadDraft?> _repairLegacyDraftForRecovery(
    UploadDraft draft, {
    required String fallbackSource,
  }) async {
    if (_cancelIfScopeChanged(draft: draft)) return null;
    if (draft.resourceId != null || draft.recordingId != null) {
      return draft;
    }
    if (!draft.linkLocalRecording) {
      if (safeContentHash(draft.contentHash) == null) {
        _markFailure(
          draft,
          UploadDraftStage.tokenFailed,
          recordingLibraryError('RECORDING_CONTENT_HASH_FAILED'),
        );
        return null;
      }
      return draft;
    }
    final item = _localRecordingRepository.findById(draft.localRecordingId);
    if (item == null) {
      _markFailure(
        draft,
        UploadDraftStage.tokenFailed,
        recordingLibraryError('RECORDING_NOT_FOUND'),
      );
      return null;
    }
    var uploadItem = item;
    if (safeContentHash(uploadItem.contentHash) == null) {
      _logStage(
        _RecordingUploadPhase.preparing,
        draft,
        outcome: 'repairingHash',
      );
      final hashed = await _ensureContentHash(item);
      if (_cancelIfScopeChanged(draft: draft)) return null;
      if (!hashed.ok || hashed.value == null) {
        _markFailure(
          draft,
          UploadDraftStage.tokenFailed,
          hashed.error ??
              recordingLibraryError('RECORDING_CONTENT_HASH_FAILED'),
        );
        return null;
      }
      uploadItem = hashed.value!;
    }
    final rebuilt = _draftFromItem(
      item: uploadItem,
      sourceScene: _recoveredSourceScene(draft),
      backendSource:
          draft.recordingSource ??
          _recordingSourceForRecovery(draft, fallback: fallbackSource),
      fileSource: RecordingFileSource.fromRoute(
        draft.entrySource ?? draft.recordingSource,
      ),
      title: draft.title ?? uploadItem.displayName,
      contentLineId: draft.contentLineId,
      workspaceId: draft.workspaceId,
    );
    if (rebuilt is AppFailure) {
      _markFailure(draft, UploadDraftStage.tokenFailed, rebuilt);
      return null;
    }
    final rebuiltDraft = rebuilt as UploadDraft;
    if (safeContentHash(draft.contentHash) == rebuiltDraft.contentHash &&
        draft.uploadTokenKey == rebuiltDraft.uploadTokenKey &&
        draft.completeUploadKey == rebuiltDraft.completeUploadKey &&
        draft.createRecordingKey == rebuiltDraft.createRecordingKey &&
        draft.workspaceId == rebuiltDraft.workspaceId) {
      return draft;
    }
    final saved = _draftStore.saveDraft(rebuiltDraft);
    if (!saved.ok || saved.value == null) {
      _markFailure(
        draft,
        UploadDraftStage.tokenFailed,
        saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED'),
      );
      return null;
    }
    _logStage(
      _RecordingUploadPhase.preparing,
      saved.value!,
      outcome: 'hashRepaired',
    );
    return saved.value!;
  }

  Future<LocalRecordingResult<RecordingLibraryItem>> _ensureContentHash(
    RecordingLibraryItem item,
  ) => _localRecordingRepository
      .ensureContentHash(item)
      .timeout(
        _localPreparationTimeout,
        onTimeout: () => LocalRecordingResult<RecordingLibraryItem>.failure(
          recordingLibraryError('RECORDING_CONTENT_HASH_TIMEOUT'),
        ),
      );

  Future<CreateRecordingResponse?> _runDraft(
    UploadDraft draft, {
    required String fallbackSource,
    String? contentLineId,
  }) async {
    if (_cancelIfScopeChanged(draft: draft)) return null;
    var current = draft;
    final recordingSource =
        current.recordingSource ??
        _recordingSourceForRecovery(current, fallback: fallbackSource);
    if (current.contentLineId == null && contentLineId != null) {
      if (!isSafeRecordingLibraryIdentifier(contentLineId)) {
        _fail(
          recordingLibraryError('RECORDING_CONTENT_LINE_ID_INVALID'),
          jobId: draft.draftId,
        );
        return null;
      }
      current = _saveStage(
        current.copyWith(contentLineId: contentLineId),
        current.stage,
      );
    }
    if (current.contentLineId != null &&
        !isSafeRecordingLibraryIdentifier(current.contentLineId!)) {
      _fail(
        recordingLibraryError('RECORDING_CONTENT_LINE_ID_INVALID'),
        jobId: draft.draftId,
      );
      return null;
    }
    _set(_RecordingUploadPhase.preparing, current);
    final metadata = _metadataFor(current);
    UploadToken? token;

    if (current.resourceId == null) {
      if (current.uploadId == null ||
          current.stage == UploadDraftStage.localReady ||
          current.stage == UploadDraftStage.tokenFailed ||
          current.stage == UploadDraftStage.objectUploadFailed) {
        current = _saveStage(current, UploadDraftStage.uploadTokenRequesting);
        _set(_RecordingUploadPhase.requestingToken, current);
        if (_cancelIfScopeChanged(draft: current)) return null;
        final tokenResult = await _uploadClient.requestUploadToken(
          metadata: metadata,
          idempotencyKey: current.uploadTokenKey,
        );
        if (_cancelIfScopeChanged(draft: current)) return null;
        if (!tokenResult.ok || tokenResult.value == null) {
          _markFailure(
            current,
            UploadDraftStage.tokenFailed,
            tokenResult.error ?? uploadFailure('UPLOAD_TOKEN_FAILED'),
          );
          return null;
        }
        token = tokenResult.value!;
        current = _saveStage(
          current.copyWith(uploadId: token.uploadId, clearLastError: true),
          UploadDraftStage.uploadTokenReady,
        );
      }

      if (current.stage != UploadDraftStage.objectUploaded &&
          current.stage != UploadDraftStage.completing &&
          current.stage != UploadDraftStage.completed) {
        token ??= await _refreshTokenForObjectUpload(current, metadata);
        if (_cancelIfScopeChanged(draft: current)) return null;
        if (token == null) return null;
        current = _saveStage(current, UploadDraftStage.objectUploading);
        _set(_RecordingUploadPhase.uploadingObject, current);
        if (_cancelIfScopeChanged(draft: current)) return null;
        final objectResult = await _uploadClient.uploadToObjectStore(
          token: token,
          metadata: metadata,
          onProgress: (bytesSent, totalBytes) => _onObjectUploadProgress(
            draftId: current.draftId,
            bytesSent: bytesSent,
            totalBytes: totalBytes,
          ),
        );
        if (_cancelIfScopeChanged(draft: current)) return null;
        if (!objectResult.ok) {
          _markFailure(
            current,
            UploadDraftStage.objectUploadFailed,
            objectResult.error ?? uploadFailure('UPLOAD_OBJECT_FAILED'),
          );
          return null;
        }
        current = _saveStage(
          current.copyWith(uploadId: token.uploadId, clearLastError: true),
          UploadDraftStage.objectUploaded,
        );
      }

      final uploadId = current.uploadId;
      if (uploadId == null) {
        _markFailure(
          current,
          UploadDraftStage.completeFailed,
          uploadFailure('UPLOAD_ID_MISSING'),
        );
        return null;
      }
      current = _saveStage(current, UploadDraftStage.completing);
      _set(_RecordingUploadPhase.completingUpload, current);
      if (_cancelIfScopeChanged(draft: current)) return null;
      final complete = await _uploadClient.completeUpload(
        uploadId: uploadId,
        metadata: metadata,
        idempotencyKey: current.completeUploadKey,
      );
      if (_cancelIfScopeChanged(draft: current)) return null;
      if (!complete.ok || complete.value == null) {
        _markFailure(
          current,
          UploadDraftStage.completeFailed,
          complete.error ?? uploadFailure('UPLOAD_COMPLETE_FAILED'),
        );
        return null;
      }
      current = _saveStage(
        current.copyWith(
          resourceId: complete.value!.resourceId,
          uploadId: complete.value!.uploadId,
          clearLastError: true,
        ),
        UploadDraftStage.completed,
      );
    }

    if (current.recordingId == null) {
      final resource = ResourceIndex(
        resourceId: current.resourceId!,
        uploadId: current.uploadId ?? 'upload-${current.draftId}',
        sourceScene: current.sourceScene,
        mimeType: current.mimeType,
        sizeBytes: current.sizeBytes,
        durationSeconds: current.durationSeconds,
        sha256: current.contentHash,
      );
      current = _saveStage(current, UploadDraftStage.creatingRecording);
      _set(_RecordingUploadPhase.creatingRecording, current);
      if (_cancelIfScopeChanged(draft: current)) return null;
      final created = await _recordingApi.createRecording(
        CreateRecordingInput(
          resource: resource,
          title: current.title ?? current.fileName,
          source: recordingSource,
          recordedAt: current.recordedAt ?? now,
          contentLineId: current.contentLineId,
          idempotencyKey: current.createRecordingKey,
        ),
      );
      if (_cancelIfScopeChanged(draft: current)) return null;
      if (!created.ok || created.data == null) {
        _markFailure(
          current,
          UploadDraftStage.createRecordingFailed,
          created.error ?? recordingApiFailure('CREATE_RECORDING_FAILED'),
        );
        return null;
      }
      final response = created.data!;
      current = _saveStage(
        current.copyWith(
          recordingId: response.recording.recordingId,
          asrTaskId:
              response.asrTask?.asrTaskId ?? response.recording.asrTaskId,
          clearLastError: true,
        ),
        UploadDraftStage.persistingLocalLink,
      );
      _set(_RecordingUploadPhase.persistingLocalLink, current);
      if (_cancelIfScopeChanged(draft: current)) return null;
      if (current.linkLocalRecording &&
          !_persistRemoteLink(current, response.recording)) {
        return null;
      }
      current = _saveStage(current, UploadDraftStage.asrQueued);
      _stopObjectUploadProgress(current.draftId);
      _state = _state.copyWith(
        status: RecordingFileJobStatus.processing,
        activeDraft: current,
        createdRecording: response,
        clearError: true,
      );
      _publish();
      _logStage(
        _state.status ?? RecordingFileJobStatus.processing,
        current,
        outcome: 'succeeded',
      );
      _scheduleProcessingHandoff(current);
      return response;
    }

    current = _saveStage(current, UploadDraftStage.persistingLocalLink);
    _set(_RecordingUploadPhase.persistingLocalLink, current);
    if (_cancelIfScopeChanged(draft: current)) return null;
    final recording = RecordingAsset(
      recordingId: current.recordingId!,
      title: current.title ?? current.fileName,
      status: RecordingRemoteStatus.queued,
      asrTaskId: current.asrTaskId,
      contentLineId: current.contentLineId,
      recordedAt: current.recordedAt,
    );
    if (current.linkLocalRecording && !_persistRemoteLink(current, recording)) {
      return null;
    }
    current = _saveStage(current, UploadDraftStage.asrQueued);
    final response = CreateRecordingResponse(
      recording: recording,
      asrTask: current.asrTaskId == null
          ? null
          : AsrTaskSnapshot(
              asrTaskId: current.asrTaskId!,
              status: RecordingRemoteStatus.queued,
            ),
    );
    _stopObjectUploadProgress(current.draftId);
    _state = _state.copyWith(
      status: RecordingFileJobStatus.processing,
      activeDraft: current,
      createdRecording: response,
      clearError: true,
    );
    _publish();
    _logStage(
      _state.status ?? RecordingFileJobStatus.processing,
      current,
      outcome: 'succeeded',
    );
    _scheduleProcessingHandoff(current);
    return response;
  }

  Future<UploadToken?> _refreshTokenForObjectUpload(
    UploadDraft current,
    UploadMetadata metadata,
  ) async {
    if (_cancelIfScopeChanged(draft: current)) return null;
    _set(_RecordingUploadPhase.requestingToken, current);
    if (_cancelIfScopeChanged(draft: current)) return null;
    final tokenResult = await _uploadClient.requestUploadToken(
      metadata: metadata,
      idempotencyKey: current.uploadTokenKey,
    );
    if (_cancelIfScopeChanged(draft: current)) return null;
    if (!tokenResult.ok || tokenResult.value == null) {
      _markFailure(
        current,
        UploadDraftStage.tokenFailed,
        tokenResult.error ?? uploadFailure('UPLOAD_TOKEN_FAILED'),
      );
      return null;
    }
    return tokenResult.value!;
  }

  Object _draftFromItem({
    required RecordingLibraryItem item,
    required String sourceScene,
    required String backendSource,
    required RecordingFileSource fileSource,
    required String title,
    String? contentLineId,
    String? workspaceId,
  }) {
    if (item.status == RecordingLibraryStatus.recycled ||
        item.localFileState != RecordingLocalFileState.ready ||
        item.appPrivateUri == null ||
        item.sizeBytes <= 0) {
      return recordingLibraryError('RECORDING_UPLOAD_NOT_READY');
    }
    final mimeType = _mimeFor(item.format);
    if (mimeType == null) {
      return recordingLibraryError('RECORDING_FORMAT_UNSUPPORTED');
    }
    return createInitialUploadDraft(
      draftId: recordingFileJobId(item),
      localRecordingId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      fileName: item.displayName,
      mimeType: mimeType,
      sizeBytes: item.sizeBytes,
      durationSeconds: item.durationSeconds,
      sourceScene: sourceScene,
      workspaceId: workspaceId ?? _activeWorkspaceIdValue(),
      recordingSource: backendSource,
      entrySource: fileSource.routeValue,
      updatedAt: now,
      contentHash: item.contentHash,
      contentLineId: contentLineId,
      recordedAt: item.createdAt,
      title: title,
    );
  }

  UploadMetadata _metadataFor(UploadDraft draft) {
    return UploadMetadata(
      sourceScene: draft.sourceScene,
      fileName: draft.fileName,
      mimeType: draft.mimeType,
      sizeBytes: draft.sizeBytes,
      durationSeconds: draft.durationSeconds,
      appPrivateUri: draft.appPrivateUri,
      sha256: draft.contentHash,
      workspaceId: draft.workspaceId,
    );
  }

  String? _activeWorkspaceIdValue() {
    final workspaceId = _activeWorkspaceId?.call()?.trim();
    return workspaceId == null || workspaceId.isEmpty ? null : workspaceId;
  }

  bool get _hasActiveWorkspaceResolver => _activeWorkspaceId != null;

  bool _isDraftInActiveWorkspace(UploadDraft draft) {
    if (!_hasActiveWorkspaceResolver) return true;
    final draftWorkspaceId = _normalizedWorkspaceId(draft.workspaceId);
    return draftWorkspaceId != null &&
        draftWorkspaceId == _activeWorkspaceIdValue();
  }

  bool _cancelIfScopeChanged({
    UploadDraft? draft,
    String? expectedWorkspaceId,
    String? jobId,
  }) {
    if (_disposed || _cancelIfAccountChanged(draft: draft, jobId: jobId)) {
      return true;
    }
    if (!_hasActiveWorkspaceResolver) return false;

    final frozenWorkspaceId = _normalizedWorkspaceId(
      draft?.workspaceId ?? expectedWorkspaceId,
    );
    final activeWorkspaceId = _activeWorkspaceIdValue();
    if (frozenWorkspaceId != null && frozenWorkspaceId == activeWorkspaceId) {
      return false;
    }

    final errorCode = activeWorkspaceId == null
        ? 'RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE'
        : 'RECORDING_UPLOAD_WORKSPACE_CHANGED';
    final failedJobId = draft?.draftId ?? jobId;
    _stopAllObjectUploadProgress();
    _state = _state.copyWith(
      status: RecordingFileJobStatus.failed,
      activeDraft: draft,
      lastErrorCode: errorCode,
      lastErrorJobId: failedJobId,
      failureCodesByJobId: Map<String, String>.unmodifiable({
        ..._state.failureCodesByJobId,
        if (failedJobId != null) failedJobId: errorCode,
      }),
      clearActiveUploadDrafts: true,
    );
    _publish();
    if (draft == null) {
      _logWithoutDraft('workspace', 'cancelled', errorCode: errorCode);
    } else {
      _logStage(
        RecordingFileJobStatus.failed,
        draft,
        outcome: 'cancelled',
        errorCode: errorCode,
      );
    }
    return true;
  }

  String? _normalizedWorkspaceId(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  bool _persistRemoteLink(UploadDraft draft, RecordingAsset recording) {
    final linked = _localRecordingRepository.linkRemoteRecording(
      localRecordingId: draft.localRecordingId,
      remoteRecordingId: recording.recordingId,
      contentLineId: recording.contentLineId ?? draft.contentLineId,
      linkedAt: now,
    );
    if (linked.ok) return true;
    _markFailure(
      draft,
      UploadDraftStage.localLinkFailed,
      linked.error ?? recordingLibraryError('RECORDING_REMOTE_LINK_FAILED'),
    );
    return false;
  }

  UploadDraft _saveStage(UploadDraft draft, UploadDraftStage stage) {
    final next = draft.copyWith(stage: stage, updatedAt: now);
    final saved = _draftStore.saveDraft(next);
    if (!saved.ok || saved.value == null) {
      final failure =
          saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED');
      _stopObjectUploadProgress(draft.draftId);
      _state = _state.copyWith(
        status: RecordingFileJobStatus.failed,
        activeDraft: draft,
        lastErrorCode: failure.code,
        lastErrorJobId: draft.draftId,
        failureCodesByJobId: Map<String, String>.unmodifiable({
          ..._state.failureCodesByJobId,
          draft.draftId: failure.code,
        }),
      );
      _publish();
      _logStage(
        RecordingFileJobStatus.failed,
        draft,
        outcome: 'failed',
        errorCode: failure.code,
        draftStage: stage,
      );
      throw _RecordingCheckpointWriteException();
    }
    return saved.value!;
  }

  void _set(_RecordingUploadPhase phase, UploadDraft draft) {
    final tracksObjectBytes = phase == _RecordingUploadPhase.uploadingObject;
    final activeDrafts = Map<String, UploadDraft>.of(
      _state.activeUploadDraftsById,
    )..[draft.draftId] = draft;
    _state = _state.copyWith(
      status: RecordingFileJobStatus.uploading,
      activeDraft: draft,
      clearError: true,
      activeUploadDraftsById: Map<String, UploadDraft>.unmodifiable(
        activeDrafts,
      ),
    );
    if (tracksObjectBytes) {
      _beginObjectUploadProgress(draft);
    } else {
      _stopObjectUploadProgress(draft.draftId);
    }
    _publish();
    _logStage(phase, draft, outcome: 'started');
  }

  void _beginObjectUploadProgress(UploadDraft draft) {
    _objectUploadProgressSessions.remove(draft.draftId)?.stop();
    _objectUploadProgressSessions[draft.draftId] = _ObjectUploadProgressSession(
      draft: draft,
    );
    _syncObjectUploadProgressState(preferredDraftId: draft.draftId);
  }

  void _stopObjectUploadProgress(String draftId) {
    _objectUploadProgressSessions.remove(draftId)?.stop();
    _syncObjectUploadProgressState();
  }

  void _stopAllObjectUploadProgress() {
    for (final session in _objectUploadProgressSessions.values) {
      session.stop();
    }
    _objectUploadProgressSessions.clear();
    _syncObjectUploadProgressState();
  }

  void _settleActiveUpload(String draftId) {
    if (!_state.activeUploadDraftsById.containsKey(draftId) &&
        !_state.activeJobIds.contains(draftId)) {
      return;
    }
    final activeDrafts = Map<String, UploadDraft>.of(
      _state.activeUploadDraftsById,
    )..remove(draftId);
    _state = _state.copyWith(
      activeJobIds: Set<String>.unmodifiable(
        Set<String>.of(_state.activeJobIds)..remove(draftId),
      ),
      activeUploadDraftsById: Map<String, UploadDraft>.unmodifiable(
        activeDrafts,
      ),
    );
    _publish();
  }

  void _syncObjectUploadProgressState({String? preferredDraftId}) {
    final progressByDraftId =
        Map<String, RecordingObjectUploadProgress>.fromEntries(
          _objectUploadProgressSessions.entries.map(
            (entry) => MapEntry<String, RecordingObjectUploadProgress>(
              entry.key,
              entry.value.progress,
            ),
          ),
        );
    String? projectionDraftId;
    if (preferredDraftId != null &&
        progressByDraftId.containsKey(preferredDraftId)) {
      projectionDraftId = preferredDraftId;
    } else if (_state.uploadProgressDraftId != null &&
        progressByDraftId.containsKey(_state.uploadProgressDraftId)) {
      projectionDraftId = _state.uploadProgressDraftId;
    } else if (_state.activeDraft != null &&
        progressByDraftId.containsKey(_state.activeDraft!.draftId)) {
      projectionDraftId = _state.activeDraft!.draftId;
    } else if (progressByDraftId.isNotEmpty) {
      projectionDraftId = progressByDraftId.keys.last;
    }
    final projection = projectionDraftId == null
        ? null
        : progressByDraftId[projectionDraftId];
    _state = _state.copyWith(
      uploadProgressByDraftId:
          Map<String, RecordingObjectUploadProgress>.unmodifiable(
            progressByDraftId,
          ),
      uploadProgressDraftId: projectionDraftId,
      clearUploadProgressDraftId: projectionDraftId == null,
      uploadBytesSent: projection?.bytesSent,
      uploadTotalBytes: projection?.totalBytes,
      uploadBytesPerSecond: projection?.bytesPerSecond,
      estimatedRemainingSeconds: projection?.estimatedRemainingSeconds,
      clearEstimatedRemainingSeconds:
          projection != null && projection.estimatedRemainingSeconds == null,
      clearUploadProgress: projection == null,
    );
  }

  void _onObjectUploadProgress({
    required String draftId,
    required int bytesSent,
    required int totalBytes,
  }) {
    if (_disposed) return;
    final session = _objectUploadProgressSessions[draftId];
    if (session == null || !_isDraftInActiveWorkspace(session.draft)) return;
    final activeAccountScope = _activeAccountScope;
    if (_accountScope != null &&
        activeAccountScope != null &&
        _accountScope != _normalizedAccountScope(activeAccountScope())) {
      return;
    }

    final safeTotal = session.draft.sizeBytes > 0
        ? session.draft.sizeBytes
        : totalBytes;
    final safeSent = bytesSent.clamp(0, safeTotal).toInt();
    final elapsed = session.watch.elapsed;
    final complete = safeSent >= safeTotal;
    if (!complete &&
        elapsed - session.lastPublishedAt < _objectUploadProgressInterval) {
      return;
    }

    final sampleElapsed = elapsed - session.lastPublishedAt;
    final sampleBytes = safeSent - session.lastPublishedBytes;
    final sampleSeconds = sampleElapsed.inMicroseconds / 1000000;
    final sampleRate = sampleBytes > 0 && sampleSeconds > 0
        ? sampleBytes / sampleSeconds
        : 0.0;
    final previousRate = session.progress.bytesPerSecond;
    final rate = sampleRate <= 0
        ? previousRate
        : previousRate <= 0
        ? sampleRate
        : (previousRate * .65) + (sampleRate * .35);
    final remainingBytes = safeTotal - safeSent;
    final eta = rate > 0 ? (remainingBytes / rate).ceil() : null;

    session
      ..lastPublishedAt = elapsed
      ..lastPublishedBytes = safeSent
      ..progress = RecordingObjectUploadProgress(
        draftId: draftId,
        bytesSent: safeSent,
        totalBytes: safeTotal,
        bytesPerSecond: rate,
        estimatedRemainingSeconds: eta,
      );
    _syncObjectUploadProgressState(preferredDraftId: draftId);
    _publish();
  }

  void _markFailure(
    UploadDraft draft,
    UploadDraftStage stage,
    AppFailure failure,
  ) {
    final saved = _draftStore.markFailed(
      draft: draft,
      stage: stage,
      errorCode: failure.code,
      now: now,
    );
    final checkpoint = saved.value;
    final effectiveFailure = !saved.ok || checkpoint == null
        ? saved.error ?? uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED')
        : failure;
    _stopObjectUploadProgress(draft.draftId);
    _state = _state.copyWith(
      status: RecordingFileJobStatus.failed,
      activeDraft: checkpoint ?? draft,
      lastErrorCode: effectiveFailure.code,
      lastErrorJobId: draft.draftId,
      failureCodesByJobId: Map<String, String>.unmodifiable({
        ..._state.failureCodesByJobId,
        draft.draftId: effectiveFailure.code,
      }),
    );
    _publish();
    _logStage(
      RecordingFileJobStatus.failed,
      checkpoint ?? draft,
      outcome: 'failed',
      errorCode: effectiveFailure.code,
      draftStage: stage,
    );
  }

  void _fail(AppFailure failure, {required String jobId}) {
    _state = _state.copyWith(
      status: RecordingFileJobStatus.failed,
      lastErrorCode: failure.code,
      lastErrorJobId: jobId,
      failureCodesByJobId: Map<String, String>.unmodifiable({
        ..._state.failureCodesByJobId,
        jobId: failure.code,
      }),
      clearActiveDraft: true,
      clearCreatedRecording: true,
    );
    _publish();
    _logWithoutDraft(
      'validation',
      'failed',
      errorCode: failure.code,
      jobId: jobId,
    );
  }

  bool _cancelIfAccountChanged({UploadDraft? draft, String? jobId}) {
    final boundScope = _accountScope;
    final activeScope = _activeAccountScope;
    if (boundScope == null || activeScope == null) return false;
    if (boundScope == _normalizedAccountScope(activeScope())) return false;

    const errorCode = 'RECORDING_UPLOAD_ACCOUNT_CHANGED';
    final failedJobId = draft?.draftId ?? jobId;
    _stopAllObjectUploadProgress();
    _state = _state.copyWith(
      status: RecordingFileJobStatus.failed,
      activeDraft: draft,
      lastErrorCode: errorCode,
      lastErrorJobId: failedJobId,
      failureCodesByJobId: Map<String, String>.unmodifiable({
        ..._state.failureCodesByJobId,
        if (failedJobId != null) failedJobId: errorCode,
      }),
      clearActiveUploadDrafts: true,
    );
    _publish();
    if (draft == null) {
      _logWithoutDraft('account', 'cancelled', errorCode: errorCode);
    } else {
      _logStage(
        RecordingFileJobStatus.failed,
        draft,
        outcome: 'cancelled',
        errorCode: errorCode,
      );
    }
    return true;
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  /// Returns whether this checkpoint had already been scheduled by this
  /// controller instance. Tracker recovery handles later app/process resumes.
  bool _scheduleProcessingHandoff(UploadDraft draft) {
    final port = _processingPort;
    if (port == null || _disposed || !_isDraftInActiveWorkspace(draft)) {
      return false;
    }
    if (!_scheduledProcessingHandoffDraftIds.add(draft.draftId)) return true;
    try {
      unawaited(
        port.track(draft).catchError((Object _) {
          _scheduledProcessingHandoffDraftIds.remove(draft.draftId);
        }),
      );
    } on Object {
      _scheduledProcessingHandoffDraftIds.remove(draft.draftId);
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopAllObjectUploadProgress();
    _scheduledProcessingHandoffDraftIds.clear();
    _inFlightUploads.clear();
    super.dispose();
  }

  void _logStage(
    Object status,
    UploadDraft draft, {
    required String outcome,
    String? errorCode,
    UploadDraftStage? draftStage,
  }) {
    final safeDraftId = _safeLogIdentifier(draft.draftId, 'draft');
    final stage =
        draftStage?.name ??
        switch (status) {
          _RecordingUploadPhase value => value.name,
          RecordingFileJobStatus value => value.name,
          _ => 'uploading',
        };
    if (kDebugMode) {
      debugPrint(
        '[RecordingUpload] stage=$stage outcome=$outcome '
        'draft=$safeDraftId'
        '${errorCode == null ? '' : ' errorCode=${_safeErrorCode(errorCode)}'}',
      );
    }
    _diagnosticLogger?.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.upload,
        severity: outcome == 'failed'
            ? DiagnosticSeverity.error
            : DiagnosticSeverity.info,
        safeSummary: 'recording_upload_${stage}_$outcome',
        correlationId: 'recording-upload-$safeDraftId',
        metadata: <String, Object?>{
          'stage': stage,
          'outcome': outcome,
          'draftId': safeDraftId,
          if (errorCode != null) 'errorCode': _safeErrorCode(errorCode),
        },
      ),
    );
  }

  void _logWithoutDraft(
    String stage,
    String outcome, {
    String? errorCode,
    String? jobId,
  }) {
    final safeStage = _safeLogIdentifier(stage, 'upload');
    final safeJobId = jobId == null ? null : _safeLogIdentifier(jobId, 'draft');
    if (kDebugMode) {
      debugPrint(
        '[RecordingUpload] stage=$safeStage outcome=$outcome'
        '${safeJobId == null ? '' : ' draft=$safeJobId'}'
        '${errorCode == null ? '' : ' errorCode=${_safeErrorCode(errorCode)}'}',
      );
    }
    _diagnosticLogger?.log(
      DiagnosticLogInput(
        category: DiagnosticCategory.upload,
        severity: outcome == 'failed'
            ? DiagnosticSeverity.error
            : DiagnosticSeverity.info,
        safeSummary: 'recording_upload_${safeStage}_$outcome',
        correlationId: safeJobId == null ? null : 'recording-upload-$safeJobId',
        metadata: <String, Object?>{
          'stage': safeStage,
          'outcome': outcome,
          if (safeJobId != null) 'draftId': safeJobId,
          if (errorCode != null) 'errorCode': _safeErrorCode(errorCode),
        },
      ),
    );
  }
}

final class _ObjectUploadProgressSession {
  _ObjectUploadProgressSession({required this.draft})
    : watch = Stopwatch()..start(),
      progress = RecordingObjectUploadProgress(
        draftId: draft.draftId,
        bytesSent: 0,
        totalBytes: draft.sizeBytes,
        bytesPerSecond: 0,
      );

  final UploadDraft draft;
  final Stopwatch watch;
  Duration lastPublishedAt = Duration.zero;
  int lastPublishedBytes = 0;
  RecordingObjectUploadProgress progress;

  void stop() => watch.stop();
}

final class _RecordingCheckpointWriteException implements Exception {}

RecordingFileJobStatus recordingFileJobStatusForDraft(
  UploadDraft draft, {
  RecordingProcessingTask? processingTask,
}) {
  if (processingTask != null) return processingTask.status;
  return switch (draft.stage) {
    UploadDraftStage.asrQueued ||
    UploadDraftStage.uploaded => RecordingFileJobStatus.processing,
    UploadDraftStage.asrCompleted => RecordingFileJobStatus.ready,
    UploadDraftStage.asrFailed ||
    UploadDraftStage.tokenFailed ||
    UploadDraftStage.objectUploadFailed ||
    UploadDraftStage.completeFailed ||
    UploadDraftStage.createRecordingFailed ||
    UploadDraftStage.localLinkFailed ||
    UploadDraftStage.cancelled => RecordingFileJobStatus.failed,
    _ => RecordingFileJobStatus.uploading,
  };
}

String _safeLogIdentifier(String value, String fallback) {
  final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_:-]'), '');
  if (safe.isEmpty) return fallback;
  return safe.length <= 72 ? safe : safe.substring(0, 72);
}

String? _normalizedAccountScope(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _normalizedRecordingSource(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(normalized)
      ? normalized
      : null;
}

RecordingFileSource _recordingFileSourceFromLegacy(
  String? source, {
  required RecordingLibraryItem item,
}) {
  return switch (source?.trim()) {
    'monologue' => RecordingFileSource.monologue,
    'meeting' => RecordingFileSource.meeting,
    'internal_recording' => RecordingFileSource.internalRecording,
    'recording_card' => RecordingFileSource.recordingCard,
    'v3_material_upload' => RecordingFileSource.audioImport,
    _ when item.source == RecordingLibrarySource.device =>
      RecordingFileSource.recordingCard,
    _ => RecordingFileSource.localLibrary,
  };
}

bool _isSafeRecordingPrivateInput(RecordingPrivateAudioInput input) {
  return RegExp(
        r'^draft-[A-Za-z0-9][A-Za-z0-9._-]{0,191}$',
      ).hasMatch(input.jobId) &&
      isSafeRecordingLibraryIdentifier(input.localFileId) &&
      RegExp(
        r'^app-private-media://screen-capture/[A-Za-z0-9][A-Za-z0-9._-]*\.(m4a|mp4|wav)$',
      ).hasMatch(input.appPrivateUri) &&
      RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._-]*\.(m4a|mp4|wav)$',
      ).hasMatch(input.fileName) &&
      const <String>{'audio/mp4', 'audio/wav'}.contains(input.mimeType) &&
      input.sizeBytes > 0 &&
      input.durationSeconds > 0 &&
      safeContentHash(input.contentHash) != null &&
      safeDisplayName(input.title) != null;
}

String _safeErrorCode(String value) {
  return RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(value)
      ? value
      : 'RECORDING_UPLOAD_FAILED';
}

String? _mimeFor(RecordingLibraryFormat format) {
  return switch (format) {
    RecordingLibraryFormat.mp3 => 'audio/mpeg',
    RecordingLibraryFormat.opus => 'audio/opus',
    RecordingLibraryFormat.m4a => 'audio/mp4',
    RecordingLibraryFormat.wav => 'audio/wav',
    RecordingLibraryFormat.unknown => null,
  };
}

String _recoveredSourceScene(UploadDraft draft) {
  // Early meeting builds used an unsupported upload scene before any token
  // existed. Upgrade only that pre-upload legacy state; sessions with an
  // upload id remain bound to their server-side constraints.
  if (draft.uploadId == null && draft.sourceScene == 'meeting') {
    return 'raw_material';
  }
  return draft.sourceScene;
}

String _recordingSourceForRecovery(
  UploadDraft draft, {
  required String fallback,
}) {
  return switch (draft.sourceScene) {
    'monologue' => 'monologue',
    'meeting' => 'meeting',
    _ => fallback,
  };
}
