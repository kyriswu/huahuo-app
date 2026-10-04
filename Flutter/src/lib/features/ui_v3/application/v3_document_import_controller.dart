import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/native/document_import_format.dart';
import '../../../core/native/native_file_port.dart';
import '../data/v3_document_import_store.dart';
import '../domain/document_import_progress.dart';
import '../domain/feed_item_models.dart';
import '../domain/profile_activity_models.dart';
import 'knowledge_library_controller.dart';
import 'profile_hub_controller.dart';

enum V3DocumentImportStatus {
  idle,
  preparing,
  ready,
  importing,
  completed,
  cancelled,
  failed,
}

enum V3DocumentRecoveryOutcome { restored, missing, superseded }

abstract interface class DocumentAnalysisPort {
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  });
}

@immutable
final class DocumentAnalysisResult {
  const DocumentAnalysisResult({
    required this.remoteNoteId,
    this.outlineMarkdown,
    this.distillation,
  });

  final String remoteNoteId;
  final String? outlineMarkdown;
  final UploadDigitalTwinDistillation? distillation;
}

final class UnavailableDocumentAnalysisPort implements DocumentAnalysisPort {
  const UnavailableDocumentAnalysisPort();

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async => NativeFileResult<DocumentAnalysisResult>.failure(
    const AppFailure(
      code: 'DOCUMENT_ANALYSIS_SERVICE_UNAVAILABLE',
      category: AppFailureCategory.api,
      message: 'Document analysis service is unavailable',
      userMessageKey: 'document.analysis.unavailable',
      isRetryable: true,
      recoveryActions: <String>['retry'],
    ),
  );
}

/// Runs the documented Resource -> Note ingestion -> HNote promotion flow.
///
/// The local file never becomes request JSON. Only verified bytes move through
/// the signed object upload and every later operation references its server
/// issued Resource or HNote identity.
final class RemoteDocumentAnalysisPort implements DocumentAnalysisPort {
  RemoteDocumentAnalysisPort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
    Future<void> Function(Duration)? delay,
    ObjectUploadTransport? objectUploadTransport,
    this.maxPollAttempts = 90,
    this.pollInterval = const Duration(seconds: 2),
  }) : _apiClient = apiClient,
       _workspaceId = workspaceId,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration)),
       _objectUploadTransport = objectUploadTransport;

  final ApiClient _apiClient;
  final String? Function() _workspaceId;
  final Future<void> Function(Duration) _delay;
  final ObjectUploadTransport? _objectUploadTransport;
  final int maxPollAttempts;
  final Duration pollInterval;

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async {
    try {
      return await _analyze(
        task: task,
        privateFile: privateFile,
        distillToDigitalTwin: distillToDigitalTwin,
        onCheckpoint: onCheckpoint,
      );
    } on _DocumentCheckpointFailure {
      return _remoteFailure('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
    } on Object {
      return _remoteFailure('DOCUMENT_IMPORT_FAILED');
    }
  }

  Future<NativeFileResult<DocumentAnalysisResult>> _analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async {
    final workspaceId = _documentOpaqueId(_workspaceId());
    if (workspaceId == null) {
      return _remoteFailure('WORKSPACE_CONTEXT_UNAVAILABLE');
    }
    if (!_isRemoteSupportedDocument(task)) {
      return _remoteFailure('DOCUMENT_IMPORT_TYPE_UNSUPPORTED');
    }
    if (task.sizeBytes <= 0 || task.sizeBytes > maxDocumentImportBytes) {
      return _remoteFailure(
        task.sizeBytes <= 0
            ? 'DOCUMENT_IMPORT_FILE_EMPTY'
            : 'DOCUMENT_IMPORT_FILE_TOO_LARGE',
      );
    }
    final existingNoteId = _documentOpaqueId(task.remoteNoteId);
    if (existingNoteId != null) {
      return NativeFileResult<DocumentAnalysisResult>.success(
        DocumentAnalysisResult(remoteNoteId: existingNoteId),
      );
    }
    var checkpoint = task;
    Future<bool> persist(V3DocumentImportTask next) async {
      checkpoint = next;
      return await onCheckpoint?.call(next) ?? true;
    }

    Future<void> enterPhase(V3DocumentImportPhase phase) async {
      if (checkpoint.phase == phase) return;
      if (!await persist(checkpoint.copyWith(phase: phase))) {
        throw const _DocumentCheckpointFailure();
      }
    }

    var ingestionId = task.ingestionId;
    UploadDigitalTwinDistillation? distillation =
        task.distillationTaskId != null && task.distillationResourceId != null
        ? UploadDigitalTwinDistillation(
            taskId: task.distillationTaskId!,
            resourceId: task.distillationResourceId!,
            ingestionId: ingestionId,
            state: 'queued',
          )
        : null;

    final metadata = UploadMetadata(
      sourceScene: 'note_import',
      fileName: task.displayName,
      mimeType: _documentMimeType(task),
      sizeBytes: task.sizeBytes,
      durationSeconds: 0,
      appPrivateUri: 'app-private://document-import/${task.privateFileName}',
      sha256: task.sha256,
      workspaceId: workspaceId,
      distillToDigitalTwin: distillToDigitalTwin,
    );
    final uploader = UploadClient(
      apiClient: _apiClient,
      objectTransport:
          _objectUploadTransport ??
          HttpObjectUploadTransport(
            requestTimeout: const Duration(minutes: 10),
            openRead: (uri) {
              if (uri != metadata.appPrivateUri) {
                return Stream<List<int>>.error(
                  StateError('DOCUMENT_UPLOAD_PRIVATE_REF_INVALID'),
                );
              }
              return privateFile!.openRead();
            },
          ),
    );
    if (ingestionId == null) {
      var uploadId = checkpoint.uploadId;
      var resourceId = checkpoint.uploadResourceId;
      if (uploadId != null && _documentOpaqueId(resourceId) == null) {
        return _remoteFailure('DOCUMENT_UPLOAD_TOKEN_INCOMPLETE');
      }
      if (uploadId == null) {
        if (privateFile == null) {
          return _remoteFailure('DOCUMENT_IMPORT_PRIVATE_FILE_MISSING');
        }
        await enterPhase(V3DocumentImportPhase.requestingUpload);
        final token = await uploader.requestUploadToken(
          metadata: metadata,
          idempotencyKey: _documentRequestKey('upload', [
            workspaceId,
            task.id,
            task.createdAt.toIso8601String(),
            '${task.attemptCount}',
            '$distillToDigitalTwin',
          ]),
        );
        final uploadToken = token.value;
        if (!token.ok || uploadToken == null) {
          return _uploadFailure(token.error, 'DOCUMENT_UPLOAD_TOKEN_FAILED');
        }
        resourceId = _documentOpaqueId(uploadToken.resourceId);
        if (resourceId == null) {
          return _remoteFailure('DOCUMENT_UPLOAD_TOKEN_INCOMPLETE');
        }
        await enterPhase(V3DocumentImportPhase.uploading);
        final uploaded = await uploader.uploadToObjectStore(
          token: uploadToken,
          metadata: metadata,
        );
        if (!uploaded.ok) {
          return _uploadFailure(uploaded.error, 'DOCUMENT_UPLOAD_FAILED');
        }
        uploadId = uploadToken.uploadId;
        if (!await persist(
          checkpoint.copyWith(uploadId: uploadId, uploadResourceId: resourceId),
        )) {
          return _remoteFailure('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
        }
      }
      await enterPhase(V3DocumentImportPhase.confirmingUpload);
      final completed = await uploader.completeUpload(
        uploadId: uploadId,
        metadata: metadata,
        idempotencyKey: 'document-upload-complete-${task.id}-$uploadId',
      );
      final resource = completed.value;
      if (!completed.ok || resource == null) {
        if (completed.error?.code == 'UPLOAD_TOKEN_EXPIRED') {
          if (!await persist(
            checkpoint.copyWith(clearUploadCheckpoint: true),
          )) {
            return _remoteFailure('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
          }
        }
        return _uploadFailure(
          completed.error,
          'DOCUMENT_UPLOAD_COMPLETE_FAILED',
        );
      }
      if (resource.uploadId != uploadId || resource.resourceId != resourceId) {
        return _remoteFailure('DOCUMENT_UPLOAD_RESOURCE_MISMATCH');
      }
      distillation = resource.digitalTwinDistillation;
      if (distillToDigitalTwin && distillation?.ingestionId == null) {
        return _remoteFailure('DIGITAL_TWIN_DISTILLATION_RECEIPT_MISSING');
      }
      ingestionId = distillation?.ingestionId;
      if (!await persist(
        checkpoint.copyWith(
          ingestionId: ingestionId,
          distillationTaskId: distillation?.taskId,
          distillationResourceId: distillation?.resourceId,
        ),
      )) {
        return _remoteFailure('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
      }
    }
    await enterPhase(
      ingestionId != null
          ? V3DocumentImportPhase.checkingIngestion
          : V3DocumentImportPhase.creatingIngestion,
    );
    final created = ingestionId != null
        ? await _getIngestion(
            workspaceId: workspaceId,
            ingestionId: ingestionId,
          )
        : await _createIngestion(
            workspaceId: workspaceId,
            resourceId: checkpoint.uploadResourceId!,
            idempotencyKey: _documentRequestKey('ingestion', [
              workspaceId,
              checkpoint.uploadResourceId!,
            ]),
          );
    final ingestion = created.data;
    if (!created.ok || ingestion == null) {
      return _apiFailure(
        created.error,
        ingestionId == null
            ? 'DOCUMENT_INGESTION_CREATE_FAILED'
            : 'DOCUMENT_INGESTION_POLL_FAILED',
      );
    }
    if (ingestionId != null && ingestion.ingestionId != ingestionId) {
      return _remoteFailure('DOCUMENT_INGESTION_ID_MISMATCH');
    }
    if (checkpoint.ingestionId != ingestion.ingestionId &&
        !await persist(
          checkpoint.copyWith(ingestionId: ingestion.ingestionId),
        )) {
      return _remoteFailure('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
    }
    final promoted = await _waitForPromotion(
      workspaceId: workspaceId,
      initial: ingestion,
      title: task.displayName,
      task: task,
      enterPhase: enterPhase,
      serverPromotes: distillToDigitalTwin,
    );
    if (!promoted.ok || promoted.value == null) return promoted;
    return NativeFileResult<DocumentAnalysisResult>.success(
      DocumentAnalysisResult(
        remoteNoteId: promoted.value!.remoteNoteId,
        distillation: distillation,
      ),
    );
  }

  Future<NativeFileResult<DocumentAnalysisResult>> _waitForPromotion({
    required String workspaceId,
    required _DocumentIngestionSnapshot initial,
    required String title,
    required V3DocumentImportTask task,
    required Future<void> Function(V3DocumentImportPhase) enterPhase,
    bool serverPromotes = false,
  }) async {
    var current = initial;
    var consecutiveReadFailures = 0;
    final pollAttempts = maxPollAttempts < 1 ? 1 : maxPollAttempts;
    for (var attempt = 0; attempt < pollAttempts; attempt++) {
      final promoted = current.promotedNoteId;
      if (current.status == 'promoted') {
        if (promoted == null) {
          return _remoteFailure('DOCUMENT_INGESTION_RESPONSE_INVALID');
        }
        return NativeFileResult<DocumentAnalysisResult>.success(
          DocumentAnalysisResult(remoteNoteId: promoted),
        );
      }
      if (_documentIngestionFailed(current.status)) {
        return _remoteFailure(switch (current.status) {
          'expired' => 'DOCUMENT_INGESTION_EXPIRED',
          'cancelled' => 'DOCUMENT_INGESTION_CANCELLED',
          'quarantined' => current.failureCode ?? 'NOTE_INGESTION_QUARANTINED',
          _ => current.failureCode ?? 'DOCUMENT_INGESTION_REMOTE_FAILED',
        }, retryable: false);
      }
      if (!_documentIngestionReady(current.status) &&
          !const {'created', 'queued', 'validating'}.contains(current.status)) {
        return _remoteFailure('DOCUMENT_INGESTION_STATUS_INVALID');
      }
      await enterPhase(
        _documentIngestionReady(current.status)
            ? V3DocumentImportPhase.creatingNote
            : V3DocumentImportPhase.parsing,
      );
      if (_documentIngestionReady(current.status) && !serverPromotes) {
        final promotedResult = await _promoteIngestion(
          workspaceId: workspaceId,
          ingestionId: current.ingestionId,
          title: title,
          idempotencyKey: _documentRequestKey('promote', [
            workspaceId,
            current.ingestionId,
            title,
          ]),
        );
        final noteId = promotedResult.data;
        if (!promotedResult.ok || noteId == null) {
          return _apiFailure(
            promotedResult.error,
            'DOCUMENT_INGESTION_PROMOTE_FAILED',
          );
        }
        return NativeFileResult<DocumentAnalysisResult>.success(
          DocumentAnalysisResult(remoteNoteId: noteId),
        );
      }
      if (attempt + 1 >= pollAttempts) break;
      await _delay(pollInterval);
      final polled = await _getIngestion(
        workspaceId: workspaceId,
        ingestionId: current.ingestionId,
      );
      if (!polled.ok || polled.data == null) {
        consecutiveReadFailures += 1;
        if (polled.error?.isRetryable == true &&
            consecutiveReadFailures < 3 &&
            attempt + 2 < pollAttempts) {
          continue;
        }
        return _apiFailure(polled.error, 'DOCUMENT_INGESTION_POLL_FAILED');
      }
      consecutiveReadFailures = 0;
      if (polled.data!.ingestionId != initial.ingestionId) {
        return _remoteFailure('DOCUMENT_INGESTION_ID_MISMATCH');
      }
      if (_documentIngestionReady(current.status) &&
          const {
            'created',
            'queued',
            'validating',
          }.contains(polled.data!.status)) {
        return _remoteFailure('DOCUMENT_INGESTION_STATUS_INVALID');
      }
      current = polled.data!;
    }
    return _remoteFailure('DOCUMENT_INGESTION_TIMEOUT');
  }

  Future<ApiResult<_DocumentIngestionSnapshot>> _createIngestion({
    required String workspaceId,
    required String resourceId,
    required String idempotencyKey,
  }) => _apiClient.request<_DocumentIngestionSnapshot>(
    ApiRequestOptions<_DocumentIngestionSnapshot>(
      endpointId: 'createWorkspaceNoteIngestion',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: <String, Object?>{'resourceId': resourceId},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseDocumentIngestion,
    ),
  );

  Future<ApiResult<_DocumentIngestionSnapshot>> _getIngestion({
    required String workspaceId,
    required String ingestionId,
  }) => _apiClient.request<_DocumentIngestionSnapshot>(
    ApiRequestOptions<_DocumentIngestionSnapshot>(
      endpointId: 'workspaceNoteIngestion',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'ingestionId': ingestionId,
      },
      parseData: _parseDocumentIngestion,
    ),
  );

  Future<ApiResult<String>> _promoteIngestion({
    required String workspaceId,
    required String ingestionId,
    required String title,
    required String idempotencyKey,
  }) => _apiClient.request<String>(
    ApiRequestOptions<String>(
      endpointId: 'promoteWorkspaceNoteIngestion',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'ingestionId': ingestionId,
      },
      body: <String, Object?>{'title': title},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parsePromotedDocumentNoteId,
    ),
  );
}

final class _DocumentIngestionSnapshot {
  const _DocumentIngestionSnapshot({
    required this.ingestionId,
    required this.status,
    this.promotedNoteId,
    this.failureCode,
  });

  final String ingestionId;
  final String status;
  final String? promotedNoteId;
  final String? failureCode;
}

_DocumentIngestionSnapshot? _parseDocumentIngestion(Object? value) {
  final data = asObjectMap(value);
  final raw = data == null ? null : asObjectMap(data['ingestion']) ?? data;
  if (raw == null) return null;
  final ingestionId = _documentOpaqueId(raw['ingestionId']);
  final status = _documentStatus(raw['status']);
  if (ingestionId == null || status == null) return null;
  final safeError = asObjectMap(raw['safeError']);
  return _DocumentIngestionSnapshot(
    ingestionId: ingestionId,
    status: status,
    promotedNoteId: _documentOpaqueId(raw['promotedNoteId']),
    failureCode:
        _documentErrorCode(raw['failureCode']) ??
        _documentErrorCode(safeError?['code']),
  );
}

String? _parsePromotedDocumentNoteId(Object? value) {
  final data = asObjectMap(value);
  if (data == null) return null;
  final note = asObjectMap(data['note']);
  return _documentOpaqueId(note?['noteId'] ?? data['noteId']);
}

bool _isRemoteSupportedDocument(V3DocumentImportTask task) =>
    _documentFormatForTask(task) != null;

String _documentMimeType(V3DocumentImportTask task) =>
    _documentFormatForTask(task)?.mimeType ?? 'application/octet-stream';

DocumentImportFormat? _documentFormatForTask(V3DocumentImportTask task) =>
    DocumentImportFormat.fromFileName(task.privateFileName);

bool _documentIngestionReady(String status) =>
    status == 'ready' || status == 'ready_to_promote';

bool _documentIngestionFailed(String status) => const <String>{
  'failed',
  'quarantined',
  'expired',
  'cancelled',
}.contains(status);

String? _documentOpaqueId(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^[A-Za-z0-9._:-]{1,160}$').hasMatch(text) ? text : null;
}

String? _documentStatus(Object? value) {
  if (value is! String) return null;
  final text = value.trim().toLowerCase();
  return RegExp(r'^[a-z_]{1,64}$').hasMatch(text) ? text : null;
}

String? _documentErrorCode(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(text) ? text : null;
}

NativeFileResult<DocumentAnalysisResult> _uploadFailure(
  AppFailure? error,
  String fallback,
) => _remoteFailure(error?.code ?? fallback, retryable: error?.isRetryable);

NativeFileResult<DocumentAnalysisResult> _apiFailure(
  AppFailure? error,
  String fallback,
) => _remoteFailure(error?.code ?? fallback, retryable: error?.isRetryable);

NativeFileResult<DocumentAnalysisResult> _remoteFailure(
  String code, {
  bool? retryable,
  String? remoteNoteId,
}) {
  final terminalIngestionFailure =
      documentImportRequiresReselection(code) ||
      code == 'IDEMPOTENCY_KEY_CONFLICT';
  return NativeFileResult<DocumentAnalysisResult>.failure(
    AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: code == 'NOTE_INGESTION_UNSUPPORTED'
          ? 'The current service has not enabled this document format'
          : code == 'NOTE_INGESTION_QUARANTINED'
          ? 'The server rejected this document during validation or extraction'
          : 'Remote document ingestion failed',
      userMessageKey: 'document.import.$code',
      isRetryable: !terminalIngestionFailure && (retryable ?? true),
      recoveryActions: terminalIngestionFailure
          ? const <String>['none']
          : const <String>['retry'],
      metadata: <String, Object?>{
        if (_documentOpaqueId(remoteNoteId) != null)
          'remoteNoteId': remoteNoteId,
      },
    ),
  );
}

final class V3DocumentImportState {
  const V3DocumentImportState({
    required this.status,
    this.selectedDocuments = const <PickedDocumentFile>[],
    this.durableTasks = const <V3DocumentImportTask>[],
    this.importedNotes = const <V3FeedItem>[],
    this.lastErrorCode,
  });

  const V3DocumentImportState.initial()
    : status = V3DocumentImportStatus.idle,
      selectedDocuments = const <PickedDocumentFile>[],
      durableTasks = const <V3DocumentImportTask>[],
      importedNotes = const <V3FeedItem>[],
      lastErrorCode = null;

  final V3DocumentImportStatus status;
  final List<PickedDocumentFile> selectedDocuments;
  final List<V3DocumentImportTask> durableTasks;
  final List<V3FeedItem> importedNotes;
  final String? lastErrorCode;

  int get importedCount => importedNotes.length;
  bool get hasWaitingTasks => durableTasks.any(
    (task) =>
        task.status == V3DocumentImportTaskStatus.waiting &&
        task.hasAcceptedIngestion,
  );
  bool get hasRetryableTasks => durableTasks.any((task) => task.isRetryable);
  bool get hasUnacceptedTasks =>
      durableTasks.any((task) => !task.acceptedForImport);
  bool get canRetryFailure =>
      status == V3DocumentImportStatus.failed &&
      (hasUnacceptedTasks || hasRetryableTasks);
  bool get isTerminalFailure =>
      status == V3DocumentImportStatus.failed && !canRetryFailure;
  Set<String> get durablyAcceptedPickerRefs => durableTasks
      .where((task) => task.acceptedForImport)
      .map((task) => task.pickerRef)
      .toSet();

  V3DocumentImportState copyWith({
    V3DocumentImportStatus? status,
    List<PickedDocumentFile>? selectedDocuments,
    List<V3DocumentImportTask>? durableTasks,
    List<V3FeedItem>? importedNotes,
    String? lastErrorCode,
    bool clearSelectedDocuments = false,
    bool clearDurableTasks = false,
    bool clearImportedNotes = false,
    bool clearError = false,
  }) => V3DocumentImportState(
    status: status ?? this.status,
    selectedDocuments: clearSelectedDocuments
        ? const <PickedDocumentFile>[]
        : selectedDocuments ?? this.selectedDocuments,
    durableTasks: clearDurableTasks
        ? const <V3DocumentImportTask>[]
        : durableTasks ?? this.durableTasks,
    importedNotes: clearImportedNotes
        ? const <V3FeedItem>[]
        : importedNotes ?? this.importedNotes,
    lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
  );
}

final class V3DocumentImportController extends ChangeNotifier {
  V3DocumentImportController({
    required NativeFilePort nativeFilePort,
    required KnowledgeLibraryController knowledgeLibrary,
    required ProfileHubController profileHub,
    required V3DocumentImportStore store,
    DocumentAnalysisPort analysisPort = const UnavailableDocumentAnalysisPort(),
    Future<void> Function(Duration)? projectionDelay,
    this.projectionMaxAttempts = 30,
    this.projectionPollInterval = const Duration(seconds: 2),
    this.onDistillationNoteReady,
  }) : _nativeFilePort = nativeFilePort,
       _knowledgeLibrary = knowledgeLibrary,
       _profileHub = profileHub,
       _store = store,
       _analysisPort = analysisPort,
       _projectionDelay =
           projectionDelay ?? ((duration) => Future<void>.delayed(duration));

  final NativeFilePort _nativeFilePort;
  final KnowledgeLibraryController _knowledgeLibrary;
  final ProfileHubController _profileHub;
  final V3DocumentImportStore _store;
  final DocumentAnalysisPort _analysisPort;
  final Future<void> Function(Duration) _projectionDelay;
  final int projectionMaxAttempts;
  final Duration projectionPollInterval;
  final Future<bool> Function(V3FeedItem)? onDistillationNoteReady;

  V3DocumentImportState _state = const V3DocumentImportState.initial();
  bool _pickerInFlight = false;
  bool _operationInFlight = false;
  Completer<void>? _operationCompletion;
  final Set<int> _recoveryRevisionsInFlight = <int>{};
  bool _freshSessionActive = false;
  int _sessionRevision = 0;
  final Map<String, String> _taskIdByPickerRef = <String, String>{};

  V3DocumentImportState get state => _state;

  Future<bool> beginFreshSession() async {
    _freshSessionActive = true;
    final revision = ++_sessionRevision;
    final activeOperation = _operationCompletion?.future;
    if (activeOperation != null) await activeOperation;
    if (!_ownsSession(revision)) return false;
    _taskIdByPickerRef.clear();
    _state = const V3DocumentImportState.initial();
    notifyListeners();
    return true;
  }

  /// Called by the global derived-task tracker after it has durably resolved a
  /// document outline. It never starts network work or recreates raw assets.
  void refreshTrackedOutline(String fileAgentRunId) {
    final taskIds = _state.durableTasks.map((task) => task.id).toSet();
    if (taskIds.isEmpty || fileAgentRunId.trim().isEmpty) return;
    final refreshed = _store
        .listTasks()
        .where((task) => taskIds.contains(task.id))
        .toList(growable: false);
    final hadTrackedRun = _state.durableTasks.any(
      (task) => task.outlineFileAgentRunId == fileAgentRunId,
    );
    if (!hadTrackedRun || refreshed.isEmpty) return;
    _state = _state.copyWith(
      durableTasks: List<V3DocumentImportTask>.unmodifiable(refreshed),
    );
    notifyListeners();
  }

  Future<V3DocumentRecoveryOutcome> recoverPending({
    bool force = false,
    String? taskId,
  }) async {
    if (_freshSessionActive && !force) {
      return V3DocumentRecoveryOutcome.superseded;
    }
    if (force) {
      _freshSessionActive = false;
      _sessionRevision += 1;
    }
    final recoveryRevision = _sessionRevision;
    final activeOperation = _operationCompletion?.future;
    if (activeOperation != null) {
      await activeOperation;
      if (recoveryRevision != _sessionRevision) {
        return V3DocumentRecoveryOutcome.superseded;
      }
    }
    _recoveryRevisionsInFlight.add(recoveryRevision);
    try {
      final tasks = _store
          .listTasks()
          .where(
            (task) =>
                task.needsRawImport && (taskId == null || task.id == taskId),
          )
          .map(
            (task) => task.status == V3DocumentImportTaskStatus.processing
                ? task.copyWith(
                    status: V3DocumentImportTaskStatus.failed,
                    lastErrorCode: 'DOCUMENT_IMPORT_INTERRUPTED',
                    failureRetryable: true,
                  )
                : task,
          )
          .toList(growable: false);
      if (tasks.isEmpty) {
        _taskIdByPickerRef.clear();
        _state = const V3DocumentImportState.initial();
        notifyListeners();
        return V3DocumentRecoveryOutcome.missing;
      }
      final documents = await _documentsFor(tasks);
      if (recoveryRevision != _sessionRevision) {
        return V3DocumentRecoveryOutcome.superseded;
      }
      final persisted = await _store.saveAllDurably(tasks);
      if (recoveryRevision != _sessionRevision) {
        return V3DocumentRecoveryOutcome.superseded;
      }
      if (!persisted) {
        _state = _state.copyWith(
          durableTasks: tasks,
          selectedDocuments: documents,
        );
        _fail('DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
        return V3DocumentRecoveryOutcome.restored;
      }
      _taskIdByPickerRef
        ..clear()
        ..addEntries(
          tasks.map(
            (task) => MapEntry<String, String>(task.pickerRef, task.id),
          ),
        );
      final hasRecoverableWork = tasks.any((task) => task.isRetryable);
      final hasUnfinishedRawImport = tasks.any((task) => task.needsRawImport);
      String? recoveredError;
      for (final task in tasks) {
        recoveredError ??= task.lastErrorCode;
      }
      _state = _state.copyWith(
        status: hasRecoverableWork
            ? V3DocumentImportStatus.ready
            : hasUnfinishedRawImport
            ? V3DocumentImportStatus.failed
            : V3DocumentImportStatus.completed,
        selectedDocuments: documents,
        durableTasks: tasks,
        clearImportedNotes: true,
        lastErrorCode: hasUnfinishedRawImport ? recoveredError : null,
        clearError: hasRecoverableWork || !hasUnfinishedRawImport,
      );
      notifyListeners();
      return V3DocumentRecoveryOutcome.restored;
    } finally {
      _recoveryRevisionsInFlight.remove(recoveryRevision);
    }
  }

  Set<String> completedPickerRefs(Iterable<String> pickerRefs) {
    final completedTaskIds = _state.durableTasks
        .where((task) => task.rawAssetCreated)
        .map((task) => task.id)
        .toSet();
    return pickerRefs
        .where(
          (pickerRef) =>
              completedTaskIds.contains(_taskIdByPickerRef[pickerRef]),
        )
        .toSet();
  }

  Future<bool> prepareDocuments(List<PickedDocumentFile> documents) async {
    final revision = _sessionRevision;
    if (documents.any((document) => !_isSupportedDocument(document))) {
      if (_ownsSession(revision)) {
        _fail('DOCUMENT_IMPORT_TYPE_UNSUPPORTED');
      }
      return false;
    }
    return _stageDocuments(documents, revision: revision);
  }

  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocuments() async {
    if (_pickerInFlight || _operationInFlight) {
      return NativeFileResult<List<PickedDocumentFile>>.cancelled();
    }
    final revision = _sessionRevision;
    _pickerInFlight = true;
    try {
      final result = await _nativeFilePort.pickDocumentFiles();
      if (!_ownsSession(revision)) {
        return NativeFileResult<List<PickedDocumentFile>>.cancelled();
      }
      final documents = result.value;
      if (!result.ok || documents == null || documents.isEmpty) {
        final error = result.error;
        if (result.cancelled ||
            result.ok ||
            error?.code == 'DOCUMENT_PICKER_CANCELLED' ||
            error?.code == 'DOCUMENT_PICKER_EMPTY') {
        } else {
          _fail(error?.code ?? 'DOCUMENT_PICKER_EMPTY');
        }
        return result;
      }
      _state = _state.copyWith(
        status: V3DocumentImportStatus.idle,
        clearSelectedDocuments: true,
        clearDurableTasks: true,
        clearImportedNotes: true,
        clearError: true,
      );
      if (documents.any((document) => !_isSupportedDocument(document))) {
        _fail('DOCUMENT_IMPORT_TYPE_UNSUPPORTED');
        return NativeFileResult<List<PickedDocumentFile>>.failure(
          _documentFailure(
            'DOCUMENT_IMPORT_TYPE_UNSUPPORTED',
            'Only supported Note document formats may be imported',
          ),
        );
      }
      final staged = await _stageDocuments(documents, revision: revision);
      if (!staged) {
        return NativeFileResult<List<PickedDocumentFile>>.failure(
          _documentFailure(
            _state.lastErrorCode ?? 'DOCUMENT_IMPORT_STAGE_FAILED',
            'Selected documents could not be persisted',
          ),
        );
      }
      return result;
    } on Object {
      const code = 'NATIVE_DOCUMENT_PICKER_FAILED';
      if (_ownsSession(revision)) _fail(code);
      return NativeFileResult<List<PickedDocumentFile>>.failure(
        _documentFailure(code, 'Native document picker failed'),
      );
    } finally {
      _pickerInFlight = false;
    }
  }

  Future<List<V3FeedItem>> retryFailed() => importSelected();

  Future<List<V3FeedItem>> importSelected({
    bool distillToDigitalTwin = false,
    bool deferDigitalTwinDistillation = false,
  }) async {
    if (_operationInFlight ||
        _recoveryRevisionsInFlight.contains(_sessionRevision)) {
      return const <V3FeedItem>[];
    }
    final operationRevision = _sessionRevision;
    final operationTaskIds = _state.durableTasks.map((task) => task.id).toSet();
    _operationInFlight = true;
    final operationCompletion = Completer<void>();
    _operationCompletion = operationCompletion;
    _set(V3DocumentImportStatus.importing, clearError: true);
    final imported = <V3FeedItem>[..._state.importedNotes];
    void publishProgress() {
      if (!_ownsSession(operationRevision)) return;
      _state = _state.copyWith(
        durableTasks: _store
            .listTasks()
            .where((task) => operationTaskIds.contains(task.id))
            .toList(growable: false),
        importedNotes: List<V3FeedItem>.unmodifiable(imported),
      );
      notifyListeners();
    }

    String? firstError;
    try {
      final originalTasks = _state.durableTasks;
      final acceptedTasks = originalTasks
          .map(
            (task) => task.acceptedForImport
                ? task
                : task.copyWith(
                    acceptedForImport: true,
                    distillToDigitalTwin: distillToDigitalTwin,
                    deferDigitalTwinDistillation: deferDigitalTwinDistillation,
                    updatedAt: DateTime.now().toUtc(),
                  ),
          )
          .toList(growable: false);
      if (!listEquals(acceptedTasks, originalTasks)) {
        final persisted = await _store.saveAllDurably(acceptedTasks);
        if (!persisted) {
          await _store.saveAllDurably(originalTasks);
          if (_ownsSession(operationRevision)) {
            _state = _state.copyWith(
              status: V3DocumentImportStatus.failed,
              durableTasks: originalTasks,
              lastErrorCode: 'DOCUMENT_IMPORT_ACCEPT_PERSIST_FAILED',
              clearImportedNotes: true,
            );
            notifyListeners();
          }
          return const <V3FeedItem>[];
        }
        if (_ownsSession(operationRevision)) {
          _state = _state.copyWith(durableTasks: acceptedTasks);
        }
      }
      final unfinished = acceptedTasks
          .where((task) => task.needsRawImport)
          .toList();
      final tasks = acceptedTasks
          .where((task) => task.isCompleted || task.isRetryable)
          .toList();
      if (tasks.isEmpty) {
        if (_ownsSession(operationRevision)) {
          _state = _state.copyWith(
            status: unfinished.isEmpty
                ? V3DocumentImportStatus.completed
                : V3DocumentImportStatus.failed,
            lastErrorCode: unfinished.isEmpty
                ? null
                : unfinished.first.lastErrorCode,
            clearError: unfinished.isEmpty,
          );
          notifyListeners();
        }
        return _state.importedNotes;
      }

      for (final initialTask in tasks) {
        var task = initialTask;
        try {
          V3FeedItem? note;
          if (task.needsRawImport) {
            task = task.copyWith(
              status: V3DocumentImportTaskStatus.processing,
              phase: !task.hasRemoteCheckpoint && task.remoteNoteId == null
                  ? V3DocumentImportPhase.preparingFile
                  : task.phase,
              attemptCount: task.attemptCount + 1,
              updatedAt: DateTime.now().toUtc(),
              clearError: true,
            );
            if (!await _store.saveAllDurably([task])) {
              const code = 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED';
              firstError ??= code;
              await _markFailed(task, code);
              continue;
            }
            publishProgress();
            var remoteNoteId = _documentOpaqueId(task.remoteNoteId);
            if (remoteNoteId == null) {
              final verified = task.hasRemoteCheckpoint
                  ? null
                  : await _store.resolveVerifiedFile(task);
              final privateFile = verified?.value;
              if (!task.hasRemoteCheckpoint &&
                  (verified?.ok != true || privateFile == null)) {
                final code =
                    verified?.error?.code ??
                    'DOCUMENT_IMPORT_PRIVATE_VERIFY_FAILED';
                firstError ??= code;
                await _markFailed(task, code);
                continue;
              }
              final analysis = await _analysisPort.analyze(
                task: task,
                privateFile: privateFile,
                distillToDigitalTwin:
                    task.distillToDigitalTwin &&
                    !task.deferDigitalTwinDistillation,
                onCheckpoint: (checkpoint) async {
                  task = checkpoint.copyWith(updatedAt: DateTime.now().toUtc());
                  final persisted = await _store.saveAllDurably([task]);
                  publishProgress();
                  return persisted;
                },
              );
              remoteNoteId = analysis.value?.remoteNoteId;
              if (!analysis.ok || remoteNoteId == null) {
                final code =
                    analysis.error?.code ?? 'DOCUMENT_ANALYSIS_RESULT_INVALID';
                firstError ??= code;
                await _markFailed(
                  task,
                  code,
                  remoteNoteId:
                      _documentOpaqueId(
                        analysis.error?.metadata['remoteNoteId'],
                      ) ??
                      task.remoteNoteId,
                  waiting:
                      task.hasAcceptedIngestion &&
                      code == 'DOCUMENT_INGESTION_TIMEOUT',
                  retryable: analysis.error?.isRetryable,
                );
                continue;
              }
              task = task.copyWith(
                remoteNoteId: remoteNoteId,
                phase: V3DocumentImportPhase.synchronizingNote,
                distillationTaskId: analysis.value?.distillation?.taskId,
                distillationResourceId:
                    analysis.value?.distillation?.resourceId,
                updatedAt: DateTime.now().toUtc(),
              );
              if (!await _store.saveAllDurably([task])) {
                const code = 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED';
                firstError ??= code;
                await _markFailed(task, code);
                continue;
              }
            }
            task = task.copyWith(
              phase: V3DocumentImportPhase.synchronizingNote,
            );
            if (!await _store.saveAllDurably([task])) {
              const code = 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED';
              firstError ??= code;
              await _markFailed(task, code);
              continue;
            }
            publishProgress();
            final noteResult = await _canonicalImportedNote(
              remoteNoteId: remoteNoteId,
              task: task,
            );
            note = noteResult.value;
            final persisted = await _knowledgeLibrary.flushPersistenceResult();
            if (!noteResult.ok || note == null || !persisted) {
              const fallback = 'DOCUMENT_REMOTE_NOTE_UNAVAILABLE';
              final code = !persisted
                  ? 'DOCUMENT_IMPORT_NOTE_PERSIST_FAILED'
                  : noteResult.error?.code ?? fallback;
              firstError ??= code;
              await _markFailed(task, code, remoteNoteId: task.remoteNoteId);
              continue;
            }
            final importedNote = note;
            if (task.distillToDigitalTwin &&
                task.deferDigitalTwinDistillation) {
              task = task.copyWith(
                phase: V3DocumentImportPhase.queuingDistillation,
              );
              if (!await _store.saveAllDurably([task])) {
                const code = 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED';
                firstError ??= code;
                await _markFailed(task, code);
                continue;
              }
              publishProgress();
            }
            if (task.distillToDigitalTwin &&
                task.deferDigitalTwinDistillation &&
                !await (onDistillationNoteReady?.call(importedNote) ??
                    Future.value(false))) {
              const code = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
              firstError ??= code;
              await _markFailed(
                task,
                code,
                remoteNoteId: task.remoteNoteId,
                retryable: true,
              );
              continue;
            }
            final completedTask = task.copyWith(
              status: V3DocumentImportTaskStatus.completed,
              noteId: importedNote.id,
              rawAssetCreated: true,
              updatedAt: DateTime.now().toUtc(),
              clearError: true,
            );
            if (!await _store.saveAllDurably([completedTask])) {
              const code = 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED';
              firstError ??= code;
              await _markFailed(task, code);
              continue;
            }
            task = completedTask;
            if (!imported.any((item) => item.id == importedNote.id)) {
              imported.add(importedNote);
            }
            _profileHub.recordActivity(
              V3ProfileActivity(
                id: 'document-import-${importedNote.id}',
                occurredAt: DateTime.now(),
                type: V3ProfileActivityType.upload,
                title: importedNote.title,
                feedItemId: importedNote.id,
                route: '/v3/feed/items/${Uri.encodeComponent(importedNote.id)}',
              ),
            );
          } else {
            final remoteNoteId = _documentOpaqueId(task.remoteNoteId);
            if (remoteNoteId == null) continue;
            final noteResult = await _canonicalImportedNote(
              remoteNoteId: remoteNoteId,
              task: task,
            );
            note = noteResult.value;
            if (note == null) continue;
            final importedNote = note;
            if (!imported.any((item) => item.id == importedNote.id)) {
              imported.add(importedNote);
            }
          }

          // Document import stops after the original HNote is created. Outline
          // and point-of-fire generation are explicit asset-detail actions.
        } on Object {
          const code = 'DOCUMENT_IMPORT_FAILED';
          firstError ??= code;
          await _markFailed(task, code);
        } finally {
          publishProgress();
        }
      }

      final currentTasks = _store
          .listTasks()
          .where((task) => operationTaskIds.contains(task.id))
          .toList(growable: false);
      final documents = await _documentsFor(currentTasks);
      final terminalError =
          firstError ??
          currentTasks
              .where((task) => task.needsRawImport && !task.isRetryable)
              .map((task) => task.lastErrorCode)
              .firstWhere(
                (code) => code != null && code.isNotEmpty,
                orElse: () => null,
              );
      if (_ownsSession(operationRevision)) {
        _state = _state.copyWith(
          status: terminalError == null
              ? V3DocumentImportStatus.completed
              : V3DocumentImportStatus.failed,
          selectedDocuments: documents,
          durableTasks: currentTasks,
          importedNotes: List<V3FeedItem>.unmodifiable(imported),
          lastErrorCode: terminalError,
          clearError: terminalError == null,
        );
        notifyListeners();
      }
      return List<V3FeedItem>.unmodifiable(imported);
    } on Object {
      if (_ownsSession(operationRevision)) {
        _fail('DOCUMENT_IMPORT_FAILED', keepImported: true);
      }
      return List<V3FeedItem>.unmodifiable(imported);
    } finally {
      _operationInFlight = false;
      if (!operationCompletion.isCompleted) operationCompletion.complete();
      if (identical(_operationCompletion, operationCompletion)) {
        _operationCompletion = null;
      }
    }
  }

  Future<bool> _stageDocuments(
    List<PickedDocumentFile> documents, {
    required int revision,
  }) async {
    if (!_ownsSession(revision)) return false;
    _set(V3DocumentImportStatus.preparing, clearError: true);
    if (documents.isEmpty) {
      _state = _state.copyWith(
        status: V3DocumentImportStatus.ready,
        clearSelectedDocuments: true,
        clearDurableTasks: true,
        clearImportedNotes: true,
        clearError: true,
      );
      notifyListeners();
      return true;
    }
    final tasksById = <String, V3DocumentImportTask>{};
    final taskIdByPickerRef = <String, String>{};
    for (final document in documents) {
      final result = await _store.stage(document);
      if (!_ownsSession(revision)) return false;
      final task = result.value;
      if (!result.ok || task == null) {
        _fail(result.error?.code ?? 'DOCUMENT_IMPORT_STAGE_FAILED');
        return false;
      }
      tasksById[task.id] = task;
      taskIdByPickerRef[document.pickerRef] = task.id;
    }
    final tasks = tasksById.values.toList(growable: false);
    final stagedDocuments = await _documentsFor(tasks);
    if (!_ownsSession(revision)) return false;
    _taskIdByPickerRef
      ..clear()
      ..addAll(taskIdByPickerRef);
    _state = _state.copyWith(
      status: V3DocumentImportStatus.ready,
      selectedDocuments: stagedDocuments,
      durableTasks: List<V3DocumentImportTask>.unmodifiable(tasks),
      clearImportedNotes: true,
      clearError: true,
    );
    notifyListeners();
    return true;
  }

  bool _ownsSession(int revision) => revision == _sessionRevision;

  Future<List<PickedDocumentFile>> _documentsFor(
    List<V3DocumentImportTask> tasks,
  ) async {
    final documents = <PickedDocumentFile>[];
    for (final task in tasks) {
      final fileResult = await _store.resolveVerifiedFile(task);
      documents.add(
        PickedDocumentFile(
          pickerRef: task.pickerRef,
          displayName: task.displayName,
          mimeType: task.mimeType,
          sizeBytes: task.sizeBytes,
          sourcePath: fileResult.value?.path,
          contentHash: task.sha256,
        ),
      );
    }
    return List<PickedDocumentFile>.unmodifiable(documents);
  }

  Future<NativeFileResult<V3FeedItem>> _canonicalImportedNote({
    required String remoteNoteId,
    required V3DocumentImportTask task,
    String? outlineMarkdown,
  }) async {
    final attempts = projectionMaxAttempts < 1 ? 1 : projectionMaxAttempts;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      final reconciled = await _knowledgeLibrary.synchronizeWorkspaceContent();
      final remoteNote = _knowledgeLibrary.noteForId(remoteNoteId);
      if (reconciled && remoteNote != null) {
        final imported = remoteNote.copyWith(
          source: V3MaterialSource.documentImport,
          summaryBody: _firstNonEmptyMarkdown(
            outlineMarkdown,
            remoteNote.summaryBody,
          ),
        );
        _knowledgeLibrary.updateNote(imported);
        return NativeFileResult<V3FeedItem>.success(imported);
      }
      if (attempt + 1 < attempts) {
        await _projectionDelay(projectionPollInterval);
      }
    }
    return NativeFileResult<V3FeedItem>.failure(
      _documentFailure(
        'DOCUMENT_REMOTE_NOTE_UNAVAILABLE',
        'Promoted document note could not be loaded',
      ),
    );
  }

  Future<V3DocumentImportTask> _markFailed(
    V3DocumentImportTask task,
    String code, {
    String? remoteNoteId,
    bool waiting = false,
    bool? retryable,
  }) async {
    final failed = task.copyWith(
      status: waiting && task.hasAcceptedIngestion
          ? V3DocumentImportTaskStatus.waiting
          : V3DocumentImportTaskStatus.failed,
      lastErrorCode: code,
      failureRetryable: retryable,
      remoteNoteId: remoteNoteId,
      updatedAt: DateTime.now().toUtc(),
    );
    if (!await _store.saveAllDurably([failed])) {
      final unsaved = failed.copyWith(
        status: V3DocumentImportTaskStatus.failed,
        lastErrorCode: 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED',
        failureRetryable: true,
      );
      _store.save(unsaved);
      return unsaved;
    }
    return failed;
  }

  void _set(
    V3DocumentImportStatus status, {
    bool clearSelectedDocuments = false,
    bool clearDurableTasks = false,
    bool clearImportedNotes = false,
    bool clearError = false,
  }) {
    _state = _state.copyWith(
      status: status,
      clearSelectedDocuments: clearSelectedDocuments,
      clearDurableTasks: clearDurableTasks,
      clearImportedNotes: clearImportedNotes,
      clearError: clearError,
    );
    notifyListeners();
  }

  void _fail(String code, {bool keepImported = false}) {
    _state = _state.copyWith(
      status: V3DocumentImportStatus.failed,
      lastErrorCode: code,
      clearImportedNotes: !keepImported,
    );
    notifyListeners();
  }
}

String? _firstNonEmptyMarkdown(String? first, String? second) {
  for (final value in <String?>[first, second]) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}

AppFailure _documentFailure(String code, String message) => AppFailure(
  code: code,
  category: AppFailureCategory.storage,
  message: message,
  userMessageKey: 'document.import.$code',
  isRetryable: true,
  recoveryActions: const <String>['retry'],
);

bool _isSupportedDocument(PickedDocumentFile document) =>
    !document.isAudio &&
    DocumentImportFormat.fromFileName(document.displayName) != null;

String _documentRequestKey(String operation, List<String> identity) =>
    'document-$operation-v2-${sha256.convert(utf8.encode(identity.join('\u0000')))}';

final class _DocumentCheckpointFailure implements Exception {
  const _DocumentCheckpointFailure();
}
