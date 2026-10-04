import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/ingestion/application/meeting_capture_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  group('RecordingUploadController', () {
    test(
      'preflight failures belong to jobs and only the retried error clears',
      () async {
        final database = AppDatabase();
        _seedItem(database);
        UploadDraftStore(database: database).saveDraft(_importedDraft());
        String? workspaceId;
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
          workspaceIdProvider: () => workspaceId,
        );
        addTearDown(controller.dispose);

        expect(await controller.uploadLocalRecording(item: _item()), isNull);
        expect(controller.state.activeDraft, isNull);
        expect(controller.state.activeJobIds, isEmpty);
        expect(
          controller.state.failureCodesByJobId['draft-local-1'],
          'RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE',
        );
        expect(controller.state.lastErrorJobId, 'draft-local-1');
        final other = _privateInput('other');
        expect(
          await controller.uploadPrivateAudio(
            input: other,
            fileSource: RecordingFileSource.audioImport,
          ),
          isNull,
        );
        expect(controller.state.failureCodesByJobId, hasLength(2));
        expect(controller.state.lastErrorJobId, other.jobId);
        expect(transport.requests, isEmpty);

        workspaceId = 'workspace-1';
        expect(await controller.retryJob('draft-local-1'), isTrue);
        expect(
          controller.state.failureCodesByJobId.containsKey('draft-local-1'),
          isFalse,
        );
        expect(
          controller.state.failureCodesByJobId[other.jobId],
          'RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE',
        );
        expect(controller.state.activeJobIds, isEmpty);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.lastErrorJobId, isNull);
      },
    );

    test(
      'retry reports missing local input instead of silently waiting',
      () async {
        final database = AppDatabase();
        UploadDraftStore(database: database).saveDraft(_importedDraft());
        final controller = _controller(
          database: database,
          apiTransport: _RecordingUploadApiTransport(),
          objectTransport: _ObjectTransport(),
        );
        addTearDown(controller.dispose);
        expect(await controller.retryJob('draft-local-1'), isFalse);
        expect(
          controller.state.failureCodesByJobId['draft-local-1'],
          'RECORDING_LOCAL_FILE_NOT_FOUND',
        );
      },
    );

    test('binds an imported local draft only on explicit upload', () async {
      final database = AppDatabase();
      _seedItem(database);
      final store = UploadDraftStore(database: database);
      final unbound = _importedDraft();
      store.saveDraft(unbound);
      final transport = _RecordingUploadApiTransport(
        onRequest: (request) {
          final saved = store.getDraft(unbound.draftId)!;
          expect(saved.workspaceId, 'workspace-1');
          expect(saved.workspaceState, UploadDraftWorkspaceState.bound);
          expect(saved.uploadTokenKey, isNot(unbound.uploadTokenKey));
          expect(saved.completeUploadKey, isNot(unbound.completeUploadKey));
          expect(saved.createRecordingKey, isNot(unbound.createRecordingKey));
        },
      );
      final objectTransport = _ObjectTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: objectTransport,
      );
      addTearDown(controller.dispose);

      expect(await controller.recoverDrafts(), isEmpty);
      expect(store.getDraft(unbound.draftId)!.workspaceId, isNull);
      expect(transport.requests, isEmpty);

      final result = await controller.uploadLocalRecording(item: _item());
      expect(result?.recording.recordingId, 'rec-1');
      expect(result?.asrTask?.asrTaskId, 'asr-1');
      expect(
        store.getDraft(unbound.draftId)!.stage,
        UploadDraftStage.asrQueued,
      );
      expect(objectTransport.requests, hasLength(1));
      final requestCount = transport.requests.length;
      expect(await controller.uploadLocalRecording(item: _item()), isNotNull);
      expect(transport.requests, hasLength(requestCount));
      expect(objectTransport.requests, hasLength(1));
    });

    for (final stage in <UploadDraftStage>[
      UploadDraftStage.uploadTokenRequesting,
      UploadDraftStage.tokenFailed,
      UploadDraftStage.objectUploading,
    ]) {
      test('does not rebind an uncertain unscoped draft at $stage', () async {
        final database = AppDatabase();
        _seedItem(database);
        final draft = _importedDraft().copyWith(stage: stage);
        UploadDraftStore(database: database).saveDraft(draft);
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );
        addTearDown(controller.dispose);

        expect(draft.workspaceState, UploadDraftWorkspaceState.unsafeUnbound);
        expect(await controller.uploadLocalRecording(item: _item()), isNull);
        expect(controller.state.lastErrorCode, 'RECORDING_UPLOAD_JOB_CONFLICT');
        expect(transport.requests, isEmpty);
      });
    }

    test('does not rebind a local draft frozen to another workspace', () async {
      final database = AppDatabase();
      _seedItem(database);
      UploadDraftStore(
        database: database,
      ).saveDraft(_importedDraft(workspaceId: 'workspace-other'));
      final transport = _RecordingUploadApiTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: _ObjectTransport(),
      );
      addTearDown(controller.dispose);
      expect(await controller.uploadLocalRecording(item: _item()), isNull);
      expect(controller.state.lastErrorCode, 'RECORDING_UPLOAD_JOB_CONFLICT');
      expect(transport.requests, isEmpty);
    });

    test('times out local hashing before requesting an upload token', () async {
      final transport = _RecordingUploadApiTransport();
      final database = AppDatabase();
      final item = _item(contentHash: null);
      _seedItem(database, item: item);
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: _ObjectTransport(),
        fileStorage: _PendingHashFileStorage(),
        localPreparationTimeout: Duration.zero,
      );

      final result = await controller.uploadLocalRecording(item: item);

      expect(result, isNull);
      expect(controller.state.status, RecordingFileJobStatus.failed);
      expect(controller.state.lastErrorCode, 'RECORDING_CONTENT_HASH_TIMEOUT');
      expect(transport.requests, isEmpty);
    });

    test('does not start upload while local deletion is locked', () async {
      final transport = _RecordingUploadApiTransport();
      final objectTransport = _ObjectTransport();
      final database = AppDatabase();
      _seedItem(database);
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: objectTransport,
        deletionLedger: const _UploadBlockedDeletionLedger(),
      );

      final result = await controller.uploadLocalRecording(item: _item());

      expect(result, isNull);
      expect(controller.state.status, RecordingFileJobStatus.failed);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_LOCAL_DELETE_IN_PROGRESS',
      );
      expect(transport.requests, isEmpty);
      expect(objectTransport.requests, isEmpty);
    });

    test('holds the file lease while content hashing is pending', () async {
      final transport = _RecordingUploadApiTransport();
      final objectTransport = _ObjectTransport();
      final database = AppDatabase();
      final storage = _ControlledHashFileStorage();
      final item = _item(contentHash: null);
      _seedItem(database, item: item);
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: storage,
      );
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: objectTransport,
        localRecordingRepository: repository,
      );
      addTearDown(controller.dispose);

      final upload = controller.uploadLocalRecording(item: item);
      await storage.hashStarted.future;
      expect(controller.state.activeJobIds, contains('draft-local-1'));
      final deletion = await repository.deletePermanently(item.recordingId);

      expect(deletion.ok, isFalse);
      expect(deletion.error?.code, 'RECORDING_DELETE_UPLOAD_IN_PROGRESS');
      expect(transport.requests, isEmpty);
      storage.completeHash(_hash);
      expect(await upload, isNotNull);
      expect(controller.state.activeJobIds, isEmpty);
      expect(objectTransport.requests, hasLength(1));
    });

    test(
      'runs upload token, object upload, complete, and create recording',
      () async {
        final transport = _RecordingUploadApiTransport();
        final objectTransport = _ObjectTransport();
        final database = AppDatabase();
        final processingPort = _RecordingProcessingPort();
        _seedItem(database);
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: objectTransport,
          processingPort: processingPort,
        );

        final result = await controller.uploadLocalRecording(
          item: _item(),
          contentLineId: 'line-1',
        );

        expect(result?.recording.recordingId, 'rec-1');
        expect(result?.asrTask?.asrTaskId, 'asr-1');
        expect(controller.state.status, RecordingFileJobStatus.processing);
        expect(controller.state.activeDraft?.stage, UploadDraftStage.asrQueued);
        expect(
          UploadDraftStore(database: database).getDraft('draft-local-1')?.stage,
          UploadDraftStage.asrQueued,
        );
        expect(processingPort.tracked.single.stage, UploadDraftStage.asrQueued);
        expect(processingPort.tracked.single.recordingId, 'rec-1');
        expect(
          objectTransport.requests.single.appPrivateUri,
          _item().appPrivateUri,
        );
        expect(transport.paths, <String>[
          '/api/v1/media/upload-token',
          '/api/v1/media/uploads/upload-1/complete',
          '/api/v1/recordings',
        ]);
        expect(
          _body(transport.requests[0]),
          containsPair('workspaceId', 'workspace-1'),
        );
        expect(_body(transport.requests[1]), <String, Object?>{
          'workspaceId': 'workspace-1',
        });
        expect(
          _body(transport.requests[2]),
          containsPair('audioResourceId', 'resource-1'),
        );
        expect(_body(transport.requests[2]).containsKey('resourceId'), isFalse);
        final linked = RecordingLibraryItem.fromRecord(
          RecordingDao(database).getLocalRecording('local-1')!,
        );
        expect(linked?.remoteRecordingId, 'rec-1');
        expect(linked?.contentLineId, 'line-1');
        expect(linked?.hasServerChatContext, isTrue);
      },
    );

    test('keeps one draft progress when another upload advances', () async {
      final objectTransport = _ControlledConcurrentObjectTransport();
      final controller = _controller(
        apiTransport: _RecordingUploadApiTransport(),
        objectTransport: objectTransport,
      );
      addTearDown(controller.dispose);
      final inputA = _privateInput('a');
      final inputB = _privateInput('b');

      final uploadA = controller.uploadPrivateAudio(
        input: inputA,
        fileSource: RecordingFileSource.audioImport,
      );
      await objectTransport.waitUntilStarted(inputA.appPrivateUri);
      final uploadB = controller.uploadPrivateAudio(
        input: inputB,
        fileSource: RecordingFileSource.audioImport,
      );
      await objectTransport.waitUntilStarted(inputB.appPrivateUri);
      expect(
        controller.state.activeUploadDraftsById.keys,
        containsAll(<String>[inputA.jobId, inputB.jobId]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      objectTransport.reportProgress(inputB.appPrivateUri, inputB.sizeBytes);

      expect(
        controller.state.progressForDraft(inputB.jobId)?.bytesSent,
        inputB.sizeBytes,
      );
      expect(
        controller.state.progressForDraft(inputB.jobId)?.bytesPerSecond,
        greaterThan(0),
      );

      final invalidResult = await controller.uploadPrivateAudio(
        input: _privateInput('invalid', contentHash: 'invalid'),
        fileSource: RecordingFileSource.audioImport,
      );
      expect(invalidResult, isNull);
      expect(controller.state.activeDraft, isNull);
      expect(
        controller.state.uploadProgressByDraftId.keys,
        containsAll(<String>[inputA.jobId, inputB.jobId]),
      );
      expect(
        controller.state.activeUploadDraftsById.keys,
        containsAll(<String>[inputA.jobId, inputB.jobId]),
      );

      objectTransport.complete(inputA.appPrivateUri);
      expect(await uploadA, isNotNull);

      final progressB = controller.state.progressForDraft(inputB.jobId);
      expect(progressB, isNotNull);
      expect(progressB?.bytesSent, inputB.sizeBytes);
      expect(progressB?.estimatedRemainingSeconds, 0);
      expect(
        controller.state.uploadProgressByDraftId,
        isNot(contains(inputA.jobId)),
      );
      expect(
        controller.state.activeUploadDraftsById.keys,
        contains(inputB.jobId),
      );
      expect(
        controller.state.activeUploadDraftsById,
        isNot(contains(inputA.jobId)),
      );

      objectTransport.complete(inputB.appPrivateUri);
      expect(await uploadB, isNotNull);
      expect(controller.state.uploadProgressByDraftId, isEmpty);
      expect(controller.state.activeUploadDraftsById, isEmpty);
    });

    test('re-enrolls only the matching queued processing checkpoint', () async {
      final database = AppDatabase();
      final processingPort = _RecordingProcessingPort();
      final controller = _controller(
        database: database,
        apiTransport: _RecordingUploadApiTransport(),
        objectTransport: _ObjectTransport(),
        processingPort: processingPort,
      );
      final draft = _processingDraft();
      UploadDraftStore(database: database).saveDraft(draft);

      final first = controller.handoffQueuedProcessingForLocalRecording(
        localRecordingId: 'local-1',
        recordingId: 'rec-1',
      );
      final second = controller.handoffQueuedProcessingForLocalRecording(
        localRecordingId: 'local-1',
        recordingId: 'rec-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.status, RecordingProcessingHandoffStatus.enqueued);
      expect(second.status, RecordingProcessingHandoffStatus.alreadyEnrolled);
      expect(processingPort.tracked, hasLength(1));
      expect(processingPort.tracked.single.draftId, draft.draftId);
      expect(processingPort.tracked.single.recordingId, 'rec-1');

      UploadDraftStore(database: database).saveDraft(
        draft.copyWith(
          stage: UploadDraftStage.asrCompleted,
          updatedAt: _time().add(const Duration(minutes: 1)),
        ),
      );
      final terminal = controller.handoffQueuedProcessingForLocalRecording(
        localRecordingId: 'local-1',
        recordingId: 'rec-1',
      );

      expect(terminal.status, RecordingProcessingHandoffStatus.alreadyTerminal);
      expect(processingPort.tracked, hasLength(1));
    });

    test(
      'uses recording ASR task id when create omits expanded task',
      () async {
        final database = AppDatabase();
        final processingPort = _RecordingProcessingPort();
        _seedItem(database);
        final controller = _controller(
          database: database,
          apiTransport: _RecordingUploadApiTransport(omitAsrTaskObject: true),
          objectTransport: _ObjectTransport(),
          processingPort: processingPort,
        );

        final result = await controller.uploadLocalRecording(item: _item());

        expect(result?.asrTask, isNull);
        expect(controller.state.status, RecordingFileJobStatus.processing);
        expect(controller.state.activeDraft?.stage, UploadDraftStage.asrQueued);
        expect(controller.state.activeDraft?.asrTaskId, 'asr-1');
        expect(processingPort.tracked.single.asrTaskId, 'asr-1');
      },
    );

    test(
      'reports an unavailable processing handoff for a queued checkpoint',
      () {
        final database = AppDatabase();
        final controller = _controller(
          database: database,
          apiTransport: _RecordingUploadApiTransport(),
          objectTransport: _ObjectTransport(),
        );
        UploadDraftStore(database: database).saveDraft(_processingDraft());

        final result = controller.handoffQueuedProcessingForLocalRecording(
          localRecordingId: 'local-1',
          recordingId: 'rec-1',
        );

        expect(result.status, RecordingProcessingHandoffStatus.unavailable);
        expect(result.failureCode, 'RECORDING_PROCESSING_HANDOFF_UNAVAILABLE');
      },
    );

    test(
      'does not hand off a checkpoint frozen to another workspace',
      () async {
        final database = AppDatabase();
        final processingPort = _RecordingProcessingPort();
        final controller = _controller(
          database: database,
          apiTransport: _RecordingUploadApiTransport(),
          objectTransport: _ObjectTransport(),
          workspaceId: 'workspace-b',
          processingPort: processingPort,
        );
        UploadDraftStore(
          database: database,
        ).saveDraft(_processingDraft(workspaceId: 'workspace-a'));

        final result = controller.handoffQueuedProcessingForLocalRecording(
          localRecordingId: 'local-1',
          recordingId: 'rec-1',
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          result.status,
          RecordingProcessingHandoffStatus.missingCheckpoint,
        );
        expect(processingPort.tracked, isEmpty);
      },
    );

    test(
      'object upload failure does not complete or create recording',
      () async {
        final transport = _RecordingUploadApiTransport();
        final database = AppDatabase();
        _seedItem(database);
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(fail: true),
        );

        final result = await controller.uploadLocalRecording(item: _item());

        expect(result, isNull);
        expect(controller.state.status, RecordingFileJobStatus.failed);
        expect(controller.state.lastErrorCode, 'UPLOAD_OBJECT_FAILED');
        expect(transport.paths, <String>['/api/v1/media/upload-token']);
        expect(
          controller.state.activeDraft?.stage,
          UploadDraftStage.objectUploadFailed,
        );
      },
    );

    test(
      'stops a bound upload when the authenticated account changes',
      () async {
        final database = AppDatabase();
        const ownerScope = 'user-a';
        var activeScope = ownerScope;
        _seedItem(database, accountScope: ownerScope);
        final transport = _RecordingUploadApiTransport(
          onRequest: (request) {
            if (request.url.path == '/api/v1/media/upload-token') {
              activeScope = 'user-b';
            }
          },
        );
        final objectTransport = _ObjectTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: objectTransport,
          accountScope: ownerScope,
          activeAccountScope: () => activeScope,
        );

        final result = await controller.uploadLocalRecording(item: _item());

        expect(result, isNull);
        expect(controller.state.status, RecordingFileJobStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'RECORDING_UPLOAD_ACCOUNT_CHANGED',
        );
        expect(objectTransport.requests, isEmpty);
        expect(transport.paths, <String>['/api/v1/media/upload-token']);
        expect(
          UploadDraftStore(
            database: database,
            accountScope: ownerScope,
          ).getDraft('draft-local-1')?.stage,
          UploadDraftStage.uploadTokenRequesting,
        );
        expect(
          UploadDraftStore(
            database: database,
            accountScope: 'user-b',
          ).getDraft('draft-local-1'),
          isNull,
        );
      },
    );

    test('stops a bound upload when its active workspace changes', () async {
      final database = AppDatabase();
      _seedItem(database);
      var activeWorkspaceId = 'workspace-a';
      var switchAfterFirstToken = true;
      final transport = _RecordingUploadApiTransport(
        onRequest: (request) {
          if (switchAfterFirstToken &&
              request.url.path == '/api/v1/media/upload-token') {
            switchAfterFirstToken = false;
            activeWorkspaceId = 'workspace-b';
          }
        },
      );
      final objectTransport = _ObjectTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: objectTransport,
        workspaceIdProvider: () => activeWorkspaceId,
      );

      final interrupted = await controller.uploadLocalRecording(item: _item());

      expect(interrupted, isNull);
      expect(controller.state.status, RecordingFileJobStatus.failed);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_UPLOAD_WORKSPACE_CHANGED',
      );
      expect(objectTransport.requests, isEmpty);
      expect(transport.paths, <String>['/api/v1/media/upload-token']);
      expect(
        UploadDraftStore(database: database).getDraft('draft-local-1')?.stage,
        UploadDraftStage.uploadTokenRequesting,
      );

      activeWorkspaceId = 'workspace-a';
      final recovered = await controller.recoverDrafts();

      expect(recovered.single.recording.recordingId, 'rec-1');
      expect(transport.paths, <String>[
        '/api/v1/media/upload-token',
        '/api/v1/media/upload-token',
        '/api/v1/media/uploads/upload-1/complete',
        '/api/v1/recordings',
      ]);
      expect(objectTransport.requests, hasLength(1));
      expect(
        UploadDraftStore(database: database).getDraft('draft-local-1')?.stage,
        UploadDraftStage.asrQueued,
      );
    });

    test('logs safe stage and error code for object upload failure', () async {
      final database = AppDatabase();
      final dao = DiagnosticLogDao(database);
      _seedItem(database);
      final controller = _controller(
        database: database,
        apiTransport: _RecordingUploadApiTransport(),
        objectTransport: _ObjectTransport(fail: true),
        diagnosticLogger: DiagnosticLogger(dao: dao),
      );

      await controller.uploadLocalRecording(item: _item());

      final logs = dao.query(
        const DiagnosticLogQuery(includeDeveloperOnly: true),
      );
      expect(
        logs.any(
          (event) =>
              event.safeSummary ==
                  'recording_upload_objectUploadFailed_failed' &&
              event.redactedMetadata['stage'] == 'objectUploadFailed' &&
              event.redactedMetadata['errorCode'] == 'UPLOAD_OBJECT_FAILED',
        ),
        isTrue,
      );
      expect(
        logs.expand((event) => event.redactedMetadata.keys),
        isNot(contains('appPrivateUri')),
      );
    });

    test('repairs missing hash before requesting an upload token', () async {
      final database = AppDatabase();
      final item = _item(contentHash: null);
      _seedItem(database, item: item);
      final transport = _RecordingUploadApiTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: _ObjectTransport(),
        fileStorage: const _HashingFileStorage(),
      );

      final result = await controller.uploadLocalRecording(item: item);

      expect(result?.recording.recordingId, 'rec-1');
      final tokenRequest = transport.requests.first;
      final body = jsonDecode(tokenRequest.body!) as Map<String, Object?>;
      expect(body['sha256'], _hash);
      expect(
        tokenRequest.headers['X-Idempotency-Key'],
        startsWith('idem-upload-draft-local-1-'),
      );
      expect(
        tokenRequest.headers['X-Idempotency-Key'],
        isNot('idem-upload-draft-local-1-aaaaaaaaaaaa'),
      );
      expect(
        RecordingLibraryItem.fromRecord(
          RecordingDao(database).getLocalRecording('local-1')!,
        )?.contentHash,
        _hash,
      );
    });

    test(
      'recovers a completed-object draft after controller recreation',
      () async {
        final database = AppDatabase();
        _seedItem(database);
        final draftStore = UploadDraftStore(database: database);
        final draft = createInitialUploadDraft(
          draftId: 'draft-local-1',
          localRecordingId: 'local-1',
          appPrivateUri: 'app-private://recordings/local-1/source.m4a',
          fileName: 'Meeting.m4a',
          mimeType: 'audio/mp4',
          sizeBytes: 2048,
          durationSeconds: 90,
          sourceScene: 'raw_material',
          workspaceId: 'workspace-1',
          recordingSource: 'local_upload',
          updatedAt: _time(),
          contentHash: _hash,
          title: 'Meeting.m4a',
          contentLineId: 'line-1',
        );
        draftStore.saveDraft(
          draft.copyWith(
            stage: UploadDraftStage.objectUploaded,
            uploadId: 'upload-1',
          ),
        );
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        final recovered = await controller.recoverDrafts();

        expect(recovered.single.recording.recordingId, 'rec-1');
        expect(controller.state.activeDraft?.stage, UploadDraftStage.asrQueued);
        expect(transport.paths, <String>[
          '/api/v1/media/uploads/upload-1/complete',
          '/api/v1/recordings',
        ]);
        expect(controller.state.activeDraft?.stage, UploadDraftStage.asrQueued);
        final linked = RecordingLibraryItem.fromRecord(
          RecordingDao(database).getLocalRecording('local-1')!,
        );
        expect(linked?.remoteRecordingId, 'rec-1');
        expect(linked?.contentLineId, 'line-1');
      },
    );

    test(
      'leaves queued remote processing to the detail tracker on recovery',
      () async {
        final database = AppDatabase();
        final store = UploadDraftStore(database: database);
        final queued =
            createInitialUploadDraft(
              draftId: 'draft-local-queued',
              localRecordingId: 'local-queued',
              appPrivateUri: 'app-private://recordings/local-queued/source.m4a',
              fileName: 'Queued.m4a',
              mimeType: 'audio/mp4',
              sizeBytes: 2048,
              durationSeconds: 90,
              sourceScene: 'raw_material',
              recordingSource: 'local_upload',
              updatedAt: _time(),
            ).copyWith(
              stage: UploadDraftStage.asrQueued,
              recordingId: 'rec-queued',
              asrTaskId: 'asr-queued',
            );
        expect(store.saveDraft(queued).ok, isTrue);
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        final recovered = await controller.recoverDrafts();

        expect(recovered, isEmpty);
        expect(transport.paths, isEmpty);
        expect(
          store.getDraft(queued.draftId)?.stage,
          UploadDraftStage.asrQueued,
        );
      },
    );

    test('rebuilds a hashless failed draft before recovery', () async {
      final database = AppDatabase();
      final item = _item(contentHash: null);
      _seedItem(database, item: item);
      final oldDraft = createInitialUploadDraft(
        draftId: 'draft-local-1',
        localRecordingId: 'local-1',
        appPrivateUri: item.appPrivateUri!,
        fileName: item.displayName,
        mimeType: 'audio/mp4',
        sizeBytes: item.sizeBytes,
        durationSeconds: item.durationSeconds,
        sourceScene: 'raw_material',
        workspaceId: 'workspace-1',
        recordingSource: 'local_upload',
        updatedAt: _time(),
      );
      UploadDraftStore(database: database).markFailed(
        draft: oldDraft.copyWith(uploadId: 'upload-expired'),
        stage: UploadDraftStage.objectUploadFailed,
        errorCode: 'UPLOAD_OBJECT_HTTP_ERROR',
        now: _time(),
      );
      final transport = _RecordingUploadApiTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: _ObjectTransport(),
        fileStorage: const _HashingFileStorage(),
      );

      final recovered = await controller.recoverDrafts();

      expect(recovered.single.recording.recordingId, 'rec-1');
      expect(
        transport.requests.first.headers['X-Idempotency-Key'],
        startsWith('idem-upload-draft-local-1-'),
      );
      expect(controller.state.activeDraft?.contentHash, _hash);
    });

    test(
      'recovers a failed local link without creating a second recording',
      () async {
        final database = AppDatabase();
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        final first = await controller.uploadLocalRecording(
          item: _item(),
          contentLineId: 'line-1',
        );

        expect(first, isNull);
        expect(
          controller.state.activeDraft?.stage,
          UploadDraftStage.localLinkFailed,
        );
        expect(transport.paths.last, '/api/v1/recordings');

        _seedItem(database);
        final recovered = await controller.recoverDrafts();

        expect(recovered.single.recording.recordingId, 'rec-1');
        expect(
          transport.paths.where((path) => path == '/api/v1/recordings'),
          hasLength(1),
        );
        final linked = RecordingLibraryItem.fromRecord(
          RecordingDao(database).getLocalRecording('local-1')!,
        );
        expect(linked?.contentLineId, 'line-1');
        expect(linked?.remoteRecordingId, 'rec-1');
      },
    );

    test(
      'recovery preserves exact monologue source for a raw-material draft',
      () async {
        final database = AppDatabase();
        _seedItem(database);
        final draftStore = UploadDraftStore(database: database);
        final draft = createInitialUploadDraft(
          draftId: 'draft-local-1',
          localRecordingId: 'local-1',
          appPrivateUri: 'app-private://recordings/local-1/source.m4a',
          fileName: 'Monologue.m4a',
          mimeType: 'audio/mp4',
          sizeBytes: 2048,
          durationSeconds: 90,
          sourceScene: 'raw_material',
          workspaceId: 'workspace-1',
          recordingSource: 'monologue',
          updatedAt: _time(),
          contentHash: _hash,
          title: 'Monologue.m4a',
        );
        draftStore.saveDraft(
          draft.copyWith(
            stage: UploadDraftStage.objectUploaded,
            uploadId: 'upload-1',
          ),
        );
        expect(
          draftStore.getDraft(draft.draftId)?.recordingSource,
          'monologue',
        );
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        await controller.recoverDrafts();

        final recordingRequest = transport.requests.singleWhere(
          (request) => request.url.path == '/api/v1/recordings',
        );
        final body = jsonDecode(recordingRequest.body!) as Map<String, Object?>;
        expect(body['source'], 'monologue');
      },
    );

    test(
      'recovery preserves meeting source from the persisted scene',
      () async {
        final database = AppDatabase();
        _seedItem(database);
        final draftStore = UploadDraftStore(database: database);
        final draft = createInitialUploadDraft(
          draftId: 'draft-local-1',
          localRecordingId: 'local-1',
          appPrivateUri: 'app-private://recordings/local-1/source.m4a',
          fileName: 'Meeting.m4a',
          mimeType: 'audio/mp4',
          sizeBytes: 2048,
          durationSeconds: 90,
          sourceScene: 'meeting',
          workspaceId: 'workspace-1',
          recordingSource: 'meeting',
          updatedAt: _time(),
          contentHash: _hash,
          title: 'Meeting.m4a',
        );
        final legacyRecord =
            draft
                .copyWith(
                  stage: UploadDraftStage.objectUploaded,
                  uploadId: 'upload-1',
                )
                .toRecord()
              ..remove('recording_source');
        database.upsertRecord(
          LocalTableName.localRecordingUploadDrafts,
          draft.draftId,
          legacyRecord,
        );
        expect(draftStore.getDraft(draft.draftId)?.recordingSource, isNull);
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        await controller.recoverDrafts();

        final recordingRequest = transport.requests.singleWhere(
          (request) => request.url.path == '/api/v1/recordings',
        );
        final body = jsonDecode(recordingRequest.body!) as Map<String, Object?>;
        expect(body['source'], 'meeting');
      },
    );

    test('meeting adapter uses raw-material policy for WAV uploads', () async {
      final database = AppDatabase();
      final item = _item(
        format: RecordingLibraryFormat.wav,
        displayName: 'Meeting.wav',
      );
      _seedItem(database, item: item);
      final transport = _RecordingUploadApiTransport();
      final controller = _controller(
        database: database,
        apiTransport: transport,
        objectTransport: _ObjectTransport(),
      );

      final result = await RecordingUploadMeetingPort(controller).upload(item);

      expect(result.ok, isTrue);
      final tokenRequest = transport.requests.firstWhere(
        (request) => request.url.path == '/api/v1/media/upload-token',
      );
      expect(_body(tokenRequest)['sourceScene'], 'raw_material');
      expect(_body(tokenRequest)['mimeType'], 'audio/wav');
      final recordingRequest = transport.requests.singleWhere(
        (request) => request.url.path == '/api/v1/recordings',
      );
      expect(_body(recordingRequest)['source'], 'meeting');
    });

    test(
      'upgrades a failed legacy meeting WAV draft before recovery',
      () async {
        final database = AppDatabase();
        final item = _item(
          format: RecordingLibraryFormat.wav,
          displayName: 'Meeting.wav',
        );
        _seedItem(database, item: item);
        const legacyTokenKey = 'idem-upload-draft-local-1-aaaaaaaaaaaa';
        final legacyDraft = UploadDraft(
          draftId: 'draft-local-1',
          localRecordingId: item.recordingId,
          appPrivateUri: item.appPrivateUri!,
          fileName: item.displayName,
          mimeType: 'audio/wav',
          sizeBytes: item.sizeBytes,
          durationSeconds: item.durationSeconds,
          sourceScene: 'meeting',
          workspaceId: 'workspace-1',
          recordingSource: 'meeting',
          stage: UploadDraftStage.tokenFailed,
          updatedAt: _time(),
          uploadTokenKey: legacyTokenKey,
          completeUploadKey: 'idem-complete-draft-local-1-aaaaaaaaaaaa',
          createRecordingKey:
              'idem-create-recording-draft-local-1-aaaaaaaaaaaa',
          contentHash: _hash,
          lastErrorCode: 'UPLOAD_MIME_UNSUPPORTED',
        );
        final store = UploadDraftStore(database: database);
        store.saveDraft(legacyDraft);
        final transport = _RecordingUploadApiTransport();
        final controller = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
        );

        final recovered = await controller.recoverDrafts();

        expect(recovered.single.recording.recordingId, 'rec-1');
        final tokenRequest = transport.requests.firstWhere(
          (request) => request.url.path == '/api/v1/media/upload-token',
        );
        expect(
          tokenRequest.headers['X-Idempotency-Key'],
          isNot(legacyTokenKey),
        );
        expect(_body(tokenRequest)['sourceScene'], 'raw_material');
        expect(_body(tokenRequest)['mimeType'], 'audio/wav');
        expect(_body(tokenRequest)['workspaceId'], 'workspace-1');
        expect(
          store.getDraft(legacyDraft.draftId)?.sourceScene,
          'raw_material',
        );
        expect(store.getDraft(legacyDraft.draftId)?.workspaceId, 'workspace-1');
        final recordingRequest = transport.requests.singleWhere(
          (request) => request.url.path == '/api/v1/recordings',
        );
        expect(_body(recordingRequest)['source'], 'meeting');
      },
    );

    test(
      'recovery waits for the draft frozen workspace before retrying',
      () async {
        final database = AppDatabase();
        _seedItem(database);
        var activeWorkspaceId = 'workspace-a';
        final transport = _RecordingUploadApiTransport();
        final firstController = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(fail: true),
          workspaceIdProvider: () => activeWorkspaceId,
        );

        expect(
          await firstController.uploadLocalRecording(item: _item()),
          isNull,
        );
        final firstToken = transport.requests.singleWhere(
          (request) => request.url.path == '/api/v1/media/upload-token',
        );
        final frozenKey = firstToken.headers['X-Idempotency-Key'];
        expect(_body(firstToken)['workspaceId'], 'workspace-a');

        activeWorkspaceId = 'workspace-b';
        final recoveryController = _controller(
          database: database,
          apiTransport: transport,
          objectTransport: _ObjectTransport(),
          workspaceIdProvider: () => activeWorkspaceId,
        );

        final skipped = await recoveryController.recoverDrafts();

        final tokenRequests = transport.requests
            .where(
              (request) => request.url.path == '/api/v1/media/upload-token',
            )
            .toList();
        expect(skipped, isEmpty);
        expect(tokenRequests, hasLength(1));
        expect(
          tokenRequests.map((request) => _body(request)['workspaceId']),
          everyElement('workspace-a'),
        );
        expect(
          tokenRequests.map((request) => request.headers['X-Idempotency-Key']),
          everyElement(frozenKey),
        );
        expect(
          UploadDraftStore(database: database).getDraft('draft-local-1')?.stage,
          UploadDraftStage.objectUploadFailed,
        );

        activeWorkspaceId = 'workspace-a';
        final resumed = await recoveryController.recoverDrafts();

        expect(resumed.single.recording.recordingId, 'rec-1');
        final resumedTokenRequests = transport.requests
            .where(
              (request) => request.url.path == '/api/v1/media/upload-token',
            )
            .toList();
        expect(resumedTokenRequests, hasLength(2));
        expect(
          resumedTokenRequests.map((request) => _body(request)['workspaceId']),
          everyElement('workspace-a'),
        );
        expect(
          UploadDraftStore(database: database).getDraft('draft-local-1')?.stage,
          UploadDraftStage.asrQueued,
        );
      },
    );
  });
}

RecordingUploadController _controller({
  AppDatabase? database,
  required ApiTransport apiTransport,
  required ObjectUploadTransport objectTransport,
  FileStoragePort? fileStorage,
  DiagnosticLogger? diagnosticLogger,
  String? workspaceId = 'workspace-1',
  String? Function()? workspaceIdProvider,
  String? accountScope,
  String? Function()? activeAccountScope,
  RecordingProcessingPort? processingPort,
  LocalRecordingDeletionLedgerPort? deletionLedger,
  LocalRecordingRepository? localRecordingRepository,
  Duration localPreparationTimeout = const Duration(minutes: 2),
}) {
  final db = database ?? AppDatabase();
  final apiClient = ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token-ok',
    ),
    transport: apiTransport,
  );
  final repository =
      localRecordingRepository ??
      LocalRecordingRepository(
        database: db,
        fileStorage: fileStorage ?? const UnavailableFileStoragePort(),
        accountScope: accountScope,
        deletionLedger: deletionLedger,
      );
  return RecordingUploadController(
    uploadClient: UploadClient(
      apiClient: apiClient,
      objectTransport: objectTransport,
    ),
    draftStore: UploadDraftStore(database: db, accountScope: accountScope),
    recordingApi: RecordingApi(apiClient: apiClient),
    localRecordingRepository: repository,
    diagnosticLogger: diagnosticLogger,
    activeWorkspaceId: workspaceIdProvider ?? () => workspaceId,
    accountScope: accountScope,
    activeAccountScope: activeAccountScope,
    now: _time,
    processingPort: processingPort,
    localPreparationTimeout: localPreparationTimeout,
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

void _seedItem(
  AppDatabase database, {
  RecordingLibraryItem? item,
  String? accountScope,
}) {
  final effectiveItem = item ?? _item();
  RecordingDao(
    database,
    userScope: accountScope,
  ).upsertLocalRecording(effectiveItem.recordingId, effectiveItem.toRecord());
}

RecordingLibraryItem _item({
  String? contentHash = _hash,
  RecordingLibraryFormat format = RecordingLibraryFormat.m4a,
  String? displayName,
}) {
  final extension = format == RecordingLibraryFormat.wav ? 'wav' : 'm4a';
  return RecordingLibraryItem(
    recordingId: 'local-1',
    source: RecordingLibrarySource.localImport,
    displayName: displayName ?? 'Meeting.$extension',
    format: format,
    localFileState: RecordingLocalFileState.ready,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: 90,
    sizeBytes: 2048,
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: _time(),
    updatedAt: _time(),
    appPrivateUri: 'app-private://recordings/local-1/source.$extension',
    contentHash: contentHash,
  );
}

RecordingPrivateAudioInput _privateInput(
  String suffix, {
  String contentHash = _hash,
}) {
  return RecordingPrivateAudioInput(
    jobId: 'draft-concurrent-$suffix',
    localFileId: 'private-$suffix',
    appPrivateUri: 'app-private-media://screen-capture/concurrent-$suffix.m4a',
    fileName: 'concurrent-$suffix.m4a',
    mimeType: 'audio/mp4',
    sizeBytes: 2048,
    durationSeconds: 90,
    contentHash: contentHash,
    recordedAt: _time(),
    title: 'Concurrent $suffix',
  );
}

UploadDraft _importedDraft({String? workspaceId}) => createInitialUploadDraft(
  draftId: 'draft-local-1',
  localRecordingId: 'local-1',
  appPrivateUri: 'app-private://recordings/local-1/source.m4a',
  fileName: 'Meeting.m4a',
  mimeType: 'audio/mp4',
  sizeBytes: 2048,
  durationSeconds: 90,
  sourceScene: 'raw_material',
  recordingSource: 'local_upload',
  updatedAt: _time(),
  workspaceId: workspaceId,
  contentHash: _hash,
  title: 'Meeting.m4a',
);

UploadDraft _processingDraft({String workspaceId = 'workspace-1'}) =>
    createInitialUploadDraft(
      draftId: 'draft-local-1',
      localRecordingId: 'local-1',
      appPrivateUri: 'app-private://recordings/local-1/source.m4a',
      fileName: 'Meeting.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 2048,
      durationSeconds: 90,
      sourceScene: 'raw_material',
      recordingSource: 'recording_card',
      updatedAt: _time(),
      workspaceId: workspaceId,
      contentHash: _hash,
      recordedAt: _time(),
      title: 'Meeting.m4a',
    ).copyWith(
      stage: UploadDraftStage.asrQueued,
      recordingId: 'rec-1',
      asrTaskId: 'asr-1',
      updatedAt: _time(),
    );

final class _HashingFileStorage extends UnavailableFileStoragePort {
  const _HashingFileStorage();

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<String>.success(_hash);
  }
}

final class _PendingHashFileStorage extends UnavailableFileStoragePort {
  @override
  Future<FileStorageResult<String>> hashPrivateAudio(String appPrivateUri) =>
      Completer<FileStorageResult<String>>().future;
}

final class _ControlledHashFileStorage extends UnavailableFileStoragePort {
  final hashStarted = Completer<void>();
  final _hashResult = Completer<FileStorageResult<String>>();

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(String appPrivateUri) {
    if (!hashStarted.isCompleted) hashStarted.complete();
    return _hashResult.future;
  }

  void completeHash(String hash) {
    if (!_hashResult.isCompleted) {
      _hashResult.complete(FileStorageResult<String>.success(hash));
    }
  }
}

final class _UploadBlockedDeletionLedger
    implements LocalRecordingDeletionLedgerPort {
  const _UploadBlockedDeletionLedger();

  @override
  Iterable<String> deletionInProgressLocalRecordingIds() => const <String>[];

  @override
  bool canStartUpload(String localRecordingId) => false;

  @override
  bool beginLocalDeletion(String localRecordingId, DateTime at) => false;

  @override
  void finishLocalDeletion(String localRecordingId, DateTime at) {}

  @override
  void restoreLocalDeletion(String localRecordingId, DateTime at) {}
}

DateTime _time() => DateTime.utc(2026, 7, 1, 9);

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final class _RecordingProcessingPort implements RecordingProcessingPort {
  final tracked = <UploadDraft>[];

  @override
  Future<void> track(UploadDraft draft) async {
    tracked.add(draft);
  }
}

final class _RecordingUploadApiTransport implements ApiTransport {
  _RecordingUploadApiTransport({
    this.onRequest,
    this.omitAsrTaskObject = false,
  });

  final paths = <String>[];
  final requests = <ApiTransportRequest>[];
  final void Function(ApiTransportRequest request)? onRequest;
  final bool omitAsrTaskObject;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    paths.add(request.url.path);
    requests.add(request);
    onRequest?.call(request);
    if (request.url.path == '/api/v1/media/upload-token') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'uploadId': 'upload-1',
            'uploadUrl': 'https://upload.example.test/object/upload-1?sig=ok',
            'method': 'PUT',
            'headers': <String, Object?>{'x-upload': 'ok'},
          },
        },
      );
    }
    if (request.url.path == '/api/v1/media/uploads/upload-1/complete') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'status': 'completed',
            'uploadId': 'upload-1',
            'resourceId': 'resource-1',
          },
        },
      );
    }
    if (request.url.path == '/api/v1/recordings') {
      return ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'recording': <String, Object?>{
              'recordingId': 'rec-1',
              'title': 'Meeting.m4a',
              'status': 'processing',
              'asrTaskId': 'asr-1',
            },
            if (!omitAsrTaskObject)
              'asrTask': <String, Object?>{
                'asrTaskId': 'asr-1',
                'status': 'queued',
              },
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

final class _ObjectTransport implements ObjectUploadTransport {
  _ObjectTransport({this.fail = false});

  final bool fail;
  final requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    requests.add(request);
    if (fail) {
      return ObjectUploadResult.failure(
        const AppFailure(
          code: 'UPLOAD_OBJECT_FAILED',
          category: AppFailureCategory.network,
          message: 'failed',
          userMessageKey: 'recording.upload.objectFailed',
          isRetryable: true,
        ),
      );
    }
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}

final class _ControlledConcurrentObjectTransport
    implements ObjectUploadTransport {
  final Map<String, ObjectUploadRequest> _requests =
      <String, ObjectUploadRequest>{};
  final Map<String, Completer<void>> _started = <String, Completer<void>>{};
  final Map<String, Completer<ObjectUploadResult>> _results =
      <String, Completer<ObjectUploadResult>>{};

  Future<void> waitUntilStarted(String appPrivateUri) =>
      _started.putIfAbsent(appPrivateUri, Completer<void>.new).future;

  void reportProgress(String appPrivateUri, int bytesSent) {
    final request = _requests[appPrivateUri];
    if (request == null) {
      throw StateError('Upload has not started: $appPrivateUri');
    }
    request.onProgress?.call(bytesSent, request.sizeBytes);
  }

  void complete(String appPrivateUri) {
    final request = _requests[appPrivateUri];
    final result = _results[appPrivateUri];
    if (request == null || result == null || result.isCompleted) {
      throw StateError('Upload is not pending: $appPrivateUri');
    }
    result.complete(
      ObjectUploadResult.success(statusCode: 200, bytesSent: request.sizeBytes),
    );
  }

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    _requests[request.appPrivateUri] = request;
    final result = _results.putIfAbsent(
      request.appPrivateUri,
      Completer<ObjectUploadResult>.new,
    );
    final started = _started.putIfAbsent(
      request.appPrivateUri,
      Completer<void>.new,
    );
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}
