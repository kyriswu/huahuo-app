import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_detail_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_item_detail_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/outline_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_transcription_detail_page.dart';

import '../../support/figma_golden_test_support.dart';

const _transcriptionAccountScope = 'transcription-page-test-user';

Widget _transcriptionTestProviderScope({
  required List<Override> overrides,
  required Widget child,
}) {
  return ProviderScope(
    overrides: <Override>[
      resolvedDeviceIdProvider.overrideWithValue('transcription-test-device'),
      authenticatedRecordingUserScopeProvider.overrideWith(
        (ref) => _transcriptionAccountScope,
      ),
      ...overrides,
    ],
    child: child,
  );
}

RecordingDetailController _scopedDetailController({
  required RecordingApiPort api,
  Duration pollInterval = Duration.zero,
  int maxPollAttempts = 200,
  PollDelay? delay,
}) {
  return RecordingDetailController(
    api: api,
    pollInterval: pollInterval,
    maxPollAttempts: maxPollAttempts,
    delay: delay ?? (_) async {},
    accountScope: _transcriptionAccountScope,
  );
}

void main() {
  setUpAll(loadFigmaGoldenFonts);

  for (final failVisibleJob in <bool>[true, false]) {
    testWidgets(
      'local upload shows job-owned preflight state (matching=$failVisibleJob)',
      (tester) async {
        final database = AppDatabase();
        final item = RecordingLibraryItem(
          recordingId: 'local-upload',
          source: RecordingLibrarySource.localImport,
          displayName: 'Meeting.m4a',
          format: RecordingLibraryFormat.m4a,
          localFileState: RecordingLocalFileState.ready,
          status: RecordingLibraryStatus.localOnly,
          durationSeconds: 90,
          sizeBytes: 2048,
          isFavorite: false,
          tagIds: const <String>[],
          createdAt: DateTime.utc(2026, 9, 7),
          updatedAt: DateTime.utc(2026, 9, 7),
          appPrivateUri: 'app-private://recordings/local-upload/source.m4a',
        );
        RecordingDao(
          database,
        ).upsertLocalRecording(item.recordingId, item.toRecord());
        final store = UploadDraftStore(database: database);
        store.saveDraft(
          createInitialUploadDraft(
            draftId: 'draft-local-upload',
            localRecordingId: item.recordingId,
            appPrivateUri: item.appPrivateUri!,
            fileName: item.displayName,
            mimeType: 'audio/mp4',
            sizeBytes: item.sizeBytes,
            durationSeconds: item.durationSeconds,
            sourceScene: 'raw_material',
            recordingSource: 'local_upload',
            updatedAt: item.updatedAt,
          ),
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const UnavailableFileStoragePort(),
        );
        late RecordingUploadController controller;
        await tester.pumpWidget(
          _transcriptionTestProviderScope(
            overrides: [
              uploadDraftStoreProvider.overrideWithValue(store),
              recordingUploadControllerProvider.overrideWith(
                (ref) => controller = RecordingUploadController(
                  uploadClient: ref.read(recordingUploadClientProvider),
                  recordingApi: ref.read(recordingApiProvider),
                  draftStore: store,
                  localRecordingRepository: repository,
                  activeWorkspaceId: () => null,
                ),
              ),
            ],
            child: const MaterialApp(
              home: V3TranscriptionJobPage(
                jobId: 'draft-local-upload',
                source: RecordingFileSource.localLibrary,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('等待上传'), findsOneWidget);
        expect(find.text('上传并转写'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('transcription-pending-progress')),
          findsNothing,
        );
        expect(find.textContaining('服务端正在处理'), findsNothing);

        if (failVisibleJob) {
          await tester.tap(
            find.byKey(const ValueKey('transcription-pending-retry')),
          );
        } else {
          await controller.uploadPrivateAudio(
            input: RecordingPrivateAudioInput(
              jobId: 'draft-another-upload',
              localFileId: 'another-upload',
              appPrivateUri:
                  'app-private://recordings/another-upload/source.m4a',
              fileName: 'another.m4a',
              mimeType: 'audio/mp4',
              sizeBytes: 2048,
              durationSeconds: 90,
              contentHash: 'a' * 64,
              recordedAt: item.createdAt,
              title: 'another',
            ),
            fileSource: RecordingFileSource.audioImport,
          );
        }
        await tester.pumpAndSettle();
        expect(controller.state.activeDraft, isNull);
        expect(controller.state.activeJobIds, isEmpty);
        expect(find.text('正在上传'), findsNothing);
        expect(find.text('正在转写'), findsNothing);
        expect(
          find.byKey(const ValueKey('transcription-pending-progress')),
          findsNothing,
        );
        expect(
          find.text('暂时无法开始转写'),
          failVisibleJob ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('等待上传'),
          failVisibleJob ? findsNothing : findsOneWidget,
        );
        expect(store.getDraft('draft-local-upload')!.recordingId, isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('a missing durable job checkpoint fails without a spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: const <Override>[],
        child: const MaterialApp(
          home: V3TranscriptionJobPage(
            jobId: 'draft-missing-checkpoint',
            source: RecordingFileSource.monologue,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('暂时无法开始转写'), findsOneWidget);
    expect(find.text('无法识别这项录音任务，请返回后重新进入。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transcription-pending-progress')),
      findsNothing,
    );
  });

  testWidgets(
    'keeps an indeterminate progress bar for active ASR without a percent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _DetailApi(detail: _DetailApi._activeDetail);
      final controller = _scopedDetailController(
        api: api,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
        delay: (_) async {},
      );
      await tester.pumpWidget(
        _transcriptionTestProviderScope(
          overrides: [
            recordingDetailControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            home: const TickerMode(
              enabled: false,
              child: V3TranscriptionDetailPage(recordingId: 'recording-1'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('transcription-progress')),
      );
      expect(progress.value, isNull);
      expect(find.text('正在转写'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('transcription-background')),
        findsOneWidget,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../recording_card/goldens/recording_card_transcribing.png',
        ),
      );
    },
  );

  testWidgets('renders returned transcription detail from the recording API', (
    tester,
  ) async {
    final api = _DetailApi();
    final controller = _scopedDetailController(
      api: api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
      delay: (_) async {},
    );
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: V3TranscriptionDetailPage(recordingId: 'recording-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(api.detailCalls, 1);
    expect(find.text('服务端转写内容'), findsOneWidget);
    expect(find.text('服务端总结'), findsNothing);
    expect(find.text('转写详情'), findsOneWidget);
    expect(find.text('先返回，稍后查看'), findsOneWidget);
    expect(find.textContaining('消息通知'), findsOneWidget);
    expect(find.text('后台转写'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('transcription-view-asset')),
      findsNothing,
    );
    expect(find.text('继续对话'), findsNothing);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('transcription-progress')),
    );
    expect(progress.value, isNull);
  });

  testWidgets('uses the recording retry action for an allowed ASR retry', (
    tester,
  ) async {
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-1',
        title: '服务器录音',
        status: RecordingRemoteStatus.failed,
      ),
      asrTask: AsrTaskSnapshot(
        asrTaskId: 'asr-1',
        status: RecordingRemoteStatus.failed,
      ),
      retryActions: <RecordingRetryAction>[
        RecordingRetryAction(stage: 'asr', title: '重新转写', allowed: true),
      ],
    );
    final api = _DetailApi(detail: detail);
    final controller = _scopedDetailController(api: api, maxPollAttempts: 1);
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: V3TranscriptionDetailPage(recordingId: 'recording-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('重新转写'));
    await tester.pump();
    await tester.pump();

    expect(api.retryStages, <String>['asr']);
    expect(api.retryAsrCalls, 0);
  });

  testWidgets('keeps derived outline retry on the Note detail surface', (
    tester,
  ) async {
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-derived-retry',
        title: '服务器录音',
        status: RecordingRemoteStatus.failed,
        transcriptStatus: 'final_transcript_generated',
        minutesStatus: 'failed',
      ),
      asrTask: AsrTaskSnapshot(
        asrTaskId: 'asr-derived-retry',
        status: RecordingRemoteStatus.completed,
      ),
      finalTranscript: '已经保留的原始转写',
      finalTranscriptConfirmed: true,
      retryActions: <RecordingRetryAction>[
        RecordingRetryAction(
          stage: 'minutes_generation',
          title: '重新生成纲要',
          allowed: true,
        ),
        RecordingRetryAction(
          stage: 'recording_note_outline',
          title: '重试笔记纲要',
          allowed: true,
        ),
      ],
    );
    final controller = _scopedDetailController(api: _DetailApi(detail: detail));
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: V3TranscriptionDetailPage(
            recordingId: 'recording-derived-retry',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('重新生成纲要'), findsNothing);
    expect(find.text('重试笔记纲要'), findsNothing);
    expect(find.text('服务端允许的重试'), findsNothing);
  });

  testWidgets(
    'shows asset creation instead of aggregate failure while noteRef is pending',
    (tester) async {
      const detail = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'recording-awaiting-note-ref',
          title: '已经转写的录音',
          status: RecordingRemoteStatus.failed,
          transcriptStatus: 'failed',
          minutesStatus: 'failed',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-awaiting-note-ref',
          status: RecordingRemoteStatus.generatingMinutes,
        ),
        finalTranscript: '最终转写已经完成，正在等待正式资产。',
        finalTranscriptConfirmed: true,
      );
      final controller = _scopedDetailController(
        api: _DetailApi(detail: detail),
        maxPollAttempts: 1,
      );

      await tester.pumpWidget(
        _transcriptionTestProviderScope(
          overrides: [
            recordingDetailControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: V3TranscriptionDetailPage(
              recordingId: 'recording-awaiting-note-ref',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('正在创建资产'), findsWidgets);
      expect(find.text('处理失败'), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('transcription-progress')),
            )
            .value,
        isNull,
      );
      expect(find.text('最终转写已经完成，正在等待正式资产。'), findsOneWidget);
    },
  );

  testWidgets('background transcription returns through the fallback route', (
    tester,
  ) async {
    final controller = _scopedDetailController(
      api: _DetailApi(detail: _DetailApi._activeDetail),
      maxPollAttempts: 1,
    );
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const V3TranscriptionDetailPage(recordingId: 'recording-1'),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Text('已返回首页'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('transcription-background')),
    );
    await tester.pumpAndSettle();

    expect(find.text('已返回首页'), findsOneWidget);
  });

  testWidgets(
    'shows transcription progress while the first detail request is pending',
    (tester) async {
      final detailResponse = Completer<ApiResult<RecordingDetail>>();
      final api = _DetailApi(detailResponse: detailResponse.future);
      final controller = _scopedDetailController(
        api: api,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
        delay: (_) async {},
      );
      await tester.pumpWidget(
        _transcriptionTestProviderScope(
          overrides: [
            recordingDetailControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: V3TranscriptionDetailPage(recordingId: 'recording-1'),
          ),
        ),
      );
      await tester.pump();

      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('transcription-progress')),
      );
      expect(progress.value, isNull);
      expect(find.text('正在同步转写状态'), findsOneWidget);

      detailResponse.complete(_success(_DetailApi._activeDetail));
      await tester.pump();
    },
  );

  testWidgets('rejects an empty route id without contacting the API', (
    tester,
  ) async {
    final api = _DetailApi();
    final controller = _scopedDetailController(
      api: api,
      pollInterval: Duration.zero,
      delay: (_) async {},
    );
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: V3TranscriptionDetailPage(recordingId: ''),
        ),
      ),
    );
    await tester.pump();

    expect(api.detailCalls, 0);
    expect(find.text('RECORDING_ROUTE_ID_INVALID'), findsNothing);
    expect(find.text('无法识别这项录音任务，请返回后重新进入。'), findsOneWidget);
  });

  testWidgets(
    'does not open a deposited local asset without canonical server binding',
    (tester) async {
      final api = _DetailApi(detail: _DetailApi._contextualDetail);
      final controller = _scopedDetailController(
        api: api,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
        delay: (_) async {},
      );
      final library = KnowledgeLibraryController(initialNotes: const []);
      library.upsertProcessedTranscription(
        id: 'recording-1',
        title: '访谈录音',
        rawBody: '用户确认沉淀的独白内容。',
        preserveUserEdits: true,
      );
      final router = GoRouter(
        initialLocation: '/detail',
        routes: <RouteBase>[
          GoRoute(
            path: '/detail',
            builder: (context, state) => _transcriptionTestProviderScope(
              overrides: [
                recordingDetailControllerProvider.overrideWith(
                  (ref) => controller,
                ),
                knowledgeLibraryControllerProvider.overrideWith(
                  (ref) => library,
                ),
              ],
              child: const V3TranscriptionDetailPage(
                recordingId: 'recording-1',
              ),
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) => Text(
              'item:${state.pathParameters['itemId']};stage:${state.uri.queryParameters['stage']}',
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      await tester.pump();

      expect(find.text('转写详情'), findsOneWidget);
      expect(library.isDeposited('recording-1'), isTrue);
      await tester.tap(
        find.byKey(const ValueKey<String>('transcription-view-asset-top')),
      );
      await tester.pump();
      expect(find.text('item:recording-1;stage:summary'), findsNothing);
    },
  );

  testWidgets(
    'does not render or persist a detail owned by the previous account',
    (tester) async {
      final accountScopeProvider = StateProvider<String?>((ref) => 'user-a');
      final api = _DetailApi(detail: _DetailApi._contextualDetail);
      final controller = RecordingDetailController(
        api: api,
        pollInterval: Duration.zero,
        delay: (_) async {},
        accountScope: 'user-a',
      );
      final library = KnowledgeLibraryController(initialNotes: const []);
      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: <Override>[
          authenticatedRecordingUserScopeProvider.overrideWith(
            (ref) => ref.watch(accountScopeProvider),
          ),
          recordingDetailControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
      );
      addTearDown(container.dispose);
      var switched = false;
      controller.addListener(() {
        if (switched || controller.state.detail == null) return;
        switched = true;
        container.read(accountScopeProvider.notifier).state = 'user-b';
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: V3TranscriptionDetailPage(recordingId: 'recording-1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(switched, isTrue);
      expect(library.noteForId('recording-1'), isNull);
      expect(find.text('服务端转写内容'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'waits for a final transcript and deposited cloud asset before opening it',
    (tester) async {
      const provisional = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'recording-1',
          title: '访谈录音',
          status: RecordingRemoteStatus.generatingMinutes,
          transcriptStatus: 'speaker_confirmed',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-1',
          status: RecordingRemoteStatus.generatingMinutes,
        ),
        finalTranscript: '没有说话人标注的临时文本',
      );
      const attributed = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'recording-1',
          title: '访谈录音',
          status: RecordingRemoteStatus.generatingMinutes,
          transcriptStatus: 'final_transcript_generated',
        ),
        noteRef: RecordingNoteRef(
          noteId: 'note-recording-1',
          rawPartRevisionId: 'raw-revision-recording-1',
          outlinePartRevisionId: 'outline-revision-recording-1',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-1',
          status: RecordingRemoteStatus.generatingMinutes,
        ),
        finalTranscript: '@谢居洋 00:00:00\n这是最终内容。',
      );
      final releaseAttributed = Completer<void>();
      final api = _DetailApi.sequence(<RecordingDetail>[
        provisional,
        attributed,
      ]);
      final controller = _scopedDetailController(
        api: api,
        pollInterval: Duration.zero,
        maxPollAttempts: 2,
        delay: (_) => releaseAttributed.future,
      );
      final remotePort = _CloudRecordingNotePort(
        V3FeedItem(
          id: 'note-recording-1',
          title: '访谈录音',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 17),
          rawBody: '@谢居洋 00:00:00\n这是最终内容。',
          remoteNoteId: 'note-recording-1',
          noteRevisionId: 'note-revision-recording-1',
          rawPartRevisionId: 'raw-revision-recording-1',
          etag: 'etag-recording-1',
          contentCursor: 'cursor-recording-1',
          syncState: NoteSyncState.synced,
        ),
      );
      final library = KnowledgeLibraryController(
        notePort: remotePort,
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      final router = GoRouter(
        initialLocation: '/detail',
        routes: <RouteBase>[
          GoRoute(
            path: '/detail',
            builder: (context, state) =>
                const V3TranscriptionDetailPage(recordingId: 'recording-1'),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) => Text(
              'item:${state.pathParameters['itemId']};stage:${state.uri.queryParameters['stage']}',
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        _transcriptionTestProviderScope(
          overrides: [
            recordingDetailControllerProvider.overrideWith((ref) => controller),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(api.detailCalls, 1);
      expect(library.noteForId('recording-1'), isNull);
      expect(find.text('转写详情'), findsOneWidget);

      releaseAttributed.complete();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(api.detailCalls, 2);
      expect(remotePort.loadCalls, greaterThanOrEqualTo(1));
      expect(library.isDeposited('note-recording-1'), isTrue);
      expect(find.text('item:note-recording-1;stage:summary'), findsOneWidget);
    },
  );

  testWidgets('waits for the exact referenced Raw revision before opening', (
    tester,
  ) async {
    const noteId = 'note-recording-revision-1';
    final releaseRemoteRevision = Completer<void>();
    final remotePort = _CloudRecordingNotePort(
      V3FeedItem(
        id: noteId,
        title: '最新录音资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 17),
        rawBody: '最新的服务端转写正文',
        remoteNoteId: noteId,
        noteRevisionId: 'note-revision-current',
        rawPartRevisionId: 'raw-revision-current',
        etag: 'etag-current',
        contentCursor: 'cursor-current',
        syncState: NoteSyncState.synced,
      ),
      loadGate: releaseRemoteRevision.future,
    );
    final library = KnowledgeLibraryController(
      notePort: remotePort,
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: noteId,
          title: '旧录音资产',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 16),
          rawBody: '旧的服务端转写正文',
          remoteNoteId: noteId,
          noteRevisionId: 'note-revision-stale',
          rawPartRevisionId: 'raw-revision-stale',
          etag: 'etag-stale',
          contentCursor: 'cursor-stale',
          syncState: NoteSyncState.synced,
        ),
      ],
      includeDemoFixtures: false,
    );
    expect(library.depositContent(noteId), isNotNull);
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-revision-1',
        title: '最新录音资产',
        status: RecordingRemoteStatus.generatingMinutes,
        transcriptStatus: 'final_transcript_generated',
      ),
      noteRef: RecordingNoteRef(
        noteId: noteId,
        rawPartRevisionId: 'raw-revision-current',
        outlinePartRevisionId: 'outline-revision-current',
      ),
      finalTranscript: '最新的服务端转写正文',
    );
    final controller = _scopedDetailController(
      api: _DetailApi(detail: detail),
      maxPollAttempts: 1,
    );
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) => const V3TranscriptionDetailPage(
            recordingId: 'recording-revision-1',
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) => Text(
            'item:${state.pathParameters['itemId']};stage:${state.uri.queryParameters['stage']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(remotePort.loadCalls, 1);
    expect(find.text('转写详情'), findsOneWidget);
    expect(find.text('item:$noteId;stage:summary'), findsNothing);

    releaseRemoteRevision.complete();
    await tester.pumpAndSettle();

    expect(
      library.noteForId(noteId)?.rawPartRevisionId,
      'raw-revision-current',
    );
    expect(find.text('item:$noteId;stage:summary'), findsOneWidget);
  });

  testWidgets('shows automatic speaker fallback without confirmation UI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _DetailApi.sequence(<RecordingDetail>[
      _speakerLabelDetail(),
      _speakerResolvedDetail(),
    ]);
    final releasePendingStage = Completer<void>();
    final controller = _scopedDetailController(
      api: api,
      pollInterval: Duration.zero,
      delay: (_) => releasePendingStage.future,
    );
    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          home: const V3TranscriptionDetailPage(recordingId: 'recording-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(api.detailCalls, 1);
    expect(find.text('正在整理转写'), findsWidgets);
    expect(find.text('正在识别说话人'), findsNothing);
    expect(find.text('标注说话人'), findsNothing);
    expect(find.text('确认并继续'), findsNothing);

    releasePendingStage.complete();
    await tester.pump();
    await tester.pump();

    expect(api.detailCalls, 2);
    expect(find.text('@说话人 1 00:00:00\n转写已经完成。'), findsOneWidget);
  });

  testWidgets('automatically opens the canonical outline while it generates', (
    tester,
  ) async {
    const noteId = 'note-recording-cloud-1';
    final remotePort = _CloudRecordingNotePort(
      V3FeedItem(
        id: noteId,
        title: '服务端录音资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 10),
        rawBody: '服务端最终转写内容',
        remoteNoteId: noteId,
        noteRevisionId: 'note-revision-cloud-1',
        rawPartRevisionId: 'raw-revision-cloud-1',
        etag: 'etag-cloud-1',
        contentCursor: 'cursor-cloud-1',
        syncState: NoteSyncState.synced,
      ),
    );
    final library = KnowledgeLibraryController(
      notePort: remotePort,
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-cloud-1',
        title: '服务端录音资产',
        status: RecordingRemoteStatus.generatingMinutes,
        transcriptStatus: 'final_transcript_generated',
        minutesStatus: 'running',
        summaryStatus: 'pending',
      ),
      noteRef: RecordingNoteRef(
        noteId: noteId,
        rawPartRevisionId: 'raw-revision-cloud-1',
        outlinePartRevisionId: 'outline-revision-cloud-1',
      ),
      asrTask: AsrTaskSnapshot(
        asrTaskId: 'asr-cloud-1',
        status: RecordingRemoteStatus.generatingMinutes,
      ),
      finalTranscript: '服务端最终转写内容',
    );
    final api = _DetailApi(detail: detail);
    final controller = _scopedDetailController(
      api: api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
      delay: (_) async {},
    );
    final outline = _CountingOutlineRepository();
    final recordingPollGate = Completer<void>();
    addTearDown(() {
      if (!recordingPollGate.isCompleted) recordingPollGate.complete();
    });
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const V3TranscriptionDetailPage(recordingId: 'recording-cloud-1'),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) => V3FeedItemDetailPage(
            itemId: state.pathParameters['itemId']!,
            initialStage: V3ContentStage.summary,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          resolvedDeviceIdProvider.overrideWithValue(
            'transcription-cross-page-device',
          ),
          feedItemDetailControllerProvider.overrideWith((ref, itemId) {
            return FeedItemDetailController.withDependencies(
              itemId: itemId,
              library: library,
              outlineRepository: outline,
              recordingApi: api,
              recordingPollInterval: Duration.zero,
              recordingPollDelay: (_) => recordingPollGate.future,
            );
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    for (var frame = 0; frame < 12; frame += 1) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(remotePort.loadCalls, greaterThanOrEqualTo(1));
    expect(controller.state.status, RecordingDetailControllerStatus.terminal);
    expect(library.isDeposited(noteId), isTrue);
    expect(find.byType(V3FeedItemDetailPage), findsOneWidget);
    expect(find.text('正在生成纲要'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('detail-generate-outline')), findsNothing);
    expect(outline.calls, 0);
    expect(library.noteForId(noteId)?.recordingId, 'recording-cloud-1');
    expect(library.noteForId(noteId)?.minutesStatus, 'running');
    expect(library.noteForId(noteId)?.summaryStatus, 'pending');
  });

  testWidgets('opens the asset outline even when outline generation fails', (
    tester,
  ) async {
    const noteId = 'note-recording-outline-failed';
    final remotePort = _CloudRecordingNotePort(
      V3FeedItem(
        id: noteId,
        title: '纲要失败录音资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 12),
        rawBody: '原始转写不会丢失',
        remoteNoteId: noteId,
        noteRevisionId: 'note-revision-outline-failed',
        rawPartRevisionId: 'raw-revision-outline-failed',
        etag: 'etag-outline-failed',
        contentCursor: 'cursor-outline-failed',
        syncState: NoteSyncState.synced,
      ),
    );
    final library = KnowledgeLibraryController(
      notePort: remotePort,
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-outline-failed',
        title: '纲要失败录音资产',
        status: RecordingRemoteStatus.failed,
        transcriptStatus: 'failed',
        minutesStatus: 'failed',
      ),
      noteRef: RecordingNoteRef(
        noteId: noteId,
        rawPartRevisionId: 'raw-revision-outline-failed',
        outlinePartRevisionId: 'outline-revision-outline-failed',
      ),
      asrTask: AsrTaskSnapshot(
        asrTaskId: 'asr-outline-failed',
        status: RecordingRemoteStatus.generatingMinutes,
      ),
      finalTranscript: '原始转写不会丢失',
      finalTranscriptConfirmed: true,
      retryActions: <RecordingRetryAction>[
        RecordingRetryAction(
          stage: 'minutes_generation',
          title: '重新生成纲要',
          allowed: true,
        ),
      ],
    );
    final controller = _scopedDetailController(
      api: _DetailApi(detail: detail),
      pollInterval: Duration.zero,
      delay: (_) async {},
    );
    final router = GoRouter(
      initialLocation: '/detail',
      routes: <RouteBase>[
        GoRoute(
          path: '/detail',
          builder: (context, state) => const V3TranscriptionDetailPage(
            recordingId: 'recording-outline-failed',
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) => Text(
            'item:${state.pathParameters['itemId']};stage:${state.uri.queryParameters['stage']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(library.isDeposited(noteId), isTrue);
    expect(library.noteForId(noteId)?.rawBody, '原始转写不会丢失');
    expect(find.text('item:$noteId;stage:summary'), findsOneWidget);
  });

  testWidgets(
    'does not expose intermediate minutes or aggregate summary as derived content',
    (tester) async {
      const detail = RecordingDetail(
        recording: RecordingAsset(
          recordingId: 'recording-markdown-1',
          title: 'Markdown 录音',
          status: RecordingRemoteStatus.completed,
          transcriptStatus: 'final_transcript_generated',
        ),
        asrTask: AsrTaskSnapshot(
          asrTaskId: 'asr-markdown-1',
          status: RecordingRemoteStatus.completed,
        ),
        finalTranscript: '服务端转写内容',
        minutesMarkdown: '# 中间纪要\n\n- 尚未写入正式纲要',
        summary: '## 中间总结\n\n尚未生成点火',
        noteOutlineTask: RecordingNoteOutlineTask(
          taskId: 'outline-task-running',
          status: RecordingNoteOutlineTaskStatus.running,
        ),
      );
      final controller = _scopedDetailController(
        api: _DetailApi(detail: detail),
        pollInterval: Duration.zero,
        delay: (_) async {},
      );

      await tester.pumpWidget(
        _transcriptionTestProviderScope(
          overrides: [
            recordingDetailControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: V3TranscriptionDetailPage(
              recordingId: 'recording-markdown-1',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('transcription-outline-markdown')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('transcription-summary-markdown')),
        findsNothing,
      );
      expect(find.text('中间纪要'), findsNothing);
      expect(find.text('中间总结'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders only the exact current canonical recording outline', (
    tester,
  ) async {
    const noteId = 'note-canonical-outline-1';
    final note = V3FeedItem(
      id: noteId,
      title: '正式录音资产',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 3),
      rawBody: '服务端转写内容',
      summaryBody: '# 正式纲要\n\n- 已写入当前 Outline revision',
      remoteNoteId: noteId,
      recordingId: 'recording-structured-1',
      noteRevisionId: 'note-revision-current',
      rawPartRevisionId: 'raw-revision-current',
      outlinePartRevisionId: 'outline-revision-current',
      etag: 'etag-current',
      contentCursor: 'cursor-current',
      syncState: NoteSyncState.synced,
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    expect(library.depositContent(noteId), isNotNull);
    const detail = RecordingDetail(
      recording: RecordingAsset(
        recordingId: 'recording-structured-1',
        title: '结构化纪要录音',
        status: RecordingRemoteStatus.completed,
        transcriptStatus: 'final_transcript_generated',
      ),
      asrTask: AsrTaskSnapshot(
        asrTaskId: 'asr-structured-1',
        status: RecordingRemoteStatus.completed,
      ),
      finalTranscript: '服务端转写内容',
      noteRef: RecordingNoteRef(
        noteId: noteId,
        rawPartRevisionId: 'raw-revision-current',
        outlinePartRevisionId: 'outline-revision-current',
      ),
      minutesMarkdown: '# 中间纪要',
      noteOutlineTask: RecordingNoteOutlineTask(
        taskId: 'outline-task-succeeded',
        status: RecordingNoteOutlineTaskStatus.succeeded,
      ),
    );
    final controller = _scopedDetailController(
      api: _DetailApi(detail: detail),
      pollInterval: Duration.zero,
      delay: (_) async {},
    );

    await tester.pumpWidget(
      _transcriptionTestProviderScope(
        overrides: [
          recordingDetailControllerProvider.overrideWith((ref) => controller),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(
          home: V3TranscriptionDetailPage(
            recordingId: 'recording-structured-1',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final outline = tester.widget<V3AssistantReplyMarkdown>(
      find.byKey(const ValueKey<String>('transcription-outline-markdown')),
    );
    expect(outline.source, '# 正式纲要\n\n- 已写入当前 Outline revision');
    expect(find.text('正式纲要'), findsOneWidget);
    expect(find.text('中间纪要'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final class _CloudRecordingNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  _CloudRecordingNotePort(this.note, {this.loadGate});

  final V3FeedItem note;
  final Future<void>? loadGate;
  int loadCalls = 0;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    loadCalls += 1;
    await loadGate;
    return KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[note]);
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    return const KnowledgeNotePortResult.unavailable();
  }
}

final class _CountingOutlineRepository implements OutlineRepository {
  int calls = 0;

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    calls += 1;
    return '# 不应生成';
  }
}

final class _DetailApi implements RecordingApiPort {
  _DetailApi({RecordingDetail? detail, this.detailResponse})
    : _detail = detail ?? _completedDetail,
      _details = null;

  _DetailApi.sequence(List<RecordingDetail> details)
    : assert(details.length > 1),
      _detail = details.last,
      _details = List<RecordingDetail>.unmodifiable(details),
      detailResponse = null;

  static const _completedDetail = RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'recording-1',
      title: '服务器录音',
      status: RecordingRemoteStatus.completed,
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-1',
      status: RecordingRemoteStatus.completed,
    ),
    finalTranscript: '服务端转写内容',
    summary: '服务端总结',
  );

  static const _contextualDetail = RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'recording-1',
      title: '服务器录音',
      status: RecordingRemoteStatus.completed,
      contentLineId: 'line-1',
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-1',
      status: RecordingRemoteStatus.completed,
      progress: 100,
    ),
    finalTranscript: '服务端转写内容',
  );

  static const _activeDetail = RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'recording-1',
      title: '手机录音.m4a',
      status: RecordingRemoteStatus.asrRunning,
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-active',
      status: RecordingRemoteStatus.asrRunning,
    ),
  );

  final RecordingDetail _detail;
  final List<RecordingDetail>? _details;
  final Future<ApiResult<RecordingDetail>>? detailResponse;
  int detailCalls = 0;
  final retryStages = <String>[];
  var retryAsrCalls = 0;

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    final response = detailResponse;
    if (response != null) return response;
    final details = _details;
    if (details == null) return _success(_detail);
    final index = detailCalls - 1;
    return _success(
      details[index < details.length ? index : details.length - 1],
    );
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) {
    retryAsrCalls += 1;
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) {
    retryStages.add(stage);
    return Future<ApiResult<RetryRecordingResponse>>.value(
      ApiResult<RetryRecordingResponse>.success(
        data: RetryRecordingResponse(
          recordingId: recordingId,
          stage: stage,
          status: RecordingRetryReceiptStatus.queued,
        ),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
  }
}

RecordingDetail _speakerLabelDetail() {
  return const RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'recording-1',
      title: '服务器录音',
      status: RecordingRemoteStatus.speakerLabelPending,
      transcriptStatus: 'speaker_labeling',
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-1',
      status: RecordingRemoteStatus.speakerLabelPending,
      version: 4,
    ),
  );
}

RecordingDetail _speakerResolvedDetail() {
  return const RecordingDetail(
    recording: RecordingAsset(
      recordingId: 'recording-1',
      title: '服务器录音',
      status: RecordingRemoteStatus.deposited,
      transcriptStatus: 'final_transcript_generated',
    ),
    asrTask: AsrTaskSnapshot(
      asrTaskId: 'asr-1',
      status: RecordingRemoteStatus.completed,
      version: 5,
    ),
    finalTranscript: '@说话人 1 00:00:00\n转写已经完成。',
    finalTranscriptConfirmed: false,
  );
}

ApiResult<T> _success<T>(T data) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}
