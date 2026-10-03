import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../api/api_envelope.dart';
import '../database/app_database.dart';
import '../database/recording_dao.dart';

enum UploadDraftStage {
  localReady,
  uploadTokenRequesting,
  uploadTokenReady,
  objectUploading,
  objectUploaded,
  completing,
  completed,
  creatingRecording,
  persistingLocalLink,
  asrQueued,
  uploaded,
  asrCompleted,
  asrFailed,
  tokenFailed,
  objectUploadFailed,
  completeFailed,
  createRecordingFailed,
  localLinkFailed,
  cancelled,
}

enum UploadDraftWorkspaceState { unboundLocal, bound, unsafeUnbound }

final class UploadDraft {
  const UploadDraft({
    required this.draftId,
    required this.localRecordingId,
    required this.appPrivateUri,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.sourceScene,
    this.workspaceId,
    this.recordingSource,
    this.entrySource,
    this.linkLocalRecording = true,
    required this.stage,
    required this.updatedAt,
    required this.uploadTokenKey,
    required this.completeUploadKey,
    required this.createRecordingKey,
    this.contentHash,
    this.uploadId,
    this.resourceId,
    this.recordingId,
    this.asrTaskId,
    this.lastErrorCode,
    this.contentLineId,
    this.recordedAt,
    this.title,
  });

  final String draftId;
  final String localRecordingId;
  final String appPrivateUri;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String sourceScene;
  final String? workspaceId;

  UploadDraftWorkspaceState get workspaceState {
    if (workspaceId?.trim().isNotEmpty == true) {
      return UploadDraftWorkspaceState.bound;
    }
    if (stage == UploadDraftStage.localReady &&
        uploadId == null &&
        resourceId == null &&
        recordingId == null &&
        asrTaskId == null) {
      return UploadDraftWorkspaceState.unboundLocal;
    }
    return UploadDraftWorkspaceState.unsafeUnbound;
  }

  final String? recordingSource;
  final String? entrySource;
  final bool linkLocalRecording;
  final UploadDraftStage stage;
  final DateTime updatedAt;
  final String uploadTokenKey;
  final String completeUploadKey;
  final String createRecordingKey;
  final String? contentHash;
  final String? uploadId;
  final String? resourceId;
  final String? recordingId;
  final String? asrTaskId;
  final String? lastErrorCode;
  final String? contentLineId;
  final DateTime? recordedAt;
  final String? title;

  bool get isTerminal =>
      stage == UploadDraftStage.asrCompleted ||
      stage == UploadDraftStage.asrFailed ||
      stage == UploadDraftStage.cancelled;

  bool get isRecoverable => !isTerminal;

  UploadDraft copyWith({
    UploadDraftStage? stage,
    DateTime? updatedAt,
    String? uploadId,
    String? resourceId,
    String? recordingId,
    String? asrTaskId,
    String? lastErrorCode,
    String? contentLineId,
    DateTime? recordedAt,
    String? title,
    String? recordingSource,
    String? entrySource,
    bool? linkLocalRecording,
    String? workspaceId,
    String? appPrivateUri,
    int? sizeBytes,
    int? durationSeconds,
    bool clearLastError = false,
  }) {
    return UploadDraft(
      draftId: draftId,
      localRecordingId: localRecordingId,
      appPrivateUri: appPrivateUri ?? this.appPrivateUri,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sourceScene: sourceScene,
      workspaceId: workspaceId ?? this.workspaceId,
      recordingSource: recordingSource ?? this.recordingSource,
      entrySource: entrySource ?? this.entrySource,
      linkLocalRecording: linkLocalRecording ?? this.linkLocalRecording,
      stage: stage ?? this.stage,
      updatedAt: updatedAt ?? this.updatedAt,
      uploadTokenKey: uploadTokenKey,
      completeUploadKey: completeUploadKey,
      createRecordingKey: createRecordingKey,
      contentHash: contentHash,
      uploadId: uploadId ?? this.uploadId,
      resourceId: resourceId ?? this.resourceId,
      recordingId: recordingId ?? this.recordingId,
      asrTaskId: asrTaskId ?? this.asrTaskId,
      lastErrorCode: clearLastError
          ? null
          : lastErrorCode ?? this.lastErrorCode,
      contentLineId: contentLineId ?? this.contentLineId,
      recordedAt: recordedAt ?? this.recordedAt,
      title: title ?? this.title,
    );
  }

  LocalDatabaseRecord toRecord() {
    return <String, Object?>{
      'draft_id': draftId,
      'local_file_id': localRecordingId,
      'local_recording_id': localRecordingId,
      'app_private_uri': appPrivateUri,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'duration_seconds': durationSeconds,
      'source_scene': sourceScene,
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (recordingSource != null) 'recording_source': recordingSource,
      if (entrySource != null) 'entry_source': entrySource,
      'link_local_recording': linkLocalRecording,
      'stage': stage.name,
      'updated_at': updatedAt.toIso8601String(),
      'upload_idempotency_key': uploadTokenKey,
      'complete_idempotency_key': completeUploadKey,
      'create_recording_idempotency_key': createRecordingKey,
      if (contentHash != null) 'content_hash': contentHash,
      if (uploadId != null) 'resource_upload_id': uploadId,
      if (resourceId != null) 'resource_id': resourceId,
      if (recordingId != null) 'recording_id': recordingId,
      if (asrTaskId != null) 'asr_task_id': asrTaskId,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
      if (contentLineId != null) 'content_line_id': contentLineId,
      if (recordedAt != null) 'recorded_at': recordedAt!.toIso8601String(),
      if (title != null) 'title': title,
    };
  }

  static UploadDraft? fromRecord(LocalDatabaseRecord record) {
    final draftId = record['draft_id'] as String?;
    final localRecordingId =
        (record['local_recording_id'] ??
                record['local_file_id'] ??
                record['recording_id'])
            as String?;
    final appPrivateUri = record['app_private_uri'] as String?;
    final fileName = record['file_name'] as String?;
    final mimeType = record['mime_type'] as String?;
    final sourceScene = record['source_scene'] as String?;
    final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
    final stage = _parseStage(record['stage']);
    final uploadTokenKey = record['upload_idempotency_key'] as String?;
    final completeUploadKey = record['complete_idempotency_key'] as String?;
    final createRecordingKey =
        record['create_recording_idempotency_key'] as String?;
    if (draftId == null ||
        localRecordingId == null ||
        appPrivateUri == null ||
        fileName == null ||
        mimeType == null ||
        sourceScene == null ||
        updatedAt == null ||
        stage == null ||
        uploadTokenKey == null ||
        completeUploadKey == null ||
        createRecordingKey == null) {
      return null;
    }
    final size = record['size_bytes'];
    final duration = record['duration_seconds'];
    return UploadDraft(
      draftId: draftId,
      localRecordingId: localRecordingId,
      appPrivateUri: appPrivateUri,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: size is int ? size : 0,
      durationSeconds: duration is int ? duration : 0,
      sourceScene: sourceScene,
      workspaceId: record['workspace_id'] as String?,
      recordingSource: record['recording_source'] as String?,
      entrySource: record['entry_source'] as String?,
      linkLocalRecording: record['link_local_recording'] is bool
          ? record['link_local_recording'] as bool
          : true,
      stage: stage,
      updatedAt: updatedAt,
      uploadTokenKey: uploadTokenKey,
      completeUploadKey: completeUploadKey,
      createRecordingKey: createRecordingKey,
      contentHash: record['content_hash'] as String?,
      uploadId:
          (record['resource_upload_id'] ?? record['upload_id']) as String?,
      resourceId: record['resource_id'] as String?,
      recordingId: record['recording_id'] as String?,
      asrTaskId: record['asr_task_id'] as String?,
      lastErrorCode: record['last_error_code'] as String?,
      contentLineId: record['content_line_id'] as String?,
      recordedAt: DateTime.tryParse('${record['recorded_at'] ?? ''}'),
      title: record['title'] as String?,
    );
  }
}

final class UploadDraftStoreResult<T> {
  const UploadDraftStoreResult._({required this.ok, this.value, this.error});

  factory UploadDraftStoreResult.success(T value) {
    return UploadDraftStoreResult<T>._(ok: true, value: value);
  }

  factory UploadDraftStoreResult.failure(AppFailure error) {
    return UploadDraftStoreResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class UploadDraftStore {
  UploadDraftStore({
    required AppDatabase database,
    String? accountScope,
    bool requireAuthenticatedAccount = false,
  }) : _dao = RecordingDao(database, userScope: accountScope),
       _requiresAuthenticatedAccount = requireAuthenticatedAccount;

  final RecordingDao _dao;
  final bool _requiresAuthenticatedAccount;

  bool get _canAccess => !_requiresAuthenticatedAccount || _dao.isUserScoped;

  UploadDraftStoreResult<UploadDraft> saveDraft(UploadDraft draft) {
    if (!_canAccess) {
      return UploadDraftStoreResult<UploadDraft>.failure(
        uploadDraftFailure('UPLOAD_DRAFT_LOGIN_REQUIRED'),
      );
    }
    try {
      _dao.upsertUploadDraftRecord(draft.draftId, draft.toRecord());
      return UploadDraftStoreResult<UploadDraft>.success(draft);
    } catch (cause) {
      return UploadDraftStoreResult<UploadDraft>.failure(
        uploadDraftFailure('UPLOAD_DRAFT_WRITE_FAILED', cause: cause),
      );
    }
  }

  UploadDraft? getDraft(String draftId) {
    if (!_canAccess) return null;
    final record = _dao.getUploadDraftRecord(draftId);
    return record == null ? null : UploadDraft.fromRecord(record);
  }

  List<UploadDraft> listRecoverableDrafts({String? sourceScene}) {
    if (!_canAccess) return const <UploadDraft>[];
    final drafts = _dao
        .listUploadDraftRecords()
        .map(UploadDraft.fromRecord)
        .whereType<UploadDraft>()
        .where((draft) => draft.isRecoverable)
        .where(
          (draft) => sourceScene == null || draft.sourceScene == sourceScene,
        )
        .toList();
    drafts.sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
    return List<UploadDraft>.unmodifiable(drafts);
  }

  /// Remote work starts only after the upload workflow has durably created a
  /// recording. Keep it separate so recovery never replays create-recording.
  List<UploadDraft> listQueuedRecordingProcessingDrafts({String? workspaceId}) {
    if (!_canAccess) return const <UploadDraft>[];
    final normalizedWorkspaceId = _normalizedWorkspaceId(workspaceId);
    final drafts = _dao
        .listUploadDraftRecords()
        .map(UploadDraft.fromRecord)
        .whereType<UploadDraft>()
        .where(
          (draft) =>
              draft.stage == UploadDraftStage.asrQueued &&
              draft.recordingId?.trim().isNotEmpty == true,
        )
        .where(
          (draft) =>
              normalizedWorkspaceId == null ||
              _normalizedWorkspaceId(draft.workspaceId) ==
                  normalizedWorkspaceId,
        )
        .toList();
    drafts.sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
    return List<UploadDraft>.unmodifiable(drafts);
  }

  /// Durable terminal checkpoints for the server-owned recording flow.
  ///
  /// A recording id is authoritative even when an abbreviated create response
  /// omitted its ASR task id.
  List<UploadDraft> listTerminalRecordingProcessingDrafts({
    String? workspaceId,
  }) {
    if (!_canAccess) return const <UploadDraft>[];
    final normalizedWorkspaceId = _normalizedWorkspaceId(workspaceId);
    final drafts = _dao
        .listUploadDraftRecords()
        .map(UploadDraft.fromRecord)
        .whereType<UploadDraft>()
        .where(
          (draft) =>
              (draft.stage == UploadDraftStage.asrCompleted ||
                  draft.stage == UploadDraftStage.asrFailed) &&
              draft.recordingId?.trim().isNotEmpty == true,
        )
        .where(
          (draft) =>
              normalizedWorkspaceId == null ||
              _normalizedWorkspaceId(draft.workspaceId) ==
                  normalizedWorkspaceId,
        )
        .toList();
    drafts.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<UploadDraft>.unmodifiable(drafts);
  }

  List<UploadDraft> listDraftsForLocalRecording(String localRecordingId) {
    if (!_canAccess) return const <UploadDraft>[];
    final normalized = localRecordingId.trim();
    if (normalized.isEmpty) return const <UploadDraft>[];
    return List<UploadDraft>.unmodifiable(
      _dao
          .listUploadDraftsFor(normalized)
          .map(UploadDraft.fromRecord)
          .whereType<UploadDraft>(),
    );
  }

  UploadDraftStoreResult<UploadDraft> markFailed({
    required UploadDraft draft,
    required UploadDraftStage stage,
    required String errorCode,
    DateTime? now,
  }) {
    return saveDraft(
      draft.copyWith(
        stage: stage,
        lastErrorCode: errorCode,
        updatedAt: now ?? DateTime.now().toUtc(),
      ),
    );
  }

  UploadDraftStoreResult<bool> deleteDraft(String draftId) {
    if (!_canAccess) {
      return UploadDraftStoreResult<bool>.failure(
        uploadDraftFailure('UPLOAD_DRAFT_LOGIN_REQUIRED'),
      );
    }
    try {
      return UploadDraftStoreResult<bool>.success(
        _dao.deleteUploadDraftRecord(draftId),
      );
    } catch (cause) {
      return UploadDraftStoreResult<bool>.failure(
        uploadDraftFailure('UPLOAD_DRAFT_DELETE_FAILED', cause: cause),
      );
    }
  }
}

UploadDraft createInitialUploadDraft({
  required String draftId,
  required String localRecordingId,
  required String appPrivateUri,
  required String fileName,
  required String mimeType,
  required int sizeBytes,
  required int durationSeconds,
  required String sourceScene,
  required String recordingSource,
  String? entrySource,
  bool linkLocalRecording = true,
  required DateTime updatedAt,
  String? workspaceId,
  String? contentHash,
  String? contentLineId,
  DateTime? recordedAt,
  String? title,
}) {
  final idempotencySeed = _uploadRequestSeed(
    draftId: draftId,
    contentHash: contentHash,
    sourceScene: sourceScene,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    workspaceId: workspaceId,
  );
  return UploadDraft(
    draftId: draftId,
    localRecordingId: localRecordingId,
    appPrivateUri: appPrivateUri,
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    durationSeconds: durationSeconds,
    sourceScene: sourceScene,
    workspaceId: _normalizedWorkspaceId(workspaceId),
    recordingSource: recordingSource,
    entrySource: entrySource,
    linkLocalRecording: linkLocalRecording,
    stage: UploadDraftStage.localReady,
    updatedAt: updatedAt,
    uploadTokenKey: _keyFor(idempotencySeed, 'upload'),
    completeUploadKey: _keyFor(idempotencySeed, 'complete'),
    createRecordingKey: _keyFor(idempotencySeed, 'create-recording'),
    contentHash: contentHash,
    contentLineId: contentLineId,
    recordedAt: recordedAt,
    title: title,
  );
}

String _uploadRequestSeed({
  required String draftId,
  required String? contentHash,
  required String sourceScene,
  required String fileName,
  required String mimeType,
  required int sizeBytes,
  required int durationSeconds,
  required String? workspaceId,
}) {
  final normalizedHash = contentHash?.trim().toLowerCase();
  final identity = <String>[
    'upload-request-v2',
    draftId,
    normalizedHash != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedHash)
        ? normalizedHash
        : '',
    sourceScene.trim(),
    fileName.trim(),
    mimeType.trim().toLowerCase(),
    sizeBytes.toString(),
    durationSeconds.toString(),
    _normalizedWorkspaceId(workspaceId) ?? '',
  ].join('\u0000');
  final fingerprint = sha256.convert(utf8.encode(identity)).toString();
  return '$draftId-${fingerprint.substring(0, 24)}';
}

String? _normalizedWorkspaceId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

AppFailure uploadDraftFailure(String code, {Object? cause}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: 'Upload draft operation failed',
    userMessageKey: 'recording.uploadDraft.error.$code',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
    cause: cause,
  );
}

UploadDraftStage? _parseStage(Object? value) {
  for (final stage in UploadDraftStage.values) {
    if (stage.name == value) return stage;
  }
  return null;
}

String _keyFor(String draftId, String operation) {
  final safeDraft = draftId.replaceAll(RegExp(r'[^A-Za-z0-9._:-]+'), '-');
  return 'idem-$operation-$safeDraft';
}
