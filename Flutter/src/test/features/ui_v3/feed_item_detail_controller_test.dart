import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_batch_transcription_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/automatic_outline_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_item_detail_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_append_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/outline_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/sprout_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';

void main() {
  test(
    'disposed detail readback cannot publish to the retired route',
    () async {
      final note = _syncedNote(id: 'disposed-readback-note');
      final library = KnowledgeLibraryController(
        initialNotes: [note],
        notePort: _LateResultKnowledgeNotePort(note),
        includeDemoFixtures: false,
      );
      addTearDown(library.dispose);
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
      );
      final refresh = controller.refreshDerivedParts();
      controller.dispose();
      expect(await refresh, isFalse);
      expect(library.noteForId(note.id)?.summaryBody, '# 云端迟到的纲要');
      expect(await controller.refreshDerivedParts(), isFalse);
      final replacement = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
      );
      addTearDown(replacement.dispose);
      expect(replacement.item.summaryBody, '# 云端迟到的纲要');
    },
  );

  testWidgets(
    'automatic Outline projection wait is shown instead of failure or manual generation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final note = _syncedNote(id: 'automatic-projection-wait');
      final library = KnowledgeLibraryController(
        initialNotes: [note],
        includeDemoFixtures: false,
      );
      final coordinator = AutomaticOutlineCoordinator(
        library: library,
        repository: null,
        tracker: _MutableDerivedPartTracker(
          taskId: 'none',
          localNoteId: 'other',
          remoteNoteId: 'other',
          targetPart: NoteFileAgentPart.outline,
          outputPartRevisionId: 'none',
        ),
        workspaceScope: 'workspace-test',
        retryBaseDelay: const Duration(hours: 1),
      );
      await coordinator.reconcileNow();
      expect(
        coordinator.tasks.single.phase,
        AutomaticOutlinePhase.retryWaiting,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            automaticOutlineCoordinatorProvider.overrideWith(
              (ref) => coordinator,
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: MaterialApp(
            home: V3FeedItemDetailPage(
              itemId: note.id,
              initialStage: V3ContentStage.summary,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('纲要等待自动恢复'), findsOneWidget);
      expect(find.text('纲要生成失败'), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-generate-outline')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('automatic Outline failure cannot leak across Raw revisions', () {
    final note = _syncedNote(
      id: 'revision-scoped-failure',
    ).copyWith(outlinePartRevisionId: 'outline-empty');
    final library = KnowledgeLibraryController(
      initialNotes: [note],
      includeDemoFixtures: false,
    );
    final tracker = _MutableDerivedPartTracker(
      taskId: 'auto-failed',
      localNoteId: note.id,
      remoteNoteId: note.remoteNoteId!,
      targetPart: NoteFileAgentPart.outline,
      outputPartRevisionId: '',
      operationId: 'auto-outline-v1-history',
      inputPartRevisionId: note.rawPartRevisionId,
      targetPartRevisionId: note.outlinePartRevisionId,
    )..completeFailed();
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      _RecordingOutlineRepository(),
      tracker,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);
    controller.refreshFromTaskTracker();
    expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
    library.updateNote(note.copyWith(rawPartRevisionId: 'raw-new'));
    controller.refreshFromLibrary();
    controller.refreshFromTaskTracker();
    expect(controller.outlineStatus, V3OutlineTaskStatus.notStarted);
    expect(controller.outlineErrorCode, isNull);
  });

  testWidgets('empty outline action invokes generation and renders writeback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = _syncedNote(id: 'outline-button-note');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final outline = _RecordingOutlineRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          outlineRepositoryProvider.overrideWithValue(outline),
          sproutRepositoryProvider.overrideWithValue(
            const _UnusedSproutRepository(),
          ),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('纲要'));
    await tester.pumpAndSettle();
    expect(find.text('生成纲要'), findsOneWidget);

    await tester.tap(find.text('生成纲要'));
    await tester.pumpAndSettle();

    expect(outline.operationIds, hasLength(1));
    expect(library.noteForId(note.id)?.summaryBody, contains('已生成纲要'));
    expect(find.text('已生成纲要'), findsOneWidget);
  });

  testWidgets('append summary does not hide formal outline action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = _syncedNote(id: 'outline-with-append-note');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final append = NoteAppendController(
      knowledgeLibrary: library,
      port: const _CompletedAppendPort(),
    );
    await append.submit(
      targetNoteId: note.id,
      source: NoteAppendSource.document,
      title: '追加材料',
    );
    expect(append.itemsFor(note.id).single.status, NoteAppendStatus.completed);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          noteAppendControllerProvider.overrideWith((ref) => append),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          outlineRepositoryProvider.overrideWithValue(
            _RecordingOutlineRepository(),
          ),
          sproutRepositoryProvider.overrideWithValue(
            const _UnusedSproutRepository(),
          ),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: note.id)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('纲要'));
    await tester.pumpAndSettle();

    expect(find.text('追加摘要'), findsOneWidget);
    expect(find.text('生成纲要'), findsOneWidget);
  });

  testWidgets('recording outline retry is exposed on the Note detail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = _recordingNote(
      id: 'recording-outline-widget-retry',
      minutesStatus: 'succeeded',
      summaryStatus: 'succeeded',
    );
    final notePort = _AutomaticRecordingNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final api = _AutomaticRecordingApi(
      detail: _recordingDetail(
        recordingId: note.recordingId!,
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
        outlineTaskStatus: RecordingNoteOutlineTaskStatus.failed,
        outlineFailureCode: 'WORKSPACE_NOT_READY',
        retryActions: const <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '重新生成纲要',
            allowed: true,
          ),
        ],
      ),
      onRetry: () => notePort.outlineReady = true,
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      recordingApi: api,
      recordingPollInterval: Duration.zero,
      recordingPollDelay: (_) =>
          Future<void>.delayed(const Duration(milliseconds: 1)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedItemDetailControllerProvider(
            note.id,
          ).overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          outlineRepositoryProvider.overrideWithValue(
            _RecordingOutlineRepository(),
          ),
          sproutRepositoryProvider.overrideWithValue(
            const _UnusedSproutRepository(),
          ),
        ],
        child: MaterialApp(
          home: V3FeedItemDetailPage(
            itemId: note.id,
            initialStage: V3ContentStage.summary,
          ),
        ),
      ),
    );
    final retry = find.byKey(const ValueKey('detail-retry-outline'));
    for (var frame = 0; frame < 20 && retry.evaluate().isEmpty; frame += 1) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    for (var frame = 0; frame < 20 && api.retryStages.isEmpty; frame += 1) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    for (
      var frame = 0;
      frame < 20 && controller.outlineStatus != V3OutlineTaskStatus.succeeded;
      frame += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(api.retryStages, <String>['recording_note_outline']);
    expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('failed recording update keeps the persisted outline visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const itemId = 'recording-outline-existing-content';
    final note =
        _recordingNote(
          id: itemId,
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
        ).copyWith(
          summaryBody: '# 已保存纲要\n\n- 这是上一次成功生成的内容',
          outlinePartRevisionId: 'outline-revision-$itemId',
        );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: _AutomaticRecordingNotePort(),
      includeDemoFixtures: false,
    );
    final api = _AutomaticRecordingApi(
      detail: _recordingDetail(
        recordingId: note.recordingId!,
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
        outlineTaskStatus: RecordingNoteOutlineTaskStatus.failed,
        outlineFailureCode: 'WORKSPACE_NOT_READY',
        retryActions: const <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'recording_note_outline',
            title: '重新生成纲要',
            allowed: true,
          ),
        ],
      ),
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      recordingApi: api,
      recordingPollInterval: Duration.zero,
      recordingPollDelay: (_) async {},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedItemDetailControllerProvider(
            note.id,
          ).overrideWith((ref) => controller),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          outlineRepositoryProvider.overrideWithValue(
            _RecordingOutlineRepository(),
          ),
          sproutRepositoryProvider.overrideWithValue(
            const _UnusedSproutRepository(),
          ),
        ],
        child: MaterialApp(
          home: V3FeedItemDetailPage(
            itemId: note.id,
            initialStage: V3ContentStage.summary,
          ),
        ),
      ),
    );
    for (
      var frame = 0;
      frame < 20 && controller.outlineStatus != V3OutlineTaskStatus.failed;
      frame += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.text('纲要更新失败'), findsOneWidget);
    expect(find.text('已保存纲要'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-summary-content')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('detail-retry-outline')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'opening an outline stage keeps a failed task in notification history',
    (tester) async {
      final note = _syncedNote(id: 'restored-terminal-outline-note');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      const projection = PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'local:agentTask:restored-outline',
            source: PendingMessageSource.agentTask,
            scene: 'outline',
            title: '纲要任务未完成',
            body: '打开资产查看状态后重试。',
            state: PendingMessageState.failed,
            isUnread: false,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            canMarkHandled: false,
            taskId: 'restored-outline-run-1',
            targetType: 'asset',
            targetId: 'restored-terminal-outline-note',
            stage: 'outline',
            isTask: true,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWithValue(projection),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: MaterialApp(
            home: V3FeedItemDetailPage(
              itemId: note.id,
              initialStage: V3ContentStage.summary,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(notifications.state.handledTaskIds, isEmpty);
    },
  );

  testWidgets(
    'authoritative raw content keeps a task without exact result provenance',
    (tester) async {
      const itemId = 'cold-start-missing-raw-note';
      const taskId = 'cold-start-raw-task-1';
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      const projection = PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'local:agentTask:cold-start-raw',
            source: PendingMessageSource.agentTask,
            scene: 'asset',
            title: '资料已生成',
            body: '可以查看结果。',
            state: PendingMessageState.succeeded,
            isUnread: true,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            taskId: taskId,
            targetType: 'asset',
            targetId: itemId,
            stage: 'raw',
            isTask: true,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWithValue(projection),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: const MaterialApp(home: V3FeedItemDetailPage(itemId: itemId)),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('detail-authoritative-unavailable')),
        findsOneWidget,
      );
      expect(notifications.state.handledTaskIds, isEmpty);
      expect(library.noteForId(itemId), isNull);

      library.updateNote(_syncedNote(id: itemId));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('detail-authoritative-unavailable')),
        findsNothing,
      );
      expect(notifications.state.handledTaskIds, isNot(contains(taskId)));
    },
  );

  testWidgets(
    'canonical Raw recording Note owns the receipt only after rendering',
    (tester) async {
      const itemId = 'local-recording-transcript-note';
      const recordingId = 'local-recording-transcript-1';
      final note = V3FeedItem(
        id: itemId,
        title: '本地录音转写',
        source: V3MaterialSource.monologue,
        createdAt: DateTime.utc(2026, 9, 2, 10),
        rawBody: '这是设备上已经可见、但尚未形成云端资产的转写。',
        recordingId: recordingId,
        syncState: NoteSyncState.synced,
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      final projectionStateProvider = StateProvider<PendingMessageProjection>(
        (ref) => const PendingMessageProjection(
          isLoading: false,
          resolutionIsDemo: false,
          items: <PendingMessage>[
            PendingMessage(
              id: 'local-recording-tracker-result',
              source: PendingMessageSource.recordingTranscription,
              scene: 'recording',
              title: '本地转写已完成',
              body: '录音仍在云端沉淀。',
              state: PendingMessageState.succeeded,
              isUnread: true,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              taskId: 'local-recording-tracker-task',
              targetType: 'recording',
              targetId: recordingId,
              stage: 'recording_processing',
              isTask: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWith(
              (ref) => ref.watch(projectionStateProvider),
            ),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: const MaterialApp(home: V3FeedItemDetailPage(itemId: itemId)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(V3FeedItemDetailPage)),
      );

      expect(
        notifications.state.handledTaskIds,
        isNot(contains('recording:$recordingId')),
      );

      library.updateNote(
        note.copyWith(
          remoteNoteId: 'remote-recording-note-1',
          noteRevisionId: 'recording-note-revision-1',
          rawPartRevisionId: 'recording-raw-revision-1',
          syncState: NoteSyncState.synced,
          updatedAt: DateTime.utc(2026, 9, 2, 10, 1),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final detailController = container.read(
        feedItemDetailControllerProvider(itemId),
      );
      expect(detailController.stage, V3ContentStage.raw);
      expect(detailController.item.remoteNoteId, 'remote-recording-note-1');
      expect(
        detailController.item.rawPartRevisionId,
        'recording-raw-revision-1',
      );
      expect(detailController.item.syncState, NoteSyncState.synced);
      expect(
        notifications.state.handledTaskIds,
        contains('recording:$recordingId'),
      );

      container
          .read(projectionStateProvider.notifier)
          .state = const PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'remote-recording-cloud-result',
            source: PendingMessageSource.remote,
            scene: 'recording',
            title: '录音已沉淀',
            body: '云端资产已经生成。',
            state: PendingMessageState.succeeded,
            isUnread: true,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            remoteNotificationId: 'remote-recording-cloud-result',
            taskId: 'recording:local-recording-transcript-1',
            targetType: 'recording',
            targetId: recordingId,
            stage: 'recording_processing',
            isTask: true,
            eventType: 'recording.deposit.succeeded',
          ),
        ],
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        notifications.state.handledTaskIds,
        contains('recording:$recordingId'),
      );
    },
  );

  testWidgets('raw aggregation acknowledges only its exact generated task', (
    tester,
  ) async {
    final seeds = <V3FeedItem>[
      for (var index = 0; index < 4; index += 1)
        V3FeedItem(
          id: 'source-note-$index',
          title: '聚合素材 $index',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 2, 9, index),
          rawBody: '聚合素材正文 $index',
        ),
      V3FeedItem(
        id: 'aggregation-hotspot',
        title: '聚合热点',
        source: V3MaterialSource.hotspot,
        ownership: V3NoteOwnership.hotspot,
        createdAt: DateTime.utc(2026, 9, 2, 10),
        rawBody: '热点正文',
      ),
    ];
    final library = KnowledgeLibraryController(
      initialNotes: seeds,
      includeDemoFixtures: false,
    );
    for (final note in seeds.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final profileHub = ProfileHubController(
      referenceDay: DateTime.utc(2026, 9, 2),
    );
    final aggregation = FeedAggregationController(
      library: library,
      profileHub: profileHub,
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
      now: () => DateTime.utc(2026, 9, 2, 11),
    );
    expect(aggregation.startSelection(), isTrue);
    final generated = await aggregation.confirm();
    expect(generated, isNotNull);
    final completedTaskId = aggregation.completedTaskId!;
    const unrelatedTaskId = 'unrelated-raw-task';
    final notifications = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    final projection = PendingMessageProjection(
      isLoading: false,
      resolutionIsDemo: false,
      items: <PendingMessage>[
        PendingMessage(
          id: 'aggregation-complete-row',
          source: PendingMessageSource.aggregation,
          scene: 'feed_ai',
          title: '聚合完成',
          body: '结果已经生成。',
          state: PendingMessageState.succeeded,
          isUnread: true,
          isDemo: false,
          isOpening: false,
          isResolving: false,
          taskId: completedTaskId,
          targetType: 'asset',
          targetId: generated!.id,
          stage: 'raw',
          isTask: true,
        ),
        PendingMessage(
          id: 'unrelated-raw-row',
          source: PendingMessageSource.agentTask,
          scene: 'asset',
          title: '其他任务',
          body: '缺少精确结果证明。',
          state: PendingMessageState.succeeded,
          isUnread: true,
          isDemo: false,
          isOpening: false,
          isResolving: false,
          taskId: unrelatedTaskId,
          targetType: 'asset',
          targetId: generated.id,
          stage: 'raw',
          isTask: true,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith((ref) => aggregation),
          notificationControllerProvider.overrideWith((ref) => notifications),
          pendingMessageProjectionProvider.overrideWithValue(projection),
          profileHubControllerProvider.overrideWith((ref) => profileHub),
        ],
        child: MaterialApp(home: V3FeedItemDetailPage(itemId: generated.id)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(notifications.state.handledTaskIds, contains(completedTaskId));
    expect(
      notifications.state.handledTaskIds,
      isNot(contains(unrelatedTaskId)),
    );
  });

  testWidgets(
    'visible outline acknowledges an exact remote result that arrives later',
    (tester) async {
      const outputRevision = 'late-outline-revision-2';
      final note = _syncedNote(id: 'late-remote-outline-note').copyWith(
        summaryBody: '# 旧纲要\n\n- 这是先前任务的结果',
        outlinePartRevisionId: 'late-outline-revision-1',
        updatedAt: DateTime.utc(2026, 9, 2, 14),
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      final runTracker = _RecordingDerivedPartTracker(
        taskLedger: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.derivedPart(
            taskId: 'late-remote-outline-task',
            localNoteId: note.id,
            remoteNoteId: note.remoteNoteId,
            targetPart: NoteFileAgentPart.outline,
            status: 'succeeded',
            createdAt: DateTime.utc(2026, 9, 2, 14),
            outputPartRevisionId: outputRevision,
          ),
        ],
      );
      final detailController = FeedItemDetailController(
        note.id,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        _RecordingOutlineRepository(),
        runTracker,
      );
      library.addListener(detailController.refreshFromLibrary);
      addTearDown(
        () => library.removeListener(detailController.refreshFromLibrary),
      );
      final projectionStateProvider = StateProvider<PendingMessageProjection>(
        (ref) => const PendingMessageProjection(
          isLoading: false,
          resolutionIsDemo: false,
          items: <PendingMessage>[],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWith(
              (ref) => ref.watch(projectionStateProvider),
            ),
            feedItemDetailControllerProvider(
              note.id,
            ).overrideWith((ref) => detailController),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: MaterialApp(
            home: V3FeedItemDetailPage(
              itemId: note.id,
              initialStage: V3ContentStage.summary,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(V3FeedItemDetailPage)),
      );

      expect(notifications.state.handledTaskIds, isEmpty);

      container
          .read(projectionStateProvider.notifier)
          .state = const PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'late-remote-unrelated-outline',
            source: PendingMessageSource.remote,
            scene: 'outline',
            title: '其他纲要已完成',
            body: '这不是当前页面的结果。',
            state: PendingMessageState.succeeded,
            isUnread: true,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            remoteNotificationId: 'late-remote-unrelated-outline',
            taskId: 'late-remote-unrelated-task',
            targetType: 'asset',
            targetId: 'another-note',
            stage: 'outline',
            isTask: true,
          ),
        ],
      );
      await tester.pump();
      await tester.pump();
      expect(notifications.state.handledTaskIds, isEmpty);

      container
          .read(projectionStateProvider.notifier)
          .state = const PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'late-remote-outline-delivery',
            source: PendingMessageSource.remote,
            scene: 'outline',
            title: '纲要已完成',
            body: '当前页面已经展示结果。',
            state: PendingMessageState.succeeded,
            isUnread: true,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            remoteNotificationId: 'late-remote-outline-delivery',
            taskId: 'late-remote-outline-task',
            targetType: 'asset',
            targetId: 'late-remote-outline-note',
            stage: 'outline',
            isTask: true,
          ),
        ],
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(notifications.state.handledTaskIds, isEmpty);

      library.updateNote(
        note.copyWith(
          summaryBody: '# 新纲要\n\n- 这是当前任务的精确结果',
          outlinePartRevisionId: outputRevision,
          updatedAt: DateTime.utc(2026, 9, 2, 14, 1),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        notifications.state.handledTaskIds,
        contains('late-remote-outline-task'),
      );
    },
  );

  testWidgets(
    'a covered detail waits for visible persisted content before acknowledgement',
    (tester) async {
      final note = _syncedNote(id: 'covered-terminal-outline-note');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      const outputRevision = 'covered-outline-revision-2';
      final runTracker = _RecordingDerivedPartTracker(
        taskLedger: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.derivedPart(
            taskId: 'covered-outline-run-1',
            localNoteId: note.id,
            remoteNoteId: note.remoteNoteId,
            targetPart: NoteFileAgentPart.outline,
            status: 'succeeded',
            createdAt: DateTime.utc(2026, 8, 15, 12),
            outputPartRevisionId: outputRevision,
          ),
        ],
      );
      final detailController = FeedItemDetailController(
        note.id,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        _RecordingOutlineRepository(),
        runTracker,
      );
      library.addListener(detailController.refreshFromLibrary);
      addTearDown(
        () => library.removeListener(detailController.refreshFromLibrary),
      );
      final activity = AppActivityCoordinator();
      addTearDown(activity.dispose);
      final projectionStateProvider = StateProvider<PendingMessageProjection>(
        (ref) => const PendingMessageProjection(
          isLoading: false,
          resolutionIsDemo: false,
          items: <PendingMessage>[
            PendingMessage(
              id: 'local:agentTask:covered-outline',
              source: PendingMessageSource.agentTask,
              scene: 'outline',
              title: '纲要生成中',
              body: '正在处理。',
              state: PendingMessageState.processing,
              isUnread: false,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              canMarkHandled: false,
              taskId: 'covered-outline-run-1',
              targetType: 'asset',
              targetId: 'covered-terminal-outline-note',
              stage: 'outline',
              isTask: true,
            ),
          ],
        ),
      );
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWith(
              (ref) => ref.watch(projectionStateProvider),
            ),
            feedItemDetailControllerProvider(
              note.id,
            ).overrideWith((ref) => detailController),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: <NavigatorObserver>[appRouteObserver],
            home: V3FeedItemDetailPage(
              itemId: note.id,
              initialStage: V3ContentStage.summary,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(V3FeedItemDetailPage)),
      );

      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      container
          .read(projectionStateProvider.notifier)
          .state = const PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'local:agentTask:covered-outline',
            source: PendingMessageSource.agentTask,
            scene: 'outline',
            title: '纲要已完成',
            body: '可以查看结果。',
            state: PendingMessageState.succeeded,
            isUnread: false,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            canMarkHandled: false,
            taskId: 'covered-outline-run-1',
            targetType: 'asset',
            targetId: 'covered-terminal-outline-note',
            stage: 'outline',
            isTask: true,
          ),
        ],
      );
      library.updateNote(
        note.copyWith(updatedAt: DateTime.utc(2026, 8, 15, 12)),
      );
      await tester.pump();
      await tester.pump();

      expect(notifications.state.handledTaskIds, isEmpty);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(notifications.state.handledTaskIds, isEmpty);

      activity.updateLifecycle(AppLifecycleState.inactive);
      library.updateNote(
        note.copyWith(
          summaryBody: '# 已生成纲要\n\n- 真实结果已经写入',
          outlinePartRevisionId: outputRevision,
          updatedAt: DateTime.utc(2026, 8, 15, 13),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(notifications.state.handledTaskIds, isEmpty);

      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(
        notifications.state.handledTaskIds,
        contains('covered-outline-run-1'),
      );
    },
  );

  testWidgets('visible result retries a transient exact verifier miss', (
    tester,
  ) async {
    const itemId = 'retry-exact-outline-note';
    const taskId = 'retry-exact-outline-task';
    const outputRevision = 'retry-exact-outline-r2';
    final note = _syncedNote(id: itemId).copyWith(
      summaryBody: '# 已生成纲要\n\n- 当前页面正在展示精确结果',
      outlinePartRevisionId: outputRevision,
      updatedAt: DateTime.utc(2026, 9, 2, 16),
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final notifications = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    final runTracker = _RecordingDerivedPartTracker(
      verificationResults: <String?>[null, outputRevision],
    );
    final detailController = FeedItemDetailController(
      itemId,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      _RecordingOutlineRepository(),
      runTracker,
    );
    library.addListener(detailController.refreshFromLibrary);
    addTearDown(
      () => library.removeListener(detailController.refreshFromLibrary),
    );
    final projectionStateProvider = StateProvider<PendingMessageProjection>(
      (ref) => const PendingMessageProjection(
        isLoading: false,
        resolutionIsDemo: false,
        items: <PendingMessage>[
          PendingMessage(
            id: 'local:agentTask:retry-exact-outline-task',
            source: PendingMessageSource.agentTask,
            scene: 'outline',
            title: '纲要已完成',
            body: '可以查看结果。',
            state: PendingMessageState.succeeded,
            isUnread: false,
            isDemo: false,
            isOpening: false,
            isResolving: false,
            canMarkHandled: false,
            taskId: taskId,
            targetType: 'asset',
            targetId: itemId,
            stage: 'outline',
            isTask: true,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          notificationControllerProvider.overrideWith((ref) => notifications),
          pendingMessageProjectionProvider.overrideWith(
            (ref) => ref.watch(projectionStateProvider),
          ),
          feedItemDetailControllerProvider(
            itemId,
          ).overrideWith((ref) => detailController),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
          outlineRepositoryProvider.overrideWithValue(
            _RecordingOutlineRepository(),
          ),
          sproutRepositoryProvider.overrideWithValue(
            const _UnusedSproutRepository(),
          ),
        ],
        child: const MaterialApp(
          home: V3FeedItemDetailPage(
            itemId: itemId,
            initialStage: V3ContentStage.summary,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(runTracker.verificationCalls, 1);
    expect(notifications.state.handledTaskIds, isNot(contains(taskId)));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();

    expect(runTracker.verificationCalls, 2);
    expect(notifications.state.handledTaskIds, contains(taskId));
  });

  testWidgets(
    'foreground starts a fresh exact verifier while the prior generation waits',
    (tester) async {
      const itemId = 'foreground-exact-outline-note';
      const taskId = 'foreground-exact-outline-task';
      const outputRevision = 'foreground-exact-outline-r2';
      final note = _syncedNote(id: itemId).copyWith(
        summaryBody: '# 已生成纲要\n\n- 当前页面正在展示精确结果',
        outlinePartRevisionId: outputRevision,
        updatedAt: DateTime.utc(2026, 9, 2, 17),
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      final firstVerification = Completer<String?>();
      final runTracker = _RecordingDerivedPartTracker(
        verificationResults: <FutureOr<String?>>[
          firstVerification.future,
          outputRevision,
        ],
      );
      final detailController = FeedItemDetailController(
        itemId,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        _RecordingOutlineRepository(),
        runTracker,
      );
      library.addListener(detailController.refreshFromLibrary);
      addTearDown(
        () => library.removeListener(detailController.refreshFromLibrary),
      );
      final activity = AppActivityCoordinator();
      addTearDown(activity.dispose);
      final projectionStateProvider = StateProvider<PendingMessageProjection>(
        (ref) => const PendingMessageProjection(
          isLoading: false,
          resolutionIsDemo: false,
          items: <PendingMessage>[
            PendingMessage(
              id: 'local:agentTask:foreground-exact-outline-task',
              source: PendingMessageSource.agentTask,
              scene: 'outline',
              title: '纲要已完成',
              body: '可以查看结果。',
              state: PendingMessageState.succeeded,
              isUnread: false,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              canMarkHandled: false,
              taskId: taskId,
              targetType: 'asset',
              targetId: itemId,
              stage: 'outline',
              isTask: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('detail-test-device-1'),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            notificationControllerProvider.overrideWith((ref) => notifications),
            pendingMessageProjectionProvider.overrideWith(
              (ref) => ref.watch(projectionStateProvider),
            ),
            feedItemDetailControllerProvider(
              itemId,
            ).overrideWith((ref) => detailController),
            profileHubControllerProvider.overrideWith(
              (ref) => ProfileHubController(),
            ),
            outlineRepositoryProvider.overrideWithValue(
              _RecordingOutlineRepository(),
            ),
            sproutRepositoryProvider.overrideWithValue(
              const _UnusedSproutRepository(),
            ),
          ],
          child: const MaterialApp(
            home: V3FeedItemDetailPage(
              itemId: itemId,
              initialStage: V3ContentStage.summary,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(runTracker.verificationCalls, 1);
      expect(notifications.state.handledTaskIds, isNot(contains(taskId)));

      activity.updateLifecycle(AppLifecycleState.inactive);
      await tester.pump();
      activity.updateLifecycle(AppLifecycleState.resumed);
      for (var i = 0; i < 5 && runTracker.verificationCalls < 2; i += 1) {
        await tester.pump();
      }

      expect(runTracker.verificationCalls, 2);
      expect(notifications.state.handledTaskIds, contains(taskId));

      firstVerification.complete(null);
      await tester.pump();
      expect(runTracker.verificationCalls, 2);
      expect(notifications.state.handledTaskIds, contains(taskId));
    },
  );

  test('exact terminal writeback exits the finalizing detail state', () {
    const outputRevision = 'terminal-outline-revision-2';
    final note = _syncedNote(id: 'terminal-outline-transition-note');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final tracker = _MutableDerivedPartTracker(
      taskId: 'agent_run_terminal_outline_1',
      localNoteId: note.id,
      remoteNoteId: note.remoteNoteId!,
      targetPart: NoteFileAgentPart.outline,
      outputPartRevisionId: outputRevision,
    );
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      _RecordingOutlineRepository(),
      tracker,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    controller.refreshFromTaskTracker();
    expect(controller.outlineStatus, V3OutlineTaskStatus.running);

    library.updateNote(
      note.copyWith(
        summaryBody: '# 已生成纲要\n\n- 精确写回已经可见',
        outlinePartRevisionId: outputRevision,
        updatedAt: DateTime.utc(2026, 9, 2, 15),
      ),
    );
    controller.refreshFromLibrary();
    expect(controller.outlineStatus, V3OutlineTaskStatus.running);

    var terminalNotifications = 0;
    controller.addListener(() => terminalNotifications += 1);
    tracker.completeSucceeded();
    controller.refreshFromTaskTracker();

    expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
    expect(terminalNotifications, 1);
  });

  test(
    'outline failure is visible and retry uses a new operation id',
    () async {
      final note = _syncedNote(id: 'outline-retry-note');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final outline = _RecordingOutlineRepository(failuresRemaining: 1);
      final controller = FeedItemDetailController(
        note.id,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        outline,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);
      final initialSnapshot = library.noteForId(note.id)!;

      expect(await controller.startOutline(), isFalse);
      expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
      expect(controller.outlineFailureMessage, isNotEmpty);
      expect(controller.item.summaryError, isNull);
      expect(library.noteForId(note.id), same(initialSnapshot));

      expect(await controller.retryOutline(), isTrue);
      expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
      expect(outline.operationIds, hasLength(2));
      expect(outline.operationIds.first, isNot(outline.operationIds.last));
    },
  );

  test(
    'accepted outline retry restores operation across route reconstruction',
    () async {
      final note = _syncedNote(id: 'accepted-outline-tracking-retry').copyWith(
        outlinePartRevisionId:
            'outline-revision-accepted-outline-tracking-retry',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final tracker = _RejectOnceDerivedPartTracker();
      final firstController = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: repository,
        runTracker: tracker,
      );
      addTearDown(library.dispose);

      expect(await firstController.startOutline(), isFalse);
      expect(
        firstController.outlineErrorCode,
        'DERIVED_TASK_TRACKER_UNAVAILABLE',
      );
      library.updateNote(
        note.copyWith(
          summaryBody: '# 后端已完成纲要',
          outlinePartRevisionId: 'outline-revision-after-completion',
          updatedAt: note.updatedAt.add(const Duration(seconds: 1)),
        ),
      );
      firstController.dispose();

      final reopenedController = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: repository,
        runTracker: tracker,
      );
      addTearDown(reopenedController.dispose);

      expect(await reopenedController.retryOutline(), isTrue);
      expect(repository.operationIds, hasLength(1));
      expect(repository.markTrackedCalls, 1);
      expect(tracker.trackCalls, 2);
    },
  );

  test(
    'accepted outline finishes durable handoff after detail disposal',
    () async {
      final note = _syncedNote(id: 'disposed-outline-handoff').copyWith(
        outlinePartRevisionId: 'outline-revision-disposed-outline-handoff',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _AcceptedOutlineRepository();
      final tracker = _DeferredDurableDerivedPartTracker();
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: repository,
        runTracker: tracker,
      );
      addTearDown(library.dispose);

      final started = controller.startOutline();
      await tracker.enrollmentStarted.future;
      controller.dispose();
      tracker.acknowledgeEnrollment();

      expect(await started, isTrue);
      expect(repository.markTrackedCalls, 1);
      expect(tracker.taskLedger, hasLength(1));
      expect(tracker.taskLedger.single.localNoteId, note.id);
      expect(
        tracker.taskLedger.single.targetPartRevisionId,
        note.outlinePartRevisionId,
      );
    },
  );

  test('outline explains an unpublished server capability', () async {
    final note = _syncedNote(id: 'outline-capability-note');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      const _FailingOutlineRepository('OUTLINE_CAPABILITY_NOT_PUBLISHED'),
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(await controller.startOutline(), isFalse);
    expect(controller.outlineFailureMessage, '纲要能力当前未发布，请稍后再试。');
  });

  test(
    'outline distinguishes an unavailable cloud sync from an unbound asset',
    () async {
      final note = _localNote(id: 'outline-sync-unavailable');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final controller = FeedItemDetailController(
        note.id,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        _RecordingOutlineRepository(),
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      expect(await controller.startOutline(), isFalse);
      expect(controller.outlineFailureMessage, '云端同步暂不可用，请稍后重试。');
    },
  );

  test(
    'sprout without a remote HNote fails visibly before repository call',
    () async {
      final note = V3FeedItem(
        id: 'local-sprout-note',
        title: '本地旧资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 12),
        rawBody: '尚未同步到 HNote 的正文。',
        syncState: NoteSyncState.localOnly,
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final sprout = _CountingSproutRepository();
      final controller = FeedItemDetailController(
        note.id,
        library,
        sprout,
        ProfileHubController(),
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      expect(await controller.startSprout(), isFalse);
      expect(sprout.calls, 0);
      expect(controller.sproutStatus, V3SproutTaskStatus.failed);
      expect(controller.sproutFailureMessage, contains('同步'));
      expect(controller.item.sproutStatus, V3SproutTaskStatus.notStarted);
      expect(controller.item.sproutError, isNull);
    },
  );

  test(
    'sprout submission survives detail disposal until tracker handoff',
    () async {
      final note = _syncedNote(id: 'background-sprout-note');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _DeferredAcceptedSproutRepository();
      final tracker = _RecordingDerivedPartTracker();
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: tracker,
      );
      addTearDown(library.dispose);

      final started = controller.startSprout();
      await _waitUntil(() => repository.submitCalls == 1);
      expect(
        library.sproutSubmissionFor(note.id)?.status,
        V3SproutTaskStatus.running,
      );

      controller.dispose();
      repository.complete(_acceptedSproutSnapshot(note));

      expect(await started, isTrue);
      expect(library.sproutSubmissionFor(note.id), isNull);
      expect(tracker.trackedFileAgentRunIds, <String>['file-run-background']);
    },
  );

  test(
    'sprout pre-acceptance failure remains visible after disposal',
    () async {
      final note = _syncedNote(id: 'failed-background-sprout');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _DeferredAcceptedSproutRepository();
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: _RecordingDerivedPartTracker(),
      );
      addTearDown(library.dispose);

      final started = controller.startSprout();
      await _waitUntil(() => repository.submitCalls == 1);
      controller.dispose();
      repository.fail('FAYA_RUN_SUBMIT_FAILED');

      expect(await started, isFalse);
      final submission = library.sproutSubmissionFor(note.id);
      expect(submission?.status, V3SproutTaskStatus.failed);
      expect(submission?.errorCode, 'FAYA_RUN_SUBMIT_FAILED');

      final reopened = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: _RecordingDerivedPartTracker(),
      );
      addTearDown(reopened.dispose);
      expect(reopened.sproutStatus, V3SproutTaskStatus.failed);
      expect(reopened.sproutFailureMessage, contains('重试'));
    },
  );

  test(
    'reopened running sprout observes a later shared submission failure',
    () async {
      final note = _syncedNote(id: 'reopened-before-sprout-failure');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _DeferredAcceptedSproutRepository();
      final original = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: _RecordingDerivedPartTracker(),
      );
      addTearDown(library.dispose);

      final started = original.startSprout();
      await _waitUntil(() => repository.submitCalls == 1);
      original.dispose();

      final reopened = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: _RecordingDerivedPartTracker(),
      );
      library.addListener(reopened.refreshFromLibrary);
      addTearDown(() {
        library.removeListener(reopened.refreshFromLibrary);
        reopened.dispose();
      });
      expect(reopened.sproutStatus, V3SproutTaskStatus.running);

      repository.fail('FAYA_RUN_SUBMIT_FAILED');

      expect(await started, isFalse);
      expect(reopened.sproutStatus, V3SproutTaskStatus.failed);
      expect(reopened.sproutErrorCode, 'FAYA_RUN_SUBMIT_FAILED');
      expect(reopened.sproutFailureMessage, contains('重试'));
    },
  );

  test(
    'accepted sprout keeps provisional failure when tracker rejects it',
    () async {
      final note = _syncedNote(id: 'rejected-sprout-tracking');
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _DeferredAcceptedSproutRepository();
      final tracker = _RecordingDerivedPartTracker(acceptTracking: false);
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        sproutRepository: repository,
        runTracker: tracker,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      final started = controller.startSprout();
      await _waitUntil(() => repository.submitCalls == 1);
      repository.complete(_acceptedSproutSnapshot(note));

      expect(await started, isFalse);
      expect(tracker.trackedStatuses, <String?>['queued']);
      expect(controller.sproutStatus, V3SproutTaskStatus.failed);
      expect(controller.sproutErrorCode, 'DERIVED_TASK_TRACKER_UNAVAILABLE');
      expect(
        library.sproutSubmissionFor(note.id)?.status,
        V3SproutTaskStatus.failed,
      );
    },
  );

  test('immediately failed accepted sprout reopens as terminal', () async {
    final note = _syncedNote(id: 'immediate-terminal-sprout');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final repository = _DeferredAcceptedSproutRepository();
    final tracker = _RecordingDerivedPartTracker();
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      sproutRepository: repository,
      runTracker: tracker,
    );
    addTearDown(library.dispose);

    final started = controller.startSprout();
    await _waitUntil(() => repository.submitCalls == 1);
    repository.complete(
      _acceptedSproutSnapshot(
        note,
        status: 'failed',
        failureCode: 'NOTE_FILE_AGENT_FAILED',
      ),
    );

    expect(await started, isFalse);
    controller.dispose();
    final reopened = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      sproutRepository: repository,
      runTracker: tracker,
    );
    addTearDown(reopened.dispose);
    expect(reopened.sproutStatus, V3SproutTaskStatus.failed);
    expect(reopened.sproutErrorCode, 'NOTE_FILE_AGENT_FAILED');
  });

  test('reopened sprout restores an accepted run cancellation', () {
    final note = _syncedNote(id: 'cancelled-background-sprout');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final tracker = _RecordingDerivedPartTracker(
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'file-run-cancelled',
          localNoteId: note.id,
          targetPart: NoteFileAgentPart.germination,
          status: 'cancelled',
          createdAt: DateTime.utc(2026, 8, 31, 10),
          failureCode: 'NOTE_FILE_AGENT_CANCELLED',
        ),
      ],
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      sproutRepository: const _UnusedSproutRepository(),
      runTracker: tracker,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(controller.sproutStatus, V3SproutTaskStatus.failed);
    expect(controller.sproutErrorCode, 'NOTE_FILE_AGENT_CANCELLED');
    expect(controller.sproutFailureMessage, contains('重试'));
  });

  test('exact sprout ledger survives a newer unrelated completion', () {
    final note = _syncedNote(id: 'older-cancelled-sprout');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final tracker = _RecordingDerivedPartTracker(
      completion: const DerivedPartRunCompletion(
        fileAgentRunId: 'newer-file-run',
        agentRunId: 'newer-agent-run',
        localNoteId: 'different-note',
        remoteNoteId: 'different-remote-note',
        targetPart: NoteFileAgentPart.outline,
        status: 'failed',
        failureCode: 'NEWER_UNRELATED_FAILURE',
      ),
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'newer-file-run',
          localNoteId: 'different-note',
          targetPart: NoteFileAgentPart.outline,
          status: 'failed',
          createdAt: DateTime.utc(2026, 8, 31, 11),
          failureCode: 'NEWER_UNRELATED_FAILURE',
        ),
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'older-file-run',
          localNoteId: note.id,
          targetPart: NoteFileAgentPart.germination,
          status: 'cancelled',
          createdAt: DateTime.utc(2026, 8, 31, 10),
          failureCode: 'NOTE_FILE_AGENT_CANCELLED',
        ),
      ],
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      sproutRepository: const _UnusedSproutRepository(),
      runTracker: tracker,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(controller.sproutStatus, V3SproutTaskStatus.failed);
    expect(controller.sproutErrorCode, 'NOTE_FILE_AGENT_CANCELLED');
  });

  test('active sprout submission wins over an older terminal ledger', () {
    final note = _syncedNote(id: 'retried-background-sprout');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    )..beginSproutSubmission(noteId: note.id, operationId: 'current-retry');
    final tracker = _RecordingDerivedPartTracker(
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'older-file-run',
          localNoteId: note.id,
          targetPart: NoteFileAgentPart.germination,
          status: 'failed',
          createdAt: DateTime.utc(2026, 8, 31, 9),
          failureCode: 'OLDER_FAILURE',
        ),
      ],
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      sproutRepository: const _UnusedSproutRepository(),
      runTracker: tracker,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(controller.sproutStatus, V3SproutTaskStatus.running);
    expect(controller.sproutErrorCode, isNull);
  });

  test('late cloud outline replaces only the current detail failure', () async {
    final note = _syncedNote(id: 'late-outline-note');
    final notePort = _LateResultKnowledgeNotePort(note);
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      _RecordingOutlineRepository(failuresRemaining: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(await controller.startOutline(), isFalse);
    expect(controller.outlineStatus, V3OutlineTaskStatus.failed);

    expect(await controller.refreshDerivedParts(), isTrue);
    expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
    expect(controller.outlineFailureMessage, isNull);
    expect(controller.item.summaryBody, '# 云端迟到的纲要');
  });

  test('unavailable readback preserves a current detail failure', () async {
    final note = _syncedNote(id: 'unavailable-readback-note');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: const _UnavailableDerivedPartPort(),
      includeDemoFixtures: false,
    );
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      _RecordingOutlineRepository(failuresRemaining: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(await controller.startOutline(), isFalse);
    final failure = controller.outlineFailureMessage;

    expect(await controller.refreshDerivedParts(), isFalse);
    expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
    expect(controller.outlineFailureMessage, failure);
  });

  test('legacy local asset syncs before outline generation', () async {
    final note = _localNote(id: 'legacy-outline-note');
    final notePort = _SynchronizingKnowledgeNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final outline = _RecordingOutlineRepository();
    final controller = FeedItemDetailController(
      note.id,
      library,
      const _UnusedSproutRepository(),
      ProfileHubController(),
      outline,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(await controller.startOutline(), isTrue);
    expect(notePort.calls, 1);
    expect(outline.notes.single.remoteNoteId, 'remote-${note.id}');
    expect(outline.notes.single.rawPartRevisionId, 'raw-revision-1');
    expect(controller.item.summaryBody, contains('已生成纲要'));
  });

  test(
    'outline uses a binding that completed after the detail route opened',
    () async {
      final note = _localNote(id: 'late-binding-outline-note');
      final notePort = _SynchronizingKnowledgeNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final outline = _RecordingOutlineRepository();
      final controller = FeedItemDetailController(
        note.id,
        library,
        const _UnusedSproutRepository(),
        ProfileHubController(),
        outline,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      expect(
        (await library.syncNote(note.id)).outcome,
        KnowledgeNoteSyncOutcome.synced,
      );
      expect(await controller.startOutline(), isTrue);

      expect(notePort.calls, 1);
      expect(outline.notes.single.remoteNoteId, 'remote-${note.id}');
      expect(outline.notes.single.rawPartRevisionId, 'raw-revision-1');
    },
  );

  test('legacy local asset syncs before sprout generation', () async {
    final note = _localNote(id: 'legacy-sprout-note');
    final notePort = _SynchronizingKnowledgeNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final sprout = _RecordingSproutRepository();
    final controller = FeedItemDetailController(
      note.id,
      library,
      sprout,
      ProfileHubController(),
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(await controller.startSprout(), isTrue);
    expect(notePort.calls, 1);
    expect(sprout.notes.single.remoteNoteId, 'remote-${note.id}');
    expect(sprout.notes.single.rawPartRevisionId, 'raw-revision-1');
    expect(controller.item.sproutStatus, V3SproutTaskStatus.succeeded);
    expect(controller.item.sproutReport?.title, '${note.title} · 深度洞察报告');
  });

  test(
    'recording outline polls recording detail and HNote without File Agent',
    () async {
      final note = _recordingNote(id: 'recording-outline-poll');
      final notePort = _AutomaticRecordingNotePort(outlineReady: true);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final outline = _RecordingOutlineRepository();
      final api = _AutomaticRecordingApi(
        detail: _recordingDetail(
          recordingId: note.recordingId!,
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
        ),
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: outline,
        recordingApi: api,
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) async {},
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      await _waitUntil(
        () => controller.outlineStatus == V3OutlineTaskStatus.succeeded,
      );

      expect(controller.item.summaryBody, '# 后端自动纲要');
      expect(controller.item.minutesStatus, 'succeeded');
      expect(controller.item.summaryStatus, 'succeeded');
      expect(api.detailCalls, greaterThanOrEqualTo(1));
      expect(notePort.loadCalls, greaterThanOrEqualTo(1));
      expect(await controller.startOutline(), isFalse);
      expect(outline.operationIds, isEmpty);
    },
  );

  test(
    'persisted recording outline is readable without local task history',
    () {
      final note = V3FeedItem(
        id: 'recording-outline-cold-cache',
        title: '历史录音',
        source: V3MaterialSource.recordingCard,
        createdAt: DateTime.utc(2026, 8, 27),
        rawBody: '录音最终转写正文',
        summaryBody: '# 已生成纲要',
        remoteNoteId: 'remote-recording-outline-cold-cache',
        noteRevisionId: 'note-revision-recording-outline-cold-cache',
        rawPartRevisionId: 'raw-revision-recording-outline-cold-cache',
        outlinePartRevisionId: 'outline-revision-recording-outline-cold-cache',
        etag: '"recording-outline-cold-cache"',
        contentCursor: 'cursor-recording-outline-cold-cache',
        syncState: NoteSyncState.synced,
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      expect(controller.usesBackendRecordingOutline, isTrue);
      expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
      expect(controller.item.summaryBody, '# 已生成纲要');
    },
  );

  test(
    'cached recording outline still verifies the exact server receipt',
    () async {
      const itemId = 'recording-outline-cached-verification';
      final note =
          _recordingNote(
            id: itemId,
            minutesStatus: 'succeeded',
            summaryStatus: 'succeeded',
          ).copyWith(
            summaryBody: '# 已缓存纲要',
            outlinePartRevisionId: 'outline-revision-$itemId',
          );
      final notePort = _AutomaticRecordingNotePort(outlineReady: true);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final api = _AutomaticRecordingApi(
        detail: _recordingDetail(
          recordingId: note.recordingId!,
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
        ),
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        recordingApi: api,
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) async {},
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
      await _waitUntil(() => api.detailCalls > 0);
      await _waitUntil(() => controller.item.summaryBody == '# 后端自动纲要');

      expect(controller.outlineStatus, V3OutlineTaskStatus.succeeded);
      expect(api.detailCalls, 1);
      expect(notePort.loadCalls, greaterThanOrEqualTo(1));
    },
  );

  test(
    'recording intermediate outline stays running without exact final receipt',
    () async {
      final note = _recordingNote(id: 'recording-intermediate-outline');
      final notePort = _AutomaticRecordingNotePort(outlineReady: true);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final blockedDelay = Completer<void>();
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        recordingApi: _AutomaticRecordingApi(
          detail: _recordingDetail(
            recordingId: note.recordingId!,
            minutesStatus: 'succeeded',
            summaryStatus: 'running',
          ),
        ),
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) => blockedDelay.future,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      await _waitUntil(() => notePort.loadCalls > 0);

      expect(controller.item.summaryBody, '# 后端自动纲要');
      expect(
        controller.item.outlinePartRevisionId,
        'outline-revision-${note.id}',
      );
      expect(controller.outlineTaskStatus, V3DerivedTaskStatus.running);
      expect(controller.outlineStatus, V3OutlineTaskStatus.running);
    },
  );

  test('recording outline poll exhaustion remains nonterminal', () async {
    final note = _recordingNote(id: 'recording-outline-timeout');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: _AutomaticRecordingNotePort(),
      includeDemoFixtures: false,
    );
    final api = _AutomaticRecordingApi(
      detail: _recordingDetail(
        recordingId: note.recordingId!,
        minutesStatus: 'running',
        summaryStatus: 'pending',
      ),
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      recordingApi: api,
      recordingPollInterval: Duration.zero,
      recordingPollDelay: (_) async {},
      recordingMaxPollAttempts: 1,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    await _waitUntil(() => api.detailCalls == 1);
    await Future<void>.delayed(Duration.zero);

    expect(controller.outlineTaskStatus, V3DerivedTaskStatus.running);
    expect(controller.outlineErrorCode, isNull);
    expect(controller.canRetryOutline, isFalse);
    expect(api.detailCalls, 1);
    expect(await controller.retryOutline(), isFalse);
    expect(api.retryStages, isEmpty);
  });

  test(
    'recording outline retries only an authorized recording stage',
    () async {
      final note = _recordingNote(
        id: 'recording-outline-retry',
        minutesStatus: 'failed',
      );
      final notePort = _AutomaticRecordingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final outline = _RecordingOutlineRepository();
      late final _AutomaticRecordingApi api;
      final processingRetryPort = _FakeRecordingProcessingRetryPort();
      final retryEvents = <String>[];
      final runTracker = _RecordingOutlineRetryTracker(retryEvents);
      final retryLifecycle = _FakeRecordingOutlineRetryLifecyclePort(
        retryEvents,
      );
      final staleFailure = _recordingDetail(
        recordingId: note.recordingId!,
        minutesStatus: 'failed',
        retryActions: const <RecordingRetryAction>[
          RecordingRetryAction(
            stage: 'minutes_generation',
            title: '重新生成纲要',
            allowed: true,
          ),
        ],
      );
      api = _AutomaticRecordingApi(
        detail: staleFailure,
        detailsAfterRetry: <RecordingDetail>[
          staleFailure,
          _recordingDetail(
            recordingId: note.recordingId!,
            minutesStatus: 'succeeded',
            summaryStatus: 'succeeded',
            outlineTaskId: 'outline-task-after-retry',
          ),
        ],
        onRetry: () => notePort.outlineReady = true,
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: outline,
        runTracker: runTracker,
        recordingApi: api,
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) async {},
        idempotencyKeyFactory: () => 'recording-retry-idem',
        recordingProcessingRetryPort: processingRetryPort,
        recordingOutlineRetryLifecyclePort: retryLifecycle,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      await _waitUntil(() => controller.canRetryOutline);
      expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
      expect(await controller.retryOutline(), isTrue);
      await _waitUntil(
        () => controller.outlineStatus == V3OutlineTaskStatus.succeeded,
      );

      expect(api.retryStages, <String>['minutes_generation']);
      expect(api.retryKeys, <String>['recording-retry-idem']);
      expect(processingRetryPort.recordingIds, <String>[note.recordingId!]);
      final trackerRestart = retryEvents.indexWhere(
        (event) => event == 'track:${note.recordingId}:retry:-:retry-task-1',
      );
      final batchAcceptance = retryEvents.indexWhere(
        (event) =>
            event ==
            'accept:${note.recordingId}:retry-task-1:'
                'minutes_generation:retry-task-1',
      );
      expect(trackerRestart, greaterThanOrEqualTo(0));
      expect(batchAcceptance, greaterThan(trackerRestart));
      expect(outline.operationIds, isEmpty);
    },
  );

  test('recording outline never falls back to an ASR-only retry', () async {
    final note = _recordingNote(
      id: 'recording-outline-asr-only',
      minutesStatus: 'succeeded',
      summaryStatus: 'succeeded',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: _AutomaticRecordingNotePort(),
      includeDemoFixtures: false,
    );
    final api = _AutomaticRecordingApi(
      detail: _recordingDetail(
        recordingId: note.recordingId!,
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
        outlineTaskStatus: RecordingNoteOutlineTaskStatus.failed,
        retryActions: const <RecordingRetryAction>[
          RecordingRetryAction(stage: 'asr', title: '重新转写', allowed: true),
        ],
      ),
    );
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      recordingApi: api,
      recordingPollInterval: Duration.zero,
      recordingPollDelay: (_) async {},
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    await _waitUntil(() => api.detailCalls > 0);
    await Future<void>.delayed(Duration.zero);

    expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
    expect(controller.canRetryOutline, isFalse);
    expect(await controller.retryOutline(), isFalse);
    expect(api.retryStages, isEmpty);
  });

  test(
    'recording Note outline retries the exact server-authorized stage',
    () async {
      final note = _recordingNote(
        id: 'recording-note-outline-retry',
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
      );
      final notePort = _AutomaticRecordingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: notePort,
        includeDemoFixtures: false,
      );
      final outline = _RecordingOutlineRepository();
      late final _AutomaticRecordingApi api;
      final retryLifecycle = _FakeRecordingOutlineRetryLifecyclePort();
      api = _AutomaticRecordingApi(
        detail: _recordingDetail(
          recordingId: note.recordingId!,
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
          outlineTaskStatus: RecordingNoteOutlineTaskStatus.failed,
          outlineFailureCode: 'WORKSPACE_NOT_READY',
          retryActions: const <RecordingRetryAction>[
            RecordingRetryAction(
              stage: 'recording_note_outline',
              title: '重新生成纲要',
              allowed: true,
            ),
          ],
        ),
        onRetry: () => notePort.outlineReady = true,
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        outlineRepository: outline,
        recordingApi: api,
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) async {},
        idempotencyKeyFactory: () => 'recording-note-outline-retry-idem',
        recordingOutlineRetryLifecyclePort: retryLifecycle,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);

      await _waitUntil(
        () =>
            controller.canRetryOutline &&
            controller.outlineStatus == V3OutlineTaskStatus.failed,
      );
      expect(controller.outlineErrorCode, 'WORKSPACE_NOT_READY');
      expect(controller.outlineFailureMessage, contains('工作空间尚未准备完成'));

      expect(await controller.retryOutline(), isTrue);
      await _waitUntil(
        () => controller.outlineStatus == V3OutlineTaskStatus.succeeded,
      );

      expect(api.retryStages, <String>['recording_note_outline']);
      expect(api.retryKeys, <String>['recording-note-outline-retry-idem']);
      expect(retryLifecycle.events, <String>[
        'accept:${note.recordingId}:retry-task-1:recording_note_outline:'
            'recording-outline-task-${note.id}',
      ]);
      expect(outline.operationIds, isEmpty);
    },
  );

  test(
    'recording outline retry rejection restores the exact failure',
    () async {
      final note = _recordingNote(
        id: 'recording-outline-retry-rejected',
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        notePort: _AutomaticRecordingNotePort(),
        includeDemoFixtures: false,
      );
      final retryLifecycle = _FakeRecordingOutlineRetryLifecyclePort();
      final api = _AutomaticRecordingApi(
        detail: _recordingDetail(
          recordingId: note.recordingId!,
          minutesStatus: 'succeeded',
          summaryStatus: 'succeeded',
          outlineTaskStatus: RecordingNoteOutlineTaskStatus.failed,
          outlineFailureCode: 'WORKSPACE_NOT_READY',
          retryActions: const <RecordingRetryAction>[
            RecordingRetryAction(
              stage: 'recording_note_outline',
              title: '重新生成纲要',
              allowed: true,
            ),
          ],
        ),
        retryResult: ApiResult<RetryRecordingResponse>.failure(
          error: const AppFailure(
            code: 'WORKSPACE_NOT_READY',
            category: AppFailureCategory.api,
            message: 'workspace is not ready',
            userMessageKey: 'workspace.not_ready',
            isRetryable: true,
          ),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        recordingApi: api,
        recordingPollInterval: Duration.zero,
        recordingPollDelay: (_) async {},
        recordingOutlineRetryLifecyclePort: retryLifecycle,
      );
      addTearDown(controller.dispose);
      addTearDown(library.dispose);
      await _waitUntil(() => controller.canRetryOutline);

      expect(await controller.retryOutline(), isFalse);

      expect(controller.outlineStatus, V3OutlineTaskStatus.failed);
      expect(controller.outlineErrorCode, 'WORKSPACE_NOT_READY');
      expect(controller.outlineFailureMessage, contains('工作空间尚未准备完成'));
      expect(retryLifecycle.events, <String>[
        'reject:${note.recordingId}:WORKSPACE_NOT_READY',
      ]);
    },
  );

  test('legacy recording source never falls back to generic outline', () async {
    final note = V3FeedItem(
      id: 'legacy-recording-without-id',
      title: '跨设备录音资产',
      source: V3MaterialSource.recordingCard,
      createdAt: DateTime.utc(2026, 8, 17),
      rawBody: '已经同步的录音正文',
      minutesStatus: 'failed',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final outline = _RecordingOutlineRepository();
    final controller = FeedItemDetailController.withDependencies(
      itemId: note.id,
      library: library,
      outlineRepository: outline,
    );
    addTearDown(controller.dispose);
    addTearDown(library.dispose);

    expect(controller.canGenerateOutline, isFalse);
    expect(controller.canRetryOutline, isFalse);
    expect(await controller.startOutline(), isFalse);
    expect(await controller.retryOutline(), isFalse);
    expect(outline.operationIds, isEmpty);
  });

  test('outline selector follows the asset source', () {
    for (final source in <V3MaterialSource>{
      V3MaterialSource.meeting,
      V3MaterialSource.internalRecording,
      V3MaterialSource.monologue,
      V3MaterialSource.recordingCard,
    }) {
      final selector = outlineSelectorForSource(source);
      expect(selector.agentProfileId, 'recording_postprocess_agent');
      expect(selector.skillProfileIds, <String>['meeting_minutes']);
    }

    final selector = outlineSelectorForSource(V3MaterialSource.documentImport);
    expect(selector.agentProfileId, 'general_minutes');
    expect(selector.skillProfileIds, <String>['general_minutes']);
  });
}

V3FeedItem _syncedNote({required String id}) => V3FeedItem(
  id: id,
  title: '待生成资产',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 12),
  rawBody: '这是用于生成纲要的完整原始内容。',
  remoteNoteId: 'remote-$id',
  noteRevisionId: 'note-revision-$id',
  rawPartRevisionId: 'raw-revision-$id',
  etag: '"note-$id"',
  contentCursor: 'cursor-$id',
  syncState: NoteSyncState.synced,
);

V3FeedItem _localNote({required String id}) => V3FeedItem(
  id: id,
  title: '历史本地资产',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 12),
  rawBody: '这是等待同步的历史资产原文。',
  syncState: NoteSyncState.localOnly,
);

NoteFileAgentRunSnapshot _acceptedSproutSnapshot(
  V3FeedItem note, {
  String status = 'queued',
  String? failureCode,
}) => NoteFileAgentRunSnapshot(
  fileAgentRunId: 'file-run-background',
  noteId: note.remoteNoteId!,
  status: status,
  agentRunId: 'agent-run-background',
  inputPart: NoteFileAgentPart.raw,
  inputPartRevisionId: note.rawPartRevisionId!,
  targetPart: NoteFileAgentPart.germination,
  targetPartRevisionId: 'germination-revision-background',
  failureCode: failureCode,
);

V3FeedItem _recordingNote({
  required String id,
  String? minutesStatus = 'running',
  String? summaryStatus = 'pending',
}) => V3FeedItem(
  id: id,
  title: '自动处理录音',
  source: V3MaterialSource.meeting,
  createdAt: DateTime.utc(2026, 8, 17),
  rawBody: '录音最终转写正文',
  recordingId: 'recording-$id',
  minutesStatus: minutesStatus,
  summaryStatus: summaryStatus,
  remoteNoteId: 'remote-$id',
  noteRevisionId: 'note-revision-$id',
  rawPartRevisionId: 'raw-revision-$id',
  etag: '"note-$id"',
  contentCursor: 'cursor-$id',
  syncState: NoteSyncState.synced,
);

RecordingDetail _recordingDetail({
  required String recordingId,
  String? minutesStatus,
  String? summaryStatus,
  RecordingNoteOutlineTaskStatus? outlineTaskStatus,
  String? outlineFailureCode,
  String? outlineTaskId,
  List<RecordingRetryAction> retryActions = const <RecordingRetryAction>[],
}) {
  final localNoteId = recordingId.startsWith('recording-')
      ? recordingId.substring('recording-'.length)
      : recordingId;
  final outlineSucceeded =
      minutesStatus == 'succeeded' && summaryStatus == 'succeeded';
  final effectiveOutlineTaskStatus =
      outlineTaskStatus ??
      (outlineSucceeded ? RecordingNoteOutlineTaskStatus.succeeded : null);
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: recordingId,
      title: '自动处理录音',
      status: minutesStatus == 'failed'
          ? RecordingRemoteStatus.failed
          : RecordingRemoteStatus.generatingSummary,
      transcriptStatus: 'final_transcript_generated',
      minutesStatus: minutesStatus,
      summaryStatus: summaryStatus,
    ),
    finalTranscript: '录音最终转写正文',
    finalTranscriptConfirmed: true,
    noteRef: outlineSucceeded
        ? RecordingNoteRef(
            noteId: 'remote-$localNoteId',
            rawPartRevisionId: 'raw-revision-$localNoteId',
            outlinePartRevisionId: 'outline-revision-$localNoteId',
          )
        : null,
    noteOutlineTask: effectiveOutlineTaskStatus != null
        ? RecordingNoteOutlineTask(
            taskId: outlineTaskId ?? 'recording-outline-task-$localNoteId',
            status: effectiveOutlineTaskStatus,
            failureCode: outlineFailureCode,
          )
        : null,
    retryActions: retryActions,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition was not reached');
}

final class _RecordingOutlineRepository implements OutlineRepository {
  _RecordingOutlineRepository({this.failuresRemaining = 0});

  int failuresRemaining;
  final List<String> operationIds = <String>[];
  final List<V3FeedItem> notes = <V3FeedItem>[];

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    operationIds.add(operationId);
    notes.add(note);
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw const OutlineGenerationException('OUTLINE_RUN_SUBMIT_FAILED');
    }
    return '# 已生成纲要\n\n- 保留原始事实';
  }
}

final class _RecordingSproutRepository implements SproutRepository {
  final List<V3FeedItem> notes = <V3FeedItem>[];

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    notes.add(note);
    return V3SproutReport(
      id: 'sprout-result',
      noteId: note.id,
      title: '${note.title} · 深度洞察报告',
      markdown: '# 深度洞察报告\n\n- 已生成',
      generatedAt: DateTime.utc(2026, 8, 12),
    );
  }
}

final class _DeferredAcceptedSproutRepository
    implements SproutRepository, AcceptedSproutRunRepository {
  final Completer<NoteFileAgentRunSnapshot> _submission =
      Completer<NoteFileAgentRunSnapshot>();
  int submitCalls = 0;

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
  }) {
    submitCalls += 1;
    return _submission.future;
  }

  void complete(NoteFileAgentRunSnapshot snapshot) =>
      _submission.complete(snapshot);

  void fail(String code) =>
      _submission.completeError(SproutGenerationException(code));

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) => throw StateError('accepted submission path expected');
}

final class _MutableDerivedPartTracker implements DerivedPartRunTrackingPort {
  _MutableDerivedPartTracker({
    required this.taskId,
    required this.localNoteId,
    required this.remoteNoteId,
    required this.targetPart,
    required this.outputPartRevisionId,
    this.operationId,
    this.inputPartRevisionId,
    this.targetPartRevisionId,
  });

  final String taskId;
  final String localNoteId;
  final String remoteNoteId;
  final NoteFileAgentPart targetPart;
  final String outputPartRevisionId;
  final String? operationId;
  final String? inputPartRevisionId;
  final String? targetPartRevisionId;
  bool _pending = true;
  String _status = 'finalizing';

  void completeSucceeded() {
    _pending = false;
    _status = 'succeeded';
  }

  void completeFailed() {
    _pending = false;
    _status = 'failed';
  }

  @override
  String? derivedPartStatus(
    String candidateNoteId,
    NoteFileAgentPart candidatePart,
  ) => candidateNoteId == localNoteId && candidatePart == targetPart
      ? _status
      : null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(
    String candidateNoteId,
    NoteFileAgentPart candidatePart,
  ) =>
      _pending && candidateNoteId == localNoteId && candidatePart == targetPart;

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => _pending
      ? null
      : DerivedPartRunCompletion(
          fileAgentRunId: taskId,
          localNoteId: localNoteId,
          remoteNoteId: remoteNoteId,
          targetPart: targetPart,
          status: _status,
          outputPartRevisionId: outputPartRevisionId,
          operationId: operationId,
          inputPartRevisionId: inputPartRevisionId,
          targetPartRevisionId: targetPartRevisionId,
        );

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {}
}

final class _RecordingDerivedPartTracker
    implements
        DerivedPartRunTrackingPort,
        DerivedPartResultVerificationPort,
        AgentTaskLedgerPort {
  _RecordingDerivedPartTracker({
    this.completion,
    List<AgentTaskLedgerEntry> taskLedger = const <AgentTaskLedgerEntry>[],
    List<FutureOr<String?>> verificationResults = const <FutureOr<String?>>[],
    this.acceptTracking = true,
  }) : _taskLedger = List<AgentTaskLedgerEntry>.of(taskLedger),
       _verificationResults = List<FutureOr<String?>>.of(verificationResults);

  final DerivedPartRunCompletion? completion;
  final bool acceptTracking;
  final List<AgentTaskLedgerEntry> _taskLedger;
  final List<FutureOr<String?>> _verificationResults;
  int verificationCalls = 0;
  @override
  List<AgentTaskLedgerEntry> get taskLedger =>
      List<AgentTaskLedgerEntry>.unmodifiable(_taskLedger);
  final List<String> trackedFileAgentRunIds = <String>[];
  final List<String?> trackedStatuses = <String?>[];

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    trackedFileAgentRunIds.add(fileAgentRunId);
    trackedStatuses.add(status);
    if (!acceptTracking) return;
    _taskLedger.removeWhere((entry) => entry.taskId == fileAgentRunId);
    _taskLedger.add(
      AgentTaskLedgerEntry.derivedPart(
        taskId: fileAgentRunId,
        localNoteId: localNoteId,
        remoteNoteId: remoteNoteId,
        targetPart: targetPart,
        status: status ?? 'queued',
        createdAt: DateTime.utc(2026, 8, 31, 12),
        inputPartRevisionId: inputPartRevisionId,
        targetPartRevisionId: targetPartRevisionId,
        operationId: operationId,
        agentRunId: agentRunId,
      ),
    );
  }

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      false;

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => completion;

  @override
  Future<String?> verifySucceededDerivedOutputRevision({
    required String fileAgentRunId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    verificationCalls += 1;
    return Future<String?>.value(
      _verificationResults.isEmpty ? null : _verificationResults.removeAt(0),
    );
  }
}

final class _AcceptedOutlineRepository
    implements
        OutlineRepository,
        AcceptedOutlineRunRepository,
        OutlineAdmissionTrackingPort,
        PendingOutlineAdmissionPort {
  final List<String> operationIds = <String>[];
  int markTrackedCalls = 0;
  String? _pendingOperationId;
  NoteFileAgentRunSnapshot? _pendingAccepted;

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async => throw StateError('accepted outline path expected');

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    operationIds.add(operationId);
    _pendingOperationId ??= operationId;
    final accepted = NoteFileAgentRunSnapshot(
      fileAgentRunId: 'file-run-${note.id}',
      noteId: note.remoteNoteId!,
      status: 'queued',
      agentRunId: 'agent-run-${note.id}',
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: note.rawPartRevisionId!,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId: note.outlinePartRevisionId!,
    );
    _pendingAccepted = accepted;
    return accepted;
  }

  @override
  void markOutlineAdmissionTracked(NoteFileAgentRunSnapshot accepted) {
    markTrackedCalls += 1;
    _pendingOperationId = null;
    _pendingAccepted = null;
  }

  @override
  PendingOutlineAdmission? pendingOutlineAdmission(V3FeedItem note) =>
      _pendingOperationId == null
      ? null
      : PendingOutlineAdmission(
          operationId: _pendingOperationId!,
          accepted: _pendingAccepted,
        );

  @override
  String? pendingOutlineOperationId(V3FeedItem note) => _pendingOperationId;
}

final class _RejectOnceDerivedPartTracker
    implements DerivedPartRunTrackingPort, AgentTaskLedgerPort {
  final List<AgentTaskLedgerEntry> _ledger = <AgentTaskLedgerEntry>[];
  int trackCalls = 0;

  @override
  List<AgentTaskLedgerEntry> get taskLedger =>
      List<AgentTaskLedgerEntry>.unmodifiable(_ledger);

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    trackCalls += 1;
    if (trackCalls == 1) return;
    _ledger.add(
      AgentTaskLedgerEntry.derivedPart(
        taskId: fileAgentRunId,
        localNoteId: localNoteId,
        remoteNoteId: remoteNoteId,
        targetPart: targetPart,
        status: status ?? 'queued',
        createdAt: DateTime.utc(2026, 9, 15),
        inputPartRevisionId: inputPartRevisionId,
        targetPartRevisionId: targetPartRevisionId,
        operationId: operationId,
        agentRunId: agentRunId,
      ),
    );
  }

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      false;

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => null;
}

final class _DeferredDurableDerivedPartTracker
    implements DerivedPartRunTrackingPort, AgentTaskLedgerPort {
  final Completer<void> enrollmentStarted = Completer<void>();
  final Completer<void> _enrollmentAcknowledged = Completer<void>();
  final List<AgentTaskLedgerEntry> _ledger = <AgentTaskLedgerEntry>[];

  void acknowledgeEnrollment() => _enrollmentAcknowledged.complete();

  @override
  List<AgentTaskLedgerEntry> get taskLedger =>
      List<AgentTaskLedgerEntry>.unmodifiable(_ledger);

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    enrollmentStarted.complete();
    await _enrollmentAcknowledged.future;
    _ledger.add(
      AgentTaskLedgerEntry.derivedPart(
        taskId: fileAgentRunId,
        agentRunId: agentRunId,
        localNoteId: localNoteId,
        remoteNoteId: remoteNoteId,
        targetPart: targetPart,
        status: status ?? 'queued',
        createdAt: DateTime.utc(2026, 9, 15),
        inputPartRevisionId: inputPartRevisionId,
        targetPartRevisionId: targetPartRevisionId,
        operationId: operationId,
      ),
    );
  }

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      false;

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => null;
}

final class _FailingOutlineRepository implements OutlineRepository {
  const _FailingOutlineRepository(this.code);

  final String code;

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async => throw OutlineGenerationException(code);
}

final class _UnusedSproutRepository implements SproutRepository {
  const _UnusedSproutRepository();

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async => throw StateError('unused');
}

final class _CountingSproutRepository implements SproutRepository {
  int calls = 0;

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    calls += 1;
    throw StateError('unexpected sprout call');
  }
}

final class _SynchronizingKnowledgeNotePort implements KnowledgeNotePort {
  int calls = 0;

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    calls += 1;
    final local = request.localNote!;
    return KnowledgeNotePortResult.success(
      local.copyWith(
        remoteNoteId: 'remote-${local.id}',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        remoteRevision: 1,
        etag: '"note-1"',
        contentCursor: 'cursor-1',
        syncState: NoteSyncState.synced,
      ),
    );
  }
}

final class _LateResultKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteDetailPort {
  _LateResultKnowledgeNotePort(this._note);

  final V3FeedItem _note;

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async => KnowledgeNotePortResult.success(
    _note.copyWith(summaryBody: '# 云端迟到的纲要', clearSummaryError: true),
  );

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _UnavailableDerivedPartPort
    implements KnowledgeNotePort, KnowledgeNoteRemoteDetailPort {
  const _UnavailableDerivedPartPort();

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async => const KnowledgeNotePortResult.unavailable();

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _AutomaticRecordingNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteDetailPort {
  _AutomaticRecordingNotePort({this.outlineReady = false});

  bool outlineReady;
  int loadCalls = 0;

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async {
    loadCalls += 1;
    final note = fallback;
    if (note == null) return const KnowledgeNotePortResult.unavailable();
    return KnowledgeNotePortResult.success(
      outlineReady
          ? note.copyWith(
              summaryBody: '# 后端自动纲要',
              outlinePartRevisionId: 'outline-revision-$localId',
            )
          : note,
    );
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _AutomaticRecordingApi implements RecordingApiPort {
  _AutomaticRecordingApi({
    required this.detail,
    this.onRetry,
    this.retryResult,
    List<RecordingDetail> detailsAfterRetry = const <RecordingDetail>[],
  }) : _detailsAfterRetry = List<RecordingDetail>.of(detailsAfterRetry);

  RecordingDetail detail;
  final VoidCallback? onRetry;
  final ApiResult<RetryRecordingResponse>? retryResult;
  final List<RecordingDetail> _detailsAfterRetry;
  bool _retryAccepted = false;
  int detailCalls = 0;
  final List<String> retryStages = <String>[];
  final List<String> retryKeys = <String>[];

  Never _unexpected() => throw StateError('unexpected recording API call');

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    if (_retryAccepted && _detailsAfterRetry.isNotEmpty) {
      detail = _detailsAfterRetry.removeAt(0);
    }
    return _apiSuccess(detail);
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async {
    retryStages.add(stage);
    retryKeys.add(idempotencyKey);
    final configuredResult = retryResult;
    if (configuredResult != null) return configuredResult;
    _retryAccepted = true;
    if (_detailsAfterRetry.isEmpty) {
      detail = _recordingDetail(
        recordingId: recordingId,
        minutesStatus: 'succeeded',
        summaryStatus: 'succeeded',
        outlineTaskId: 'retry-task-1',
      );
    }
    onRetry?.call();
    return _apiSuccess(
      RetryRecordingResponse(
        recordingId: recordingId,
        stage: stage,
        status: RecordingRetryReceiptStatus.queued,
        taskId: 'retry-task-1',
      ),
    );
  }

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) async => _unexpected();

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) async =>
      _unexpected();

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) async => _unexpected();
}

final class _FakeRecordingProcessingRetryPort
    implements RecordingProcessingRetryPort {
  final List<String> recordingIds = <String>[];

  @override
  Future<bool> reenrollAfterRetry(String recordingId) async {
    recordingIds.add(recordingId);
    return true;
  }
}

final class _FakeRecordingOutlineRetryLifecyclePort
    implements RecordingOutlineRetryLifecyclePort {
  _FakeRecordingOutlineRetryLifecyclePort([List<String>? events])
    : events = events ?? <String>[];

  final List<String> events;

  @override
  Future<void> acceptOutlineRetry({
    required String recordingId,
    required String retryTaskId,
    required String retryStage,
    String? supersededOutlineTaskId,
  }) async {
    events.add(
      'accept:$recordingId:$retryTaskId:$retryStage:'
      '${supersededOutlineTaskId ?? '-'}',
    );
  }

  @override
  Future<void> rejectOutlineRetry({
    required String recordingId,
    required String errorCode,
  }) async {
    events.add('reject:$recordingId:$errorCode');
  }
}

final class _RecordingOutlineRetryTracker
    implements DerivedPartRunTrackingPort, RecordingOutlineRunTrackingPort {
  _RecordingOutlineRetryTracker(this.events);

  final List<String> events;
  String? _localNoteId;
  String? _expectedTaskId;
  String? _supersededTaskId;

  @override
  Future<void> trackRecordingOutline({
    required String recordingId,
    required String localNoteId,
    required String remoteNoteId,
    bool restart = false,
    String? expectedPublicTaskId,
    String? supersededPublicTaskId,
  }) async {
    _localNoteId = localNoteId;
    _expectedTaskId = expectedPublicTaskId;
    _supersededTaskId = supersededPublicTaskId;
    events.add(
      'track:$recordingId:${restart ? 'retry' : 'initial'}:'
      '${expectedPublicTaskId ?? '-'}:${supersededPublicTaskId ?? '-'}',
    );
  }

  @override
  bool acceptsRecordingOutlineTask(String localNoteId, String? publicTaskId) {
    if (localNoteId != _localNoteId) return false;
    final expectedTaskId = _expectedTaskId;
    if (expectedTaskId != null) return publicTaskId == expectedTaskId;
    final supersededTaskId = _supersededTaskId;
    if (supersededTaskId != null) {
      return publicTaskId != null && publicTaskId != supersededTaskId;
    }
    return true;
  }

  @override
  bool isRecordingOutlinePending(String localNoteId) => false;

  @override
  String? recordingOutlineStatus(String localNoteId) => null;

  @override
  RecordingOutlineRunCompletion? get lastRecordingOutlineCompletion => null;

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      false;

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => null;

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {}
}

ApiResult<T> _apiSuccess<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

final class _CompletedAppendPort implements NoteAppendPort {
  const _CompletedAppendPort();

  @override
  bool get isDemo => true;

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    onProgress(NoteAppendStatus.analyzing);
    return const NoteAppendPortResult(
      ok: true,
      summary: '追加材料摘要',
      isDemo: true,
    );
  }
}
