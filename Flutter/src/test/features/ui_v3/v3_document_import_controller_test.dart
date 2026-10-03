import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_document_import_page.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/document_import_format.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/v3_document_import_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/document_import_progress.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_activity_models.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_document_import_store.dart';

void main() {
  _checkpointCases();
  _importLifecycleCases();
  test(
    'digital twin material reuses worker ingestion and preserves lineage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-twin-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/meeting.md');
      await source.writeAsString('# Meeting evidence');
      final transport = _SequenceApiTransport([
        _response({
          'uploadId': 'upload_1',
          'resourceId': 'resource_1',
          'uploadUrl': 'https://objects.example.test/upload_1',
          'method': 'PUT',
        }),
        _response({
          'uploadId': 'upload_1',
          'resourceId': 'resource_1',
          'digitalTwinDistillation': {
            'taskId': 'distill_1',
            'resourceId': 'resource_1',
            'ingestionId': 'ingestion_1',
            'state': 'queued',
            'proposalIds': <String>[],
          },
        }),
        _response({
          'ingestion': {'ingestionId': 'ingestion_1', 'status': 'ready'},
        }),
        _response({
          'ingestion': {
            'ingestionId': 'ingestion_1',
            'status': 'promoted',
            'promotedNoteId': 'note_1',
          },
        }),
      ]);
      final result =
          await RemoteDocumentAnalysisPort(
            apiClient: ApiClient(
              config: ApiClientConfig(
                baseUrl: Uri.parse('https://api.example.test'),
                clientVersion: 'test',
                deviceId: 'test-device',
                platform: 'test',
                locale: 'zh-CN',
                getAccessToken: () => 'token',
              ),
              transport: transport,
            ),
            workspaceId: () => 'workspace_1',
            objectUploadTransport: const _SuccessfulObjectUploadTransport(),
            delay: (_) async {},
          ).analyze(
            task: V3DocumentImportTask(
              id: 'import-1',
              pickerRef: 'picked-document://meeting',
              displayName: 'meeting.md',
              mimeType: 'text/markdown',
              sizeBytes: await source.length(),
              sha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              privateFileName: 'meeting.md',
              status: V3DocumentImportTaskStatus.staged,
              attemptCount: 0,
              createdAt: DateTime.utc(2026, 9, 5),
              updatedAt: DateTime.utc(2026, 9, 5),
            ),
            privateFile: source,
            distillToDigitalTwin: true,
          );
      expect(result.ok, isTrue, reason: result.error?.code);
      expect(result.value?.remoteNoteId, 'note_1');
      expect(result.value?.distillation?.taskId, 'distill_1');
      expect(result.value?.distillation?.resourceId, 'resource_1');
      expect(
        jsonDecode(transport.requests.first.body!)['distillToDigitalTwin'],
        isTrue,
      );
      expect(
        transport.requests.skip(2).map((request) => request.method),
        everyElement('GET'),
      );
      expect(
        transport.requests.skip(2).map((request) => request.url.path),
        everyElement(
          '/api/v1/workspaces/workspace_1/note-ingestions/ingestion_1',
        ),
      );
    },
  );

  test(
    'deferred distillation imports a canonical Note without automatic remote distillation',
    () async {
      final directory = await Directory.systemTemp.createTemp('huahuo-import-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('A customer needs a verifiable pilot.');
      final remote = _remoteNote(
        id: 'note-brief',
        title: 'brief.md',
        body: 'A customer needs a verifiable pilot.',
      );
      final library = _remoteLibrary(remote);
      final analysis = _CountingDocumentAnalysisPort('note-brief');
      final queuedNotes = <String>[];
      final importStore = _store(AppDatabase(), directory);
      final profileHub = ProfileHubController(
        referenceDay: DateTime.utc(2026, 7, 13),
      );
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[
              PickedDocumentFile(
                pickerRef: 'picked-document://brief',
                displayName: 'brief.md',
                mimeType: 'text/markdown',
                sizeBytes: await source.length(),
                sourcePath: source.path,
              ),
            ],
          ),
        ),
        knowledgeLibrary: library,
        profileHub: profileHub,
        store: importStore,
        analysisPort: analysis,
        onDistillationNoteReady: (note) async {
          queuedNotes.add(note.remoteNoteId!);
          return true;
        },
      );

      final picked = await controller.pickDocuments();
      expect(picked.ok, isTrue, reason: controller.state.lastErrorCode);
      expect(controller.state.status, V3DocumentImportStatus.ready);
      final imported = await controller.importSelected(
        distillToDigitalTwin: true,
        deferDigitalTwinDistillation: true,
      );
      expect(analysis.receivedDistillation, isFalse);
      expect(queuedNotes, ['note-brief']);
      expect(
        importStore.listTasks().single.deferDigitalTwinDistillation,
        isTrue,
      );

      expect(
        controller.state.status,
        V3DocumentImportStatus.completed,
        reason: controller.state.lastErrorCode,
      );
      expect(imported, hasLength(1));
      expect(
        library.noteForId(imported.single.id)?.rawBody,
        'A customer needs a verifiable pilot.',
      );
      expect(imported.single.id, 'note-brief');
      expect(imported.single.source, V3MaterialSource.documentImport);
      expect(
        profileHub.activities.any(
          (activity) =>
              activity.feedItemId == imported.single.id &&
              activity.type == V3ProfileActivityType.upload,
        ),
        isTrue,
      );
    },
  );

  test(
    'promoted document waits until the canonical Note projection is visible',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-late-projection-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/late.md');
      await source.writeAsString('Canonical content arrives after promotion.');
      final remote = _remoteNote(
        id: 'note-late',
        title: 'late.md',
        body: 'Canonical content arrives after promotion.',
      );
      final notePort = _RemoteListNotePort.sequence(<List<V3FeedItem>>[
        const <V3FeedItem>[],
        const <V3FeedItem>[],
        <V3FeedItem>[remote],
      ]);
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        notePort: notePort,
      );
      await library.restore();
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[_picked(source, 'late.md', 'text/markdown')],
          ),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: _store(AppDatabase(), directory),
        analysisPort: const _FakeDocumentAnalysisPort('note-late'),
        projectionMaxAttempts: 3,
        projectionPollInterval: Duration.zero,
        projectionDelay: (_) async {},
      );

      await controller.pickDocuments();
      final imported = await controller.importSelected();

      expect(
        controller.state.status,
        V3DocumentImportStatus.completed,
        reason: controller.state.lastErrorCode,
      );
      expect(imported.map((note) => note.id), <String>['note-late']);
      expect(notePort.loadCalls, 3);
      expect(
        library.noteForId('note-late')?.rawBody,
        'Canonical content arrives after promotion.',
      );
    },
  );

  test(
    'projection retry reuses the promoted Note without reanalysis',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-projection-retry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/retry.md');
      await source.writeAsString('A promoted Note must not be promoted twice.');
      final remote = _remoteNote(
        id: 'note-retry',
        title: 'retry.md',
        body: 'A promoted Note must not be promoted twice.',
      );
      final notePort = _RemoteListNotePort.sequence(<List<V3FeedItem>>[
        const <V3FeedItem>[],
        <V3FeedItem>[remote],
      ]);
      final analysis = _CountingDocumentAnalysisPort('note-retry');
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[_picked(source, 'retry.md', 'text/markdown')],
          ),
        ),
        knowledgeLibrary: KnowledgeLibraryController(
          initialNotes: const <V3FeedItem>[],
          includeDemoFixtures: false,
          notePort: notePort,
        ),
        profileHub: ProfileHubController(),
        store: _store(AppDatabase(), directory),
        analysisPort: analysis,
        projectionMaxAttempts: 1,
        projectionPollInterval: Duration.zero,
        projectionDelay: (_) async {},
      );

      await controller.pickDocuments();
      final first = await controller.importSelected();
      final retried = await controller.retryFailed();

      expect(first, isEmpty);
      expect(controller.state.status, V3DocumentImportStatus.completed);
      expect(retried.map((note) => note.id), <String>['note-retry']);
      expect(analysis.calls, 1);
      expect(notePort.loadCalls, 2);
    },
  );

  test(
    'selecting an already promoted document rehydrates its existing Note',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-existing-note-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('A durable import.');
      final store = _store(AppDatabase(), directory);
      final staged = await store.stage(
        _picked(source, 'brief.md', 'text/markdown'),
      );
      expect(staged.ok, isTrue, reason: staged.error?.code);
      store.save(
        staged.value!.copyWith(
          status: V3DocumentImportTaskStatus.completed,
          noteId: 'note-existing',
          remoteNoteId: 'note-existing',
          rawAssetCreated: true,
          updatedAt: DateTime.utc(2026, 8, 15),
        ),
      );
      final remote = _remoteNote(
        id: 'note-existing',
        title: 'brief.md',
        body: 'A durable import.',
      );
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[_picked(source, 'brief.md', 'text/markdown')],
          ),
        ),
        knowledgeLibrary: _remoteLibrary(remote),
        profileHub: ProfileHubController(),
        store: store,
      );

      final picked = await controller.pickDocuments();
      final imported = await controller.importSelected();

      expect(picked.ok, isTrue, reason: controller.state.lastErrorCode);
      expect(controller.state.status, V3DocumentImportStatus.completed);
      expect(controller.state.importedCount, 1);
      expect(imported.map((note) => note.id), <String>['note-existing']);
      expect(store.listTasks().single.attemptCount, 0);
    },
  );

  test('cancelling selection creates no memory note', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-import-cancel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final library = KnowledgeLibraryController();
    final controller = V3DocumentImportController(
      nativeFilePort: _FakeNativeFilePort(
        NativeFileResult<List<PickedDocumentFile>>.failure(
          const AppFailure(
            code: 'DOCUMENT_PICKER_CANCELLED',
            category: AppFailureCategory.storage,
            message: 'cancelled',
            userMessageKey: 'document.cancelled',
          ),
        ),
      ),
      knowledgeLibrary: library,
      profileHub: ProfileHubController(),
      store: _store(AppDatabase(), directory),
    );
    final before = library.mineNotes.length;

    final result = await controller.pickDocuments();

    expect(result.ok, isFalse);
    expect(controller.state.status, V3DocumentImportStatus.idle);
    expect(library.mineNotes, hasLength(before));
  });

  test('an unresolved picker stays idle and opens only once', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-import-pending-picker-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final picker = _DeferredDocumentPicker();
    final controller = V3DocumentImportController(
      nativeFilePort: picker,
      knowledgeLibrary: KnowledgeLibraryController(),
      profileHub: ProfileHubController(),
      store: _store(AppDatabase(), directory),
    );

    final first = controller.pickDocuments();
    await Future<void>.delayed(Duration.zero);
    final second = controller.pickDocuments();

    expect(controller.state.status, V3DocumentImportStatus.idle);
    expect(picker.calls, 1);

    picker.complete(NativeFileResult<List<PickedDocumentFile>>.cancelled());
    expect((await first).cancelled, isTrue);
    expect((await second).cancelled, isTrue);
    expect(controller.state.status, V3DocumentImportStatus.idle);
  });

  test('forced exact recovery supersedes a pending picker result', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-import-picker-superseded-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final oldSource = File('${directory.path}/old.md');
    final exactSource = File('${directory.path}/exact.md');
    await oldSource.writeAsString('# Old picker result');
    await exactSource.writeAsString('# Exact recovery');
    final picker = _DeferredDocumentPicker();
    final store = _store(AppDatabase(), directory);
    final exactTask = (await store.stage(
      _picked(exactSource, 'exact.md', 'text/markdown'),
    )).value!;
    store.save(exactTask.copyWith(acceptedForImport: true));
    final controller = V3DocumentImportController(
      nativeFilePort: picker,
      knowledgeLibrary: KnowledgeLibraryController(),
      profileHub: ProfileHubController(),
      store: store,
    );

    final pendingPick = controller.pickDocuments();
    await Future<void>.delayed(Duration.zero);
    expect(
      await controller.recoverPending(force: true, taskId: exactTask.id),
      V3DocumentRecoveryOutcome.restored,
    );
    picker.complete(
      NativeFileResult<List<PickedDocumentFile>>.success(<PickedDocumentFile>[
        _picked(oldSource, 'old.md', 'text/markdown'),
      ]),
    );

    expect((await pendingPick).cancelled, isTrue);
    expect(controller.state.durableTasks.single.id, exactTask.id);
    expect(controller.state.selectedDocuments.single.displayName, 'exact.md');
  });

  test('terminal document failure does not advertise retry', () {
    final task = V3DocumentImportTask(
      id: 'document-terminal',
      pickerRef: 'picked-document://terminal.xlsx',
      displayName: 'terminal.xlsx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      sizeBytes: 2048,
      sha256: List<String>.filled(64, 'a').join(),
      privateFileName: '${List<String>.filled(64, 'a').join()}.xlsx',
      status: V3DocumentImportTaskStatus.failed,
      attemptCount: 1,
      createdAt: DateTime.utc(2026, 9, 2),
      updatedAt: DateTime.utc(2026, 9, 2),
      lastErrorCode: 'NOTE_INGESTION_UNSUPPORTED',
    );
    final state = V3DocumentImportState(
      status: V3DocumentImportStatus.failed,
      durableTasks: <V3DocumentImportTask>[task],
      lastErrorCode: task.lastErrorCode,
    );

    expect(state.hasRetryableTasks, isFalse);
    expect(state.canRetryFailure, isFalse);
    expect(state.isTerminalFailure, isTrue);
  });

  test('an empty selection remains a neutral cancellation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-import-empty-picker-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final library = KnowledgeLibraryController();
    final controller = V3DocumentImportController(
      nativeFilePort: _FakeNativeFilePort(
        NativeFileResult<List<PickedDocumentFile>>.failure(
          const AppFailure(
            code: 'DOCUMENT_PICKER_EMPTY',
            category: AppFailureCategory.storage,
            message: 'empty picker result',
            userMessageKey: 'document.empty',
          ),
        ),
      ),
      knowledgeLibrary: library,
      profileHub: ProfileHubController(),
      store: _store(AppDatabase(), directory),
    );
    final before = library.mineNotes.length;

    final result = await controller.pickDocuments();

    expect(result.ok, isFalse);
    expect(controller.state.status, V3DocumentImportStatus.idle);
    expect(controller.state.lastErrorCode, isNull);
    expect(controller.state.durableTasks, isEmpty);
    expect(library.mineNotes, hasLength(before));
  });

  test(
    'a successful picker call with no files remains a neutral cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-empty-list-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final library = KnowledgeLibraryController();
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            const <PickedDocumentFile>[],
          ),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: _store(AppDatabase(), directory),
      );
      final before = library.mineNotes.length;

      final result = await controller.pickDocuments();

      expect(result.ok, isTrue);
      expect(controller.state.status, V3DocumentImportStatus.idle);
      expect(controller.state.lastErrorCode, isNull);
      expect(controller.state.durableTasks, isEmpty);
      expect(library.mineNotes, hasLength(before));
    },
  );

  test(
    'mixed file types are rejected before a Markdown import is staged',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-md-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final markdown = File('${directory.path}/brief.md');
      final audio = File('${directory.path}/voice.wav');
      await markdown.writeAsString('# Pilot\n\nVerifiable result.');
      await audio.writeAsBytes(<int>[0x52, 0x49, 0x46, 0x46]);
      final library = KnowledgeLibraryController();
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[
              PickedDocumentFile(
                pickerRef: 'picked-document://brief-md',
                displayName: 'brief.md',
                mimeType: 'text/markdown',
                sizeBytes: await markdown.length(),
                sourcePath: markdown.path,
              ),
              PickedDocumentFile(
                pickerRef: 'picked-document://voice',
                displayName: 'voice.wav',
                mimeType: 'audio/wav',
                sizeBytes: await audio.length(),
                sourcePath: audio.path,
              ),
            ],
          ),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: _store(AppDatabase(), directory),
      );
      final before = library.mineNotes.length;

      final selected = await controller.pickDocuments();
      expect(selected.ok, isFalse);
      expect(
        controller.state.lastErrorCode,
        'DOCUMENT_IMPORT_TYPE_UNSUPPORTED',
      );
      expect(controller.state.durableTasks, isEmpty);
      expect(library.mineNotes.length, before);
    },
  );

  test(
    'stages all eight Note formats even when picker MIME is generic',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-formats-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final documents = <PickedDocumentFile>[];
      for (final format in DocumentImportFormat.values) {
        final file = File('${directory.path}/brief.${format.extension}');
        await file.writeAsString('verified-${format.extension}');
        documents.add(
          _picked(file, file.uri.pathSegments.last, 'application/octet-stream'),
        );
      }
      final library = KnowledgeLibraryController();
      final store = _store(AppDatabase(), directory);
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(documents),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: store,
      );

      final picked = await controller.pickDocuments();

      expect(picked.ok, isTrue, reason: controller.state.lastErrorCode);
      expect(controller.state.status, V3DocumentImportStatus.ready);
      expect(store.listTasks(), hasLength(DocumentImportFormat.values.length));
      expect(
        store.listTasks().map((task) => task.mimeType),
        containsAll(
          DocumentImportFormat.values.map((format) => format.mimeType),
        ),
      );
    },
  );

  test(
    'recreated controller restores only an accepted staged text file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-import-recover-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/recover.md');
      await source.writeAsString('# Recovered\n\nDurable body.');
      final database = AppDatabase();
      final store = _store(database, directory);
      final staged = await store.stage(
        _picked(source, 'recover.md', 'text/markdown'),
      );
      expect(staged.ok, isTrue, reason: staged.error?.code);
      final library = KnowledgeLibraryController();
      final before = library.mineNotes.length;
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(const []),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: _store(database, directory),
      );

      await controller.recoverPending();
      await controller.recoverPending();

      expect(controller.state.status, V3DocumentImportStatus.idle);
      expect(library.mineNotes, hasLength(before));
      expect(store.listTasks().single.isCompleted, isFalse);
      expect(store.listTasks().single.acceptedForImport, isFalse);
      await controller.recoverPending(force: true, taskId: staged.value!.id);
      expect(controller.state.status, V3DocumentImportStatus.idle);

      store.save(
        store.listTasks().single.copyWith(
          acceptedForImport: true,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      await controller.recoverPending(force: true, taskId: staged.value!.id);
      expect(controller.state.status, V3DocumentImportStatus.ready);
      expect(controller.state.durableTasks.single.id, staged.value!.id);

      await controller.recoverPending(force: true, taskId: 'missing-task');
      expect(controller.state.status, V3DocumentImportStatus.idle);
      await controller.recoverPending(force: true, taskId: staged.value!.id);

      final lateRecovery = controller.recoverPending(force: true);
      expect(await controller.beginFreshSession(), isTrue);
      await lateRecovery;
      expect(controller.state.status, V3DocumentImportStatus.idle);
      expect(controller.state.selectedDocuments, isEmpty);
      await controller.recoverPending();
      expect(controller.state.status, V3DocumentImportStatus.idle);
      await controller.recoverPending(force: true);
      expect(controller.state.status, V3DocumentImportStatus.ready);
      final restored = await store.resolveVerifiedFile(
        store.listTasks().single,
      );
      expect(restored.ok, isTrue, reason: restored.error?.code);
    },
  );

  test('remote analysis promotes raw Markdown before outline admission', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-remote-import-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/brief.md');
    await source.writeAsString('A durable import.');
    final transport = _SequenceApiTransport(<ApiTransportResponse>[
      _response(<String, Object?>{
        'uploadId': 'upload_1',
        'resourceId': 'resource_1',
        'uploadUrl': 'https://objects.example.test/upload_1',
        'method': 'PUT',
        'headers': <String, Object?>{},
      }),
      _response(<String, Object?>{
        'status': 'completed',
        'uploadId': 'upload_1',
        'resource': <String, Object?>{'resourceId': 'resource_1'},
      }),
      _response(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion_1',
          'status': 'ready_to_promote',
        },
      }, status: 202),
      _response(<String, Object?>{
        'note': <String, Object?>{'noteId': 'note_1'},
      }, status: 202),
    ]);
    final apiClient = ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: 'test',
        deviceId: 'device-test',
        platform: 'test',
        locale: 'zh-CN',
        getAccessToken: () => 'access-token',
      ),
      transport: transport,
    );
    final result =
        await RemoteDocumentAnalysisPort(
          apiClient: apiClient,
          workspaceId: () => 'workspace_1',
          objectUploadTransport: const _SuccessfulObjectUploadTransport(),
          delay: (_) async {},
        ).analyze(
          task: V3DocumentImportTask(
            id: 'document-remote-test',
            pickerRef: 'picked-document://remote',
            displayName: 'brief.md',
            mimeType: 'text/markdown',
            sizeBytes: await source.length(),
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            privateFileName:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md',
            status: V3DocumentImportTaskStatus.staged,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 8, 8),
            updatedAt: DateTime.utc(2026, 8, 8),
          ),
          privateFile: source,
        );

    expect(result.ok, isTrue, reason: result.error?.code);
    expect(result.value?.remoteNoteId, 'note_1');
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/media/upload-token',
      '/api/v1/media/uploads/upload_1/complete',
      '/api/v1/workspaces/workspace_1/note-ingestions',
      '/api/v1/workspaces/workspace_1/note-ingestions/ingestion_1/promote',
    ]);
    expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
      'resourceId': 'resource_1',
    });
    expect(result.value?.outlineMarkdown, isNull);
  });

  test('remote analysis tolerates a retryable ingestion status read', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-remote-import-transient-poll-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/brief.md');
    await source.writeAsString('A durable import.');
    final transport = _SequenceApiTransport(<ApiTransportResponse>[
      _response(<String, Object?>{
        'uploadId': 'upload_transient',
        'resourceId': 'resource_transient',
        'uploadUrl': 'https://objects.example.test/upload_transient',
        'method': 'PUT',
        'headers': <String, Object?>{},
      }),
      _response(<String, Object?>{
        'status': 'completed',
        'uploadId': 'upload_transient',
        'resource': <String, Object?>{'resourceId': 'resource_transient'},
      }),
      _response(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion_transient',
          'status': 'queued',
        },
      }, status: 202),
      _errorResponse('NETWORK_REQUEST_FAILED', retryable: true),
      _response(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion_transient',
          'status': 'ready_to_promote',
        },
      }),
      _response(<String, Object?>{
        'note': <String, Object?>{'noteId': 'note_transient'},
      }, status: 202),
    ]);

    final result =
        await RemoteDocumentAnalysisPort(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace_1',
          objectUploadTransport: const _SuccessfulObjectUploadTransport(),
          delay: (_) async {},
          maxPollAttempts: 4,
        ).analyze(
          task: V3DocumentImportTask(
            id: 'document-transient-test',
            pickerRef: 'picked-document://transient',
            displayName: 'brief.md',
            mimeType: 'text/markdown',
            sizeBytes: await source.length(),
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            privateFileName:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md',
            status: V3DocumentImportTaskStatus.staged,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 8, 28),
            updatedAt: DateTime.utc(2026, 8, 28),
          ),
          privateFile: source,
        );

    expect(result.ok, isTrue, reason: result.error?.code);
    expect(result.value?.remoteNoteId, 'note_transient');
    expect(
      transport.requests
          .where((request) => request.url.path.endsWith('/ingestion_transient'))
          .length,
      2,
    );
  });

  test('remote ingestion rejects a Resource receipt mismatch', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-remote-resource-mismatch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/brief.pdf');
    await source.writeAsBytes(<int>[0x25, 0x50, 0x44, 0x46]);
    final transport = _SequenceApiTransport(<ApiTransportResponse>[
      _response(<String, Object?>{
        'uploadId': 'upload_pdf',
        'resourceId': 'resource_token_pdf',
        'uploadUrl': 'https://objects.example.test/upload_pdf',
        'method': 'PUT',
        'headers': <String, Object?>{},
      }),
      _response(<String, Object?>{
        'status': 'completed',
        'uploadId': 'upload_pdf',
        'resource': <String, Object?>{'resourceId': 'resource_other_pdf'},
      }),
    ]);

    final result =
        await RemoteDocumentAnalysisPort(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace_1',
          objectUploadTransport: const _SuccessfulObjectUploadTransport(),
          delay: (_) async {},
        ).analyze(
          task: V3DocumentImportTask(
            id: 'document-resource-mismatch',
            pickerRef: 'picked-document://resource-mismatch',
            displayName: 'brief.pdf',
            mimeType: 'application/pdf',
            sizeBytes: await source.length(),
            sha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            privateFileName:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pdf',
            status: V3DocumentImportTaskStatus.staged,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 8, 15),
            updatedAt: DateTime.utc(2026, 8, 15),
          ),
          privateFile: source,
        );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'DOCUMENT_UPLOAD_RESOURCE_MISMATCH');
    expect(transport.requests, hasLength(2));
  });

  test(
    'remote ingestion uploads the extension-derived MIME for every Note format',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-remote-format-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      for (final format in DocumentImportFormat.values) {
        final source = File('${directory.path}/brief.${format.extension}');
        await source.writeAsString('verified ${format.extension} bytes');
        final transport = _SequenceApiTransport(<ApiTransportResponse>[
          _response(<String, Object?>{
            'uploadId': 'upload_${format.extension}',
            'resourceId': 'resource_${format.extension}',
            'uploadUrl':
                'https://objects.example.test/upload_${format.extension}',
            'method': 'PUT',
            'headers': <String, Object?>{},
          }),
          _response(<String, Object?>{
            'status': 'completed',
            'uploadId': 'upload_${format.extension}',
            'resource': <String, Object?>{
              'resourceId': 'resource_${format.extension}',
            },
          }),
          _response(<String, Object?>{
            'ingestion': <String, Object?>{
              'ingestionId': 'ingestion_${format.extension}',
              'status': 'ready_to_promote',
            },
          }, status: 202),
          _response(<String, Object?>{
            'note': <String, Object?>{'noteId': 'note_${format.extension}'},
          }, status: 202),
        ]);

        final result =
            await RemoteDocumentAnalysisPort(
              apiClient: _apiClient(transport),
              workspaceId: () => 'workspace_1',
              objectUploadTransport: const _SuccessfulObjectUploadTransport(),
              delay: (_) async {},
            ).analyze(
              task: V3DocumentImportTask(
                id: 'document-${format.extension}-test',
                pickerRef: 'picked-document://${format.extension}',
                displayName: 'brief.${format.extension}',
                // A legacy task may contain a generic provider MIME. Upload still
                // obeys the verified private filename.
                mimeType: 'application/octet-stream',
                sizeBytes: await source.length(),
                sha256:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                privateFileName:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.${format.extension}',
                status: V3DocumentImportTaskStatus.staged,
                attemptCount: 0,
                createdAt: DateTime.utc(2026, 8, 8),
                updatedAt: DateTime.utc(2026, 8, 8),
              ),
              privateFile: source,
            );

        expect(
          result.ok,
          isTrue,
          reason: '${format.extension}: ${result.error?.code}',
        );
        final body =
            jsonDecode(transport.requests.first.body!) as Map<String, dynamic>;
        expect(body['mimeType'], format.mimeType);
        expect(result.value?.remoteNoteId, 'note_${format.extension}');
      }
    },
  );

  test(
    'unsupported server ingestion format is explicit and non-retryable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-remote-unsupported-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.xlsx');
      await source.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04]);
      final transport = _SequenceApiTransport(<ApiTransportResponse>[
        _response(<String, Object?>{
          'uploadId': 'upload_xlsx',
          'resourceId': 'resource_xlsx',
          'uploadUrl': 'https://objects.example.test/upload_xlsx',
          'method': 'PUT',
          'headers': <String, Object?>{},
        }),
        _response(<String, Object?>{
          'status': 'completed',
          'uploadId': 'upload_xlsx',
          'resource': <String, Object?>{'resourceId': 'resource_xlsx'},
        }),
        _response(<String, Object?>{
          'ingestion': <String, Object?>{
            'ingestionId': 'ingestion_xlsx',
            'status': 'failed',
            'failureCode': 'NOTE_INGESTION_UNSUPPORTED',
          },
        }, status: 202),
      ]);

      final result =
          await RemoteDocumentAnalysisPort(
            apiClient: _apiClient(transport),
            workspaceId: () => 'workspace_1',
            objectUploadTransport: const _SuccessfulObjectUploadTransport(),
            delay: (_) async {},
          ).analyze(
            task: V3DocumentImportTask(
              id: 'document-xlsx-test',
              pickerRef: 'picked-document://xlsx',
              displayName: 'brief.xlsx',
              mimeType: 'application/octet-stream',
              sizeBytes: await source.length(),
              sha256:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              privateFileName:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.xlsx',
              status: V3DocumentImportTaskStatus.staged,
              attemptCount: 0,
              createdAt: DateTime.utc(2026, 8, 8),
              updatedAt: DateTime.utc(2026, 8, 8),
            ),
            privateFile: source,
          );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'NOTE_INGESTION_UNSUPPORTED');
      expect(result.error?.isRetryable, isFalse);
      expect(result.error?.recoveryActions, <String>['none']);
    },
  );

  test('quarantined server ingestion is explicit and non-retryable', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-remote-quarantined-import-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/brief.pptx');
    await source.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04]);
    final transport = _SequenceApiTransport(<ApiTransportResponse>[
      _response(<String, Object?>{
        'uploadId': 'upload_pptx',
        'resourceId': 'resource_pptx',
        'uploadUrl': 'https://objects.example.test/upload_pptx',
        'method': 'PUT',
        'headers': <String, Object?>{},
      }),
      _response(<String, Object?>{
        'status': 'completed',
        'uploadId': 'upload_pptx',
        'resource': <String, Object?>{'resourceId': 'resource_pptx'},
      }),
      _response(<String, Object?>{
        'ingestion': <String, Object?>{
          'ingestionId': 'ingestion_pptx',
          'status': 'quarantined',
          'failureCode': 'NOTE_INGESTION_QUARANTINED',
        },
      }, status: 202),
    ]);

    final result =
        await RemoteDocumentAnalysisPort(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace_1',
          objectUploadTransport: const _SuccessfulObjectUploadTransport(),
          delay: (_) async {},
        ).analyze(
          task: V3DocumentImportTask(
            id: 'document-pptx-test',
            pickerRef: 'picked-document://pptx',
            displayName: 'brief.pptx',
            mimeType: 'application/octet-stream',
            sizeBytes: await source.length(),
            sha256:
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            privateFileName:
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.pptx',
            status: V3DocumentImportTaskStatus.staged,
            attemptCount: 0,
            createdAt: DateTime.utc(2026, 8, 15),
            updatedAt: DateTime.utc(2026, 8, 15),
          ),
          privateFile: source,
        );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'NOTE_INGESTION_QUARANTINED');
    expect(result.error?.isRetryable, isFalse);
    expect(result.error?.recoveryActions, <String>['none']);
    expect(
      _remoteDocumentTask(
        source: source,
        id: 'document-pptx-quarantined',
      ).copyWith(lastErrorCode: 'NOTE_INGESTION_QUARANTINED').isRetryable,
      isFalse,
    );
  });

  test(
    'promoted note analysis skips upload and promotion before outline admission',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-remote-retry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('A durable import.');
      final transport = _SequenceApiTransport(<ApiTransportResponse>[]);
      final apiClient = _apiClient(transport);

      final result =
          await RemoteDocumentAnalysisPort(
            apiClient: apiClient,
            workspaceId: () => 'workspace_1',
            objectUploadTransport: const _SuccessfulObjectUploadTransport(),
            delay: (_) async {},
          ).analyze(
            task: _remoteDocumentTask(
              source: source,
              id: 'document-retry-test',
              remoteNoteId: 'note_existing',
              attemptCount: 1,
            ),
            privateFile: source,
          );

      expect(result.ok, isTrue, reason: result.error?.code);
      expect(result.value?.remoteNoteId, 'note_existing');
      expect(result.value?.outlineMarkdown, isNull);
      final paths = transport.requests
          .map((request) => request.url.path)
          .toList();
      expect(paths, isEmpty);
      expect(
        paths.any(
          (path) =>
              path.startsWith('/api/v1/media/') ||
              path.contains('note-ingestions'),
        ),
        isFalse,
      );
    },
  );

  test(
    'completed raw asset stays outside import recovery after its private copy is gone',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-remote-controller-retry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('A durable import.');
      final store = _store(AppDatabase(), directory);
      final staged = await store.stage(
        _picked(source, 'brief.md', 'text/markdown'),
      );
      expect(staged.ok, isTrue, reason: staged.error?.code);
      final initial = staged.value!;
      final promoted = initial.copyWith(
        status: V3DocumentImportTaskStatus.completed,
        remoteNoteId: 'note_existing',
        rawAssetCreated: true,
        outlineStatus: V3DocumentOutlineStatus.failed,
        outlineErrorCode: 'NOTE_FILE_AGENT_POLL_FAILED',
        updatedAt: DateTime.utc(2026, 8, 9),
      );
      store.save(promoted);
      await (await store.resolveVerifiedFile(promoted)).value!.delete();
      final library = _remoteLibrary(
        _remoteNote(
          id: 'note_existing',
          title: 'brief.md',
          body: 'A durable import.',
        ),
      );
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(const []),
        ),
        knowledgeLibrary: library,
        profileHub: ProfileHubController(),
        store: store,
        analysisPort: const UnavailableDocumentAnalysisPort(),
      );

      await controller.recoverPending(force: true);

      expect(controller.state.status, V3DocumentImportStatus.idle);
      expect(controller.state.durableTasks, isEmpty);
      expect(store.listTasks().single.rawAssetCreated, isTrue);
      expect(
        store.listTasks().single.outlineStatus,
        V3DocumentOutlineStatus.failed,
      );
    },
  );

  test(
    'creates only a raw asset and does not submit an outline automatically',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-document-outline-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('Raw content stays available.');
      final remote = _remoteNote(
        id: 'note-outline-failure',
        title: 'brief.md',
        body: 'Raw content stays available.',
      );
      final store = _store(AppDatabase(), directory);
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult<List<PickedDocumentFile>>.success(
            <PickedDocumentFile>[_picked(source, 'brief.md', 'text/markdown')],
          ),
        ),
        knowledgeLibrary: _remoteLibrary(remote),
        profileHub: ProfileHubController(),
        store: store,
        analysisPort: _FailingOutlineAnalysisPort(remote.id),
      );

      await controller.pickDocuments();
      final imported = await controller.importSelected();

      expect(imported.single.id, remote.id);
      expect(controller.state.status, V3DocumentImportStatus.completed);
      final task = store.listTasks().single;
      expect(task.rawAssetCreated, isTrue);
      expect(task.outlineStatus, V3DocumentOutlineStatus.notStarted);
      expect(task.outlineFileAgentRunId, isNull);
    },
  );
}

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

V3DocumentImportTask _remoteDocumentTask({
  required File source,
  required String id,
  String? remoteNoteId,
  int attemptCount = 0,
}) => V3DocumentImportTask(
  id: id,
  pickerRef: 'picked-document://$id',
  displayName: 'brief.md',
  mimeType: 'text/markdown',
  sizeBytes: source.lengthSync(),
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  privateFileName:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md',
  status: V3DocumentImportTaskStatus.staged,
  attemptCount: attemptCount,
  createdAt: DateTime.utc(2026, 8, 8),
  updatedAt: DateTime.utc(2026, 8, 8),
  remoteNoteId: remoteNoteId,
);

V3DocumentImportStore _store(AppDatabase database, Directory root) =>
    V3DocumentImportStore(
      database: database,
      rootDirectory: () async => root,
      ownerScope: 'test-user',
    );

PickedDocumentFile _picked(File file, String name, String mimeType) =>
    PickedDocumentFile(
      pickerRef: 'picked-document://$name',
      displayName: name,
      mimeType: mimeType,
      sizeBytes: file.lengthSync(),
      sourcePath: file.path,
    );

KnowledgeLibraryController _remoteLibrary(V3FeedItem note) =>
    KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
      notePort: _RemoteListNotePort(<V3FeedItem>[note]),
    );

V3FeedItem _remoteNote({
  required String id,
  required String title,
  required String body,
}) => V3FeedItem(
  id: id,
  title: title,
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 8),
  updatedAt: DateTime.utc(2026, 8, 8),
  rawBody: body,
  remoteNoteId: id,
  noteRevisionId: '$id-revision',
  rawPartRevisionId: '$id-raw',
  etag: '"$id-v1"',
  contentCursor: 'cursor-$id',
);

final class _FakeDocumentAnalysisPort implements DocumentAnalysisPort {
  const _FakeDocumentAnalysisPort(this.noteId);

  final String noteId;

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async => NativeFileResult<DocumentAnalysisResult>.success(
    DocumentAnalysisResult(remoteNoteId: noteId),
  );
}

final class _CountingDocumentAnalysisPort implements DocumentAnalysisPort {
  _CountingDocumentAnalysisPort(this.noteId);

  final String noteId;
  var calls = 0;
  bool? receivedDistillation;

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async {
    calls += 1;
    receivedDistillation = distillToDigitalTwin;
    return NativeFileResult<DocumentAnalysisResult>.success(
      DocumentAnalysisResult(remoteNoteId: noteId),
    );
  }
}

final class _FailingOutlineAnalysisPort implements DocumentAnalysisPort {
  const _FailingOutlineAnalysisPort(this.noteId);

  final String noteId;

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async => NativeFileResult<DocumentAnalysisResult>.success(
    DocumentAnalysisResult(remoteNoteId: noteId),
  );
}

final class _RemoteListNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  _RemoteListNotePort(List<V3FeedItem> notes)
    : _pages = <List<V3FeedItem>>[notes];

  _RemoteListNotePort.sequence(Iterable<List<V3FeedItem>> pages)
    : _pages = List<List<V3FeedItem>>.of(pages);

  final List<List<V3FeedItem>> _pages;
  int loadCalls = 0;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    final index = loadCalls;
    loadCalls += 1;
    final notes = _pages[index < _pages.length ? index : _pages.length - 1];
    return KnowledgeNoteRemoteLoadResult.success(notes);
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _SequenceApiTransport implements ApiTransport {
  _SequenceApiTransport(Iterable<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected API request');
    return _responses.removeAt(0);
  }
}

ApiTransportResponse _response(Map<String, Object?> data, {int status = 200}) =>
    ApiTransportResponse(
      status: status,
      body: <String, Object?>{
        'success': true,
        'traceId': 'trace-test',
        'data': data,
      },
    );

ApiTransportResponse _errorResponse(String code, {required bool retryable}) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': false,
        'traceId': 'trace-test',
        'error': <String, Object?>{
          'code': code,
          'message': 'temporary read failure',
          'retryable': retryable,
        },
      },
    );

final class _SuccessfulObjectUploadTransport implements ObjectUploadTransport {
  const _SuccessfulObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async =>
      ObjectUploadResult.success(statusCode: 200, bytesSent: request.sizeBytes);
}

final class _FakeNativeFilePort
    implements NativeFilePort, NativeDocumentFilePort {
  const _FakeNativeFilePort(this.documentResult);

  final NativeFileResult<List<PickedDocumentFile>> documentResult;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.failure(
        const AppFailure(
          code: 'UNUSED',
          category: AppFailureCategory.storage,
          message: 'unused',
          userMessageKey: 'unused',
        ),
      );

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>>
  pickDocumentFiles() async => documentResult;
}

final class _DeferredDocumentPicker
    implements NativeFilePort, NativeDocumentFilePort {
  final Completer<NativeFileResult<List<PickedDocumentFile>>> _result =
      Completer<NativeFileResult<List<PickedDocumentFile>>>();
  int calls = 0;

  void complete(NativeFileResult<List<PickedDocumentFile>> result) {
    _result.complete(result);
  }

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.cancelled();

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() {
    calls += 1;
    return _result.future;
  }
}

V3DocumentImportTask _checkpointTask({String id = 'checkpoint-1'}) =>
    V3DocumentImportTask(
      id: id,
      pickerRef: 'picked-document://checkpoint',
      displayName: 'meeting.md',
      mimeType: 'text/markdown',
      sizeBytes: 10,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      privateFileName: 'meeting.md',
      status: V3DocumentImportTaskStatus.processing,
      attemptCount: 1,
      distillToDigitalTwin: true,
      createdAt: DateTime.utc(2026, 9, 5),
      updatedAt: DateTime.utc(2026, 9, 5),
    );

Map<String, Object?> _acceptedCheckpointData() => {
  'uploadId': 'upload-1',
  'resourceId': 'resource-1',
  'digitalTwinDistillation': {
    'taskId': 'distill-1',
    'resourceId': 'resource-1',
    'ingestionId': 'ingestion-1',
    'state': 'queued',
    'proposalIds': <String>[],
  },
};

void _checkpointCases() {
  test('recovery: terminal ingestion decision is not a retryable wait', () {
    final task = _checkpointTask().copyWith(
      status: V3DocumentImportTaskStatus.failed,
      ingestionId: 'ingestion-1',
      failureRetryable: false,
      lastErrorCode: 'NOTE_INGESTION_REMOTE_FAILED',
    );
    expect(task.isRetryable, isFalse);
    expect(task.copyWith(clearError: true).failureRetryable, isNull);
  });

  test(
    'recovery: accepted ingestion resumes after timeout without local file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'twin-checkpoint-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final local = File('${directory.path}/meeting.md');
      await local.writeAsString('0123456789');
      final database = AppDatabase();
      final store = _store(database, directory);
      final requests = _SequenceApiTransport([
        _response({
          'uploadId': 'upload-1',
          'resourceId': 'resource-1',
          'uploadUrl': 'https://objects.example.test/upload',
          'method': 'PUT',
        }),
        _response(_acceptedCheckpointData()),
        _response({
          'ingestion': {'ingestionId': 'ingestion-1', 'status': 'ready'},
        }),
      ]);
      final checkpoints = <V3DocumentImportTask>[];
      final first =
          await RemoteDocumentAnalysisPort(
            apiClient: _apiClient(requests),
            workspaceId: () => 'workspace_1',
            maxPollAttempts: 1,
            objectUploadTransport: const _SuccessfulObjectUploadTransport(),
          ).analyze(
            task: _checkpointTask(),
            privateFile: local,
            distillToDigitalTwin: true,
            onCheckpoint: (task) async {
              checkpoints.add(task);
              if (task.ingestionId != null) {
                expect(requests.requests.length, greaterThanOrEqualTo(2));
              }
              return store.saveAllDurably([task]);
            },
          );
      expect(first.error?.code, 'DOCUMENT_INGESTION_TIMEOUT');
      expect(checkpoints.last.distillationTaskId, 'distill-1');
      await local.delete();
      final resumed = _SequenceApiTransport([
        _response({
          'ingestion': {
            'ingestionId': 'ingestion-1',
            'status': 'promoted',
            'promotedNoteId': 'note-1',
          },
        }),
      ]);
      final second =
          await RemoteDocumentAnalysisPort(
            apiClient: _apiClient(resumed),
            workspaceId: () => 'workspace_1',
          ).analyze(
            task: _store(database, directory).listTasks().single,
            distillToDigitalTwin: true,
          );
      expect(second.ok, isTrue, reason: second.error?.code);
      expect(second.value?.remoteNoteId, 'note-1');
      expect(second.value?.distillation?.taskId, 'distill-1');
      expect(resumed.requests.single.method, 'GET');
    },
  );

  test(
    'recovery: uploaded object resumes completion without issuing another token',
    () async {
      final task = _checkpointTask().copyWith(
        uploadId: 'upload-1',
        uploadResourceId: 'resource-1',
      );
      final requests = _SequenceApiTransport([
        _response(_acceptedCheckpointData()),
        _response({
          'ingestion': {
            'ingestionId': 'ingestion-1',
            'status': 'promoted',
            'promotedNoteId': 'note-1',
          },
        }),
      ]);
      final result = await RemoteDocumentAnalysisPort(
        apiClient: _apiClient(requests),
        workspaceId: () => 'workspace_1',
      ).analyze(task: task, distillToDigitalTwin: true);
      expect(result.ok, isTrue);
      expect(requests.requests.map((request) => request.method), [
        'POST',
        'GET',
      ]);
      expect(
        requests.requests.first.url.path,
        '/api/v1/media/uploads/upload-1/complete',
      );
    },
  );

  test(
    'recovery: failed durable acceptance stops before ingestion polling',
    () async {
      final requests = _SequenceApiTransport([
        _response(_acceptedCheckpointData()),
      ]);
      final result =
          await RemoteDocumentAnalysisPort(
            apiClient: _apiClient(requests),
            workspaceId: () => 'workspace_1',
          ).analyze(
            task: _checkpointTask().copyWith(
              uploadId: 'upload-1',
              uploadResourceId: 'resource-1',
            ),
            distillToDigitalTwin: true,
            onCheckpoint: (_) async => false,
          );
      expect(result.error?.code, 'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED');
      expect(requests.requests, hasLength(1));
    },
  );

  testWidgets('recovery: mixed batch retains working review and note actions', (
    tester,
  ) async {
    final completed = _checkpointTask().copyWith(
      status: V3DocumentImportTaskStatus.completed,
      remoteNoteId: 'note-1',
      noteId: 'note-1',
      rawAssetCreated: true,
      distillationTaskId: 'distill-1',
      distillationResourceId: 'resource-1',
    );
    final waiting = _checkpointTask(id: 'checkpoint-2').copyWith(
      status: V3DocumentImportTaskStatus.waiting,
      ingestionId: 'ingestion-2',
      lastErrorCode: 'DOCUMENT_INGESTION_TIMEOUT',
    );
    var reviews = 0;
    var notes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3DocumentImportResults(
            tasks: [completed, waiting],
            onReview: (_) => reviews += 1,
            onOpenNote: (_) => notes += 1,
          ),
        ),
      ),
    );
    expect(find.textContaining('服务器已受理，但本次查询等待已结束'), findsOneWidget);
    await tester.tap(find.text('查看候选与进度'));
    await tester.tap(find.text('查看笔记'));
    expect(reviews, 1);
    expect(notes, 1);
    expect(tester.takeException(), isNull);
  });
}

void _importLifecycleCases() {
  test(
    'actual API errors have actionable explanations and manual recovery',
    () {
      for (final code in [
        'AUTH_SESSION_EXPIRED',
        'AUTH_UNAUTHORIZED',
        'PERMISSION_DENIED',
        'WORKSPACE_FORBIDDEN',
        'NETWORK_REQUEST_FAILED',
        'API_RATE_LIMITED',
        'API_SERVER_UNAVAILABLE',
        'UPLOAD_FILE_TOO_LARGE',
      ]) {
        expect(
          documentImportErrorMessage(code),
          isNot(documentImportErrorMessage('UNKNOWN_ERROR')),
          reason: code,
        );
      }
      final task = _checkpointTask().copyWith(
        ingestionId: 'ingestion-1',
        status: V3DocumentImportTaskStatus.failed,
        failureRetryable: false,
        lastErrorCode: 'AUTH_SESSION_EXPIRED',
      );
      expect(task.isRetryable, isTrue);
      expect(task.ingestionId, 'ingestion-1');
    },
  );

  testWidgets('submission failure displays its phase, cause and code', (
    tester,
  ) async {
    final task = _checkpointTask().copyWith(
      status: V3DocumentImportTaskStatus.failed,
      uploadId: 'upload-1',
      uploadResourceId: 'resource-1',
      phase: V3DocumentImportPhase.creatingIngestion,
      lastErrorCode: 'INTERNAL_ERROR',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3DocumentImportResults(
            tasks: [task],
            onReview: (_) {},
            onOpenNote: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('提交解析任务：服务器处理请求失败'), findsOneWidget);
    expect(find.text('错误码：INTERNAL_ERROR'), findsOneWidget);
    expect(find.textContaining('后台结果待核验'), findsNothing);
  });

  test('ingestion keys follow resource identity, not file identity', () async {
    Future<String> submit(String resourceId) async {
      final transport = _SequenceApiTransport([
        _response({'uploadId': 'upload-1', 'resourceId': resourceId}),
        _response({
          'ingestion': {
            'ingestionId': 'ingestion-1',
            'status': 'promoted',
            'promotedNoteId': 'note-1',
          },
        }),
      ]);
      final result =
          await RemoteDocumentAnalysisPort(
            apiClient: _apiClient(transport),
            workspaceId: () => 'workspace_1',
          ).analyze(
            task: _checkpointTask().copyWith(
              uploadId: 'upload-1',
              uploadResourceId: resourceId,
            ),
          );
      expect(result.ok, isTrue, reason: result.error?.code);
      expect(transport.requests, hasLength(2));
      return transport.requests.last.headers.entries
          .firstWhere(
            (entry) => entry.key.toLowerCase().contains('idempotency'),
          )
          .value;
    }

    final first = await submit('resource-old');
    expect(await submit('resource-old'), first);
    expect(await submit('resource-new'), isNot(first));
  });

  test('submission 500 is a failed phase, never a background wait', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-admission-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.md');
    await source.writeAsString('submitted document');
    final store = _store(AppDatabase(), root);
    final staged = (await store.stage(
      _picked(source, 'source.md', 'text/markdown'),
    )).value!;
    store.save(
      staged.copyWith(
        acceptedForImport: true,
        uploadId: 'upload-1',
        uploadResourceId: 'resource-1',
      ),
    );
    final transport = _SequenceApiTransport([
      _response({'uploadId': 'upload-1', 'resourceId': 'resource-1'}),
      _errorResponse('INTERNAL_ERROR', retryable: true),
    ]);
    final controller = V3DocumentImportController(
      nativeFilePort: _FakeNativeFilePort(NativeFileResult.cancelled()),
      knowledgeLibrary: KnowledgeLibraryController(),
      profileHub: ProfileHubController(),
      store: store,
      analysisPort: RemoteDocumentAnalysisPort(
        apiClient: _apiClient(transport),
        workspaceId: () => 'workspace_1',
      ),
    );
    await controller.recoverPending(force: true);
    await controller.importSelected();
    final failed = controller.state.durableTasks.single;
    expect(failed.status, V3DocumentImportTaskStatus.failed);
    expect(failed.phase, V3DocumentImportPhase.creatingIngestion);
    expect(failed.lastErrorCode, 'INTERNAL_ERROR');
    expect(failed.ingestionId, isNull);
    expect(failed.uploadResourceId, 'resource-1');
    expect(controller.state.hasWaitingTasks, isFalse);
    expect(controller.state.hasRetryableTasks, isTrue);
  });

  test('repeated status read errors stop early with original error', () async {
    final transport = _SequenceApiTransport([
      _response({
        'ingestion': {'ingestionId': 'ingestion-1', 'status': 'validating'},
      }),
      for (var attempt = 0; attempt < 3; attempt++)
        _errorResponse('NETWORK_UNAVAILABLE', retryable: true),
    ]);
    final result = await RemoteDocumentAnalysisPort(
      apiClient: _apiClient(transport),
      workspaceId: () => 'workspace_1',
      delay: (_) async {},
      maxPollAttempts: 90,
    ).analyze(task: _checkpointTask().copyWith(ingestionId: 'ingestion-1'));
    expect(result.error?.code, 'NETWORK_UNAVAILABLE');
    expect(transport.requests, hasLength(4));
  });

  for (final scenario in [
    (
      status: 'expired',
      receiptId: 'ingestion-1',
      error: 'DOCUMENT_INGESTION_EXPIRED',
    ),
    (
      status: 'cancelled',
      receiptId: 'ingestion-1',
      error: 'DOCUMENT_INGESTION_CANCELLED',
    ),
    (
      status: 'quarantined',
      receiptId: 'ingestion-1',
      error: 'NOTE_INGESTION_QUARANTINED',
    ),
    (
      status: 'unknown_state',
      receiptId: 'ingestion-1',
      error: 'DOCUMENT_INGESTION_STATUS_INVALID',
    ),
    (
      status: 'promoted',
      receiptId: 'ingestion-1',
      error: 'DOCUMENT_INGESTION_RESPONSE_INVALID',
    ),
    (
      status: 'validating',
      receiptId: 'foreign-ingestion',
      error: 'DOCUMENT_INGESTION_ID_MISMATCH',
    ),
  ]) {
    test(
      'invalid or terminal receipt stops immediately: ${scenario.error}',
      () async {
        final transport = _SequenceApiTransport([
          _response({
            'ingestion': {
              'ingestionId': scenario.receiptId,
              'status': scenario.status,
            },
          }),
        ]);
        final result = await RemoteDocumentAnalysisPort(
          apiClient: _apiClient(transport),
          workspaceId: () => 'workspace_1',
        ).analyze(task: _checkpointTask().copyWith(ingestionId: 'ingestion-1'));
        expect(result.error?.code, scenario.error);
        expect(transport.requests, hasLength(1));
      },
    );
  }

  test(
    'one file exception is persisted and does not stop the next file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-batch-failure-',
      );
      addTearDown(() => root.delete(recursive: true));
      final first = File('${root.path}/first.md');
      final second = File('${root.path}/second.md');
      await first.writeAsString('first');
      await second.writeAsString('second');
      final store = _store(AppDatabase(), root);
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(
          NativeFileResult.success([
            _picked(first, 'first.md', 'text/markdown'),
            _picked(second, 'second.md', 'text/markdown'),
          ]),
        ),
        knowledgeLibrary: _remoteLibrary(
          _remoteNote(id: 'note-second', title: 'second.md', body: 'second'),
        ),
        profileHub: ProfileHubController(),
        store: store,
        analysisPort: _ThrowFirstDocumentAnalysisPort(),
      );
      await controller.pickDocuments();
      await controller.importSelected();
      expect(controller.state.importedCount, 1);
      expect(
        store.listTasks().where(
          (task) => task.status == V3DocumentImportTaskStatus.processing,
        ),
        isEmpty,
      );
      final failed = store.listTasks().singleWhere((task) => !task.isCompleted);
      expect(failed.lastErrorCode, 'DOCUMENT_IMPORT_FAILED');
      expect(failed.phase, V3DocumentImportPhase.requestingUpload);
    },
  );

  test(
    'recovery makes interrupted foreground work explicitly retryable',
    () async {
      final root = await Directory.systemTemp.createTemp('huahuo-interrupted-');
      addTearDown(() => root.delete(recursive: true));
      final store = _store(AppDatabase(), root);
      store.save(
        _checkpointTask().copyWith(
          phase: V3DocumentImportPhase.creatingIngestion,
          uploadId: 'upload-1',
          uploadResourceId: 'resource-1',
        ),
      );
      final controller = V3DocumentImportController(
        nativeFilePort: _FakeNativeFilePort(NativeFileResult.cancelled()),
        knowledgeLibrary: KnowledgeLibraryController(),
        profileHub: ProfileHubController(),
        store: store,
      );
      await controller.recoverPending(force: true);
      final task = controller.state.durableTasks.single;
      expect(task.status, V3DocumentImportTaskStatus.failed);
      expect(task.phase, V3DocumentImportPhase.creatingIngestion);
      expect(task.lastErrorCode, 'DOCUMENT_IMPORT_INTERRUPTED');
      expect(task.isRetryable, isTrue);
    },
  );
}

final class _ThrowFirstDocumentAnalysisPort implements DocumentAnalysisPort {
  var calls = 0;

  @override
  Future<NativeFileResult<DocumentAnalysisResult>> analyze({
    required V3DocumentImportTask task,
    File? privateFile,
    bool distillToDigitalTwin = false,
    Future<bool> Function(V3DocumentImportTask)? onCheckpoint,
  }) async {
    calls += 1;
    if (calls == 1) {
      await onCheckpoint?.call(
        task.copyWith(phase: V3DocumentImportPhase.requestingUpload),
      );
      throw StateError('unexpected transport error');
    }
    return NativeFileResult.success(
      const DocumentAnalysisResult(remoteNoteId: 'note-second'),
    );
  }
}
