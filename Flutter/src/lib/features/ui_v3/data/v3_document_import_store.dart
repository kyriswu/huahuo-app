import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';

import '../../../core/database/app_database.dart';
import '../../../core/native/document_import_format.dart';
import '../../../core/native/native_file_port.dart';
import '../domain/document_import_progress.dart';

enum V3DocumentImportTaskStatus {
  staged,
  processing,
  waiting,
  completed,
  failed,
}

enum V3DocumentOutlineStatus { notStarted, running, succeeded, failed }

final class V3DocumentImportTask {
  const V3DocumentImportTask({
    required this.id,
    required this.pickerRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.privateFileName,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.noteId,
    this.remoteNoteId,
    this.uploadId,
    this.uploadResourceId,
    this.ingestionId,
    this.acceptedForImport = true,
    this.distillToDigitalTwin = false,
    this.deferDigitalTwinDistillation = false,
    this.distillationTaskId,
    this.distillationResourceId,
    this.digitalTwinConfirmationId,
    this.rawAssetCreated = false,
    this.outlineStatus = V3DocumentOutlineStatus.notStarted,
    this.outlineFileAgentRunId,
    this.outlineAgentRunId,
    this.outlineErrorCode,
    this.lastErrorCode,
    this.failureRetryable,
    V3DocumentImportPhase? phase,
  }) : _phase = phase;

  final String id;
  final String pickerRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final String privateFileName;
  final V3DocumentImportTaskStatus status;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? noteId;
  final String? remoteNoteId;
  final String? uploadId;
  final String? uploadResourceId;
  final String? ingestionId;
  final bool acceptedForImport;
  final bool distillToDigitalTwin;
  final bool deferDigitalTwinDistillation;
  final String? distillationTaskId;
  final String? distillationResourceId;
  final String? digitalTwinConfirmationId;
  final bool rawAssetCreated;
  final V3DocumentOutlineStatus outlineStatus;
  final String? outlineFileAgentRunId;
  final String? outlineAgentRunId;
  final String? outlineErrorCode;
  final String? lastErrorCode;
  final bool? failureRetryable;
  final V3DocumentImportPhase? _phase;

  V3DocumentImportPhase get phase => rawAssetCreated
      ? V3DocumentImportPhase.completed
      : _phase ??
            (remoteNoteId != null
                ? V3DocumentImportPhase.synchronizingNote
                : ingestionId != null
                ? V3DocumentImportPhase.parsing
                : uploadId != null
                ? V3DocumentImportPhase.confirmingUpload
                : V3DocumentImportPhase.preparingFile);

  bool get isCompleted => rawAssetCreated;
  bool get needsRawImport => acceptedForImport && !rawAssetCreated;
  bool get hasRemoteCheckpoint =>
      (uploadId != null && uploadResourceId != null) || ingestionId != null;
  bool get hasAcceptedIngestion => ingestionId != null;
  bool get isRetryable =>
      needsRawImport &&
      (failureRetryable != false ||
          documentImportCanResumeAfterIntervention(lastErrorCode)) &&
      !documentImportRequiresReselection(lastErrorCode) &&
      lastErrorCode != 'IDEMPOTENCY_KEY_CONFLICT';

  /// The shared automatic-outline coordinator owns new submissions. Retain
  /// these fields for legacy recovery/display without creating a second task.
  bool get needsOutlineSubmission => false;
  bool get hasPendingOutline =>
      outlineStatus == V3DocumentOutlineStatus.running;
  bool get hasFailedOutline => outlineStatus == V3DocumentOutlineStatus.failed;

  V3DocumentImportTask copyWith({
    String? pickerRef,
    V3DocumentImportTaskStatus? status,
    int? attemptCount,
    DateTime? updatedAt,
    String? noteId,
    String? remoteNoteId,
    String? uploadId,
    String? uploadResourceId,
    String? ingestionId,
    bool clearUploadCheckpoint = false,
    V3DocumentImportPhase? phase,
    bool? acceptedForImport,
    bool? distillToDigitalTwin,
    bool? deferDigitalTwinDistillation,
    String? distillationTaskId,
    String? distillationResourceId,
    String? digitalTwinConfirmationId,
    bool? rawAssetCreated,
    V3DocumentOutlineStatus? outlineStatus,
    String? outlineFileAgentRunId,
    String? outlineAgentRunId,
    String? outlineErrorCode,
    String? lastErrorCode,
    bool? failureRetryable,
    bool clearNoteId = false,
    bool clearOutlineRun = false,
    bool clearOutlineError = false,
    bool clearError = false,
  }) => V3DocumentImportTask(
    id: id,
    pickerRef: pickerRef ?? this.pickerRef,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sha256: sha256,
    privateFileName: privateFileName,
    status: status ?? this.status,
    phase: phase ?? _phase,
    attemptCount: attemptCount ?? this.attemptCount,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    noteId: clearNoteId ? null : noteId ?? this.noteId,
    remoteNoteId: remoteNoteId ?? this.remoteNoteId,
    uploadId: clearUploadCheckpoint ? null : uploadId ?? this.uploadId,
    uploadResourceId: clearUploadCheckpoint
        ? null
        : uploadResourceId ?? this.uploadResourceId,
    ingestionId: ingestionId ?? this.ingestionId,
    acceptedForImport: acceptedForImport ?? this.acceptedForImport,
    distillToDigitalTwin: distillToDigitalTwin ?? this.distillToDigitalTwin,
    deferDigitalTwinDistillation:
        deferDigitalTwinDistillation ?? this.deferDigitalTwinDistillation,
    distillationTaskId: distillationTaskId ?? this.distillationTaskId,
    distillationResourceId:
        distillationResourceId ?? this.distillationResourceId,
    digitalTwinConfirmationId:
        digitalTwinConfirmationId ?? this.digitalTwinConfirmationId,
    rawAssetCreated: rawAssetCreated ?? this.rawAssetCreated,
    outlineStatus: outlineStatus ?? this.outlineStatus,
    outlineFileAgentRunId: clearOutlineRun
        ? null
        : outlineFileAgentRunId ?? this.outlineFileAgentRunId,
    outlineAgentRunId: clearOutlineRun
        ? null
        : outlineAgentRunId ?? this.outlineAgentRunId,
    outlineErrorCode: clearOutlineError
        ? null
        : outlineErrorCode ?? this.outlineErrorCode,
    lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    failureRetryable: clearError
        ? null
        : failureRetryable ?? this.failureRetryable,
  );
}

final class V3DocumentImportStore {
  V3DocumentImportStore({
    required AppDatabase database,
    required Future<Directory> Function() rootDirectory,
    String ownerScope = 'local',
    DateTime Function()? now,
  }) : _database = database,
       _rootDirectory = rootDirectory,
       _ownerScope = _opaqueScope(ownerScope),
       _now = now ?? DateTime.now;

  static const _recordSource = 'document';
  static const _recordPrefix = 'document-import:';
  static final _shaPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _privateNamePattern = RegExp(
    r'^[a-f0-9]{64}\.(?:txt|md|csv|json|pdf|docx|pptx|xlsx)$',
  );

  final AppDatabase _database;
  final Future<Directory> Function() _rootDirectory;
  final String _ownerScope;
  final DateTime Function() _now;

  Future<NativeFileResult<V3DocumentImportTask>> stage(
    PickedDocumentFile document,
  ) async {
    File? part;
    try {
      final format = DocumentImportFormat.fromFileName(document.displayName);
      if (format == null || document.isAudio) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure('DOCUMENT_IMPORT_TYPE_UNSUPPORTED'),
        );
      }
      final sourcePath = document.sourcePath?.trim();
      if (sourcePath == null || sourcePath.isEmpty) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure('DOCUMENT_BODY_SOURCE_UNAVAILABLE'),
        );
      }
      final source = File(sourcePath);
      if (!await source.exists()) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure('DOCUMENT_BODY_SOURCE_UNAVAILABLE'),
        );
      }
      final sourceSize = await source.length();
      if (sourceSize <= 0 || sourceSize > maxDocumentImportBytes) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure(
            sourceSize <= 0
                ? 'DOCUMENT_IMPORT_FILE_EMPTY'
                : 'DOCUMENT_IMPORT_FILE_TOO_LARGE',
          ),
        );
      }
      final sourceHash = (await sha256.bind(source.openRead()).first)
          .toString();
      if (!_shaPattern.hasMatch(sourceHash)) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure('DOCUMENT_IMPORT_HASH_INVALID'),
        );
      }
      if ((document.sizeBytes > 0 && document.sizeBytes != sourceSize) ||
          (document.contentHash != null &&
              document.contentHash!.toLowerCase() != sourceHash)) {
        return NativeFileResult<V3DocumentImportTask>.failure(
          _failure('DOCUMENT_IMPORT_SOURCE_MUTATED'),
        );
      }

      final existing = taskForHash(sourceHash, format: format);
      if (existing != null) {
        if (existing.isCompleted || existing.remoteNoteId != null) {
          return NativeFileResult<V3DocumentImportTask>.success(
            existing.copyWith(pickerRef: document.pickerRef),
          );
        }
        final verified = await resolveVerifiedFile(existing);
        if (verified.ok &&
            (existing.isCompleted ||
                existing.isRetryable ||
                !existing.acceptedForImport)) {
          return NativeFileResult<V3DocumentImportTask>.success(
            existing.copyWith(
              pickerRef: document.pickerRef,
              updatedAt: _now().toUtc(),
            ),
          );
        }
      }

      final directory = await _filesDirectory();
      final privateFileName = '$sourceHash.${format.extension}';
      final destination = File('${directory.path}/$privateFileName');
      var needsCopy = !await destination.exists();
      if (!needsCopy) {
        needsCopy =
            await destination.length() != sourceSize ||
            (await sha256.bind(destination.openRead()).first).toString() !=
                sourceHash;
      }
      if (needsCopy) {
        part = File(
          '${directory.path}/.$sourceHash-${_now().microsecondsSinceEpoch}.part',
        );
        await source.openRead().pipe(part.openWrite(mode: FileMode.writeOnly));
        final stagedSize = await part.length();
        final stagedHash = (await sha256.bind(part.openRead()).first)
            .toString();
        if (stagedSize != sourceSize || stagedHash != sourceHash) {
          throw const _DocumentStoreException(
            'DOCUMENT_IMPORT_COPY_INTEGRITY_FAILED',
          );
        }
        await part.rename(destination.path);
        part = null;
      }

      final now = _now().toUtc();
      if (existing != null &&
          (existing.isRetryable || !existing.acceptedForImport)) {
        final repaired = existing.copyWith(
          pickerRef: document.pickerRef,
          updatedAt: now,
        );
        save(repaired);
        return NativeFileResult<V3DocumentImportTask>.success(repaired);
      }
      final task = V3DocumentImportTask(
        id: 'document-${sourceHash.substring(0, 32)}-${format.extension}',
        pickerRef: document.pickerRef,
        displayName: _safeDisplayName(document.displayName),
        mimeType: format.mimeType,
        sizeBytes: sourceSize,
        sha256: sourceHash,
        privateFileName: privateFileName,
        status: V3DocumentImportTaskStatus.staged,
        attemptCount: existing?.attemptCount ?? 0,
        acceptedForImport: false,
        createdAt: now,
        updatedAt: now,
      );
      save(task);
      return NativeFileResult<V3DocumentImportTask>.success(task);
    } on _DocumentStoreException catch (error) {
      return NativeFileResult<V3DocumentImportTask>.failure(
        _failure(error.code),
      );
    } on FileSystemException catch (error) {
      return NativeFileResult<V3DocumentImportTask>.failure(
        _failure(switch (error.osError?.errorCode) {
          28 => 'DOCUMENT_IMPORT_STORAGE_FULL',
          1 || 13 => 'DOCUMENT_IMPORT_FILE_ACCESS_DENIED',
          _ => 'DOCUMENT_IMPORT_STAGE_FAILED',
        }),
      );
    } on Object {
      return NativeFileResult<V3DocumentImportTask>.failure(
        _failure('DOCUMENT_IMPORT_STAGE_FAILED'),
      );
    } finally {
      final pendingPart = part;
      if (pendingPart != null) {
        try {
          if (await pendingPart.exists()) await pendingPart.delete();
        } on Object {
          // A stale .part is never referenced by a task and is safe to ignore.
        }
      }
    }
  }

  void save(V3DocumentImportTask task) {
    _database.upsertRecord(
      LocalTableName.materialIngestionDrafts,
      '$_recordPrefix$_ownerScope:${task.id}',
      <String, Object?>{
        'draft_id': task.id,
        'owner_scope': _ownerScope,
        'source': _recordSource,
        'status': task.status.name,
        'phase': task.phase.name,
        'checkpoint': task.rawAssetCreated ? 'noteDeposited' : 'created',
        'picker_ref': task.pickerRef,
        'title': task.displayName,
        'mime_type': task.mimeType,
        'size_bytes': task.sizeBytes,
        'content_hash': task.sha256,
        'private_file_name': task.privateFileName,
        'attempt_count': task.attemptCount,
        'created_at': task.createdAt.toUtc().toIso8601String(),
        'updated_at': task.updatedAt.toUtc().toIso8601String(),
        if (task.noteId != null) 'note_id': task.noteId,
        if (task.remoteNoteId != null) 'remote_note_id': task.remoteNoteId,
        if (task.uploadId != null) 'upload_id': task.uploadId,
        if (task.uploadResourceId != null)
          'upload_resource_id': task.uploadResourceId,
        if (task.ingestionId != null) 'ingestion_id': task.ingestionId,
        'accepted_for_import': task.acceptedForImport,
        'distill_to_digital_twin': task.distillToDigitalTwin,
        'defer_digital_twin_distillation': task.deferDigitalTwinDistillation,
        if (task.distillationTaskId != null)
          'distillation_task_id': task.distillationTaskId,
        if (task.distillationResourceId != null)
          'distillation_resource_id': task.distillationResourceId,
        if (task.digitalTwinConfirmationId != null)
          'digital_twin_confirmation_id': task.digitalTwinConfirmationId,
        'raw_asset_created': task.rawAssetCreated,
        'outline_status': task.outlineStatus.name,
        if (task.outlineFileAgentRunId != null)
          'outline_file_agent_run_id': task.outlineFileAgentRunId,
        if (task.outlineAgentRunId != null)
          'outline_agent_run_id': task.outlineAgentRunId,
        if (task.outlineErrorCode != null)
          'outline_error_code': task.outlineErrorCode,
        if (task.lastErrorCode != null) 'last_error_code': task.lastErrorCode,
        if (task.failureRetryable != null)
          'failure_retryable': task.failureRetryable,
      },
    );
  }

  Future<bool> saveAllDurably(Iterable<V3DocumentImportTask> tasks) async {
    final batch = List<V3DocumentImportTask>.of(tasks, growable: false);
    if (batch.isEmpty) return true;
    final transaction = _database.withTransaction<bool>((_) {
      for (final task in batch) {
        save(task);
      }
      return true;
    });
    if (!transaction.ok) return false;
    try {
      await _database.flushPersistence();
      return true;
    } on Object {
      return false;
    }
  }

  List<V3DocumentImportTask> listTasks({bool includeCompleted = true}) {
    final tasks =
        _database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.materialIngestionDrafts,
            )
            .where(
              (record) =>
                  record['owner_scope'] == _ownerScope &&
                  record['source'] == _recordSource,
            )
            .map(_taskFromRecord)
            .whereType<V3DocumentImportTask>()
            .where((task) => includeCompleted || !task.isCompleted)
            .toList(growable: false)
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List<V3DocumentImportTask>.unmodifiable(tasks);
  }

  V3DocumentImportTask? taskForHash(
    String hash, {
    DocumentImportFormat? format,
  }) {
    if (!_shaPattern.hasMatch(hash)) return null;
    for (final task in listTasks()) {
      if (task.sha256 != hash) continue;
      if (format == null || _formatForTask(task) == format) return task;
    }
    return null;
  }

  V3DocumentImportTask? taskForPickerRef(String pickerRef) {
    for (final task in listTasks()) {
      if (task.pickerRef == pickerRef) return task;
    }
    return null;
  }

  /// Completes only the independently persisted outline checkpoint. The raw
  /// asset remains available regardless of the derived operation's outcome.
  bool markOutlineTerminal({
    required String fileAgentRunId,
    required String status,
    String? failureCode,
  }) {
    final safeRunId = fileAgentRunId.trim();
    if (safeRunId.isEmpty) return false;
    final normalizedStatus = status.trim().toLowerCase();
    final succeeded = normalizedStatus == 'succeeded';
    final terminal =
        succeeded ||
        const <String>{
          'failed',
          'timeout',
          'cancelled',
          'conflict',
        }.contains(normalizedStatus);
    if (!terminal) return false;
    for (final task in listTasks()) {
      if (task.outlineFileAgentRunId != safeRunId) continue;
      save(
        task.copyWith(
          outlineStatus: succeeded
              ? V3DocumentOutlineStatus.succeeded
              : V3DocumentOutlineStatus.failed,
          outlineErrorCode: succeeded
              ? null
              : _safeOutlineFailureCode(failureCode, normalizedStatus),
          updatedAt: _now().toUtc(),
          clearOutlineError: succeeded,
        ),
      );
      return true;
    }
    return false;
  }

  Future<NativeFileResult<File>> resolveVerifiedFile(
    V3DocumentImportTask task,
  ) async {
    try {
      if (!_privateNamePattern.hasMatch(task.privateFileName) ||
          !_shaPattern.hasMatch(task.sha256) ||
          !task.privateFileName.startsWith(task.sha256) ||
          _formatForTask(task) == null) {
        return NativeFileResult<File>.failure(
          _failure('DOCUMENT_IMPORT_PRIVATE_REF_INVALID'),
        );
      }
      final directory = await _filesDirectory();
      final file = File('${directory.path}/${task.privateFileName}');
      if (!await file.exists()) {
        return NativeFileResult<File>.failure(
          _failure('DOCUMENT_IMPORT_PRIVATE_FILE_MISSING'),
        );
      }
      final canonicalDirectory = await directory.resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      if (!canonicalFile.startsWith(
        '$canonicalDirectory${Platform.pathSeparator}',
      )) {
        return NativeFileResult<File>.failure(
          _failure('DOCUMENT_IMPORT_PRIVATE_REF_INVALID'),
        );
      }
      if (await file.length() != task.sizeBytes) {
        return NativeFileResult<File>.failure(
          _failure('DOCUMENT_IMPORT_PRIVATE_SIZE_MISMATCH'),
        );
      }
      final actualHash = (await sha256.bind(file.openRead()).first).toString();
      if (actualHash != task.sha256) {
        return NativeFileResult<File>.failure(
          _failure('DOCUMENT_IMPORT_PRIVATE_HASH_MISMATCH'),
        );
      }
      return NativeFileResult<File>.success(file);
    } on Object {
      return NativeFileResult<File>.failure(
        _failure('DOCUMENT_IMPORT_PRIVATE_VERIFY_FAILED'),
      );
    }
  }

  Future<Directory> _filesDirectory() async {
    final root = await _rootDirectory();
    final directory = Directory(
      '${root.path}/HuahuoAI/DocumentImports/$_ownerScope/files',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }
}

V3DocumentImportTask? _taskFromRecord(LocalDatabaseRecord record) {
  final id = _text(record['draft_id']);
  final pickerRef = _text(record['picker_ref']);
  final displayName = _text(record['title']);
  final mimeType = _text(record['mime_type']);
  final hash = _text(record['content_hash']);
  final privateFileName = _text(record['private_file_name']);
  final sizeBytes = record['size_bytes'];
  final attemptCount = record['attempt_count'];
  final statusName = _text(record['status']);
  final outlineStatusName = _text(record['outline_status']);
  final createdAt = DateTime.tryParse('${record['created_at'] ?? ''}');
  final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
  V3DocumentImportTaskStatus? status;
  for (final candidate in V3DocumentImportTaskStatus.values) {
    if (candidate.name == statusName) status = candidate;
  }
  final outlineStatus = V3DocumentOutlineStatus.values.firstWhere(
    (candidate) => candidate.name == outlineStatusName,
    orElse: () => V3DocumentOutlineStatus.notStarted,
  );
  final falseWait =
      status == V3DocumentImportTaskStatus.waiting &&
      _text(record['ingestion_id']) == null;
  V3DocumentImportPhase? phase;
  for (final candidate in V3DocumentImportPhase.values) {
    if (candidate.name == _text(record['phase'])) phase = candidate;
  }
  if (falseWait && phase == null) {
    phase = _text(record['remote_note_id']) != null
        ? V3DocumentImportPhase.synchronizingNote
        : V3DocumentImportPhase.creatingIngestion;
  }
  if (id == null ||
      pickerRef == null ||
      displayName == null ||
      mimeType == null ||
      hash == null ||
      privateFileName == null ||
      sizeBytes is! int ||
      sizeBytes <= 0 ||
      attemptCount is! int ||
      attemptCount < 0 ||
      status == null ||
      createdAt == null ||
      updatedAt == null) {
    return null;
  }
  return V3DocumentImportTask(
    id: id,
    pickerRef: pickerRef,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sha256: hash,
    privateFileName: privateFileName,
    status: falseWait ? V3DocumentImportTaskStatus.failed : status,
    phase: phase,
    attemptCount: attemptCount,
    createdAt: createdAt,
    updatedAt: updatedAt,
    noteId: _text(record['note_id']),
    remoteNoteId: _text(record['remote_note_id']),
    uploadId: _text(record['upload_id']),
    uploadResourceId: _text(record['upload_resource_id']),
    ingestionId: _text(record['ingestion_id']),
    acceptedForImport: record.containsKey('accepted_for_import')
        ? record['accepted_for_import'] == true
        : status != V3DocumentImportTaskStatus.staged ||
              attemptCount > 0 ||
              _text(record['remote_note_id']) != null ||
              _text(record['note_id']) != null ||
              record['raw_asset_created'] == true ||
              _text(record['checkpoint']) == 'noteDeposited',
    distillToDigitalTwin: record['distill_to_digital_twin'] == true,
    deferDigitalTwinDistillation:
        record['defer_digital_twin_distillation'] == true,
    distillationTaskId: _text(record['distillation_task_id']),
    distillationResourceId: _text(record['distillation_resource_id']),
    digitalTwinConfirmationId: _text(record['digital_twin_confirmation_id']),
    rawAssetCreated:
        record['raw_asset_created'] == true ||
        _text(record['checkpoint']) == 'noteDeposited',
    outlineStatus: outlineStatus,
    outlineFileAgentRunId: _text(record['outline_file_agent_run_id']),
    outlineAgentRunId: _text(record['outline_agent_run_id']),
    outlineErrorCode: _text(record['outline_error_code']),
    lastErrorCode: _text(record['last_error_code']),
    failureRetryable: record['failure_retryable'] is bool
        ? record['failure_retryable'] as bool
        : null,
  );
}

String _opaqueScope(String value) {
  final normalized = value.trim().isEmpty ? 'local' : value.trim();
  if (normalized == 'local') return 'local';
  return 'user-${sha256.convert(utf8.encode(normalized)).toString().substring(0, 32)}';
}

String _safeDisplayName(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'[\u0000-\u001f]'), '');
  if (normalized.isEmpty) return '导入资料';
  return normalized.length <= 240 ? normalized : normalized.substring(0, 240);
}

String _safeOutlineFailureCode(String? value, String fallbackStatus) {
  final candidate = value?.trim();
  if (candidate != null && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(candidate)) {
    return candidate;
  }
  return 'DOCUMENT_OUTLINE_${fallbackStatus.toUpperCase()}';
}

DocumentImportFormat? _formatForTask(V3DocumentImportTask task) =>
    DocumentImportFormat.fromFileName(task.privateFileName);

String? _text(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

AppFailure _failure(String code) => AppFailure(
  code: code,
  category: AppFailureCategory.storage,
  message: 'Document import persistence failed',
  userMessageKey: 'document.import.$code',
  isRetryable: true,
  recoveryActions: const <String>['retry'],
);

final class _DocumentStoreException implements Exception {
  const _DocumentStoreException(this.code);

  final String code;
}
