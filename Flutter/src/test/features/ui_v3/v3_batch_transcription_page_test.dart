import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_batch_transcription_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_batch_transcription.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_batch_transcription_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('keeps every terminal and active file visible in one batch', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 4, 8);
    final batch = RecordingBatchTranscriptionSnapshot(
      batchId: 'batch-ui',
      accountScope: 'account-ui',
      workspaceScope: 'workspace-ui',
      primaryItemId: 'completed',
      items: <RecordingBatchTranscriptionItem>[
        _item(
          id: 'completed',
          title: '已完成录音',
          status: RecordingBatchTranscriptionItemStatus.completed,
          phase: RecordingBatchTranscriptionPhase.assetReady,
          remoteRecordingId: 'remote-completed',
          noteId: 'note-completed',
          transcriptCompletedAt: at,
          assetReadyAt: at,
        ),
        _item(
          id: 'processing',
          title: '正在处理录音',
          status: RecordingBatchTranscriptionItemStatus.processing,
          phase: RecordingBatchTranscriptionPhase.transcribing,
          progress: 42,
        ),
        _item(
          id: 'skipped',
          title: '已跳过录音',
          status: RecordingBatchTranscriptionItemStatus.skipped,
        ),
        _item(
          id: 'unavailable',
          title: '不可用录音',
          status: RecordingBatchTranscriptionItemStatus.failed,
          failureCategory: RecordingBatchFailureCategory.unavailable,
          errorCode: 'RECORDING_LOCAL_FILE_MISSING_INTERNAL',
        ),
        _item(
          id: 'timed-out',
          title: '超时录音',
          status: RecordingBatchTranscriptionItemStatus.timedOut,
          failureCategory: RecordingBatchFailureCategory.remote,
          errorCode: 'RECORDING_REMOTE_TIMEOUT_INTERNAL',
        ),
      ],
      createdAt: at,
      updatedAt: at,
    );
    final store = _MemoryBatchStore(batch);
    final controller = RecordingBatchTranscriptionController(
      store: store,
      receiptStore: _MemoryReceiptStore(),
      executionPort: const _UnusedExecutionPort(),
      accountScope: 'account-ui',
      workspaceScope: 'workspace-ui',
    );
    addTearDown(controller.dispose);
    await controller.restore();

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3BatchTranscriptionPage(
          batchId: batch.batchId,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('transcription-batch-summary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('transcription-batch-primary-result')),
      findsOneWidget,
    );
    expect(find.text('已完成录音'), findsWidgets);
    expect(find.text('正在处理录音'), findsOneWidget);
    expect(find.text('已转写，已跳过', skipOffstage: false), findsOneWidget);
    expect(find.text('文件不可用', skipOffstage: false), findsOneWidget);
    expect(find.text('本地录音文件不可读取', skipOffstage: false), findsOneWidget);
    expect(find.text('等待服务响应超时，可继续观察', skipOffstage: false), findsOneWidget);
    expect(
      find.textContaining('RECORDING_', skipOffstage: false),
      findsNothing,
    );
    expect(find.text('返回后任务会继续在后台处理'), findsNothing);
  });

  testWidgets('renders a recoverable state when the scoped batch is absent', (
    tester,
  ) async {
    final controller = RecordingBatchTranscriptionController(
      store: _MemoryBatchStore(),
      receiptStore: _MemoryReceiptStore(),
      executionPort: const _UnusedExecutionPort(),
      accountScope: 'account-ui',
      workspaceScope: 'workspace-ui',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3BatchTranscriptionPage(
          batchId: 'missing',
          controller: controller,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('transcription-batch-not-found')),
      findsOneWidget,
    );
  });

  testWidgets('shows keyed upload metrics only during the object-upload phase', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 4, 8);
    const jobId = 'draft-batch-upload';
    final uploadTransport = _PendingObjectUploadTransport();
    final uploadController = _uploadController(uploadTransport);
    unawaited(
      uploadController.uploadPrivateAudio(
        input: RecordingPrivateAudioInput(
          jobId: jobId,
          localFileId: 'private-batch-upload',
          appPrivateUri: 'app-private-media://screen-capture/batch-upload.m4a',
          fileName: 'batch-upload.m4a',
          mimeType: 'audio/mp4',
          sizeBytes: 2048,
          durationSeconds: 90,
          contentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          recordedAt: at,
          title: '批量上传录音',
        ),
        fileSource: RecordingFileSource.audioImport,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await uploadTransport.progressReported.future;
    addTearDown(() {
      uploadController.dispose();
      uploadTransport.complete();
    });

    final uploadingController = await _batchController(
      RecordingBatchTranscriptionSnapshot(
        batchId: 'batch-upload-progress',
        accountScope: 'account-ui',
        workspaceScope: 'workspace-ui',
        primaryItemId: 'uploading',
        items: <RecordingBatchTranscriptionItem>[
          _item(
            id: 'uploading',
            title: '批量上传录音',
            jobId: jobId,
            status: RecordingBatchTranscriptionItemStatus.submitting,
            phase: RecordingBatchTranscriptionPhase.uploading,
          ),
          _item(
            id: 'already-completed',
            title: '已完成录音',
            status: RecordingBatchTranscriptionItemStatus.skipped,
          ),
        ],
        createdAt: at,
        updatedAt: at,
      ),
    );
    addTearDown(uploadingController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3BatchTranscriptionPage(
          batchId: 'batch-upload-progress',
          controller: uploadingController,
          uploadController: uploadController,
        ),
      ),
    );
    await tester.pump();

    final uploadProgress = find.byKey(
      const ValueKey('transcription-batch-item-upload-progress-uploading'),
    );
    expect(uploadProgress, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(uploadProgress).value, 1);
    final uploadDetails = tester.widget<Text>(
      find.byKey(
        const ValueKey('transcription-batch-item-upload-details-uploading'),
      ),
    );
    expect(uploadDetails.data, contains('2.0 KB / 2.0 KB'));
    expect(uploadDetails.data, contains('/s'));
    expect(uploadDetails.data, isNot(contains('--/s')));
    expect(uploadDetails.data, contains('剩余 0s'));

    final transcribingController = await _batchController(
      RecordingBatchTranscriptionSnapshot(
        batchId: 'batch-upload-progress',
        accountScope: 'account-ui',
        workspaceScope: 'workspace-ui',
        primaryItemId: 'uploading',
        items: <RecordingBatchTranscriptionItem>[
          _item(
            id: 'uploading',
            title: '批量上传录音',
            jobId: jobId,
            status: RecordingBatchTranscriptionItemStatus.processing,
            phase: RecordingBatchTranscriptionPhase.transcribing,
            progress: 42,
          ),
          _item(
            id: 'already-completed',
            title: '已完成录音',
            status: RecordingBatchTranscriptionItemStatus.skipped,
          ),
        ],
        createdAt: at,
        updatedAt: at.add(const Duration(seconds: 1)),
      ),
    );
    addTearDown(transcribingController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3BatchTranscriptionPage(
          batchId: 'batch-upload-progress',
          controller: transcribingController,
          uploadController: uploadController,
        ),
      ),
    );
    await tester.pump();

    expect(uploadProgress, findsNothing);
    expect(
      find.byKey(
        const ValueKey('transcription-batch-item-upload-details-uploading'),
      ),
      findsNothing,
    );
    expect(find.text('正在转写'), findsOneWidget);
    expect(find.textContaining('剩余 0s'), findsNothing);
  });

  testWidgets('shows full settled progress for a terminal batch with issues', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 4, 8);
    final batch = RecordingBatchTranscriptionSnapshot(
      batchId: 'batch-terminal',
      accountScope: 'account-ui',
      workspaceScope: 'workspace-ui',
      primaryItemId: 'failed',
      items: <RecordingBatchTranscriptionItem>[
        _item(
          id: 'failed',
          title: '失败录音',
          status: RecordingBatchTranscriptionItemStatus.failed,
          failureCategory: RecordingBatchFailureCategory.remote,
        ),
        _item(
          id: 'timed-out',
          title: '超时录音',
          status: RecordingBatchTranscriptionItemStatus.timedOut,
          failureCategory: RecordingBatchFailureCategory.remote,
        ),
      ],
      createdAt: at,
      updatedAt: at,
    );
    final controller = RecordingBatchTranscriptionController(
      store: _MemoryBatchStore(batch),
      receiptStore: _MemoryReceiptStore(),
      executionPort: const _UnusedExecutionPort(),
      accountScope: 'account-ui',
      workspaceScope: 'workspace-ui',
    );
    addTearDown(controller.dispose);
    await controller.restore();

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3BatchTranscriptionPage(
          batchId: batch.batchId,
          controller: controller,
        ),
      ),
    );
    await tester.pump();

    final summary = find.byKey(const ValueKey('transcription-batch-summary'));
    expect(find.descendant(of: summary, matching: find.text('2/2')), findsOne);
    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: summary,
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, 1);
  });
}

RecordingBatchTranscriptionItem _item({
  required String id,
  required String title,
  required RecordingBatchTranscriptionItemStatus status,
  String? jobId,
  RecordingBatchTranscriptionPhase? phase,
  int? progress,
  String? remoteRecordingId,
  String? noteId,
  RecordingBatchFailureCategory? failureCategory,
  String? errorCode,
  DateTime? transcriptCompletedAt,
  DateTime? assetReadyAt,
}) {
  final at = DateTime.utc(2026, 9, 4, 8);
  return RecordingBatchTranscriptionItem(
    itemId: id,
    title: title,
    fileIdentity: 'identity-$id',
    localRecordingId: 'local-$id',
    jobId: jobId ?? 'job-$id',
    remoteRecordingId: remoteRecordingId,
    noteId: noteId,
    status: status,
    phase: phase,
    progress: progress,
    outlineStatus: RecordingBatchOutlineStatus.notStarted,
    retryable: false,
    attemptCount: 0,
    failureCategory: failureCategory,
    errorCode: errorCode,
    transcriptCompletedAt: transcriptCompletedAt,
    assetReadyAt: assetReadyAt,
    createdAt: at,
    updatedAt: at,
  );
}

Future<RecordingBatchTranscriptionController> _batchController(
  RecordingBatchTranscriptionSnapshot batch,
) async {
  final controller = RecordingBatchTranscriptionController(
    store: _MemoryBatchStore(batch),
    receiptStore: _MemoryReceiptStore(),
    executionPort: const _UnusedExecutionPort(),
    accountScope: 'account-ui',
    workspaceScope: 'workspace-ui',
  );
  await controller.restore();
  return controller;
}

RecordingUploadController _uploadController(
  _PendingObjectUploadTransport objectTransport,
) {
  final database = AppDatabase();
  final apiClient = ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-ui-test',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token-ok',
    ),
    transport: const _UploadTokenApiTransport(),
  );
  return RecordingUploadController(
    uploadClient: UploadClient(
      apiClient: apiClient,
      objectTransport: objectTransport,
    ),
    draftStore: UploadDraftStore(database: database),
    recordingApi: RecordingApi(apiClient: apiClient),
    localRecordingRepository: LocalRecordingRepository(
      database: database,
      fileStorage: const UnavailableFileStoragePort(),
    ),
    activeWorkspaceId: () => 'workspace-ui',
    now: () => DateTime.utc(2026, 9, 4, 8),
  );
}

final class _MemoryBatchStore implements RecordingBatchTranscriptionStorePort {
  _MemoryBatchStore([RecordingBatchTranscriptionSnapshot? initial]) {
    if (initial != null) values[initial.batchId] = initial;
  }

  final Map<String, RecordingBatchTranscriptionSnapshot> values =
      <String, RecordingBatchTranscriptionSnapshot>{};

  @override
  void deleteBatch(String batchId) => values.remove(batchId);

  @override
  Future<bool> flush() async => true;

  @override
  List<RecordingBatchTranscriptionSnapshot> loadBatches() =>
      values.values.toList(growable: false);

  @override
  void saveBatch(RecordingBatchTranscriptionSnapshot batch) {
    values[batch.batchId] = batch;
  }
}

final class _MemoryReceiptStore
    implements RecordingTranscriptionReceiptStorePort {
  final Map<String, RecordingTranscriptionReceipt> values =
      <String, RecordingTranscriptionReceipt>{};

  @override
  RecordingTranscriptionReceipt? findByFileIdentity(String fileIdentity) =>
      values[fileIdentity];

  @override
  RecordingTranscriptionReceipt? findByLocalRecordingId(String id) => null;

  @override
  RecordingTranscriptionReceipt? findByRemoteRecordingId(String id) => null;

  @override
  Future<bool> flush() async => true;

  @override
  List<RecordingTranscriptionReceipt> listReceipts() =>
      values.values.toList(growable: false);

  @override
  void save(RecordingTranscriptionReceipt receipt) {
    values[receipt.fileIdentity] = receipt;
  }
}

final class _UnusedExecutionPort
    implements RecordingBatchTranscriptionExecutionPort {
  const _UnusedExecutionPort();

  @override
  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('not used');

  @override
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('not used');

  @override
  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('not used');
}

final class _UploadTokenApiTransport implements ApiTransport {
  const _UploadTokenApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    if (request.url.path == '/api/v1/media/upload-token') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'uploadId': 'upload-batch-ui',
            'uploadUrl':
                'https://upload.example.test/object/batch-ui?signature=test',
            'method': 'PUT',
            'headers': <String, Object?>{},
          },
        },
      );
    }
    return const ApiTransportResponse(
      status: 404,
      body: <String, Object?>{
        'success': false,
        'error': <String, Object?>{'code': 'NOT_FOUND'},
      },
    );
  }
}

final class _PendingObjectUploadTransport implements ObjectUploadTransport {
  final progressReported = Completer<void>();
  final _result = Completer<ObjectUploadResult>();
  ObjectUploadRequest? _request;

  void complete() {
    final request = _request;
    if (request == null || _result.isCompleted) return;
    _result.complete(
      ObjectUploadResult.success(statusCode: 200, bytesSent: request.sizeBytes),
    );
  }

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    _request = request;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    request.onProgress?.call(request.sizeBytes, request.sizeBytes);
    if (!progressReported.isCompleted) progressReported.complete();
    return _result.future;
  }
}
