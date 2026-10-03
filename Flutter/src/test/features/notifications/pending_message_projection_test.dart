import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/bootstrap/asset_projection_cache_scope.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/book_work/domain/masterpiece_generation.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_providers.dart';
import 'package:huahuoai_app/features/book_work/data/masterpiece_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/digital_twin_material.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ingestion/application/internal_recording_controller.dart';
import 'package:huahuoai_app/features/ingestion/application/meeting_capture_controller.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/notification_center_state_machine.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_batch_transcription.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/application/automatic_outline_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/v3_document_import_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_document_import_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';
import '../chat/assistant_runtime_test_adapter.dart';

final class _RecoveryProjectionRepository
    implements WorkbenchGenerationRepository {
  int calls = 0;

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) async {
    calls += 1;
    if (calls == 1) {
      throw const WorkbenchGenerationException(
        'AGENT_RUN_POLL_TIMEOUT',
        resultPending: true,
      );
    }
    return WorkbenchGenerationResult(
      markdown: '原始结果',
      generatedAt: DateTime.utc(2026, 9, 1),
    );
  }
}

void main() {
  test(
    'remote success read survives a late local ledger without archiving',
    () async {
      final now = DateTime.utc(2026, 9, 13);
      const remote = AppNotification(
        notificationId: 'remote-first',
        eventId: 'remote-first-event',
        eventType: 'agent_run.succeeded',
        scene: 'chat',
        targetType: 'thread',
        targetId: 'thread-1',
        title: '完成',
        body: '结果',
        status: AppNotificationStatus.unread,
        taskStatus: AppNotificationTaskStatus.succeeded,
        taskId: 'public-task',
      );
      final api = _DelayedNotificationApi([
        [remote],
        [],
      ]);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final ledger = <AgentTaskLedgerEntry>[];
      PendingMessageProjection project() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        taskLedger: ledger,
        ingestionDrafts: const [],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );
      final actions = PendingMessageActions(
        controller,
        items: () => project().items,
      );
      expect(await actions.markRead(project().items.single), isTrue);
      ledger.add(
        AgentTaskLedgerEntry.chat(
          taskId: 'run-1',
          publicTaskId: 'public-task',
          threadId: 'thread-1',
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: now,
        ),
      );
      await controller.load(forceRemote: true);
      expect(project().items.single.state, PendingMessageState.succeeded);
      expect(project().items.single.isUnread, isFalse);
      expect(controller.state.handledTaskIds, isEmpty);
      ledger.add(
        AgentTaskLedgerEntry.chat(
          taskId: 'run-2',
          publicTaskId: 'different-task',
          threadId: 'thread-1',
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: now,
        ),
      );
      expect(project().items, hasLength(2));
      expect(project().unreadCount, 1);
    },
  );

  for (final terminalStatus in ['succeeded', 'failed']) {
    test(
      'inbox follows task input completion read and late $terminalStatus',
      () async {
        final now = DateTime.utc(2026, 9, 13);
        AppNotification delivery(String status) => AppNotification(
          notificationId: 'task-notice',
          eventId: 'event-$status',
          eventType: 'agent_run.$status',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'thread-1',
          title: status,
          body: status,
          status: status == 'running'
              ? AppNotificationStatus.read
              : AppNotificationStatus.unread,
          taskStatus: AppNotificationTaskStatus.tryParse(status),
          taskId: status == 'running' ? 'public-task' : 'agent-run',
          createdAt: now,
          updatedAt: now.add(Duration(minutes: status == 'running' ? 0 : 2)),
        );
        final api = _DelayedNotificationApi([
          [delivery('running')],
          [delivery(terminalStatus)],
          [delivery('running')],
        ]);
        final notifications = NotificationController(api: api);
        addTearDown(notifications.dispose);
        await notifications.load(forceRemote: true);
        final knowledge = KnowledgeLibraryController(initialNotes: const []);
        addTearDown(knowledge.dispose);
        final aggregation = _aggregationController(now);
        addTearDown(aggregation.dispose);
        AgentTaskLedgerEntry entry(String status) => AgentTaskLedgerEntry.chat(
          taskId: 'agent-run',
          publicTaskId: 'public-task',
          threadId: 'thread-1',
          scene: ChatScene.feedAi,
          status: status,
          createdAt: now.add(const Duration(minutes: 1)),
        );
        var task = entry('running');
        var sequence = 0;
        final reducer = PendingMessageProjectionReducer();
        const policies = NotificationCenterPolicyRegistry();
        PendingMessageProjection project() => reducer.project(
          nonTaskRevision: notifications.state,
          taskDeltaSequence: sequence,
          taskDelta: AgentTaskLedgerDelta(
            upserts: [task],
            removedTaskIds: const [],
          ),
          notifications: notifications.state,
          acceptedOnboardingRunId: null,
          rebuild: () => buildPendingMessageProjection(
            notifications: notifications.state,
            aggregation: aggregation,
            knowledge: knowledge,
            taskLedger: [task],
            ingestionDrafts: const [],
            documentImport: const V3DocumentImportState.initial(),
            recordingUpload: RecordingUploadState.initial(),
          ),
        );
        final actions = PendingMessageActions(
          notifications,
          items: () => project().items,
        );
        expect(project().items.single.state, PendingMessageState.processing);
        expect(policies.attention(project().items), (
          hasProcessing: true,
          unreadCount: 0,
        ));
        task = entry('awaiting_input');
        sequence += 1;
        expect(
          project().items.single.state,
          PendingMessageState.actionRequired,
        );
        expect(policies.attention(project().items), (
          hasProcessing: false,
          unreadCount: 1,
        ));
        task = entry(terminalStatus);
        sequence += 1;
        final completed = project().items.single;
        expect(
          completed.state,
          terminalStatus == 'succeeded'
              ? PendingMessageState.succeeded
              : PendingMessageState.failed,
        );
        expect(completed.source, PendingMessageSource.agentTask);
        expect(policies.attention(project().items), (
          hasProcessing: false,
          unreadCount: 1,
        ));
        expect(await actions.markRead(completed), isTrue);
        expect(project().items.single.state, completed.state);
        expect(policies.attention(project().items), (
          hasProcessing: false,
          unreadCount: 0,
        ));
        expect(
          await actions.acknowledgeResultShown(
            targetType: 'thread',
            targetId: 'thread-1',
            matchingTaskIds: const {'agent-run', 'public-task'},
            durableSucceededTaskIds: terminalStatus == 'succeeded'
                ? const {'public-task'}
                : const {},
          ),
          isTrue,
        );
        for (var refresh = 0; refresh < 2; refresh += 1) {
          await notifications.load(forceRemote: true);
          final projected = project();
          expect(policies.attention(projected.items), (
            hasProcessing: false,
            unreadCount: 0,
          ));
          if (terminalStatus == 'succeeded') {
            expect(projected.items, isEmpty);
          } else {
            expect(projected.items.single.state, PendingMessageState.failed);
            expect(projected.items.single.isUnread, isFalse);
          }
        }
      },
    );
  }

  for (final deliveryStatus in [
    AppNotificationStatus.unread,
    AppNotificationStatus.handled,
    AppNotificationStatus.expired,
  ]) {
    test(
      'aliased terminal task owns delayed progress with $deliveryStatus',
      () {
        final now = DateTime.utc(2026, 9, 13);
        final knowledge = KnowledgeLibraryController(initialNotes: const []);
        addTearDown(knowledge.dispose);
        final aggregation = _aggregationController(now);
        addTearDown(aggregation.dispose);
        final result = buildPendingMessageProjection(
          notifications: NotificationControllerState(
            status: NotificationControllerStatus.ready,
            items: [
              AppNotification(
                notificationId: 'complete',
                eventId: 'event-complete',
                eventType: 'agent_run.succeeded',
                scene: 'chat',
                targetType: 'thread',
                targetId: 'thread-1',
                title: 'completed',
                body: 'result',
                status: deliveryStatus,
                taskId: 'agent-run',
                createdAt: now,
              ),
              AppNotification(
                notificationId: 'late',
                eventId: 'event-late',
                eventType: 'agent_run.running',
                scene: 'chat',
                targetType: 'thread',
                targetId: 'thread-1',
                title: 'running',
                body: 'stale',
                status: AppNotificationStatus.unread,
                taskStatus: AppNotificationTaskStatus.running,
                taskId: 'public-task',
                createdAt: now.add(const Duration(minutes: 1)),
              ),
            ],
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          taskLedger: [
            AgentTaskLedgerEntry.chat(
              taskId: 'agent-run',
              publicTaskId: 'public-task',
              threadId: 'thread-1',
              scene: ChatScene.feedAi,
              status: 'running',
              createdAt: now,
            ),
          ],
          ingestionDrafts: const [],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
        );
        if (deliveryStatus == AppNotificationStatus.unread) {
          expect(result.items.single.state, PendingMessageState.succeeded);
          expect(result.items.single.title, 'completed');
        } else {
          expect(result.items, isEmpty);
        }
      },
    );
  }

  test('local delivery identity ignores mutable presentation time', () {
    PendingMessage message(
      DateTime createdAt,
      PendingMessageState state, {
      PendingMessageSource source = PendingMessageSource.agentTask,
      bool isTask = true,
    }) => PendingMessage(
      id: 'local:${source.name}:stable',
      source: source,
      scene: 'chat',
      title: '任务状态',
      body: '同一个任务尝试。',
      state: state,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      createdAt: createdAt,
      route: '/v3/feed/chat?threadId=thread-stable',
      taskId: 'task-stable',
      isTask: isTask,
    );

    final earlier = message(
      DateTime.utc(2026, 9, 9),
      PendingMessageState.failed,
    );
    final later = message(
      DateTime.utc(2026, 9, 10),
      PendingMessageState.failed,
    );
    final succeeded = message(
      DateTime.utc(2026, 9, 10),
      PendingMessageState.succeeded,
    );

    expect(
      pendingMessageLocalDeliveryResolutionKey(earlier),
      pendingMessageLocalDeliveryResolutionKey(later),
    );
    expect(
      pendingMessageLocalDeliveryResolutionKey(later),
      isNot(pendingMessageLocalDeliveryResolutionKey(succeeded)),
    );
    expect(pendingMessageLocalDeliveryResolutionKeys(later), hasLength(2));
    final earlierWorkbench = message(
      DateTime.utc(2026, 9, 9),
      PendingMessageState.failed,
      source: PendingMessageSource.workbenchGeneration,
      isTask: false,
    );
    final laterWorkbench = message(
      DateTime.utc(2026, 9, 10),
      PendingMessageState.failed,
      source: PendingMessageSource.workbenchGeneration,
      isTask: false,
    );
    expect(
      pendingMessageLocalDeliveryResolutionKey(earlierWorkbench),
      pendingMessageLocalDeliveryResolutionKey(laterWorkbench),
    );
    expect(
      pendingMessageLocalDeliveryResolutionKeys(laterWorkbench),
      hasLength(2),
    );
  });

  group('long-running recovery', () {
    final now = DateTime.utc(2026, 9, 1);
    late KnowledgeLibraryController library;
    late FeedAggregationController aggregation;
    setUp(() {
      library = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
      );
      aggregation = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: now),
        repository: const UnavailableFeedAggregationRepository(),
      );
    });
    tearDown(() {
      aggregation.dispose();
      library.dispose();
    });
    PendingMessageProjection project({
      CreationCanvasDraft? draft,
      MasterpieceGenerationRecord? masterpiece,
      List<DigitalTwinMaterial> materials = const [],
      List<AgentTaskLedgerEntry> tasks = const [],
      WorkbenchGenerationController? workbench,
      Set<String> readIds = const {},
    }) => buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        locallyReadIds: readIds,
      ),
      aggregation: aggregation,
      knowledge: library,
      ingestionDrafts: const [],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
      canvasDraft: draft,
      masterpieceGeneration: masterpiece,
      masterpieceWorkspaceId: 'workspace-1',
      twinMaterials: materials,
      taskLedger: tasks,
      workbenchTasks: workbench?.tasks ?? const [],
    );

    test(
      'masterpiece notification observation never creates the command runtime',
      () async {
        final dao = AppPreferencesDao(AppDatabase());
        final store = PersistentMasterpieceGenerationStore(dao, 'audit-scope');
        var runtimeStarts = 0;
        final container = ProviderContainer(
          overrides: [
            masterpieceGenerationStoreProvider.overrideWith((ref) => store),
            masterpieceControllerProvider.overrideWith((ref) {
              runtimeStarts += 1;
              throw StateError(
                'Command runtime must not be started by observation',
              );
            }),
          ],
        );
        addTearDown(container.dispose);
        container.listen(pendingMasterpieceGenerationProvider, (_, __) {});
        expect(container.read(pendingMasterpieceGenerationProvider), isNull);
        expect(runtimeStarts, 0);
        await store.write(const MasterpieceGenerationRecord(published: true));
        expect(
          container.read(pendingMasterpieceGenerationProvider)!.published,
          isTrue,
        );
        expect(runtimeStarts, 0);
        final restoredStore = PersistentMasterpieceGenerationStore(
          dao,
          'audit-scope',
        );
        addTearDown(restoredStore.dispose);
        expect(restoredStore.read()!.published, isTrue);
      },
    );

    test(
      'workbench result delivery is exact and a read failure cannot pre-read success',
      () async {
        final note = V3FeedItem(
          id: 'recovery-note',
          title: '原始材料',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '原始内容',
        );
        final sourceLibrary = KnowledgeLibraryController(initialNotes: [note]);
        final repository = _RecoveryProjectionRepository();
        final controller =
            WorkbenchGenerationController(
                library: sourceLibrary,
                repository: repository,
              )
              ..startSelection(WorkbenchPurpose.persona)
              ..toggleNote(note.id);
        addTearDown(sourceLibrary.dispose);
        addTearDown(controller.dispose);
        expect(await controller.generate(), isFalse);
        final operationId = controller.generationId!;
        final waiting = project(workbench: controller).items.single;
        expect(waiting.state, PendingMessageState.actionRequired);
        final readIds = {pendingMessageLocalDeliveryResolutionKey(waiting)};
        expect(await controller.retry(operationId), isTrue);
        controller.startSelection(WorkbenchPurpose.lead);
        controller.clearForWorkbench();
        final completed = project(
          workbench: controller,
          readIds: readIds,
        ).items.single;
        expect(completed.state, PendingMessageState.succeeded);
        expect(completed.isUnread, isTrue);
        expect(
          Uri.parse(completed.route!).queryParameters['operationId'],
          operationId,
        );
        expect(Uri.parse(completed.route!).path, contains('/generated'));
      },
    );

    test(
      'workbench notification subscription observes immutable completion without unrelated events',
      () async {
        final note = V3FeedItem(
          id: 'observable-source',
          title: '任务来源',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '任务内容',
        );
        final sourceLibrary = KnowledgeLibraryController(initialNotes: [note]);
        final controller =
            WorkbenchGenerationController(
                library: sourceLibrary,
                repository: _RecoveryProjectionRepository(),
              )
              ..startSelection(WorkbenchPurpose.persona)
              ..toggleNote(note.id);
        final container = ProviderContainer(
          overrides: [
            workbenchGenerationControllerProvider.overrideWith(
              (ref) => controller,
            ),
          ],
        );
        addTearDown(sourceLibrary.dispose);
        addTearDown(container.dispose);
        final deliveries = <List<WorkbenchGenerationTask>>[];
        container.listen(
          pendingWorkbenchGenerationProvider,
          (_, next) => deliveries.add(next),
          fireImmediately: true,
        );
        expect(deliveries.single, isEmpty);
        await controller.generate();
        await container.pump();
        final waiting = deliveries.last;
        expect(
          waiting.single.status,
          WorkbenchGenerationTaskStatus.awaitingResult,
        );
        await controller.retry();
        await container.pump();
        expect(
          deliveries.last.single.status,
          WorkbenchGenerationTaskStatus.succeeded,
        );
        expect(
          waiting.single.status,
          WorkbenchGenerationTaskStatus.awaitingResult,
        );
      },
    );

    test('user confirmation is actionable rather than long-running work', () {
      final task = AgentTaskLedgerEntry.chat(
        taskId: 'run-confirmation',
        threadId: 'thread-confirmation',
        scene: ChatScene.feedAi,
        status: 'awaiting_confirmation',
        createdAt: now,
      );
      final message = project(tasks: [task]).items.single;
      expect(agentTaskNeedsUserInput(task), isTrue);
      expect(message.state, PendingMessageState.actionRequired);
      expect(message.title, '任务等待你确认');
      expect(
        Uri.parse(message.route!).queryParameters['threadId'],
        'thread-confirmation',
      );
    });

    test(
      'canvas retains the exact accepted session and terminal boundaries',
      () {
        final source = ScriptDraftSourceSnapshot(
          kind: ScriptDraftSourceKind.dailyRecommendation,
          sourceId: 'topic-1',
          title: '初稿',
          content: '来源正文',
          capturedAt: now,
        );
        for (final phase in [
          ScriptDraftGenerationPhase.streaming,
          ScriptDraftGenerationPhase.ready,
          ScriptDraftGenerationPhase.failed,
          ScriptDraftGenerationPhase.cancelled,
        ]) {
          final receipt = ScriptDraftGenerationReceipt(
            sessionId: 'session-1',
            source: source,
            createThreadIdempotencyKey: 'create-1',
            messageIdempotencyKey: 'message-1',
            cancelIdempotencyKey: 'cancel-1',
            phase: phase,
            threadId: 'thread-1',
            agentRunId: 'run-1',
            updatedAt: now,
            finalMarkdown: phase == ScriptDraftGenerationPhase.ready
                ? '已生成正文'
                : null,
            failureCode: phase == ScriptDraftGenerationPhase.failed
                ? 'RUN_FAILED'
                : null,
          );
          final draft = CreationCanvasDraft(
            title: '初稿',
            markdown: '',
            revision: 1,
            sessionId: 'canvas-session-1',
            scriptDraftReceipt: receipt,
            createdAt: now,
            updatedAt: now,
          );
          final messages = project(draft: draft).items
              .where(
                (item) => item.source == PendingMessageSource.canvasGeneration,
              )
              .toList();
          if (phase == ScriptDraftGenerationPhase.cancelled) {
            expect(messages, isEmpty);
          } else {
            final message = messages.single;
            expect(
              Uri.parse(message.route!).queryParameters['recoverySessionId'],
              'canvas-session-1',
            );
            expect(
              Uri.parse(message.route!).queryParameters['recoveryRunId'],
              'run-1',
            );
            expect(message.state, switch (phase) {
              ScriptDraftGenerationPhase.ready => PendingMessageState.succeeded,
              ScriptDraftGenerationPhase.failed => PendingMessageState.failed,
              _ => PendingMessageState.processing,
            });
            expect(
              message.canMarkHandled,
              phase != ScriptDraftGenerationPhase.streaming,
            );
          }
        }
      },
    );

    test('masterpiece settled is not proof of publication', () {
      final unpublished = project(
        masterpiece: const MasterpieceGenerationRecord(settled: true),
      );
      expect(
        unpublished.items.where(
          (item) => item.source == PendingMessageSource.masterpieceGeneration,
        ),
        isEmpty,
      );
      final published = project(
        masterpiece: const MasterpieceGenerationRecord(
          settled: true,
          published: true,
        ),
      );
      expect(published.items.single.state, PendingMessageState.succeeded);
      final legacy = const MasterpieceGenerationRecord(settled: true).toJson()
        ..remove('published');
      expect(MasterpieceGenerationRecord.fromJson(legacy).published, isFalse);
      expect(
        MasterpieceGenerationRecord.fromJson(
          const MasterpieceGenerationRecord(published: true).toJson(),
        ).published,
        isTrue,
      );
    });

    test('masterpiece first attempt zero remains recoverable', () {
      const intent = MasterpieceGenerationIntent(
        bookId: 'book-1',
        baseBookRevisionId: 'revision-1',
        profileId: 'profile-1',
        instruction: '生成',
        sources: [],
        sectionKey: 'section-1',
        title: '初稿',
        requestKey: 'request-1',
        initial: true,
        runId: 'run-1',
        stage: MasterpieceGenerationStage.running,
      );
      final message = project(
        masterpiece: const MasterpieceGenerationRecord(intent: intent),
      ).items.single;
      expect(message.state, PendingMessageState.processing);
      expect(message.canMarkHandled, isFalse);
      expect(message.route, contains('masterpiece'));
    });

    test(
      'Digital Twin distinguishes processing review success and removal',
      () {
        for (final status in [
          DigitalTwinMaterialStatus.generating,
          DigitalTwinMaterialStatus.reviewReady,
          DigitalTwinMaterialStatus.completed,
          DigitalTwinMaterialStatus.failed,
          DigitalTwinMaterialStatus.removed,
        ]) {
          final items = project(
            materials: [
              DigitalTwinMaterial(
                id: 'material-1',
                referenceKind: 'note',
                referenceId: 'note-1',
                title: '材料',
                createdAt: now,
                status: status,
              ),
            ],
          ).items;
          if (status == DigitalTwinMaterialStatus.removed) {
            expect(items, isEmpty);
          } else {
            expect(items.single.state, switch (status) {
              DigitalTwinMaterialStatus.completed =>
                PendingMessageState.succeeded,
              DigitalTwinMaterialStatus.reviewReady =>
                PendingMessageState.actionRequired,
              DigitalTwinMaterialStatus.failed => PendingMessageState.failed,
              _ => PendingMessageState.processing,
            });
            expect(
              Uri.parse(items.single.route!).queryParameters['materialId'],
              'material-1',
            );
          }
        }
      },
    );
  });

  test(
    'aggregation completion notification waits for readable saved output',
    () async {
      final now = DateTime.utc(2026, 9, 7);
      final notes = _AggregationOutputGate();
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
        notePort: notes,
      );
      final aggregation = _productionAggregationController(
        now,
        const _FixedTopicCollisionRunPort(
          TopicCollisionRun(
            topicCollisionRunId: 'completed-projection-run',
            workspaceId: 'workspace-production',
            status: 'succeeded',
            stage: 'persisted',
            selectedNoteCount: 4,
            outputNoteId: 'completed-output',
          ),
        ),
        library,
      );
      addTearDown(aggregation.dispose);
      addTearDown(library.dispose);
      const initial = NotificationControllerState(
        status: NotificationControllerStatus.ready,
      );
      PendingMessageProjection project([
        NotificationControllerState state = initial,
      ]) => _projectAggregation(state, aggregation, library);
      aggregation.startSelection();
      expect(project().items, isEmpty);
      final submission = aggregation.confirm();
      final submitting = project().items.single;
      await notes.started.future;
      final syncing = project().items.single;
      expect(syncing.id, submitting.id);
      expect(syncing.state, PendingMessageState.processing);
      expect(syncing.title, '《来源 0》等 4 篇 · 聚合已生成，正在同步');
      expect(project().unreadCount, 0);
      notes.result.complete(
        KnowledgeNoteRemoteLoadResult.success([
          ...library.notes,
          V3FeedItem(
            id: 'completed-output-local',
            remoteNoteId: 'completed-output',
            remoteSourceKind: 'topic_collision',
            rawPartRevisionId: 'output-raw',
            title: '真实保存的聚合结果',
            source: V3MaterialSource.note,
            createdAt: now,
            rawBody: '# 真实结果',
          ),
        ]),
      );
      await submission;
      final previousRead = initial.copyWith(
        locallyReadIds: {pendingMessageLocalDeliveryResolutionKey(syncing)},
      );
      final completed = project(previousRead).items.single;
      expect(completed.id, submitting.id);
      expect(completed.title, '《真实保存的聚合结果》聚合已完成');
      expect(completed.state, PendingMessageState.succeeded);
      expect(completed.isUnread, isTrue);
      expect(
        completed.route,
        '/v3/feed/items/completed-output-local?stage=raw',
      );
      final completedRead = initial.copyWith(
        locallyReadIds: {pendingMessageLocalDeliveryResolutionKey(completed)},
      );
      aggregation.startSelection();
      expect(project(completedRead).items.single.id, completed.id);
      expect(project(completedRead).unreadCount, 0);
      aggregation.cancelSelection();
      expect(
        project(completedRead).items.single.state,
        PendingMessageState.succeeded,
      );
    },
  );

  test('projects the resident internal recording timer and return route', () {
    final now = DateTime.utc(2026, 9, 4, 10);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    PendingMessage project(InternalRecordingStatus status) {
      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
        internalRecording: InternalRecordingState(
          status: status,
          elapsedSeconds: 125,
          sessionId: 'internal-session-1',
          startedAt: now.subtract(const Duration(seconds: 125)),
        ),
      );
      return projection.items.singleWhere(
        (item) => item.scene == 'internal_recording',
      );
    }

    final recording = project(InternalRecordingStatus.recording);
    expect(recording.title, '内录进行中');
    expect(recording.body, contains('02:05'));
    expect(recording.route, '/v3/feed/internal-recording');
    expect(recording.canMarkHandled, isFalse);

    final consent = project(InternalRecordingStatus.awaitingConsent);
    expect(consent.title, '等待录屏授权');
    expect(consent.body, contains('系统界面'));
    final extracting = project(InternalRecordingStatus.extractingAudio);
    expect(extracting.title, '内录正在处理');
    expect(extracting.body, contains('分离'));
  });

  test('projects one external recording timer and hands off to upload', () {
    final now = DateTime.utc(2026, 9, 12, 10);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    PendingMessageProjection project(
      MeetingCaptureState capture, {
      RecordingUploadState? upload,
    }) => buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: upload ?? RecordingUploadState.initial(),
      meetingCapture: capture,
    );

    MeetingCaptureState capture(
      MeetingCaptureStatus status, {
      int elapsedSeconds = 125,
      MeetingCaptureSource source = MeetingCaptureSource.liveMicrophone,
      String? transcriptionJobId,
    }) => MeetingCaptureState(
      status: status,
      source: source,
      elapsedSeconds: elapsedSeconds,
      startedAt: now.subtract(const Duration(seconds: 125)),
      correlationId: 'external-session-1',
      transcriptionJobId: transcriptionJobId,
    );

    final recording = project(
      capture(MeetingCaptureStatus.recording),
    ).items.single;
    expect(recording.title, '外录进行中');
    expect(recording.body, contains('00:02:05'));
    expect(recording.route, '/v3/feed/meeting');
    expect(recording.targetType, 'external_recording');
    expect(recording.canMarkHandled, isFalse);

    final nextSecond = project(
      capture(MeetingCaptureStatus.recording, elapsedSeconds: 126),
    ).items.single;
    expect(nextSecond.id, recording.id);
    expect(nextSecond.body, contains('00:02:06'));

    final paused = project(capture(MeetingCaptureStatus.paused)).items.single;
    expect(paused.title, '外录已暂停');
    expect(paused.body, contains('00:02:05'));
    expect(paused.route, '/v3/feed/meeting');

    final controlFailure = project(
      capture(MeetingCaptureStatus.recording).copyWith(
        lastErrorCode: 'VOICE_RECORDER_STOP_FAILED',
        failureStage: MeetingFailureStage.nativeStop,
      ),
    ).items.single;
    expect(controlFailure.id, recording.id);
    expect(controlFailure.title, '外录操作未完成');
    expect(controlFailure.body, contains('00:02:05'));
    expect(controlFailure.body, contains('录音会话仍在'));
    expect(controlFailure.state, PendingMessageState.actionRequired);
    expect(controlFailure.route, '/v3/feed/meeting');

    expect(
      project(
        capture(
          MeetingCaptureStatus.recording,
          source: MeetingCaptureSource.localLibrary,
        ),
      ).items,
      isEmpty,
    );
    expect(project(capture(MeetingCaptureStatus.completed)).items, isEmpty);

    const jobId = 'external-upload-job';
    final handedOff = project(
      capture(MeetingCaptureStatus.uploading, transcriptionJobId: jobId),
      upload: RecordingUploadState(
        status: RecordingFileJobStatus.uploading,
        activeDraft: _uploadDraft(
          now,
          draftId: jobId,
          recordingId: null,
          stage: UploadDraftStage.objectUploading,
          entrySource: 'meeting',
        ),
      ),
    );
    expect(
      handedOff.items.where((item) => item.targetType == 'external_recording'),
      isEmpty,
    );
    expect(
      handedOff.items.where(
        (item) => item.source == PendingMessageSource.recordingTranscription,
      ),
      hasLength(1),
    );

    const failureCode = 'RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE';
    final preDraftFailure = project(
      capture(MeetingCaptureStatus.failed, transcriptionJobId: jobId).copyWith(
        lastErrorCode: failureCode,
        failureStage: MeetingFailureStage.upload,
      ),
      upload: RecordingUploadState(
        status: RecordingFileJobStatus.failed,
        lastErrorCode: failureCode,
        lastErrorJobId: jobId,
        failureCodesByJobId: const <String, String>{jobId: failureCode},
        activeDraft: _uploadDraft(
          now,
          draftId: 'sibling-upload-job',
          recordingId: null,
          stage: UploadDraftStage.localReady,
          entrySource: 'audio_import',
        ),
      ),
    );
    expect(preDraftFailure.items, hasLength(1));
    expect(preDraftFailure.items.single.targetType, 'external_recording');
    expect(
      preDraftFailure.items.single.state,
      PendingMessageState.actionRequired,
    );
    expect(preDraftFailure.items.single.route, '/v3/feed/meeting');

    final otherJobFailure = project(
      capture(MeetingCaptureStatus.failed, transcriptionJobId: jobId).copyWith(
        lastErrorCode: failureCode,
        failureStage: MeetingFailureStage.upload,
      ),
      upload: const RecordingUploadState(
        status: RecordingFileJobStatus.failed,
        lastErrorCode: failureCode,
        lastErrorJobId: 'other-upload-job',
        failureCodesByJobId: <String, String>{
          jobId: failureCode,
          'other-upload-job': failureCode,
        },
      ),
    );
    expect(otherJobFailure.items, hasLength(2));
    expect(
      otherJobFailure.items.where(
        (item) => item.targetType == 'external_recording',
      ),
      hasLength(1),
    );
    expect(
      otherJobFailure.items.where(
        (item) => item.targetType == 'recording_library',
      ),
      hasLength(1),
    );
  });

  test('task revision is canonical and advances for relevant lifecycle', () {
    final createdAt = DateTime.utc(2026, 8, 31, 10);
    final first = <AgentTaskLedgerEntry>[
      AgentTaskLedgerEntry.chat(
        taskId: 'chat-run-1',
        threadId: 'thread-1',
        scene: ChatScene.feedAi,
        status: 'running',
        createdAt: createdAt,
      ),
      AgentTaskLedgerEntry.derivedPart(
        taskId: 'derived-run-1',
        localNoteId: 'note-1',
        targetPart: NoteFileAgentPart.outline,
        status: 'queued',
        createdAt: createdAt.subtract(const Duration(minutes: 1)),
      ),
    ];
    final equivalentReordered = <AgentTaskLedgerEntry>[
      AgentTaskLedgerEntry.derivedPart(
        taskId: 'derived-run-1',
        localNoteId: 'note-1',
        targetPart: NoteFileAgentPart.outline,
        status: 'queued',
        createdAt: createdAt.subtract(const Duration(minutes: 1)),
      ),
      AgentTaskLedgerEntry.chat(
        taskId: 'chat-run-1',
        threadId: 'thread-1',
        scene: ChatScene.feedAi,
        status: 'running',
        createdAt: createdAt,
      ),
    ];
    final completed = <AgentTaskLedgerEntry>[
      ...equivalentReordered.take(1),
      AgentTaskLedgerEntry.chat(
        taskId: 'chat-run-1',
        threadId: 'thread-1',
        scene: ChatScene.feedAi,
        status: 'succeeded',
        createdAt: createdAt,
      ),
    ];

    expect(
      pendingMessageTaskRevision(first),
      pendingMessageTaskRevision(equivalentReordered),
    );
    expect(
      pendingMessageTaskRevision(first),
      isNot(pendingMessageTaskRevision(completed)),
    );
  });

  test('chat result evidence requires an exact persisted identity', () {
    const threadId = 'thread-result-evidence-1';
    const agentRunId = 'agent_run_result_evidence_1';
    const publicTaskId = 'public_chat_task_result_evidence_1';
    const message = ChatMessage(
      messageId: 'assistant-result-evidence-1',
      threadId: threadId,
      scene: ChatScene.feedAi,
      role: ChatMessageRole.assistant,
      contentType: ChatMessageContentType.text,
      status: 'sent',
      agentRunId: agentRunId,
      taskId: publicTaskId,
      textPreview: '真实回复已经写入会话。',
    );
    final createdAt = DateTime.utc(2026, 9, 2, 14);

    final runOnly = pendingMessageChatResultEvidence(
      threadId: threadId,
      messages: const <ChatMessage>[message],
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: agentRunId,
          threadId: threadId,
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: createdAt,
        ),
      ],
      pendingMessages: const <PendingMessage>[],
    );
    expect(runOnly.matchingTaskIds, <String>{agentRunId});
    expect(runOnly.durableSucceededTaskIds, <String>{agentRunId});

    final acceptedAlias = pendingMessageChatResultEvidence(
      threadId: threadId,
      messages: const <ChatMessage>[message],
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: agentRunId,
          publicTaskId: publicTaskId,
          threadId: threadId,
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: createdAt,
        ),
      ],
      pendingMessages: const <PendingMessage>[],
    );
    expect(acceptedAlias.matchingTaskIds, <String>{agentRunId, publicTaskId});
    expect(acceptedAlias.durableSucceededTaskIds, <String>{publicTaskId});

    final visibleFailure = pendingMessageChatResultEvidence(
      threadId: threadId,
      messages: const <ChatMessage>[message],
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: agentRunId,
          publicTaskId: publicTaskId,
          threadId: threadId,
          scene: ChatScene.feedAi,
          status: 'failed',
          failureCode: 'AGENT_RUN_FAILED',
          createdAt: createdAt,
        ),
      ],
      pendingMessages: const <PendingMessage>[],
    );
    expect(visibleFailure.matchingTaskIds, <String>{agentRunId, publicTaskId});
    expect(visibleFailure.durableSucceededTaskIds, isEmpty);

    final remoteOnly = pendingMessageChatResultEvidence(
      threadId: threadId,
      messages: const <ChatMessage>[message],
      taskLedger: const <AgentTaskLedgerEntry>[],
      pendingMessages: const <PendingMessage>[
        PendingMessage(
          id: 'remote-result-evidence-1',
          source: PendingMessageSource.remote,
          scene: 'chat',
          title: '回复已完成',
          body: '打开会话查看回复。',
          state: PendingMessageState.succeeded,
          isUnread: true,
          isDemo: false,
          isOpening: false,
          isResolving: false,
          remoteNotificationId: 'remote-result-evidence-1',
          taskId: publicTaskId,
          targetType: 'thread',
          targetId: threadId,
          isTask: true,
        ),
      ],
    );
    expect(remoteOnly.matchingTaskIds, <String>{publicTaskId});
    expect(remoteOnly.durableSucceededTaskIds, <String>{publicTaskId});

    final wrongThread = pendingMessageChatResultEvidence(
      threadId: 'another-thread',
      messages: const <ChatMessage>[message],
      taskLedger: const <AgentTaskLedgerEntry>[],
      pendingMessages: const <PendingMessage>[],
    );
    expect(wrongThread.matchingTaskIds, isEmpty);
    expect(wrongThread.durableSucceededTaskIds, isEmpty);
  });

  test('public task delivery replaces and resolves its local Run alias', () {
    const agentRunId = 'agent_run_delivery_alias_1';
    const publicTaskId = 'public_chat_task_delivery_alias_1';
    const threadId = 'thread-delivery-alias-1';
    final createdAt = DateTime.utc(2026, 9, 2, 15);
    final ledger = <AgentTaskLedgerEntry>[
      AgentTaskLedgerEntry.chat(
        taskId: agentRunId,
        publicTaskId: publicTaskId,
        threadId: threadId,
        scene: ChatScene.feedAi,
        status: 'succeeded',
        createdAt: createdAt,
      ),
    ];
    final notification = AppNotification(
      notificationId: 'public-task-delivery-1',
      eventId: 'public-task-event-1',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: threadId,
      title: '回复已完成',
      body: '打开会话查看回复。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: publicTaskId,
      createdAt: createdAt.add(const Duration(minutes: 1)),
    );
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(createdAt);
    addTearDown(aggregation.dispose);

    PendingMessageProjection projection(Set<String> handledTaskIds) =>
        buildPendingMessageProjection(
          notifications: NotificationControllerState(
            status: NotificationControllerStatus.ready,
            items: <AppNotification>[notification],
            handledTaskIds: handledTaskIds,
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          taskLedger: ledger,
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
        );

    final visible = projection(const <String>{});
    expect(visible.items, hasLength(1));
    expect(visible.items.single.source, PendingMessageSource.remote);
    expect(visible.items.single.taskId, publicTaskId);
    expect(visible.items.single.linkedDeliveryResolutionKey, isNotNull);

    expect(
      projection(<String>{notificationTaskResolutionKey(publicTaskId)!}).items,
      isEmpty,
    );
  });

  test('contiguous task deltas patch projection without a ledger rebuild', () {
    final reducer = PendingMessageProjectionReducer();
    final notifications = NotificationControllerState.initial();
    var rebuildCalls = 0;
    PendingMessageProjection rebuild() {
      rebuildCalls += 1;
      return const PendingMessageProjection(
        items: <PendingMessage>[],
        isLoading: false,
        resolutionIsDemo: false,
      );
    }

    reducer.project(
      nonTaskRevision: 'stable',
      taskDeltaSequence: 0,
      taskDelta: null,
      notifications: notifications,
      acceptedOnboardingRunId: null,
      rebuild: rebuild,
    );
    final patched = reducer.project(
      nonTaskRevision: 'stable',
      taskDeltaSequence: 1,
      taskDelta: AgentTaskLedgerDelta(
        upserts: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.chat(
            taskId: 'agent_run_incremental_1',
            threadId: 'thread-incremental',
            scene: ChatScene.feedAi,
            status: 'running',
            createdAt: DateTime.utc(2026, 8, 31, 10),
          ),
        ],
        removedTaskIds: const <String>[],
      ),
      notifications: notifications,
      acceptedOnboardingRunId: null,
      rebuild: rebuild,
    );

    expect(rebuildCalls, 1);
    expect(reducer.fullRebuildCount, 1);
    expect(reducer.incrementallyVisitedTaskEntries, 1);
    expect(patched.items.single.taskId, 'agent_run_incremental_1');

    reducer.project(
      nonTaskRevision: 'stable',
      taskDeltaSequence: 3,
      taskDelta: AgentTaskLedgerDelta(
        upserts: const <AgentTaskLedgerEntry>[],
        removedTaskIds: const <String>{'agent_run_incremental_1'},
      ),
      notifications: notifications,
      acceptedOnboardingRunId: null,
      rebuild: rebuild,
    );
    expect(rebuildCalls, 2);

    reducer.project(
      nonTaskRevision: 'stable',
      taskDeltaSequence: 4,
      taskDelta: AgentTaskLedgerDelta(
        upserts: const <AgentTaskLedgerEntry>[],
        removedTaskIds: const <String>[],
        reset: true,
      ),
      notifications: notifications,
      acceptedOnboardingRunId: null,
      rebuild: rebuild,
    );
    expect(rebuildCalls, 3);
  });

  test('terminal Chat delta rebuilds an earlier remote delivery alias', () {
    const agentRunId = 'agent_run_remote_first_1';
    const publicTaskId = 'public_chat_task_remote_first_1';
    const threadId = 'thread-remote-first-1';
    final createdAt = DateTime.utc(2026, 9, 2, 16);
    final notification = AppNotification(
      notificationId: 'remote-first-failure-1',
      eventId: 'remote-first-event-1',
      eventType: 'agent_run.failed',
      scene: 'chat',
      targetType: 'thread',
      targetId: threadId,
      title: '回复未完成',
      body: '可以查看失败结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.failed,
      taskId: publicTaskId,
      createdAt: createdAt.add(const Duration(minutes: 1)),
    );
    final remoteState = NotificationControllerState(
      status: NotificationControllerStatus.ready,
      items: <AppNotification>[notification],
    );
    var ledgerEntry = AgentTaskLedgerEntry.chat(
      taskId: agentRunId,
      publicTaskId: publicTaskId,
      threadId: threadId,
      scene: ChatScene.feedAi,
      status: 'running',
      createdAt: createdAt,
    );
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(createdAt);
    addTearDown(aggregation.dispose);
    PendingMessageProjection rebuild(NotificationControllerState state) =>
        buildPendingMessageProjection(
          notifications: state,
          aggregation: aggregation,
          knowledge: knowledge,
          taskLedger: <AgentTaskLedgerEntry>[ledgerEntry],
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
        );
    final reducer = PendingMessageProjectionReducer();

    final remoteFirst = reducer.project(
      nonTaskRevision: 'remote-first-stable',
      taskDeltaSequence: 0,
      taskDelta: null,
      notifications: remoteState,
      acceptedOnboardingRunId: null,
      rebuild: () => rebuild(remoteState),
    );
    expect(remoteFirst.items, hasLength(1));
    expect(remoteFirst.items.single.source, PendingMessageSource.remote);
    expect(remoteFirst.items.single.linkedDeliveryResolutionKey, isNull);

    ledgerEntry = AgentTaskLedgerEntry.chat(
      taskId: agentRunId,
      publicTaskId: publicTaskId,
      threadId: threadId,
      scene: ChatScene.feedAi,
      status: 'failed',
      failureCode: 'AGENT_RUN_FAILED',
      createdAt: createdAt,
    );
    final linked = reducer.project(
      nonTaskRevision: 'remote-first-stable',
      taskDeltaSequence: 1,
      taskDelta: AgentTaskLedgerDelta(
        upserts: <AgentTaskLedgerEntry>[ledgerEntry],
        removedTaskIds: const <String>[],
      ),
      notifications: remoteState,
      acceptedOnboardingRunId: null,
      rebuild: () => rebuild(remoteState),
    );
    expect(reducer.fullRebuildCount, 2);
    final deliveryAlias = linked.items.single.linkedDeliveryResolutionKey;
    expect(deliveryAlias, isNotNull);

    final beforeResolutionHydration = rebuild(
      NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[notification],
        resolutionHydrated: false,
      ),
    );
    expect(beforeResolutionHydration.items, hasLength(1));
    expect(beforeResolutionHydration.items.single.isUnread, isFalse);
    expect(beforeResolutionHydration.unreadCount, 0);

    final restoredRead = rebuild(
      NotificationControllerState(
        status: NotificationControllerStatus.ready,
        locallyReadIds: <String>{deliveryAlias!},
      ),
    );
    expect(restoredRead.items.single.source, PendingMessageSource.agentTask);
    expect(restoredRead.items.single.isUnread, isFalse);

    final restoredArchived = rebuild(
      NotificationControllerState(
        status: NotificationControllerStatus.ready,
        handledIds: <String>{deliveryAlias},
      ),
    );
    expect(restoredArchived.items, isEmpty);
  });

  test('disabled incremental projection always uses full rebuild', () {
    final reducer = PendingMessageProjectionReducer();
    var rebuildCalls = 0;
    PendingMessageProjection rebuild() {
      rebuildCalls += 1;
      return const PendingMessageProjection(
        items: <PendingMessage>[],
        isLoading: false,
        resolutionIsDemo: false,
      );
    }

    for (var sequence = 0; sequence < 2; sequence += 1) {
      reducer.project(
        incrementalEnabled: false,
        nonTaskRevision: 'stable',
        taskDeltaSequence: sequence,
        taskDelta: AgentTaskLedgerDelta(
          upserts: <AgentTaskLedgerEntry>[
            AgentTaskLedgerEntry.chat(
              taskId: 'rollback-run-$sequence',
              threadId: 'thread-rollback',
              scene: ChatScene.feedAi,
              status: 'running',
              createdAt: DateTime.utc(2026, 8, 31, 10),
            ),
          ],
          removedTaskIds: const <String>[],
        ),
        notifications: NotificationControllerState.initial(),
        acceptedOnboardingRunId: null,
        rebuild: rebuild,
      );
    }

    expect(rebuildCalls, 2);
    expect(reducer.fullRebuildCount, 2);
    expect(reducer.incrementallyVisitedTaskEntries, 0);
  });

  test('knowledge revision ignores notes without pending work', () {
    final now = DateTime.utc(2026, 8, 31, 10);
    final first = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'ordinary-note',
          title: '初稿',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '正文一',
          remoteNoteId: 'remote-ordinary-note',
        ),
        V3FeedItem(
          id: 'pending-note',
          title: '点火中',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '正文',
          sproutStatus: V3SproutTaskStatus.running,
        ),
      ],
    );
    final unrelatedEdit = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'ordinary-note',
          title: '已编辑初稿',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '正文二',
          remoteNoteId: 'remote-ordinary-note',
        ),
        V3FeedItem(
          id: 'pending-note',
          title: '点火中',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '正文',
          sproutStatus: V3SproutTaskStatus.running,
        ),
      ],
    );
    final pendingEdit = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'pending-note',
          title: '点火中（已改名）',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '正文',
          sproutStatus: V3SproutTaskStatus.running,
        ),
      ],
    );
    addTearDown(first.dispose);
    addTearDown(unrelatedEdit.dispose);
    addTearDown(pendingEdit.dispose);

    expect(
      pendingMessageKnowledgeRevision(first),
      pendingMessageKnowledgeRevision(unrelatedEdit),
    );
    expect(
      pendingMessageKnowledgeRevision(first),
      isNot(pendingMessageKnowledgeRevision(pendingEdit)),
    );
    expect(
      pendingMessageKnowledgeRevision(
        first,
        activeDerivedNoteIds: const <String>{'remote-ordinary-note'},
      ),
      isNot(
        pendingMessageKnowledgeRevision(
          unrelatedEdit,
          activeDerivedNoteIds: const <String>{'remote-ordinary-note'},
        ),
      ),
    );
    expect(
      pendingMessageKnowledgeRevision(first),
      isNot(
        pendingMessageKnowledgeRevision(
          first,
          aggregationGeneratedNoteId: 'ordinary-note',
        ),
      ),
    );
  });

  test('badge provider notifies only when unread attention changes', () async {
    const firstItem = PendingMessage(
      id: 'one',
      source: PendingMessageSource.remote,
      scene: 'notification',
      title: '第一条',
      body: '正文',
      state: PendingMessageState.succeeded,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
    );
    const replacementItem = PendingMessage(
      id: 'replacement',
      source: PendingMessageSource.remote,
      scene: 'notification',
      title: '替换内容',
      body: '正文',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
    );
    final source = StateProvider<PendingMessageProjection>(
      (ref) => const PendingMessageProjection(
        items: <PendingMessage>[firstItem],
        isLoading: false,
        resolutionIsDemo: false,
      ),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        pendingMessageProjectionProvider.overrideWith(
          (ref) => ref.watch(source),
        ),
      ],
    );
    addTearDown(container.dispose);
    var notifications = 0;
    final subscription = container.listen<int>(
      pendingMessageBadgeCountProvider,
      (previous, next) => notifications += 1,
    );
    addTearDown(subscription.close);

    expect(subscription.read(), 1);
    container.read(source.notifier).state = const PendingMessageProjection(
      items: <PendingMessage>[replacementItem],
      isLoading: true,
      resolutionIsDemo: false,
    );
    await container.pump();
    expect(notifications, 1);

    container.read(source.notifier).state = const PendingMessageProjection(
      items: <PendingMessage>[firstItem, replacementItem],
      isLoading: false,
      resolutionIsDemo: false,
    );
    await container.pump();
    expect(notifications, 2);
    expect(subscription.read(), 1);
  });

  test('projects every unresolved source into one ordered list', () async {
    final now = DateTime.utc(2026, 7, 26, 10);
    final documentHash = List<String>.filled(64, 'a').join();
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'sprout-note',
          title: '点火素材',
          source: V3MaterialSource.note,
          createdAt: now.subtract(const Duration(hours: 2)),
          updatedAt: now.subtract(const Duration(minutes: 30)),
          rawBody: '正文',
          sproutStatus: V3SproutTaskStatus.running,
        ),
      ],
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now)..startSelection();
    addTearDown(aggregation.dispose);
    await aggregation.confirm();

    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        resolutionIsDemo: true,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'remote-1',
            eventType: 'recording.completed',
            scene: 'recording',
            targetType: 'recording',
            targetId: 'recording-1',
            title: '远端转写完成',
            body: '可打开查看',
            status: AppNotificationStatus.unread,
            createdAt: now,
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: _TaskLedgerTracker(<AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: 'agent-run-processing-1',
          threadId: 'thread-processing-1',
          scene: ChatScene.feedAi,
          status: 'running',
          createdAt: now.subtract(const Duration(minutes: 2)),
        ),
      ]),
      ingestionDrafts: <MaterialIngestionDraft>[
        MaterialIngestionDraft(
          id: 'link-1',
          source: MaterialIngestionSource.link,
          status: MaterialIngestionStatus.analyzing,
          checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
          title: 'example.com',
          createdAt: now.subtract(const Duration(minutes: 8)),
          updatedAt: now.subtract(const Duration(minutes: 4)),
          submitKey: 'submit-link-1',
        ),
        MaterialIngestionDraft(
          id: 'legacy-internal-1',
          source: MaterialIngestionSource.internalRecording,
          status: MaterialIngestionStatus.uploading,
          checkpoint: MaterialIngestionCheckpoint.resourceReady,
          title: '旧内录任务',
          createdAt: now.subtract(const Duration(days: 2)),
          updatedAt: now.subtract(const Duration(days: 1)),
          submitKey: 'submit-legacy-internal-1',
        ),
        MaterialIngestionDraft(
          id: 'legacy-meeting-1',
          source: MaterialIngestionSource.meeting,
          status: MaterialIngestionStatus.analyzing,
          checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
          title: '旧会议任务',
          createdAt: now.subtract(const Duration(days: 2)),
          updatedAt: now.subtract(const Duration(days: 1)),
          submitKey: 'submit-legacy-meeting-1',
          remoteTaskId: 'legacy-recording-1',
        ),
      ],
      documentImport: V3DocumentImportState(
        status: V3DocumentImportStatus.importing,
        durableTasks: <V3DocumentImportTask>[
          V3DocumentImportTask(
            id: 'document-1',
            pickerRef: 'picker-1',
            displayName: '方案.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1200,
            sha256: documentHash,
            privateFileName: '$documentHash.pdf',
            status: V3DocumentImportTaskStatus.processing,
            attemptCount: 1,
            createdAt: now.subtract(const Duration(minutes: 7)),
            updatedAt: now.subtract(const Duration(minutes: 3)),
          ),
          V3DocumentImportTask(
            id: 'document-selection-only',
            pickerRef: 'picker-selection-only',
            displayName: '尚未确认.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1200,
            sha256: List<String>.filled(64, 'd').join(),
            privateFileName: '${List<String>.filled(64, 'd').join()}.pdf',
            status: V3DocumentImportTaskStatus.staged,
            attemptCount: 0,
            createdAt: now.subtract(const Duration(minutes: 2)),
            updatedAt: now.subtract(const Duration(minutes: 2)),
            acceptedForImport: false,
          ),
        ],
      ),
      canvasDraft: CreationCanvasDraft(
        title: '进行中的自由创作',
        markdown: '',
        revision: 1,
        sessionId: 'all-sources-canvas-session',
        scriptDraftReceipt: ScriptDraftGenerationReceipt(
          sessionId: 'all-sources-script-session',
          source: ScriptDraftSourceSnapshot(
            kind: ScriptDraftSourceKind.dailyRecommendation,
            sourceId: 'all-sources-topic',
            title: '自由创作来源',
            content: '来源正文',
            capturedAt: now.subtract(const Duration(minutes: 12)),
          ),
          createThreadIdempotencyKey: 'all-sources-create-thread',
          messageIdempotencyKey: 'all-sources-message',
          cancelIdempotencyKey: 'all-sources-cancel',
          phase: ScriptDraftGenerationPhase.streaming,
          threadId: 'all-sources-thread',
          agentRunId: 'all-sources-run',
          updatedAt: now.subtract(const Duration(minutes: 6)),
        ),
        createdAt: now.subtract(const Duration(minutes: 12)),
        updatedAt: now.subtract(const Duration(minutes: 6)),
      ),
      workbenchTasks: <WorkbenchGenerationTask>[
        WorkbenchGenerationTask(
          id: 'all-sources-workbench',
          purpose: WorkbenchPurpose.persona,
          notes: const <V3FeedItem>[],
          startedAt: now.subtract(const Duration(minutes: 10)),
          status: WorkbenchGenerationTaskStatus.processing,
        ),
      ],
      twinMaterials: <DigitalTwinMaterial>[
        DigitalTwinMaterial(
          id: 'all-sources-twin-material',
          referenceKind: 'note',
          referenceId: 'all-sources-note',
          title: '数字孪生材料处理中',
          createdAt: now.subtract(const Duration(minutes: 9)),
          status: DigitalTwinMaterialStatus.generating,
        ),
      ],
      masterpieceGeneration: const MasterpieceGenerationRecord(
        intent: MasterpieceGenerationIntent(
          bookId: 'all-sources-book',
          baseBookRevisionId: 'all-sources-revision',
          profileId: 'all-sources-profile',
          instruction: '生成代表作',
          sources: [],
          sectionKey: 'all-sources-section',
          title: '代表作生成中',
          requestKey: 'all-sources-request',
          initial: true,
          runId: 'all-sources-masterpiece-run',
          stage: MasterpieceGenerationStage.running,
        ),
      ),
      masterpieceWorkspaceId: 'all-sources-workspace',
      recordingUpload: RecordingUploadState(
        status: RecordingFileJobStatus.processing,
        activeDraft: _uploadDraft(now.subtract(const Duration(minutes: 2))),
      ),
      recordingProcessing: RecordingProcessingState(
        tasks: <RecordingProcessingTask>[
          RecordingProcessingTask(
            draft: _uploadDraft(
              now.subtract(const Duration(minutes: 2)),
            ).copyWith(stage: UploadDraftStage.asrQueued),
            phase: RecordingProcessingPhase.transcribing,
            updatedAt: now.subtract(const Duration(minutes: 2)),
          ),
        ],
      ),
      firstLoginOnboardingEligible: true,
      onboardingReminderRequired: true,
      onboardingReminderKey: 'user-1',
      onboardingDeferredAt: now.subtract(const Duration(minutes: 1)),
      firstLaunchDeviceSetupPending: true,
    );

    expect(
      projection.items.map((item) => item.source).toSet(),
      containsAll(PendingMessageSource.values),
    );
    expect(projection.items, hasLength(PendingMessageSource.values.length));
    expect(projection.unreadCount, 4);
    expect(
      projection.items
          .where((item) => item.state == PendingMessageState.processing)
          .every((item) => !item.isUnread),
      isTrue,
    );
    expect(projection.items.map((item) => item.title), contains('远端转写完成'));
    expect(
      projection.items
          .where(
            (item) => item.source == PendingMessageSource.materialIngestion,
          )
          .map((item) => item.scene),
      <String>['link'],
    );
    expect(
      projection.items.map((item) => item.title),
      isNot(contains('导入 · 尚未确认.pdf')),
    );
    expect(
      projection.items
          .where((item) => item.source == PendingMessageSource.aggregation)
          .single
          .isDemo,
      isFalse,
    );
    final ingestionMessage = projection.items
        .where((item) => item.source == PendingMessageSource.materialIngestion)
        .single;
    expect(ingestionMessage.isDemo, isFalse);
    expect(
      Uri.parse(ingestionMessage.route!).queryParameters['draftId'],
      'link-1',
    );
    final documentMessage = projection.items
        .where((item) => item.source == PendingMessageSource.documentImport)
        .single;
    expect(
      Uri.parse(documentMessage.route!).queryParameters['taskId'],
      'document-1',
    );
    final operationalTasks = projection.items.where(
      (item) => switch (item.source) {
        PendingMessageSource.sprout ||
        PendingMessageSource.materialIngestion ||
        PendingMessageSource.documentImport ||
        PendingMessageSource.recordingTranscription => true,
        _ => false,
      },
    );
    expect(operationalTasks, isNotEmpty);
    expect(operationalTasks.every((item) => item.isTask), isTrue);
    expect(
      operationalTasks
          .where((item) => item.state == PendingMessageState.processing)
          .every(
            (item) =>
                item.shouldShowOpenAction && !item.shouldShowHandledAction,
          ),
      isTrue,
    );
  });

  test('derives asset cache freshness from relevant task revisions', () {
    const importRunning = PendingMessage(
      id: 'local:document:running',
      source: PendingMessageSource.documentImport,
      scene: 'document',
      title: '导入任务',
      body: '正在处理。',
      state: PendingMessageState.processing,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'document-run-1',
      targetType: 'asset',
      targetId: 'note-1',
      isTask: true,
    );
    const chatRunning = PendingMessage(
      id: 'local:chat:running',
      source: PendingMessageSource.agentTask,
      scene: 'chat',
      title: '聊一聊任务',
      body: '正在处理。',
      state: PendingMessageState.processing,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'chat-run-1',
      targetType: 'thread',
      targetId: 'thread-1',
      isTask: true,
    );
    const importCompleted = PendingMessage(
      id: 'local:document:running',
      source: PendingMessageSource.documentImport,
      scene: 'document',
      title: '导入任务',
      body: '已完成。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'document-run-1',
      targetType: 'asset',
      targetId: 'note-1',
      isTask: true,
    );

    final active = deriveAssetProjectionFreshness(<PendingMessage>[
      importRunning,
      chatRunning,
    ]);
    final completed = deriveAssetProjectionFreshness(<PendingMessage>[
      importCompleted,
      chatRunning,
    ]);
    final chatOnly = deriveAssetProjectionFreshness(<PendingMessage>[
      chatRunning,
    ]);

    expect(active.hasActiveWork, isTrue);
    expect(completed.hasActiveWork, isFalse);
    expect(completed.revision, isNot(active.revision));
    expect(chatOnly.hasActiveWork, isFalse);
    expect(chatOnly.revision, isEmpty);
  });

  test(
    'read aggregation completion waits for result acknowledgement',
    () async {
      final now = DateTime.utc(2026, 7, 26, 10);
      final aggregation = _aggregationController(now)..startSelection();
      addTearDown(aggregation.dispose);
      await aggregation.confirm();
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      const base = NotificationControllerState(
        status: NotificationControllerStatus.ready,
        resolutionIsDemo: true,
      );

      final first = _projectAggregation(base, aggregation, knowledge);
      final id = first.items.single.id;
      final taskId = first.items.single.taskId!;
      final deliveryKey = pendingMessageLocalDeliveryResolutionKey(
        first.items.single,
      );
      final read = _projectAggregation(
        base.copyWith(locallyReadIds: <String>{deliveryKey}),
        aggregation,
        knowledge,
      );
      final handled = _projectAggregation(
        base.copyWith(handledTaskIds: <String>{taskId}),
        aggregation,
        knowledge,
      );

      expect(first.items.single.isUnread, isTrue);
      expect(deliveryKey, isNot(id));
      expect(read.items, hasLength(1));
      expect(read.items.single.isUnread, isFalse);
      expect(handled.items, isEmpty);
    },
  );

  test(
    'server-required onboarding reminder ignores handled metadata',
    () async {
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(DateTime.utc(2026, 8, 1));
      addTearDown(aggregation.dispose);
      final reminderId = localPendingMessageId(
        PendingMessageSource.onboarding,
        'user-1',
      );

      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          handledIds: <String>{reminderId},
          locallyReadIds: <String>{reminderId},
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
        firstLoginOnboardingEligible: true,
        onboardingReminderRequired: true,
        onboardingReminderKey: 'user-1',
        onboardingDeferredAt: DateTime.utc(2026, 8, 1),
      );

      final reminder = projection.items.single;
      expect(reminder.source, PendingMessageSource.onboarding);
      expect(reminder.title, '完成基础定位');
      expect(reminder.route, '/onboarding?resume=1');
      expect(reminder.isUnread, isFalse);
      expect(reminder.canMarkHandled, isFalse);
    },
  );

  test(
    'install-local device guide remains separate from base positioning reminder',
    () {
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(DateTime.utc(2026, 8, 18));
      addTearDown(aggregation.dispose);

      PendingMessageProjection project(bool deviceGuidePending) {
        return buildPendingMessageProjection(
          notifications: const NotificationControllerState(
            status: NotificationControllerStatus.ready,
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
          firstLoginOnboardingEligible: true,
          onboardingReminderRequired: true,
          onboardingReminderKey: 'user-1',
          onboardingDeferredAt: DateTime.utc(2026, 8, 18),
          firstLaunchDeviceSetupPending: deviceGuidePending,
          firstLaunchDeviceSetupKey: 'user-1',
        );
      }

      final pending = project(true);
      final onboarding = pending.items.singleWhere(
        (item) => item.source == PendingMessageSource.onboarding,
      );
      final deviceGuide = pending.items.singleWhere(
        (item) => item.source == PendingMessageSource.firstLaunchDeviceSetup,
      );

      expect(pending.items, hasLength(2));
      expect(onboarding.route, '/onboarding?resume=1');
      expect(onboarding.canMarkHandled, isFalse);
      expect(deviceGuide.route, '/v3/onboarding/device-setup');
      expect(deviceGuide.targetType, 'first_launch_device_setup');
      expect(deviceGuide.canMarkHandled, isFalse);
      expect(pendingMessageOpenActionLabel(deviceGuide), '继续设置');

      final afterBothGuidePagesViewed = project(false);
      expect(afterBothGuidePagesViewed.items, hasLength(1));
      expect(
        afterBothGuidePagesViewed.items.single.source,
        PendingMessageSource.onboarding,
      );
    },
  );

  test(
    'restored account retains only its incomplete startup journey reminder',
    () {
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(DateTime.utc(2026, 8, 18));
      addTearDown(aggregation.dispose);

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
        onboardingReminderRequired: true,
        onboardingReminderKey: 'existing-user',
        firstLaunchDeviceSetupPending: true,
        firstLaunchDeviceSetupKey: 'existing-user',
      );

      expect(projection.items, hasLength(1));
      final deviceSetup = projection.items.single;
      expect(deviceSetup.source, PendingMessageSource.firstLaunchDeviceSetup);
      expect(deviceSetup.title, '继续完成启动设置');
      expect(deviceSetup.body, contains('按顺序完成'));
    },
  );

  test('device onboarding reminder identity is account scoped', () {
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(DateTime.utc(2026, 8, 18));
    addTearDown(aggregation.dispose);

    PendingMessage deviceReminder(String userId) =>
        buildPendingMessageProjection(
          notifications: const NotificationControllerState(
            status: NotificationControllerStatus.ready,
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
          firstLoginOnboardingEligible: true,
          firstLaunchDeviceSetupPending: true,
          firstLaunchDeviceSetupKey: userId,
        ).items.single;

    expect(deviceReminder('user-1').id, isNot(deviceReminder('user-2').id));
  });

  test(
    'completion remains projected after the graph panel is dismissed',
    () async {
      final now = DateTime.utc(2026, 7, 26, 10);
      final aggregation = _aggregationController(now)..startSelection();
      addTearDown(aggregation.dispose);
      expect(await aggregation.confirm(), isNotNull);
      aggregation.dismissCompletion();
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);

      final projection = _projectAggregation(
        const NotificationControllerState(
          status: NotificationControllerStatus.ready,
          resolutionIsDemo: true,
        ),
        aggregation,
        knowledge,
      );
      expect(projection.items.single.title, '《内容聚合 · 热点》聚合已完成');
      expect(projection.items.single.route, contains('/v3/feed/items/'));
    },
  );

  test(
    'production collision projects only its current lifecycle row',
    () async {
      final now = DateTime.utc(2026, 8, 14, 12);
      final pendingKnowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(pendingKnowledge.dispose);
      final pending = _productionAggregationController(
        now,
        _FixedTopicCollisionRunPort(_topicCollisionRun('running')),
        pendingKnowledge,
      );
      addTearDown(pending.dispose);

      expect(pending.startSelection(), isTrue);
      expect(
        _projectAggregation(
          const NotificationControllerState(
            status: NotificationControllerStatus.ready,
          ),
          pending,
          pendingKnowledge,
        ).items.where(
          (item) => item.source == PendingMessageSource.aggregation,
        ),
        isEmpty,
      );
      final submission = pending.confirm();
      final submitting = _projectAggregation(
        const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        pending,
        pendingKnowledge,
      ).items.where((item) => item.source == PendingMessageSource.aggregation);
      expect(submitting.single.title, '《来源 0》等 4 篇 · 正在提交聚合');
      expect(submitting.single.state, PendingMessageState.processing);
      final intentMessage = submitting.single;
      expect(Uri.parse(intentMessage.route!).path, '/v3/feed/aggregation');
      expect(
        Uri.parse(intentMessage.route!).queryParameters['taskId'],
        pending.taskId,
      );
      expect(intentMessage.replaceRoute, isFalse);
      await submission;
      expect(pending.matchesTaskReference(intentMessage.taskId), isTrue);
      await Future<void>.delayed(Duration.zero);

      final pendingRows = _projectAggregation(
        const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        pending,
        pendingKnowledge,
      ).items.where((item) => item.source == PendingMessageSource.aggregation);
      expect(pendingRows, hasLength(1));
      expect(pendingRows.single.id, intentMessage.id);
      expect(pendingRows.single.isUnread, isFalse);
      expect(pendingRows.single.title, '《来源 0》等 4 篇 · 观点聚合中');
      expect(
        Uri.parse(pendingRows.single.route!).queryParameters['taskId'],
        pending.taskNotices.single.reference,
      );
      expect(pendingRows.single.replaceRoute, isFalse);
      expect(pendingRows.single.state, PendingMessageState.processing);

      final queuedKnowledge = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
      );
      addTearDown(queuedKnowledge.dispose);
      final queued = _productionAggregationController(
        now,
        _FixedTopicCollisionRunPort(_topicCollisionRun('queued')),
        queuedKnowledge,
      );
      addTearDown(queued.dispose);
      queued.startSelection();
      await queued.confirm();
      expect(
        pendingMessageAggregationRevision(queued),
        isNot(pendingMessageAggregationRevision(pending)),
      );

      final failedKnowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(failedKnowledge.dispose);
      final failed = _productionAggregationController(
        now,
        _FixedTopicCollisionRunPort(
          _topicCollisionRun(
            'failed',
            failureCode: 'TOPIC_COLLISION_MODEL_FAILED',
          ),
        ),
        failedKnowledge,
      );
      addTearDown(failed.dispose);

      expect(failed.startSelection(), isTrue);
      await failed.confirm();
      await Future<void>.delayed(Duration.zero);

      final failedRows = _projectAggregation(
        const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        failed,
        failedKnowledge,
      ).items.where((item) => item.source == PendingMessageSource.aggregation);
      expect(failedRows, hasLength(1));
      expect(failedRows.single.title, '《来源 0》等 4 篇 · 观点聚合未完成');
      expect(Uri.parse(failedRows.single.route!).path, '/v3/feed/aggregation');
      expect(failedRows.single.replaceRoute, isFalse);
      expect(failedRows.single.state, PendingMessageState.failed);
      expect(failedRows.single.isUnread, isTrue);
      failed.startSelection();
      final history =
          _projectAggregation(
                const NotificationControllerState(
                  status: NotificationControllerStatus.ready,
                ),
                failed,
                failedKnowledge,
              ).items
              .where((item) => item.source == PendingMessageSource.aggregation)
              .single;
      expect(history.id, failedRows.single.id);
      expect(history.state, PendingMessageState.failed);
      failed.cancelSelection();
      expect(failed.noticeForReference(history.taskId), isNotNull);
    },
  );

  test(
    'projects one non-handleable outline task from active derived tasks',
    () async {
      final now = DateTime.utc(2026, 8, 13, 10);
      final note = V3FeedItem(
        id: 'derived-note',
        title: '待生成纲要',
        source: V3MaterialSource.note,
        createdAt: now,
        rawBody: '原始内容',
        activeDerivedTasks: const <V3ActiveDerivedTask>[
          V3ActiveDerivedTask(
            fileAgentRunId: 'file-run-1',
            stage: V3DerivedTaskStage.outline,
            status: 'queued',
          ),
        ],
        activeDerivedTasksAuthoritative: true,
      );
      final knowledge = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final tracker = ChatRunTracker(
        assistantRuntime: const UnavailableAssistantRuntime(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'local-file-run-1',
        status: 'running',
        localNoteId: note.id,
        remoteNoteId: 'remote-note-1',
        targetPart: NoteFileAgentPart.outline,
      );

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: tracker,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final task = projection.items.singleWhere(
        (item) => item.title == '《待生成纲要》纲要正在生成',
      );
      expect(task.state, PendingMessageState.processing);
      expect(task.canMarkHandled, isFalse);
      expect(task.body, '正在使用 Agent 生成纲要。');
    },
  );

  test(
    'keeps recording transcription and automatic outline as independent results',
    () async {
      final now = DateTime.utc(2026, 9, 3, 10);
      final note = V3FeedItem(
        id: 'recording-note-1',
        title: '访谈录音',
        source: V3MaterialSource.meeting,
        createdAt: now,
        rawBody: '已完成转写',
        recordingId: 'recording-1',
        remoteNoteId: 'remote-recording-note-1',
        rawPartRevisionId: 'raw-revision-1',
        outlinePartRevisionId: 'outline-revision-2',
        summaryBody: '# 最终纲要',
        activeDerivedTasks: const <V3ActiveDerivedTask>[
          V3ActiveDerivedTask(
            fileAgentRunId: 'recording-outline-shadow-run',
            stage: V3DerivedTaskStage.outline,
            status: 'running',
          ),
        ],
        activeDerivedTasksAuthoritative: true,
      );
      final knowledge = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final draft = _uploadDraft(
        now,
      ).copyWith(stage: UploadDraftStage.asrCompleted);

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskLedger: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.recordingOutline(
            taskId: 'recording-outline:stable-1',
            publicTaskId: 'outline-subtask-1',
            recordingId: 'recording-1',
            localNoteId: note.id,
            remoteNoteId: note.remoteNoteId!,
            status: 'succeeded',
            createdAt: now.add(const Duration(minutes: 1)),
            outputPartRevisionId: 'outline-revision-2',
          ),
        ],
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
        recordingProcessing: RecordingProcessingState(
          tasks: <RecordingProcessingTask>[
            RecordingProcessingTask(
              draft: draft,
              phase: RecordingProcessingPhase.completed,
              updatedAt: now,
            ),
          ],
        ),
      );

      final transcription = projection.items.singleWhere(
        (item) => item.source == PendingMessageSource.recordingTranscription,
      );
      expect(transcription.taskId, 'asr-1');
      expect(transcription.body, '转写完成，结果已保存到我的资产。');
      expect(transcription.isUnread, isTrue);
      expect(
        pendingMessageLogicalGroupKey(transcription),
        'recording:recording-1',
      );
      expect(
        Uri.parse(transcription.route!).queryParameters['destination'],
        'raw',
      );
      final outline = projection.items.singleWhere(
        (item) =>
            item.source == PendingMessageSource.agentTask &&
            item.stage == 'outline',
      );
      expect(outline.taskId, 'recording-outline:stable-1');
      expect(outline.taskResultAliasIds, <String>['outline-subtask-1']);
      expect(outline.isUnread, isTrue);
      expect(outline.route, '/v3/feed/items/recording-note-1?stage=summary');
      expect(pendingMessageLogicalGroupKey(outline), isNull);
      expect(projection.unreadCount, 2);

      final controller = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      addTearDown(controller.dispose);
      PendingMessageProjection projectWithReceipts() =>
          buildPendingMessageProjection(
            notifications: controller.state,
            aggregation: aggregation,
            knowledge: knowledge,
            taskLedger: <AgentTaskLedgerEntry>[
              AgentTaskLedgerEntry.recordingOutline(
                taskId: 'recording-outline:stable-1',
                publicTaskId: 'outline-subtask-1',
                recordingId: 'recording-1',
                localNoteId: note.id,
                remoteNoteId: note.remoteNoteId!,
                status: 'succeeded',
                createdAt: now.add(const Duration(minutes: 1)),
                outputPartRevisionId: 'outline-revision-2',
              ),
            ],
            ingestionDrafts: const <MaterialIngestionDraft>[],
            documentImport: const V3DocumentImportState.initial(),
            recordingUpload: RecordingUploadState.initial(),
            recordingProcessing: RecordingProcessingState(
              tasks: <RecordingProcessingTask>[
                RecordingProcessingTask(
                  draft: draft,
                  phase: RecordingProcessingPhase.completed,
                  updatedAt: now,
                ),
              ],
            ),
          );
      final actions = PendingMessageActions(
        controller,
        items: () => projectWithReceipts().items,
      );
      expect(
        await actions.acknowledgeResultShown(
          targetType: 'recording',
          targetId: 'recording-1',
          stage: 'recording_processing',
        ),
        isTrue,
      );
      final afterRawReceipt = projectWithReceipts();
      expect(afterRawReceipt.items, hasLength(1));
      expect(afterRawReceipt.items.single.stage, 'outline');
      expect(afterRawReceipt.items.single.isUnread, isTrue);
    },
  );

  test('remote Outline delivery replaces its local recording ledger row', () {
    final now = DateTime.utc(2026, 9, 3, 10);
    final note = V3FeedItem(
      id: 'recording-note-remote-outline',
      title: '访谈录音',
      source: V3MaterialSource.meeting,
      createdAt: now,
      rawBody: '已完成转写',
      recordingId: 'recording-remote-outline',
      remoteNoteId: 'remote-recording-note-outline',
      rawPartRevisionId: 'raw-revision-outline',
      outlinePartRevisionId: 'outline-revision-remote',
      summaryBody: '# 最终纲要',
    );
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'recording-outline-delivery',
            eventType: 'note.outline.succeeded',
            scene: 'outline',
            targetType: 'asset',
            targetId: note.id,
            title: '录音纲要已完成',
            body: '可以查看最终纲要。',
            status: AppNotificationStatus.unread,
            taskStatus: AppNotificationTaskStatus.succeeded,
            taskId: 'outline-subtask-remote',
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.recordingOutline(
          taskId: 'recording-outline:stable-remote',
          publicTaskId: 'outline-subtask-remote',
          recordingId: 'recording-remote-outline',
          localNoteId: note.id,
          remoteNoteId: note.remoteNoteId!,
          status: 'succeeded',
          createdAt: now,
          outputPartRevisionId: 'outline-revision-remote',
        ),
      ],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final outlineRows = projection.items.where(
      (item) => item.stage == 'outline' && item.targetId == note.id,
    );
    expect(outlineRows, hasLength(1));
    expect(outlineRows.single.source, PendingMessageSource.remote);
    expect(outlineRows.single.taskId, 'outline-subtask-remote');
    expect(projection.unreadCount, 1);
  });

  test(
    'recording upload opens its persisted Raw job before Recording exists',
    () {
      final now = DateTime.utc(2026, 9, 3, 10);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final draft = _uploadDraft(
        now,
        recordingId: null,
        stage: UploadDraftStage.objectUploading,
        entrySource: 'monologue',
      );

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState(
          status: RecordingFileJobStatus.uploading,
          activeDraft: draft,
          uploadProgressByDraftId:
              const <String, RecordingObjectUploadProgress>{
                'upload-1': RecordingObjectUploadProgress(
                  draftId: 'upload-1',
                  bytesSent: 256,
                  totalBytes: 1024,
                  bytesPerSecond: 128,
                  estimatedRemainingSeconds: 6,
                ),
              },
        ),
      );

      final upload = projection.items.singleWhere(
        (item) => item.source == PendingMessageSource.recordingTranscription,
      );
      expect(
        upload.route,
        '/v3/feed/transcription-jobs/upload-1?source=monologue&destination=raw',
      );
      expect(upload.recordingUploadProgress?.bytesSent, 256);
      expect(upload.recordingUploadProgress?.estimatedRemainingSeconds, 6);
    },
  );

  test('concurrent independent uploads retain one notification per draft', () {
    final now = DateTime.utc(2026, 9, 5, 11);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final draftA = _uploadDraft(
      now.subtract(const Duration(seconds: 1)),
      draftId: 'concurrent-a',
      recordingId: null,
      stage: UploadDraftStage.objectUploading,
      title: '录音 A',
    );
    final draftB = _uploadDraft(
      now,
      draftId: 'concurrent-b',
      recordingId: null,
      stage: UploadDraftStage.objectUploading,
      title: '录音 B',
    );

    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState(
        status: RecordingFileJobStatus.uploading,
        activeDraft: draftB,
        activeUploadDraftsById: <String, UploadDraft>{
          draftA.draftId: draftA,
          draftB.draftId: draftB,
        },
        uploadProgressByDraftId: const <String, RecordingObjectUploadProgress>{
          'concurrent-a': RecordingObjectUploadProgress(
            draftId: 'concurrent-a',
            bytesSent: 128,
            totalBytes: 1024,
            bytesPerSecond: 64,
            estimatedRemainingSeconds: 14,
          ),
          'concurrent-b': RecordingObjectUploadProgress(
            draftId: 'concurrent-b',
            bytesSent: 512,
            totalBytes: 1024,
            bytesPerSecond: 256,
            estimatedRemainingSeconds: 2,
          ),
        },
      ),
    );

    final uploads = projection.items
        .where(
          (item) =>
              item.source == PendingMessageSource.recordingTranscription &&
              item.state == PendingMessageState.processing,
        )
        .toList(growable: false);
    expect(uploads, hasLength(2));
    final byRoute = <String, PendingMessage>{
      for (final item in uploads) item.route!: item,
    };
    expect(
      byRoute['/v3/feed/transcription-jobs/concurrent-a?destination=raw']
          ?.recordingUploadProgress
          ?.bytesSent,
      128,
    );
    expect(
      byRoute['/v3/feed/transcription-jobs/concurrent-b?destination=raw']
          ?.recordingUploadProgress
          ?.bytesSent,
      512,
    );
  });

  test(
    'projects a terminal chat ledger row until its result is shown',
    () async {
      final now = DateTime.utc(2026, 8, 14, 10);
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'succeeded')),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
        now: () => now,
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_ledger_1',
        threadId: 'thread-ledger-1',
        scene: ChatScene.feedAi,
      );
      await Future<void>.delayed(Duration.zero);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: tracker,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final message = projection.items.singleWhere(
        (item) => item.source == PendingMessageSource.agentTask,
      );
      expect(message.state, PendingMessageState.succeeded);
      expect(message.isTask, isTrue);
      expect(message.taskId, 'agent_run_ledger_1');
      expect(message.canMarkHandled, isFalse);
      expect(
        message.route,
        '/v3/feed/chat?threadId=thread-ledger-1&purpose=general',
      );
    },
  );

  test('names Chat and derived ledger tasks after their exact subjects', () {
    final now = DateTime.utc(2026, 9, 15, 10);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: 'named-chat-run',
          threadId: 'named-chat-thread',
          scene: ChatScene.feedAi,
          status: 'running',
          createdAt: now,
          subjectTitle: '客户回访复盘',
        ),
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'named-outline-run',
          localNoteId: 'named-outline-note',
          remoteNoteId: 'named-outline-remote',
          targetPart: NoteFileAgentPart.outline,
          status: 'succeeded',
          createdAt: now.subtract(const Duration(seconds: 1)),
          subjectTitle: '外部文章：增长方法',
        ),
      ],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final byTaskId = <String, PendingMessage>{
      for (final item in projection.items)
        if (item.taskId != null) item.taskId!: item,
    };
    expect(byTaskId['named-chat-run']?.title, '《客户回访复盘》正在回复');
    expect(byTaskId['named-outline-run']?.title, '《外部文章：增长方法》纲要已完成');
  });

  test('taskless Chat lifecycle uses the exact remembered thread title', () {
    final now = DateTime.utc(2026, 9, 15, 10, 30);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    const tracker = _TaskLedgerTracker(
      <AgentTaskLedgerEntry>[],
      chatSubjects: <String, String>{'thread-delayed-chat': '客户续约复盘'},
    );

    final cases = <(String, String, PendingMessageState)>[
      ('agent_run.running', '《客户续约复盘》正在回复', PendingMessageState.processing),
      ('agent_run.succeeded', '《客户续约复盘》回复已完成', PendingMessageState.succeeded),
      ('agent_run.failed', '《客户续约复盘》回复未完成', PendingMessageState.failed),
    ];
    for (final (eventType, expectedTitle, expectedState) in cases) {
      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            AppNotification(
              notificationId: 'remote-delayed-$eventType',
              eventType: eventType,
              scene: 'chat',
              targetType: 'thread',
              targetId: 'thread-delayed-chat',
              title: '聊一聊状态有更新',
              body: '可以查看回复。',
              status: AppNotificationStatus.unread,
              createdAt: now,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: tracker,
        taskLedger: const <AgentTaskLedgerEntry>[],
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items.single.title, expectedTitle);
      expect(projection.items.single.state, expectedState);
    }

    final unrelated = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'remote-thread-member-added',
            eventType: 'thread.member_added',
            scene: 'social',
            targetType: 'thread',
            targetId: 'thread-delayed-chat',
            title: '会话成员已更新',
            body: '有一名成员加入。',
            status: AppNotificationStatus.unread,
            createdAt: now,
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: tracker,
      taskLedger: const <AgentTaskLedgerEntry>[],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );
    expect(unrelated.items.single.title, '会话成员已更新');
  });

  test('Workspace fence hides foreign, unscoped resource and hotspot rows', () {
    final now = DateTime.utc(2026, 9, 15, 11);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    const tracker = _TaskLedgerTracker(
      <AgentTaskLedgerEntry>[],
      chatSubjects: <String, String>{'shared-thread': '当前工作区会话'},
    );
    AppNotification delivery(String id, {String? workspaceId}) =>
        AppNotification(
          notificationId: id,
          workspaceId: workspaceId,
          eventType: 'agent_run.succeeded',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'shared-thread',
          title: '$id 后端标题',
          body: '可以查看回复。',
          status: AppNotificationStatus.unread,
          createdAt: now,
        );

    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          delivery('matching', workspaceId: 'workspace-b'),
          delivery('legacy'),
          delivery('foreign', workspaceId: 'workspace-a'),
          AppNotification(
            notificationId: 'legacy-hotspot',
            eventType: 'hotspot_suggestion',
            scene: 'feed',
            targetType: 'hotspot_suggestion',
            targetId: 'suggestion-1',
            title: '其他工作区热点',
            body: '不应显示。',
            status: AppNotificationStatus.unread,
            createdAt: now,
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: tracker,
      taskLedger: const <AgentTaskLedgerEntry>[],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
      activeWorkspaceId: 'workspace-b',
    );

    final byId = <String, PendingMessage>{
      for (final item in projection.items) item.id: item,
    };
    expect(byId.keys, <String>{'matching'});
    expect(byId['matching']?.title, '《当前工作区会话》回复已完成');
    expect(byId['matching']?.route, isNotNull);
  });

  test('unscoped daily notice uses fixed account-level presentation', () {
    final now = DateTime.utc(2026, 9, 15, 11, 10);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'daily-topic',
            eventType: 'topic_recommendation.ready',
            scene: 'work_ai',
            targetType: 'topic_recommendation',
            targetId: 'recommendation-from-an-unknown-workspace',
            title: '服务端不可信标题',
            body: '服务端不可信正文',
            status: AppNotificationStatus.unread,
            createdAt: now,
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskLedger: const <AgentTaskLedgerEntry>[],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
      activeWorkspaceId: 'workspace-b',
    );

    final message = projection.items.single;
    expect(message.title, '每日推荐已生成');
    expect(message.body, '今天的推荐内容已经准备好。');
    expect(message.route, AppRoutePaths.workbench);
    expect(message.targetType, 'notification');
    expect(message.targetId, 'daily-topic');
    expect(message.isTask, isFalse);
  });

  test('unscoped remote task cannot suppress a scoped local task', () {
    final now = DateTime.utc(2026, 9, 15, 11, 15);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final task = AgentTaskLedgerEntry.chat(
      taskId: 'shared-task',
      threadId: 'shared-thread',
      scene: ChatScene.feedAi,
      status: 'running',
      createdAt: now,
      subjectTitle: '当前工作区会话',
    );

    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'legacy-task',
            eventType: 'agent_run.running',
            scene: 'chat',
            targetType: 'thread',
            targetId: 'shared-thread',
            title: '历史任务仍在运行',
            body: '历史任务状态。',
            status: AppNotificationStatus.unread,
            taskStatus: AppNotificationTaskStatus.running,
            taskId: 'shared-task',
            createdAt: now,
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskLedger: <AgentTaskLedgerEntry>[task],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
      activeWorkspaceId: 'workspace-b',
    );

    expect(projection.items, hasLength(1));
    expect(
      projection.items.any(
        (item) =>
            item.isTask &&
            item.taskId == 'shared-task' &&
            item.title == '《当前工作区会话》正在回复',
      ),
      isTrue,
    );
  });

  test(
    'remote Outline delivery keeps the current title and local asset route',
    () {
      final now = DateTime.utc(2026, 9, 15, 10);
      final note = V3FeedItem(
        id: 'local-article-note',
        title: '已重命名的行业文章',
        source: V3MaterialSource.subscription,
        createdAt: now,
        rawBody: '文章原始内容',
        remoteNoteId: 'remote-article-note',
        rawPartRevisionId: 'raw-article-r1',
        outlinePartRevisionId: 'outline-article-r1',
      );
      final knowledge = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);

      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            AppNotification(
              notificationId: 'remote-outline-delivery',
              eventType: 'note.outline.succeeded',
              scene: 'outline',
              targetType: 'hnote',
              targetId: 'remote-article-note',
              title: '纲要已完成',
              body: '可以查看结果。',
              status: AppNotificationStatus.unread,
              taskStatus: AppNotificationTaskStatus.succeeded,
              taskId: 'remote-outline-task',
              createdAt: now,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskLedger: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.derivedPart(
            taskId: 'remote-outline-task',
            localNoteId: note.id,
            remoteNoteId: note.remoteNoteId,
            targetPart: NoteFileAgentPart.outline,
            status: 'succeeded',
            createdAt: now,
            subjectTitle: '旧文章标题',
          ),
        ],
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final message = projection.items.single;
      expect(message.title, '《已重命名的行业文章》纲要已完成');
      expect(message.targetType, 'asset');
      expect(message.targetId, note.id);
      expect(message.route, '/v3/feed/items/local-article-note?stage=summary');
    },
  );

  test(
    'taskless legacy Outline and Sprout keep their stage after HNote hydration',
    () {
      final now = DateTime.utc(2026, 9, 15, 10, 30);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final cases =
          <
            ({
              String label,
              String eventType,
              String scene,
              String localNoteId,
              String remoteNoteId,
              String routeStage,
            })
          >[
            (
              label: 'Outline',
              eventType: 'note.outline.succeeded',
              scene: 'outline',
              localNoteId: 'legacy-outline-local',
              remoteNoteId: 'legacy-outline-remote',
              routeStage: 'summary',
            ),
            (
              label: 'Sprout',
              eventType: 'note.germination.succeeded',
              scene: 'germination',
              localNoteId: 'legacy-sprout-local',
              remoteNoteId: 'legacy-sprout-remote',
              routeStage: 'sprout',
            ),
          ];

      for (final testCase in cases) {
        final notification = AppNotification(
          notificationId: 'legacy-${testCase.label.toLowerCase()}-delivery',
          eventType: testCase.eventType,
          scene: testCase.scene,
          targetType: 'hnote',
          targetId: testCase.remoteNoteId,
          title: '${testCase.label} 已完成',
          body: '可以查看结果。',
          status: AppNotificationStatus.unread,
          createdAt: now,
        );
        PendingMessageProjection project() => buildPendingMessageProjection(
          notifications: NotificationControllerState(
            status: NotificationControllerStatus.ready,
            items: <AppNotification>[notification],
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
        );

        final beforeHydration = project().items.single;
        expect(beforeHydration.taskId, isNull, reason: testCase.label);
        expect(beforeHydration.isTask, isFalse, reason: testCase.label);
        expect(beforeHydration.stage, isNull, reason: testCase.label);
        expect(
          beforeHydration.route,
          '/v3/feed/items/${testCase.remoteNoteId}?stage=${testCase.routeStage}',
          reason: testCase.label,
        );

        knowledge.updateNote(
          V3FeedItem(
            id: testCase.localNoteId,
            title: 'Hydrated ${testCase.label} asset',
            source: V3MaterialSource.note,
            createdAt: now,
            rawBody: 'Canonical Raw content',
            remoteNoteId: testCase.remoteNoteId,
            rawPartRevisionId: 'raw-${testCase.localNoteId}',
          ),
        );

        final afterHydration = project().items.single;
        expect(afterHydration.id, beforeHydration.id, reason: testCase.label);
        expect(afterHydration.taskId, isNull, reason: testCase.label);
        expect(afterHydration.isTask, isFalse, reason: testCase.label);
        expect(afterHydration.stage, isNull, reason: testCase.label);
        expect(afterHydration.targetId, testCase.localNoteId);
        expect(
          afterHydration.title,
          testCase.routeStage == 'summary'
              ? '《Hydrated ${testCase.label} asset》纲要已完成'
              : '《Hydrated ${testCase.label} asset》深度洞察已完成',
          reason: testCase.label,
        );
        expect(
          afterHydration.route,
          '/v3/feed/items/${testCase.localNoteId}?stage=${testCase.routeStage}',
          reason: testCase.label,
        );
      }
    },
  );

  test(
    'knowledge revision provider observes taskless asset hydration',
    () async {
      final now = DateTime.utc(2026, 9, 15, 10, 45);
      const remoteNoteId = 'provider-taskless-outline-remote';
      final notifications = NotificationController(
        api: _StaticNotificationApi(<AppNotification>[
          AppNotification(
            notificationId: 'provider-taskless-outline-delivery',
            eventType: 'note.outline.succeeded',
            scene: 'outline',
            targetType: 'hnote',
            targetId: remoteNoteId,
            title: '纲要已完成',
            body: '可以查看结果。',
            status: AppNotificationStatus.unread,
            createdAt: now,
          ),
        ]),
      );
      await notifications.load(forceRemote: true);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: const UnavailableAssistantRuntime(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'taskless-provider-scope',
      );
      final container = ProviderContainer(
        overrides: <Override>[
          notificationControllerProvider.overrideWith((ref) => notifications),
          knowledgeLibraryControllerProvider.overrideWith((ref) => knowledge),
          chatRunTrackerProvider.overrideWith((ref) => tracker),
        ],
      );
      addTearDown(container.dispose);
      final revisions = <String>[];
      final subscription = container.listen<String>(
        pendingMessageKnowledgeRevisionProvider,
        (previous, next) => revisions.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      knowledge.updateNote(
        V3FeedItem(
          id: 'provider-taskless-outline-local',
          title: '精确资产标题',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: 'Canonical Raw content',
          remoteNoteId: remoteNoteId,
          rawPartRevisionId: 'provider-taskless-raw-r1',
        ),
      );
      await container.pump();

      expect(revisions, hasLength(2));
      expect(revisions.last, isNot(revisions.first));
    },
  );

  test(
    'knowledge revision provider expands when a derived task is enrolled',
    () async {
      final now = DateTime.utc(2026, 9, 15, 10, 50);
      final note = V3FeedItem(
        id: 'provider-enrolled-outline-local',
        title: '登记前标题',
        source: V3MaterialSource.note,
        createdAt: now,
        rawBody: 'Canonical Raw content',
        remoteNoteId: 'provider-enrolled-outline-remote',
        rawPartRevisionId: 'provider-enrolled-raw-r1',
      );
      final notifications = NotificationController(
        api: _StaticNotificationApi(const <AppNotification>[]),
      );
      final knowledge = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: const UnavailableAssistantRuntime(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'enrolled-provider-scope',
      );
      final container = ProviderContainer(
        overrides: <Override>[
          notificationControllerProvider.overrideWith((ref) => notifications),
          knowledgeLibraryControllerProvider.overrideWith((ref) => knowledge),
          chatRunTrackerProvider.overrideWith((ref) => tracker),
        ],
      );
      addTearDown(container.dispose);
      final revisions = <String>[];
      final subscription = container.listen<String>(
        pendingMessageKnowledgeRevisionProvider,
        (previous, next) => revisions.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await tracker.trackDerivedPart(
        fileAgentRunId: 'provider-enrolled-file-run',
        status: 'queued',
        localNoteId: note.id,
        remoteNoteId: note.remoteNoteId!,
        targetPart: NoteFileAgentPart.outline,
      );
      await container.pump();

      expect(revisions, hasLength(2));
      final enrolledRevision = revisions.last;
      expect(enrolledRevision, isNot(revisions.first));

      knowledge.updateNote(note.copyWith(title: '登记后精确标题'));
      await container.pump();

      expect(revisions, hasLength(3));
      expect(revisions.last, isNot(enrolledRevision));
    },
  );

  test('ledger binding fails closed for a different kind target or stage', () {
    final now = DateTime.utc(2026, 9, 15, 11);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final ledger = AgentTaskLedgerEntry.derivedPart(
      taskId: 'strict-outline-task',
      localNoteId: 'strict-local-note',
      remoteNoteId: 'strict-remote-note',
      targetPart: NoteFileAgentPart.outline,
      status: 'succeeded',
      createdAt: now,
      subjectTitle: '严格绑定资产',
    );
    final cases =
        <
          ({
            String label,
            String eventType,
            String scene,
            String type,
            String id,
          })
        >[
          (
            label: 'kind',
            eventType: 'agent_run.succeeded',
            scene: 'chat',
            type: 'thread',
            id: 'strict-local-note',
          ),
          (
            label: 'target',
            eventType: 'note.outline.succeeded',
            scene: 'outline',
            type: 'hnote',
            id: 'another-remote-note',
          ),
          (
            label: 'stage',
            eventType: 'note.germination.succeeded',
            scene: 'germination',
            type: 'hnote',
            id: 'strict-remote-note',
          ),
        ];

    for (final testCase in cases) {
      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            AppNotification(
              notificationId: 'strict-${testCase.label}-delivery',
              eventType: testCase.eventType,
              scene: testCase.scene,
              targetType: testCase.type,
              targetId: testCase.id,
              title: '独立服务端事件',
              body: '不得借用不匹配的任务。',
              status: AppNotificationStatus.unread,
              taskStatus: AppNotificationTaskStatus.succeeded,
              taskId: ledger.taskId,
              createdAt: now,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskLedger: <AgentTaskLedgerEntry>[ledger],
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items, hasLength(2), reason: testCase.label);
      final remote = projection.items.singleWhere(
        (item) => item.source == PendingMessageSource.remote,
      );
      final local = projection.items.singleWhere(
        (item) => item.source == PendingMessageSource.agentTask,
      );
      expect(remote.title, '独立服务端事件', reason: testCase.label);
      expect(
        remote.linkedDeliveryResolutionKey,
        isNull,
        reason: testCase.label,
      );
      expect(local.title, '《严格绑定资产》纲要已完成');
      expect(local.route, '/v3/feed/items/strict-local-note?stage=summary');
    }
  });

  test(
    'cold knowledge routes verified derived and recording rows by local note ID',
    () {
      final now = DateTime.utc(2026, 9, 15, 12);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            AppNotification(
              notificationId: 'cold-derived-delivery',
              eventType: 'agent_run.succeeded',
              scene: 'automation',
              targetType: 'hnote',
              targetId: 'cold-derived-remote',
              title: '任务已完成',
              body: '可以查看结果。',
              status: AppNotificationStatus.unread,
              taskStatus: AppNotificationTaskStatus.succeeded,
              taskId: 'cold-derived-task',
              createdAt: now,
            ),
            AppNotification(
              notificationId: 'cold-recording-delivery',
              eventType: 'agent_run.succeeded',
              scene: 'automation',
              targetType: 'asset',
              targetId: 'cold-recording-remote',
              title: '任务已完成',
              body: '可以查看结果。',
              status: AppNotificationStatus.unread,
              taskStatus: AppNotificationTaskStatus.succeeded,
              taskId: 'cold-recording-public-task',
              createdAt: now,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskLedger: <AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.derivedPart(
            taskId: 'cold-derived-task',
            localNoteId: 'cold-derived-local',
            remoteNoteId: 'cold-derived-remote',
            targetPart: NoteFileAgentPart.outline,
            status: 'succeeded',
            createdAt: now,
            subjectTitle: '冷启动文章',
          ),
          AgentTaskLedgerEntry.recordingOutline(
            taskId: 'cold-recording-tracker-task',
            publicTaskId: 'cold-recording-public-task',
            recordingId: 'cold-recording',
            localNoteId: 'cold-recording-local',
            remoteNoteId: 'cold-recording-remote',
            status: 'succeeded',
            createdAt: now,
            subjectTitle: '冷启动录音',
          ),
        ],
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items, hasLength(2));
      expect(
        projection.items.every(
          (item) => item.source == PendingMessageSource.remote,
        ),
        isTrue,
      );
      final byTaskId = <String, PendingMessage>{
        for (final item in projection.items) item.taskId!: item,
      };
      expect(byTaskId['cold-derived-task']?.targetId, 'cold-derived-local');
      expect(
        byTaskId['cold-derived-task']?.route,
        '/v3/feed/items/cold-derived-local?stage=summary',
      );
      expect(byTaskId['cold-derived-task']?.stage, 'outline');
      expect(
        byTaskId['cold-recording-public-task']?.targetId,
        'cold-recording-local',
      );
      expect(
        byTaskId['cold-recording-public-task']?.route,
        '/v3/feed/items/cold-recording-local?stage=summary',
      );
      expect(byTaskId['cold-recording-public-task']?.stage, 'outline');
    },
  );

  test(
    'generic derived stage falls back to ledger and explicit conflict stays separate',
    () {
      final now = DateTime.utc(2026, 9, 15, 13);
      final note = V3FeedItem(
        id: 'stage-fallback-local',
        title: '点火素材',
        source: V3MaterialSource.note,
        createdAt: now,
        rawBody: '原始内容',
        remoteNoteId: 'stage-fallback-remote',
        rawPartRevisionId: 'stage-fallback-raw-r1',
      );
      final knowledge = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final ledger = AgentTaskLedgerEntry.derivedPart(
        taskId: 'stage-fallback-task',
        localNoteId: note.id,
        remoteNoteId: note.remoteNoteId,
        targetPart: NoteFileAgentPart.germination,
        status: 'succeeded',
        createdAt: now,
        subjectTitle: note.title,
      );
      PendingMessageProjection project({required bool explicitConflict}) =>
          buildPendingMessageProjection(
            notifications: NotificationControllerState(
              status: NotificationControllerStatus.ready,
              items: <AppNotification>[
                AppNotification(
                  notificationId: explicitConflict
                      ? 'explicit-conflict-delivery'
                      : 'generic-stage-delivery',
                  eventType: explicitConflict
                      ? 'note.outline.succeeded'
                      : 'agent_run.succeeded',
                  scene: explicitConflict ? 'outline' : 'automation',
                  targetType: 'hnote',
                  targetId: note.remoteNoteId!,
                  title: explicitConflict ? '纲要已完成' : '任务已完成',
                  body: '可以查看结果。',
                  status: AppNotificationStatus.unread,
                  taskStatus: AppNotificationTaskStatus.succeeded,
                  taskId: ledger.taskId,
                  createdAt: now,
                ),
              ],
            ),
            aggregation: aggregation,
            knowledge: knowledge,
            taskLedger: <AgentTaskLedgerEntry>[ledger],
            ingestionDrafts: const <MaterialIngestionDraft>[],
            documentImport: const V3DocumentImportState.initial(),
            recordingUpload: RecordingUploadState.initial(),
          );

      final generic = project(explicitConflict: false).items.single;
      expect(generic.source, PendingMessageSource.remote);
      expect(generic.stage, 'sprout');
      expect(generic.route, '/v3/feed/items/stage-fallback-local?stage=sprout');
      expect(generic.title, '《点火素材》深度洞察已完成');

      final conflicting = project(explicitConflict: true);
      expect(conflicting.items, hasLength(2));
      final remote = conflicting.items.singleWhere(
        (item) => item.source == PendingMessageSource.remote,
      );
      final local = conflicting.items.singleWhere(
        (item) => item.source == PendingMessageSource.agentTask,
      );
      expect(remote.stage, 'outline');
      expect(remote.route, '/v3/feed/items/stage-fallback-local?stage=summary');
      expect(local.stage, 'sprout');
      expect(local.route, '/v3/feed/items/stage-fallback-local?stage=sprout');
    },
  );

  test(
    'automatic Outline waits are processing and accepted ledger takes ownership',
    () {
      final now = DateTime.utc(2026, 9, 15, 10);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
      );
      final aggregation = _aggregationController(now);
      addTearDown(knowledge.dispose);
      addTearDown(aggregation.dispose);
      for (final phase in AutomaticOutlinePhase.values.where(
        (phase) => phase != AutomaticOutlinePhase.failed,
      )) {
        final task = AutomaticOutlineTaskSnapshot(
          attemptId: 'attempt-1',
          operationId: 'auto-outline-v1-notice',
          localNoteId: 'note-1',
          remoteNoteId: 'remote-1',
          inputRawRevisionId: 'raw-1',
          targetOutlineRevisionId: 'outline-1',
          subjectTitle: '笔记',
          phase: phase,
          createdAt: now,
          updatedAt: now,
          errorCode: 'WORKSPACE_NOT_READY',
          resumePhase: AutomaticOutlinePhase.submitting,
          retryAt: now.add(const Duration(seconds: 15)),
        );
        PendingMessageProjection project({
          List<AgentTaskLedgerEntry> ledger = const [],
        }) => buildPendingMessageProjection(
          notifications: const NotificationControllerState(
            status: NotificationControllerStatus.ready,
          ),
          aggregation: aggregation,
          knowledge: knowledge,
          automaticOutlineTasks: [task],
          taskLedger: ledger,
          ingestionDrafts: const [],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
        );
        final message = project().items.single;
        expect(
          message.state,
          PendingMessageState.processing,
          reason: phase.name,
        );
        expect(message.errorCode, isNull, reason: phase.name);
        expect(message.title, '《笔记》${task.statusLabel}');
        expect(message.body, task.statusMessage);
        expect(message.canMarkHandled, isFalse);
        final accepted = AgentTaskLedgerEntry.derivedPart(
          taskId: 'file-run-1',
          localNoteId: 'note-1',
          remoteNoteId: 'remote-1',
          targetPart: NoteFileAgentPart.outline,
          status: 'queued',
          createdAt: now,
          operationId: task.operationId,
          inputPartRevisionId: 'raw-1',
          targetPartRevisionId: 'outline-1',
        );
        final handedOff = project(ledger: [accepted]);
        expect(handedOff.items, hasLength(1));
        expect(handedOff.items.single.taskId, 'file-run-1');
      }
    },
  );

  test('names automatic Outline pre-admission failures', () {
    final now = DateTime.utc(2026, 9, 15, 10);
    final knowledge = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      automaticOutlineTasks: <AutomaticOutlineTaskSnapshot>[
        AutomaticOutlineTaskSnapshot(
          attemptId: 'automatic-outline-attempt',
          operationId: 'automatic-outline-operation',
          localNoteId: 'saved-chat-note',
          remoteNoteId: 'remote-saved-chat-note',
          inputRawRevisionId: 'raw-r1',
          targetOutlineRevisionId: 'outline-r1',
          subjectTitle: '保存的聊一聊内容',
          phase: AutomaticOutlinePhase.failed,
          createdAt: now,
          updatedAt: now,
          errorCode: 'OUTLINE_RUN_SUBMIT_FAILED',
        ),
      ],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final message = projection.items.single;
    expect(message.title, '《保存的聊一聊内容》纲要未完成');
    expect(message.route, '/v3/feed/items/saved-chat-note?stage=summary');
    expect(message.errorCode, 'OUTLINE_RUN_SUBMIT_FAILED');
  });

  test('consolidates remote task lifecycle rows by stable task ID', () {
    final now = DateTime.utc(2026, 8, 14, 10);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final terminal = AppNotification(
      notificationId: 'task-complete-notice',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'thread-1',
      title: '回复已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'task-chat-1',
      createdAt: now,
    );
    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'task-running-notice',
            eventType: 'agent_run.running',
            scene: 'chat',
            targetType: 'thread',
            targetId: 'thread-1',
            title: '正在分析',
            body: 'Agent 正在处理。',
            status: AppNotificationStatus.read,
            taskStatus: AppNotificationTaskStatus.running,
            taskId: 'task-chat-1',
            createdAt: now.subtract(const Duration(minutes: 1)),
          ),
          terminal,
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    expect(projection.items, hasLength(1));
    expect(projection.items.single.title, '回复已完成');
    expect(projection.items.single.taskId, 'task-chat-1');
    expect(projection.items.single.isTask, isTrue);
    expect(projection.items.single.canMarkHandled, isFalse);

    final handled = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        handledTaskIds: const <String>{'task-chat-1'},
        items: <AppNotification>[terminal],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );
    expect(handled.items, isEmpty);
  });

  test('archived current task revision cannot expose an older lifecycle', () {
    final now = DateTime.utc(2026, 9, 2, 11);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final oldRunning = AppNotification(
      notificationId: 'retry-running-old',
      eventId: 'retry-event-running-old',
      eventType: 'agent_run.running',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'retry-thread-1',
      title: '旧任务进行中',
      body: '这是已经被后续结果替代的状态。',
      status: AppNotificationStatus.read,
      taskStatus: AppNotificationTaskStatus.running,
      taskId: 'retry-task-1',
      createdAt: now.subtract(const Duration(minutes: 2)),
    );
    final currentFailed = AppNotification(
      notificationId: 'retry-failed-current',
      eventId: 'retry-event-failed-current',
      eventType: 'agent_run.failed',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'retry-thread-1',
      title: '任务未完成',
      body: '可以查看失败详情。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.failed,
      taskId: 'retry-task-1',
      createdAt: now.subtract(const Duration(minutes: 1)),
    );
    final newerRetry = AppNotification(
      notificationId: 'retry-running-new',
      eventId: 'retry-event-running-new',
      eventType: 'agent_run.running',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'retry-thread-1',
      title: '重试进行中',
      body: '正在执行新的尝试。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.running,
      taskId: 'retry-task-1',
      createdAt: now,
    );

    PendingMessageProjection project(
      List<AppNotification> notifications, {
      Set<String> handledIds = const <String>{},
    }) => buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: notifications,
        handledIds: handledIds,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskLedger: <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: 'retry-task-1',
          threadId: 'retry-thread-1',
          scene: ChatScene.feedAi,
          status: 'failed',
          createdAt: now.subtract(const Duration(seconds: 30)),
          failureCode: 'AGENT_FAILED',
        ),
      ],
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    expect(
      project(<AppNotification>[oldRunning, currentFailed]).items.single.state,
      PendingMessageState.failed,
    );
    final archived = <String>{notificationDeliveryResolutionKey(currentFailed)};
    expect(
      project(<AppNotification>[
        oldRunning,
        currentFailed,
      ], handledIds: archived).items,
      isEmpty,
    );

    final retried = project(<AppNotification>[
      oldRunning,
      currentFailed,
      newerRetry,
    ], handledIds: archived);
    expect(retried.items, hasLength(1));
    expect(retried.items.single.title, '重试进行中');
    expect(retried.items.single.state, PendingMessageState.processing);
  });

  test('legacy task acknowledgement is scoped to one event revision', () {
    final now = DateTime.utc(2026, 9, 2, 10);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    const firstRevision = AppNotification(
      notificationId: 'legacy-task-merge-row',
      eventId: 'legacy-task-event-1',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'legacy-task-thread',
      title: '第一条回复已完成',
      body: '可以查看第一条回复。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
    );
    const secondRevision = AppNotification(
      notificationId: 'legacy-task-merge-row',
      eventId: 'legacy-task-event-2',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'legacy-task-thread',
      title: '第二条回复已完成',
      body: '同一消息行承载了新的回复。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
    );

    PendingMessageProjection project(
      AppNotification notification, {
      Set<String> handledTaskIds = const <String>{},
    }) => buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[notification],
        handledTaskIds: handledTaskIds,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final first = project(firstRevision);
    final firstTaskKey = first.items.single.taskId!;
    expect(firstTaskKey, notificationDeliveryResolutionKey(firstRevision));
    final acknowledged = <String>{notificationTaskResolutionKey(firstTaskKey)!};
    expect(project(firstRevision, handledTaskIds: acknowledged).items, isEmpty);

    final second = project(secondRevision, handledTaskIds: acknowledged);
    expect(second.items, hasLength(1));
    expect(second.items.single.title, '第二条回复已完成');
    expect(second.items.single.taskId, isNot(firstTaskKey));
  });

  test(
    'projects accepted positioning Run through running, complete, and failed states',
    () {
      final now = DateTime.utc(2026, 8, 16, 9);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      const running = OnboardingAcceptedRun(
        threadId: 'positioning-thread-1',
        agentRunId: 'positioning-run-1',
        taskId: 'positioning-task-1',
        messageId: 'positioning-message-1',
        status: 'accepted',
      );

      PendingMessageProjection project(OnboardingAcceptedRun run) =>
          buildPendingMessageProjection(
            notifications: const NotificationControllerState(
              status: NotificationControllerStatus.ready,
            ),
            aggregation: aggregation,
            knowledge: knowledge,
            ingestionDrafts: const <MaterialIngestionDraft>[],
            documentImport: const V3DocumentImportState.initial(),
            recordingUpload: RecordingUploadState.initial(),
            onboardingReminderRequired: true,
            onboardingReminderKey: 'positioning-user-1',
            onboardingDeferredAt: now,
            acceptedOnboardingRun: run,
          );

      final registering = project(running).items.single;
      expect(registering.title, '基础定位提交待确认');
      expect(registering.body, contains('保持应用开启'));
      final pending = project(
        running.copyWith(workspaceId: 'workspace-1', attemptId: 'attempt-1'),
      ).items.single;
      expect(pending.title, '基础定位正在生成');
      expect(pending.state, PendingMessageState.processing);
      expect(
        pending.route,
        '/v3/workbench/deep-positioning?focus=report&taskId=${running.agentRunId}',
      );
      expect(pending.targetType, 'positioning_report');
      expect(pending.targetId, running.agentRunId);

      final completed = project(
        running.copyWith(lifecycle: OnboardingAcceptedRunLifecycle.succeeded),
      ).items.single;
      expect(completed.state, PendingMessageState.succeeded);
      expect(completed.route, contains('/v3/workbench/deep-positioning?'));
      expect(completed.route, contains('focus=report'));
      expect(completed.route, contains('taskId=${running.agentRunId}'));
      expect(completed.stage, 'report');

      final failed = project(
        running.copyWith(
          lifecycle: OnboardingAcceptedRunLifecycle.failed,
          failureCode: 'ONBOARDING_AGENT_RUN_FAILED',
        ),
      ).items.single;
      expect(failed.state, PendingMessageState.failed);
      expect(failed.route, completed.route);
      expect(failed.errorCode, 'ONBOARDING_AGENT_RUN_FAILED');
    },
  );

  test('suppresses stale positioning work for a completed session', () {
    const completedSession = SessionState(
      authState: SessionAuthState.authenticated,
      onboardingRequired: false,
      needsWorkspaceRetry: false,
      runningTaskCount: 0,
      recoveryHints: SessionRecoveryHints(),
      user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
      workspaceStatus: SessionWorkspaceStatus.ready,
      basicPositioningCompleted: true,
      positioningStatus: SessionPositioningStatus.completed,
    );
    const running = OnboardingAcceptedRun(
      threadId: 'thread-1',
      agentRunId: 'run-1',
      taskId: 'task-1',
      messageId: 'message-1',
      status: 'accepted',
    );

    expect(
      shouldProjectAcceptedOnboardingRun(
        session: completedSession,
        acceptedRun: running,
      ),
      isFalse,
    );
    expect(
      shouldProjectAcceptedOnboardingRun(
        session: completedSession,
        acceptedRun: running.copyWith(
          lifecycle: OnboardingAcceptedRunLifecycle.failed,
          failureCode: 'POSITIONING_VERSION_CONFLICT',
        ),
      ),
      isFalse,
    );
    expect(
      shouldProjectAcceptedOnboardingRun(
        session: completedSession,
        acceptedRun: running.copyWith(
          lifecycle: OnboardingAcceptedRunLifecycle.succeeded,
        ),
      ),
      isTrue,
    );
  });

  test('does not duplicate a tracked sprout task with legacy sprout state', () {
    final now = DateTime.utc(2026, 8, 13, 10);
    final note = V3FeedItem(
      id: 'sprout-derived-note',
      title: '待点火素材',
      source: V3MaterialSource.note,
      createdAt: now,
      rawBody: '原始内容',
      sproutStatus: V3SproutTaskStatus.running,
      activeDerivedTasks: const <V3ActiveDerivedTask>[
        V3ActiveDerivedTask(
          fileAgentRunId: 'file-sprout-run-1',
          stage: V3DerivedTaskStage.sprout,
          status: 'running',
        ),
      ],
      activeDerivedTasksAuthoritative: true,
    );
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final sproutItems = projection.items
        .where((item) => item.title == '《待点火素材》深度洞察')
        .toList();
    expect(sproutItems, hasLength(1));
    expect(sproutItems.single.canMarkHandled, isFalse);
  });

  test('projects and hands off a pre-acceptance sprout submission', () {
    final now = DateTime.utc(2026, 8, 31, 10);
    final note = V3FeedItem(
      id: 'preaccepted-sprout-note',
      title: '待点火素材',
      source: V3MaterialSource.note,
      createdAt: now,
      rawBody: '原始内容',
    );
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
      now: () => now,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);

    PendingMessageProjection project() => buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    knowledge.beginSproutSubmission(
      noteId: note.id,
      operationId: 'sprout-operation-1',
    );
    var item = project().items.singleWhere(
      (candidate) => candidate.source == PendingMessageSource.sprout,
    );
    expect(item.body, '深度洞察任务进行中。');
    expect(item.state, PendingMessageState.processing);
    expect(item.isDemo, isFalse);
    expect(item.route, '/v3/feed/items/preaccepted-sprout-note?stage=sprout');

    knowledge.failSproutSubmission(
      noteId: note.id,
      operationId: 'sprout-operation-1',
      errorCode: 'FAYA_RUN_SUBMIT_FAILED',
    );
    item = project().items.singleWhere(
      (candidate) => candidate.source == PendingMessageSource.sprout,
    );
    expect(item.state, PendingMessageState.failed);
    expect(item.errorCode, 'FAYA_RUN_SUBMIT_FAILED');
    expect(item.taskId, 'sprout-operation-1');
    expect(item.targetType, 'asset');
    expect(item.targetId, note.id);
    expect(item.stage, 'sprout');

    knowledge.beginSproutSubmission(
      noteId: note.id,
      operationId: 'sprout-operation-2',
    );
    knowledge.updateNote(
      note.copyWith(
        activeDerivedTasks: const <V3ActiveDerivedTask>[
          V3ActiveDerivedTask(
            fileAgentRunId: 'file-sprout-run-accepted',
            stage: V3DerivedTaskStage.sprout,
            status: 'running',
          ),
        ],
        activeDerivedTasksAuthoritative: true,
      ),
    );
    final handedOff = project().items
        .where((candidate) => candidate.title == '《待点火素材》深度洞察')
        .toList(growable: false);
    expect(handedOff, hasLength(1));
    expect(handedOff.single.taskId, 'file-sprout-run-accepted');
  });

  test(
    'keeps a running sprout ledger notification stable while HNote hydrates',
    () {
      final now = DateTime.utc(2026, 8, 31, 11);
      final knowledge = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final tracker = _TaskLedgerTracker(<AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.derivedPart(
          taskId: 'file-sprout-ledger-running',
          localNoteId: 'hydrating-sprout-note',
          targetPart: NoteFileAgentPart.germination,
          status: 'running',
          createdAt: now,
        ),
      ]);

      PendingMessageProjection project() => buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: tracker,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final beforeHydration = project().items.singleWhere(
        (item) => item.taskId == 'file-sprout-ledger-running',
      );
      expect(beforeHydration.state, PendingMessageState.processing);
      expect(beforeHydration.title, '深度洞察任务正在处理');
      expect(beforeHydration.body, contains('深度洞察任务进行中'));
      expect(
        beforeHydration.route,
        '/v3/feed/items/hydrating-sprout-note?stage=sprout',
      );

      knowledge.updateNote(
        V3FeedItem(
          id: 'hydrating-sprout-note',
          title: '随后同步的点火素材',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: '原始内容',
          activeDerivedTasks: const <V3ActiveDerivedTask>[
            V3ActiveDerivedTask(
              fileAgentRunId: 'file-sprout-ledger-running',
              stage: V3DerivedTaskStage.sprout,
              status: 'running',
            ),
          ],
          activeDerivedTasksAuthoritative: true,
        ),
      );
      final afterHydration = project().items
          .where((item) => item.targetId == 'hydrating-sprout-note')
          .toList(growable: false);
      expect(afterHydration, hasLength(1));
      expect(afterHydration.single.id, beforeHydration.id);
      expect(afterHydration.single.taskId, beforeHydration.taskId);
    },
  );

  test('terminal ledger hides only the same stale server sprout run', () {
    final now = DateTime.utc(2026, 8, 31, 12);
    final note = V3FeedItem(
      id: 'terminal-ledger-note',
      title: '终态点火素材',
      source: V3MaterialSource.note,
      createdAt: now,
      rawBody: '原始内容',
      sproutStatus: V3SproutTaskStatus.running,
      activeDerivedTasks: const <V3ActiveDerivedTask>[
        V3ActiveDerivedTask(
          fileAgentRunId: 'file-sprout-old',
          stage: V3DerivedTaskStage.sprout,
          status: 'running',
        ),
      ],
      activeDerivedTasksAuthoritative: true,
    );
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final tracker = _TaskLedgerTracker(<AgentTaskLedgerEntry>[
      AgentTaskLedgerEntry.derivedPart(
        taskId: 'file-sprout-old',
        localNoteId: note.id,
        targetPart: NoteFileAgentPart.germination,
        status: 'failed',
        failureCode: 'NOTE_FILE_AGENT_FAILED',
        createdAt: now,
      ),
    ]);

    PendingMessageProjection project() => buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: tracker,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    var noteTasks = project().items
        .where((item) => item.targetId == note.id)
        .toList(growable: false);
    expect(noteTasks, hasLength(1));
    expect(noteTasks.single.taskId, 'file-sprout-old');
    expect(noteTasks.single.state, PendingMessageState.failed);

    knowledge.updateNote(
      note.copyWith(
        activeDerivedTasks: const <V3ActiveDerivedTask>[
          V3ActiveDerivedTask(
            fileAgentRunId: 'file-sprout-new',
            stage: V3DerivedTaskStage.sprout,
            status: 'running',
          ),
        ],
        activeDerivedTasksAuthoritative: true,
      ),
    );
    noteTasks = project().items
        .where((item) => item.targetId == note.id)
        .toList(growable: false);
    expect(
      noteTasks.map((item) => item.taskId),
      containsAll(<String>['file-sprout-old', 'file-sprout-new']),
    );
  });

  test('projects a raw document asset outline as an independent task', () {
    final now = DateTime.utc(2026, 8, 13, 10);
    final hash = List<String>.filled(64, 'b').join();
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: V3DocumentImportState(
        status: V3DocumentImportStatus.completed,
        durableTasks: <V3DocumentImportTask>[
          V3DocumentImportTask(
            id: 'document-outline-1',
            pickerRef: 'picker-outline-1',
            displayName: '访谈纪要.md',
            mimeType: 'text/markdown',
            sizeBytes: 1024,
            sha256: hash,
            privateFileName: '$hash.md',
            status: V3DocumentImportTaskStatus.completed,
            attemptCount: 1,
            createdAt: now,
            updatedAt: now,
            noteId: 'note-document-outline-1',
            rawAssetCreated: true,
            outlineStatus: V3DocumentOutlineStatus.running,
            outlineFileAgentRunId: 'file-agent-outline-1',
          ),
        ],
      ),
      recordingUpload: RecordingUploadState.initial(),
    );

    final outline = projection.items.single;
    expect(outline.title, '《访谈纪要.md》纲要');
    expect(outline.state, PendingMessageState.processing);
    expect(outline.canMarkHandled, isFalse);
    expect(outline.body, contains('原始资料已沉淀'));
    expect(
      outline.route,
      '/v3/feed/items/note-document-outline-1?stage=summary',
    );
  });

  test(
    'acknowledges a displayed legacy chat notification and preserves deep route',
    () async {
      final now = DateTime.utc(2026, 8, 15, 9);
      const notification = AppNotification(
        notificationId: 'legacy-chat-notification-1',
        eventType: 'deep_positioning.reply_ready',
        scene: 'deep_positioning',
        targetType: 'thread',
        targetId: 'deep-thread-1',
        title: '定位回复已完成',
        body: '打开会话查看回复。',
        status: AppNotificationStatus.unread,
      );
      final controller = NotificationController(
        api: const _SingleNotificationApi(notification),
      );
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);

      PendingMessageProjection projection() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final item = projection().items.single;
      expect(item.isTask, isFalse);
      expect(item.targetType, 'thread');
      expect(item.targetId, 'deep-thread-1');
      expect(item.route, contains('purpose=deep-positioning'));

      final actions = PendingMessageActions(
        controller,
        items: () => projection().items,
      );
      expect(
        await actions.acknowledgeResultShown(
          targetType: 'thread',
          targetId: 'deep-thread-1',
        ),
        isTrue,
      );
      expect(controller.state.handledIds, isEmpty);
      expect(controller.state.items.single.status, AppNotificationStatus.read);
      expect(projection().items, hasLength(1));
      expect(projection().items.single.isUnread, isFalse);
    },
  );

  test('routes backend hnote and task targets to concrete pages', () {
    final now = DateTime.utc(2026, 8, 15, 9);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'notice-hnote-1',
            eventType: 'note.outline.succeeded',
            scene: 'outline',
            targetType: 'hnote',
            targetId: 'note-1',
            title: '纲要已完成',
            body: '可以查看结果。',
            status: AppNotificationStatus.unread,
          ),
          AppNotification(
            notificationId: 'notice-task-1',
            eventType: 'agent_run.succeeded',
            scene: 'work_ai',
            targetType: 'task',
            targetId: 'task-1',
            title: '任务已完成',
            body: '可以查看结果。',
            status: AppNotificationStatus.unread,
            taskStatus: AppNotificationTaskStatus.succeeded,
            taskId: 'task-1',
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final byScene = <String, PendingMessage>{
      for (final item in projection.items) item.scene: item,
    };
    expect(byScene['outline']?.targetType, 'asset');
    expect(byScene['outline']?.route, '/v3/feed/items/note-1?stage=summary');
    expect(byScene['work_ai']?.route, '/v3/workbench/tasks/task-1');
  });

  test(
    'opening reads non-processing rows without handling Agent tasks',
    () async {
      final controller = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      addTearDown(controller.dispose);
      const ordinary = PendingMessage(
        id: 'local:document:complete',
        source: PendingMessageSource.remote,
        scene: 'notification',
        title: '导入完成',
        body: '可以打开查看。',
        state: PendingMessageState.succeeded,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/import/documents',
      );
      const processing = PendingMessage(
        id: 'local:agent:processing',
        source: PendingMessageSource.agentTask,
        scene: 'outline',
        title: '纲要生成中',
        body: '正在处理。',
        state: PendingMessageState.processing,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/items/note-1?stage=summary',
        canMarkHandled: false,
        taskId: 'agent-processing-1',
        targetType: 'asset',
        targetId: 'note-1',
        stage: 'outline',
        isTask: true,
      );
      const terminalTask = PendingMessage(
        id: 'local:agent:terminal',
        source: PendingMessageSource.agentTask,
        scene: 'sprout',
        title: '点火已完成',
        body: '可以查看结果。',
        state: PendingMessageState.succeeded,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/items/note-1?stage=sprout',
        canMarkHandled: false,
        taskId: 'agent-terminal-1',
        targetType: 'asset',
        targetId: 'note-1',
        stage: 'sprout',
        isTask: true,
      );
      const failedTask = PendingMessage(
        id: 'local:agent:failed',
        source: PendingMessageSource.agentTask,
        scene: 'chat',
        title: '聊一聊任务未完成',
        body: '可以查看失败详情。',
        state: PendingMessageState.failed,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/chat?threadId=thread-failed-1',
        canMarkHandled: false,
        taskId: 'agent-failed-1',
        targetType: 'thread',
        targetId: 'thread-failed-1',
        isTask: true,
      );
      final actions = PendingMessageActions(
        controller,
        items: () => const <PendingMessage>[
          ordinary,
          processing,
          terminalTask,
          failedTask,
        ],
      );

      expect(await actions.markOpened(ordinary), isTrue);
      expect(await actions.markOpened(processing), isTrue);
      expect(await actions.markOpened(terminalTask), isTrue);
      expect(await actions.markOpened(failedTask), isTrue);

      expect(controller.state.handledIds, isNot(contains(ordinary.id)));
      expect(controller.state.locallyReadIds, contains(ordinary.id));
      expect(controller.state.handledIds, isNot(contains(processing.id)));
      expect(controller.state.handledIds, isNot(contains(terminalTask.id)));
      expect(
        controller.state.locallyReadIds,
        contains(pendingMessageLocalDeliveryResolutionKey(terminalTask)),
      );
      expect(
        controller.state.locallyReadIds,
        contains(pendingMessageLocalDeliveryResolutionKey(failedTask)),
      );
      expect(
        controller.state.handledTaskIds,
        isNot(contains('agent-terminal-1')),
      );
      expect(
        controller.state.handledTaskIds,
        isNot(contains('agent-failed-1')),
      );
      expect(
        controller.state.handledTaskIds,
        isNot(contains('agent-processing-1')),
      );
    },
  );

  test(
    'uses task-result acknowledgement only for terminal task completion',
    () async {
      final controller = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      addTearDown(controller.dispose);
      const processing = PendingMessage(
        id: 'notice-task-processing-1',
        source: PendingMessageSource.agentTask,
        scene: 'outline',
        title: '纲要生成中',
        body: '正在生成。',
        state: PendingMessageState.processing,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/items/note-1?stage=summary',
        canMarkHandled: true,
        taskId: 'task-processing-1',
        targetType: 'asset',
        targetId: 'note-1',
        isTask: true,
      );
      const succeeded = PendingMessage(
        id: 'notice-task-succeeded-1',
        source: PendingMessageSource.agentTask,
        scene: 'outline',
        title: '纲要已生成',
        body: '可以查看结果。',
        state: PendingMessageState.succeeded,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/items/note-1?stage=summary',
        remoteNotificationId: 'notice-task-succeeded-1',
        canMarkHandled: false,
        taskId: 'task-succeeded-1',
        targetType: 'asset',
        targetId: 'note-1',
        isTask: true,
      );
      const succeededDelivery = PendingMessage(
        id: 'notice-task-succeeded-delivery-2',
        source: PendingMessageSource.remote,
        scene: 'outline',
        title: '纲要已生成',
        body: '结果已写入资产。',
        state: PendingMessageState.succeeded,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/items/note-1?stage=summary',
        remoteNotificationId: 'notice-task-succeeded-delivery-2',
        canMarkHandled: false,
        taskId: 'task-succeeded-1',
        targetType: 'asset',
        targetId: 'note-1',
        isTask: true,
      );
      const failed = PendingMessage(
        id: 'notice-task-failed-1',
        source: PendingMessageSource.agentTask,
        scene: 'chat',
        title: '聊一聊任务未完成',
        body: '可以查看失败详情。',
        state: PendingMessageState.failed,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/chat?threadId=thread-failed-1',
        canMarkHandled: false,
        taskId: 'task-failed-1',
        targetType: 'thread',
        targetId: 'thread-failed-1',
        isTask: true,
      );
      const items = <PendingMessage>[
        processing,
        succeeded,
        succeededDelivery,
        failed,
      ];
      final actions = PendingMessageActions(controller, items: () => items);

      expect(processing.shouldShowOpenAction, isTrue);
      expect(processing.shouldShowHandledAction, isFalse);
      expect(succeeded.shouldShowOpenAction, isFalse);
      expect(succeeded.shouldShowHandledAction, isFalse);
      expect(
        succeeded.copyWith(isUnread: false).shouldShowHandledAction,
        isTrue,
      );
      expect(failed.shouldShowOpenAction, isFalse);
      expect(failed.shouldShowHandledAction, isFalse);
      expect(failed.copyWith(isUnread: false).shouldShowHandledAction, isTrue);
      expect(await actions.markHandled(processing), isFalse);

      expect(await actions.markHandled(succeeded), isTrue);
      expect(
        controller.state.handledTaskIds,
        contains(notificationTaskResolutionKey('task-succeeded-1')),
      );
      expect(controller.state.handledIds, isEmpty);

      expect(await actions.markHandled(failed), isTrue);
      expect(
        controller.state.handledTaskIds,
        isNot(contains(notificationTaskResolutionKey('task-failed-1'))),
      );
      expect(
        controller.state.handledIds,
        contains(pendingMessageLocalDeliveryResolutionKey(failed)),
      );
    },
  );

  test('remote read failure does not block task destinations', () async {
    final controller = NotificationController(
      api: const _ReadFailureNotificationApi(_taskUnread),
    );
    addTearDown(controller.dispose);
    await controller.load();
    const processing = PendingMessage(
      id: 'notice-task-read-failure',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '聊一聊处理中',
      body: '正在处理。',
      state: PendingMessageState.processing,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      route: '/v3/feed/chat?threadId=thread-read-failure',
      remoteNotificationId: 'notice-task-read-failure',
      canMarkHandled: false,
      taskId: 'agent-task-read-failure',
      targetType: 'thread',
      targetId: 'thread-read-failure',
      isTask: true,
    );
    const terminal = PendingMessage(
      id: 'notice-task-read-failure',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '聊一聊已完成',
      body: '可以查看回复。',
      state: PendingMessageState.succeeded,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      route: '/v3/feed/chat?threadId=thread-read-failure',
      remoteNotificationId: 'notice-task-read-failure',
      canMarkHandled: false,
      taskId: 'agent-task-read-failure',
      targetType: 'thread',
      targetId: 'thread-read-failure',
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[processing, terminal],
    );

    expect(await actions.markOpened(processing), isTrue);
    expect(
      controller.state.handledTaskIds,
      isNot(contains('agent-task-read-failure')),
    );
    expect(await actions.markOpened(terminal), isTrue);
    expect(
      controller.state.handledTaskIds,
      isNot(contains('agent-task-read-failure')),
    );
  });

  test(
    'legacy terminal task waits for visible-result acknowledgement',
    () async {
      const notification = AppNotification(
        notificationId: 'notice-legacy-task-1',
        eventType: 'agent_run.completed',
        scene: 'chat',
        targetType: 'thread',
        targetId: 'thread-legacy-task-1',
        title: '聊一聊已完成',
        body: '可以查看回复。',
        status: AppNotificationStatus.unread,
        taskId: 'agent-legacy-task-1',
      );
      final controller = NotificationController(
        api: const _SingleNotificationApi(notification),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final now = DateTime.utc(2026, 8, 15, 9);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);

      PendingMessageProjection projection() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      final item = projection().items.single;
      expect(item.isTerminalTask, isTrue);
      final actions = PendingMessageActions(
        controller,
        items: () => projection().items,
      );
      expect(await actions.markOpened(item), isTrue);
      expect(projection().items, hasLength(1));
      expect(projection().items.single.isUnread, isFalse);
      expect(
        await actions.acknowledgeResultShown(
          targetType: 'thread',
          targetId: 'thread-legacy-task-1',
        ),
        isTrue,
      );
      expect(projection().items, isEmpty);
    },
  );

  test(
    'bulk clear preserves every task but clears ordinary messages',
    () async {
      final controller = NotificationController(
        api: const UnavailableNotificationApi(),
      );
      addTearDown(controller.dispose);
      const ordinary = PendingMessage(
        id: 'local:bulk:ordinary',
        source: PendingMessageSource.remote,
        scene: 'notification',
        title: '导入完成',
        body: '可以查看。',
        state: PendingMessageState.succeeded,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        canMarkHandled: true,
      );
      const processing = PendingMessage(
        id: 'local:bulk:processing',
        source: PendingMessageSource.agentTask,
        scene: 'chat',
        title: '聊一聊处理中',
        body: '正在处理。',
        state: PendingMessageState.processing,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        canMarkHandled: false,
        taskId: 'bulk-processing-task',
        isTask: true,
      );
      const unreadOrdinary = PendingMessage(
        id: 'local:bulk:unread-ordinary',
        source: PendingMessageSource.remote,
        scene: 'notification',
        title: '尚未阅读',
        body: '阅读后才可删除。',
        state: PendingMessageState.informational,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        canMarkHandled: true,
      );
      final terminalTaskId = _identifierOfLength('note_file_agent_run_', 140);
      final terminal = PendingMessage(
        id: 'local:bulk:terminal',
        source: PendingMessageSource.agentTask,
        scene: 'outline',
        title: '纲要已完成',
        body: '可以查看。',
        state: PendingMessageState.succeeded,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        canMarkHandled: false,
        taskId: terminalTaskId,
        isTask: true,
      );
      final items = <PendingMessage>[
        ordinary,
        unreadOrdinary,
        processing,
        terminal,
      ];
      final actions = PendingMessageActions(controller, items: () => items);

      expect(canClearPendingMessages(items), isTrue);
      expect(await actions.markAllHandled(items), isTrue);
      expect(controller.state.handledIds, contains(ordinary.id));
      expect(controller.state.handledIds, isNot(contains(unreadOrdinary.id)));
      expect(
        controller.state.handledTaskIds,
        isNot(contains(notificationTaskResolutionKey(terminalTaskId))),
      );
      expect(
        controller.state.handledTaskIds,
        isNot(contains('bulk-processing-task')),
      );
      expect(
        canClearPendingMessages(const <PendingMessage>[processing]),
        isFalse,
      );
      expect(canClearPendingMessages(<PendingMessage>[terminal]), isFalse);
      expect(
        canClearPendingMessages(const <PendingMessage>[unreadOrdinary]),
        isFalse,
      );
    },
  );

  test(
    'mark all read loads every page and marks mixed unread rows in batches',
    () async {
      final api = _PagedNotificationApi();
      final controller = NotificationController(api: api);
      await controller.load(forceRemote: true);
      final actions = PendingMessageActions(
        controller,
        items: () => <PendingMessage>[
          ...controller.state.items.map(
            (item) => PendingMessage(
              id: item.notificationId,
              source: PendingMessageSource.remote,
              scene: item.scene,
              title: item.title,
              body: item.body,
              state: PendingMessageState.succeeded,
              isUnread: item.isUnread,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              remoteNotificationId: item.notificationId,
              remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
                item,
              ),
            ),
          ),
          PendingMessage(
            id: localPendingMessageId(
              PendingMessageSource.documentImport,
              'local-import-1',
            ),
            source: PendingMessageSource.documentImport,
            scene: 'document_import',
            title: '文档导入完成',
            body: '可以查看笔记',
            state: PendingMessageState.succeeded,
            isUnread: !controller.state.locallyReadIds.contains(
              localPendingMessageId(
                PendingMessageSource.documentImport,
                'local-import-1',
              ),
            ),
            isDemo: false,
            isOpening: false,
            isResolving: false,
          ),
        ],
      );

      final result = await actions.markAllRead(batchSize: 2);

      expect(result.total, 3);
      expect(result.succeeded, 3);
      expect(result.isComplete, isTrue);
      expect(api.listCursors, <String?>[null, null, 'page-2']);
      expect(api.markedIds, <String>['notice-1', 'notice-2']);
      expect(controller.state.items.every((item) => !item.isUnread), isTrue);
      expect(
        controller.state.locallyReadIds,
        contains(
          localPendingMessageId(
            PendingMessageSource.documentImport,
            'local-import-1',
          ),
        ),
      );
    },
  );

  test(
    'logical recording rows share badge read and terminal archive',
    () async {
      const remoteNotification = AppNotification(
        notificationId: 'recording-delivery-1',
        eventType: 'recording.deposit.succeeded',
        scene: 'recording',
        targetType: 'recording',
        targetId: 'recording-logical-1',
        title: '录音已沉淀',
        body: '转写结果已写入笔记。',
        status: AppNotificationStatus.unread,
        eventId: 'recording-event-1',
      );
      final controller = NotificationController(
        api: const _SingleNotificationApi(remoteNotification),
      );
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final localId = localPendingMessageId(
        PendingMessageSource.recordingTranscription,
        'recording-logical-local-task',
      );
      final rows = <PendingMessage>[
        PendingMessage(
          id: localId,
          source: PendingMessageSource.recordingTranscription,
          scene: 'recording',
          title: '本地录音已完成',
          body: '可以查看转写结果。',
          state: PendingMessageState.succeeded,
          isUnread: true,
          isDemo: false,
          isOpening: false,
          isResolving: false,
          taskId: 'recording-logical-local-task',
          targetType: 'recording',
          targetId: 'recording-logical-1',
          stage: 'recording_processing',
          isTask: true,
        ),
        PendingMessage(
          id: 'recording-delivery-1',
          source: PendingMessageSource.remote,
          scene: 'recording',
          title: '录音已沉淀',
          body: '转写结果已写入笔记。',
          state: PendingMessageState.succeeded,
          isUnread: true,
          isDemo: false,
          isOpening: false,
          isResolving: false,
          remoteNotificationId: 'recording-delivery-1',
          remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
            remoteNotification,
          ),
          taskId: 'recording:recording-logical-1',
          targetType: 'recording',
          targetId: 'recording-logical-1',
          stage: 'recording_processing',
          isTask: true,
          eventType: 'recording.deposit.succeeded',
        ),
      ];
      final actions = PendingMessageActions(controller, items: () => rows);
      final projection = PendingMessageProjection(
        items: rows,
        isLoading: false,
        resolutionIsDemo: false,
      );

      expect(projection.unreadCount, 1);
      expect(await actions.markRead(rows.last), isTrue);
      expect(controller.state.items.single.isUnread, isFalse);
      expect(
        controller.state.locallyReadIds,
        containsAll(<String>[
          pendingMessageLocalDeliveryResolutionKey(rows.first),
          notificationDeliveryResolutionKey(remoteNotification),
        ]),
      );

      expect(await actions.markHandled(rows.last), isTrue);
      expect(
        controller.state.handledTaskIds,
        containsAll(<String>[
          'recording-logical-local-task',
          'recording:recording-logical-1',
        ]),
      );
    },
  );

  test('stale recording failure cannot archive an arrived success', () async {
    final controller = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    addTearDown(controller.dispose);
    const failed = PendingMessage(
      id: 'recording-failed-stale-command',
      source: PendingMessageSource.recordingTranscription,
      scene: 'recording',
      title: '录音转写失败',
      body: '可重试。',
      state: PendingMessageState.failed,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'recording-asr-failed-1',
      targetType: 'recording',
      targetId: 'recording-race-1',
      stage: 'recording_processing',
      isTask: true,
    );
    const success = PendingMessage(
      id: 'recording-success-arrived',
      source: PendingMessageSource.remote,
      scene: 'recording',
      title: '录音已沉淀',
      body: '转写结果已写入笔记。',
      state: PendingMessageState.succeeded,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'recording:recording-race-1',
      targetType: 'recording',
      targetId: 'recording-race-1',
      stage: 'recording_processing',
      isTask: true,
      eventType: 'recording.deposit.succeeded',
    );
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[failed, success],
    );

    expect(await actions.markHandled(failed), isTrue);
    expect(
      controller.state.handledTaskIds,
      isNot(contains('recording:recording-race-1')),
    );
    expect(
      controller.state.handledIds,
      contains(pendingMessageLocalDeliveryResolutionKey(failed)),
    );
  });

  test('mark all read refreshes a fresh first page before settling', () async {
    const cached = AppNotification(
      notificationId: 'fresh-cache-notice-1',
      eventType: 'system.info',
      scene: 'notification',
      targetType: 'notification',
      targetId: 'fresh-cache-notice-1',
      title: '缓存消息',
      body: '缓存中的未读消息。',
      status: AppNotificationStatus.unread,
    );
    const arrived = AppNotification(
      notificationId: 'fresh-server-notice-2',
      eventType: 'system.info',
      scene: 'notification',
      targetType: 'notification',
      targetId: 'fresh-server-notice-2',
      title: '新到消息',
      body: '缓存建立后到达的未读消息。',
      status: AppNotificationStatus.unread,
    );
    final serverItems = <AppNotification>[cached];
    final api = _StaticNotificationApi(serverItems);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    serverItems.add(arrived);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(DateTime.utc(2026, 9, 2));
    addTearDown(aggregation.dispose);
    PendingMessageProjection projection() => buildPendingMessageProjection(
      notifications: controller.state,
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );
    final actions = PendingMessageActions(
      controller,
      items: () => projection().items,
    );

    final result = await actions.markAllRead();

    expect(api.listCalls, 2);
    expect(result.total, 2);
    expect(result.succeeded, 2);
    expect(result.fullyEnumerated, isTrue);
    expect(
      api.markedIds,
      containsAll(<String>['fresh-cache-notice-1', 'fresh-server-notice-2']),
    );
  });

  test(
    'remote read follows its terminal ledger copy out of the window',
    () async {
      final now = DateTime.utc(2026, 9, 2, 14);
      const taskId = 'cross-source-read-task-1';
      final serverItems = <AppNotification>[
        AppNotification(
          notificationId: 'cross-source-read-notice-1',
          eventId: 'cross-source-read-event-1',
          eventType: 'agent_run.failed',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'cross-source-thread-1',
          title: '回复未完成',
          body: '可以查看失败详情。',
          status: AppNotificationStatus.unread,
          taskStatus: AppNotificationTaskStatus.failed,
          taskId: taskId,
          createdAt: now.add(const Duration(minutes: 1)),
        ),
      ];
      final api = _StaticNotificationApi(serverItems);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final ledger = <AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: taskId,
          threadId: 'cross-source-thread-1',
          scene: ChatScene.feedAi,
          status: 'failed',
          failureCode: 'AGENT_RUN_FAILED',
          createdAt: now,
        ),
      ];
      final tracker = _TaskLedgerTracker(ledger);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      PendingMessageProjection projection() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: tracker,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );
      final actions = PendingMessageActions(
        controller,
        items: () => projection().items,
      );

      final remote = projection().items.single;
      expect(remote.source, PendingMessageSource.remote);
      expect(await actions.markRead(remote), isTrue);
      serverItems.clear();
      await controller.load(forceRemote: true);

      final restoredLedger = projection().items.single;
      expect(restoredLedger.source, PendingMessageSource.agentTask);
      expect(restoredLedger.isUnread, isFalse);
    },
  );

  test('remote failure archive settles its ledger copy only', () async {
    final now = DateTime.utc(2026, 9, 2, 15);
    const taskId = 'cross-source-archive-task-1';
    final serverItems = <AppNotification>[
      AppNotification(
        notificationId: 'cross-source-archive-notice-1',
        eventId: 'cross-source-archive-event-1',
        eventType: 'agent_run.failed',
        scene: 'chat',
        targetType: 'thread',
        targetId: 'cross-source-thread-2',
        title: '回复未完成',
        body: '可以查看失败详情。',
        status: AppNotificationStatus.unread,
        taskStatus: AppNotificationTaskStatus.failed,
        taskId: taskId,
        createdAt: now.add(const Duration(minutes: 1)),
      ),
    ];
    final api = _StaticNotificationApi(serverItems);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final ledger = <AgentTaskLedgerEntry>[
      AgentTaskLedgerEntry.chat(
        taskId: taskId,
        threadId: 'cross-source-thread-2',
        scene: ChatScene.feedAi,
        status: 'failed',
        failureCode: 'AGENT_RUN_FAILED',
        createdAt: now,
      ),
    ];
    final tracker = _TaskLedgerTracker(ledger);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    PendingMessageProjection projection() => buildPendingMessageProjection(
      notifications: controller.state,
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: tracker,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );
    final actions = PendingMessageActions(
      controller,
      items: () => projection().items,
    );

    expect(await actions.markHandled(projection().items.single), isTrue);
    serverItems.clear();
    await controller.load(forceRemote: true);
    expect(projection().items, isEmpty);

    ledger[0] = AgentTaskLedgerEntry.chat(
      taskId: taskId,
      threadId: 'cross-source-thread-2',
      scene: ChatScene.feedAi,
      status: 'succeeded',
      createdAt: now.add(const Duration(minutes: 2)),
    );
    final success = projection().items.single;
    expect(success.state, PendingMessageState.succeeded);
    expect(success.taskId, taskId);
  });

  test('cursor-less deployed 50-row window is not account-complete', () async {
    final notifications = List<AppNotification>.generate(
      50,
      (index) => AppNotification(
        notificationId: 'window-notice-$index',
        eventType: 'system.info',
        scene: 'notification',
        targetType: 'notification',
        targetId: 'window-notice-$index',
        title: '历史消息 $index',
        body: '已读历史消息。',
        status: AppNotificationStatus.read,
      ),
    );
    final controller = NotificationController(
      api: _DelayedNotificationApi(<List<AppNotification>>[notifications]),
    );
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[],
    );

    final result = await actions.markAllRead();

    expect(result.total, 0);
    expect(result.fullyEnumerated, isFalse);
    expect(result.isComplete, isFalse);
  });

  test('rejected server rows keep bulk-read completion partial', () async {
    const notification = AppNotification(
      notificationId: 'valid-window-notice',
      eventType: 'system.info',
      scene: 'notification',
      targetType: 'notification',
      targetId: 'valid-window-notice',
      title: '可读取消息',
      body: '这条消息可以正常标记已读。',
      status: AppNotificationStatus.unread,
    );
    final api = _StaticNotificationApi(const <AppNotification>[
      notification,
    ], rejectedItemCount: 1);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final row = PendingMessage(
      id: 'valid-window-notice',
      source: PendingMessageSource.remote,
      scene: 'notification',
      title: '可读取消息',
      body: '这条消息可以正常标记已读。',
      state: PendingMessageState.informational,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      remoteNotificationId: 'valid-window-notice',
      remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
        notification,
      ),
      targetType: 'notification',
      targetId: 'valid-window-notice',
    );
    final actions = PendingMessageActions(
      controller,
      items: () => <PendingMessage>[row],
    );

    final result = await actions.markAllRead();

    expect(result.total, 1);
    expect(result.succeeded, 1);
    expect(result.fullyEnumerated, isFalse);
    expect(result.isComplete, isFalse);
    expect(api.markedIds, <String>['valid-window-notice']);
  });

  test('destination stage never acknowledges an unknown-stage task', () async {
    final controller = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    addTearDown(controller.dispose);
    const unknownStage = PendingMessage(
      id: 'unknown-stage-task',
      source: PendingMessageSource.agentTask,
      scene: 'outline',
      title: '未知结果',
      body: '缺少结果阶段。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'unknown-stage-task',
      targetType: 'asset',
      targetId: 'stage-note-1',
      isTask: true,
    );
    const outline = PendingMessage(
      id: 'outline-stage-task',
      source: PendingMessageSource.agentTask,
      scene: 'outline',
      title: '纲要结果',
      body: '纲要已写入。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'outline-stage-task',
      targetType: 'asset',
      targetId: 'stage-note-1',
      stage: 'outline',
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[unknownStage, outline],
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'asset',
        targetId: 'stage-note-1',
        stage: 'outline',
        matchingTaskIds: const <String>{'outline-stage-task'},
        durableSucceededTaskIds: const <String>{'outline-stage-task'},
      ),
      isTrue,
    );
    expect(controller.state.handledTaskIds, contains('outline-stage-task'));
    expect(
      controller.state.handledTaskIds,
      isNot(contains('unknown-stage-task')),
    );
  });

  test('succeeded asset stage rejects wildcard result evidence', () async {
    final controller = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    addTearDown(controller.dispose);
    const row = PendingMessage(
      id: 'asset-wildcard-task',
      source: PendingMessageSource.agentTask,
      scene: 'outline',
      title: '纲要结果',
      body: '纲要已写入。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'asset-wildcard-task',
      targetType: 'asset',
      targetId: 'asset-wildcard-note',
      stage: 'outline',
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[row],
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'asset',
        targetId: 'asset-wildcard-note',
        stage: 'outline',
      ),
      isFalse,
    );
    expect(controller.state.handledTaskIds, isEmpty);
  });

  test('viewed task hides only that result for the same target', () {
    final firstTaskId = _identifierOfLength('agent_run_', 130);
    final secondTaskId = _identifierOfLength('agent_run_next_', 130);
    final now = DateTime.utc(2026, 8, 15, 9);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        handledTaskIds: <String>{notificationTaskResolutionKey(firstTaskId)!},
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: _TaskLedgerTracker(<AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.chat(
          taskId: firstTaskId,
          threadId: 'thread-shared-target',
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: now,
        ),
        AgentTaskLedgerEntry.chat(
          taskId: secondTaskId,
          threadId: 'thread-shared-target',
          scene: ChatScene.feedAi,
          status: 'succeeded',
          createdAt: now.add(const Duration(minutes: 1)),
        ),
      ]),
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    expect(projection.items, hasLength(1));
    expect(projection.items.single.taskId, secondTaskId);
  });

  test(
    'server read keeps history and active progress without badge pressure',
    () {
      final now = DateTime.utc(2026, 8, 15, 9);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      const notifications = NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          AppNotification(
            notificationId: 'notice-read-terminal',
            eventType: 'agent_run.succeeded',
            scene: 'chat',
            targetType: 'thread',
            targetId: 'thread-terminal',
            title: '回复已完成',
            body: '已经查看。',
            status: AppNotificationStatus.read,
            taskStatus: AppNotificationTaskStatus.succeeded,
            taskId: 'task-read-terminal',
          ),
          AppNotification(
            notificationId: 'notice-read-processing',
            eventType: 'agent_run.running',
            scene: 'chat',
            targetType: 'thread',
            targetId: 'thread-processing',
            title: '回复生成中',
            body: '仍在处理。',
            status: AppNotificationStatus.read,
            taskStatus: AppNotificationTaskStatus.running,
            taskId: 'task-read-processing',
          ),
          AppNotification(
            notificationId: 'notice-read-ordinary',
            eventType: 'note.ready',
            scene: 'notification',
            targetType: 'note',
            targetId: 'note-read',
            title: '普通通知',
            body: '已经查看。',
            status: AppNotificationStatus.read,
          ),
        ],
      );
      final projection = buildPendingMessageProjection(
        notifications: notifications,
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items, hasLength(3));
      expect(projection.unreadCount, 0);
      expect(
        projection.items
            .where((item) => item.taskId == 'task-read-processing')
            .single
            .state,
        PendingMessageState.processing,
      );
      expect(
        projection.items.map((item) => item.taskId),
        containsAll(<String>['task-read-terminal', 'task-read-processing']),
      );
      expect(
        projection.items
            .singleWhere((item) => item.taskId == 'task-read-terminal')
            .isUnread,
        isFalse,
      );

      final acknowledged = buildPendingMessageProjection(
        notifications: notifications.copyWith(
          handledTaskIds: const <String>{'task-read-terminal'},
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(acknowledged.items, hasLength(2));
      expect(
        acknowledged.items.map((item) => item.taskId),
        isNot(contains('task-read-terminal')),
      );
      expect(
        acknowledged.items
            .singleWhere((item) => item.taskId == 'task-read-processing')
            .state,
        PendingMessageState.processing,
      );
      expect(
        acknowledged.items
            .singleWhere((item) => item.id == 'notice-read-ordinary')
            .isUnread,
        isFalse,
      );
    },
  );

  test('local terminal tasks use the same sole completion action', () async {
    final controller = NotificationController(
      api: const UnavailableNotificationApi(),
    );
    addTearDown(controller.dispose);
    const processing = PendingMessage(
      id: 'local:recordingTranscription:processing',
      source: PendingMessageSource.recordingTranscription,
      scene: 'recording',
      title: '录音转写中',
      body: '正在处理。',
      state: PendingMessageState.processing,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      isTask: true,
    );
    const failed = PendingMessage(
      id: 'local:recordingTranscription:failed',
      source: PendingMessageSource.recordingTranscription,
      scene: 'recording',
      title: '录音转写失败',
      body: '可打开重试。',
      state: PendingMessageState.failed,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[processing, failed],
    );

    expect(processing.shouldShowOpenAction, isTrue);
    expect(processing.shouldShowHandledAction, isFalse);
    expect(failed.shouldShowOpenAction, isFalse);
    expect(failed.shouldShowHandledAction, isTrue);
    expect(await actions.markHandled(processing), isFalse);
    expect(await actions.markHandled(failed), isTrue);
    expect(
      controller.state.handledIds,
      contains(pendingMessageLocalDeliveryResolutionKey(failed)),
    );
  });

  test('uses state-specific open labels', () {
    const processing = PendingMessage(
      id: 'local:label:processing',
      source: PendingMessageSource.agentTask,
      scene: 'outline',
      title: '纲要生成中',
      body: '正在处理。',
      state: PendingMessageState.processing,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
    );
    const chat = PendingMessage(
      id: 'local:label:chat',
      source: PendingMessageSource.agentTask,
      scene: 'chat',
      title: '聊一聊已完成',
      body: '可以查看回复。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      canMarkHandled: false,
      taskId: 'task-label-chat-1',
      targetType: 'thread',
      targetId: 'thread-label-1',
      isTask: true,
    );
    const result = PendingMessage(
      id: 'local:label:result',
      source: PendingMessageSource.agentTask,
      scene: 'sprout',
      title: '点火已完成',
      body: '可以查看结果。',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      canMarkHandled: false,
      taskId: 'task-label-result-1',
      targetType: 'asset',
      targetId: 'note-label-1',
      isTask: true,
    );
    const onboarding = PendingMessage(
      id: 'local:label:onboarding',
      source: PendingMessageSource.onboarding,
      scene: 'onboarding',
      title: '完成基础定位',
      body: '继续定位。',
      state: PendingMessageState.actionRequired,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      canMarkHandled: false,
    );
    const deviceGuide = PendingMessage(
      id: 'local:label:device-guide',
      source: PendingMessageSource.firstLaunchDeviceSetup,
      scene: 'device_setup',
      title: '了解声纹和录音卡',
      body: '继续设置。',
      state: PendingMessageState.actionRequired,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      canMarkHandled: false,
      targetType: 'first_launch_device_setup',
    );
    const failedChat = PendingMessage(
      id: 'local:label:failed-chat',
      source: PendingMessageSource.agentTask,
      scene: 'chat',
      title: '聊一聊任务未完成',
      body: '可以查看失败详情。',
      state: PendingMessageState.failed,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      canMarkHandled: false,
      taskId: 'task-label-failed-1',
      targetType: 'thread',
      targetId: 'thread-label-failed-1',
      isTask: true,
    );

    expect(pendingMessageOpenActionLabel(processing), '查看进度');
    expect(pendingMessageOpenActionLabel(chat), '查看回复');
    expect(pendingMessageOpenActionLabel(result), '查看结果');
    expect(pendingMessageOpenActionLabel(onboarding), '继续定位');
    expect(pendingMessageOpenActionLabel(deviceGuide), '继续设置');
    expect(pendingMessageOpenActionLabel(failedChat), '查看失败详情');
    expect(processing.shouldShowOpenAction, isTrue);
    expect(processing.shouldShowHandledAction, isFalse);
    expect(chat.shouldShowOpenAction, isFalse);
    expect(chat.shouldShowHandledAction, isTrue);
    expect(result.shouldShowOpenAction, isFalse);
    expect(result.shouldShowHandledAction, isTrue);
    expect(failedChat.shouldShowOpenAction, isFalse);
    expect(failedChat.shouldShowHandledAction, isTrue);
  });

  test(
    'persists exact visible chat task before its terminal row arrives late',
    () async {
      const notification = AppNotification(
        notificationId: 'late-chat-notification-1',
        eventType: 'agent_run.succeeded',
        scene: 'chat',
        targetType: 'thread',
        targetId: 'late-thread-1',
        title: '回复已完成',
        body: '可以查看结果。',
        status: AppNotificationStatus.unread,
        taskStatus: AppNotificationTaskStatus.succeeded,
        taskId: 'late-agent-run-1',
      );
      final api = _DelayedNotificationApi(<List<AppNotification>>[
        const <AppNotification>[],
        const <AppNotification>[notification],
      ]);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final now = DateTime.utc(2026, 8, 15, 10);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      PendingMessageProjection projection() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );
      var actionProjectionReads = 0;
      final actions = PendingMessageActions(
        controller,
        items: () {
          actionProjectionReads += 1;
          return projection().items;
        },
      );

      expect(
        await actions.acknowledgeResultShown(
          targetType: 'thread',
          targetId: 'late-thread-1',
          matchingTaskIds: const <String>{'late-agent-run-1'},
          durableSucceededTaskIds: const <String>{'late-agent-run-1'},
        ),
        isTrue,
      );
      expect(api.listCalls, 1);
      expect(actionProjectionReads, 1);
      expect(controller.state.handledTaskIds, contains('late-agent-run-1'));
      await controller.load(forceRemote: true);
      expect(api.listCalls, 2);
      expect(projection().items, isEmpty);
    },
  );

  test('historical chat evidence cannot settle a newer thread task', () async {
    const notification = AppNotification(
      notificationId: 'new-chat-notification-1',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'shared-thread-1',
      title: '新回复已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'new-agent-run-1',
    );
    final controller = NotificationController(
      api: const _SingleNotificationApi(notification),
    );
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(DateTime.utc(2026, 9, 2, 10));
    addTearDown(aggregation.dispose);
    PendingMessageProjection projection() => buildPendingMessageProjection(
      notifications: controller.state,
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );
    final actions = PendingMessageActions(
      controller,
      items: () => projection().items,
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'thread',
        targetId: 'shared-thread-1',
        matchingTaskIds: const <String>{'historical-agent-run-1'},
        durableSucceededTaskIds: const <String>{'historical-agent-run-1'},
      ),
      isTrue,
    );
    expect(controller.state.handledTaskIds, contains('historical-agent-run-1'));
    expect(controller.state.handledTaskIds, isNot(contains('new-agent-run-1')));
    expect(projection().items.single.taskId, 'new-agent-run-1');

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'thread',
        targetId: 'shared-thread-1',
        matchingTaskIds: const <String>{'new-agent-run-1'},
        durableSucceededTaskIds: const <String>{'new-agent-run-1'},
      ),
      isTrue,
    );
    expect(projection().items, isEmpty);
  });

  test('failure evidence reads only its failed row', () async {
    const succeededNotification = AppNotification(
      notificationId: 'failure-evidence-succeeded-notification',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'failure-evidence-thread',
      title: '回复已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'failure-evidence-raced-task',
    );
    const failedNotification = AppNotification(
      notificationId: 'failure-evidence-failed-notification',
      eventType: 'agent_run.failed',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'failure-evidence-thread',
      title: '回复失败',
      body: '可以重试。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.failed,
      taskId: 'failure-evidence-failed-task',
    );
    final api = _StaticNotificationApi(const <AppNotification>[
      succeededNotification,
      failedNotification,
    ]);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final succeeded = PendingMessage(
      id: 'failure-evidence-succeeded-notification',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '回复已完成',
      body: '可以查看结果。',
      state: PendingMessageState.succeeded,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      remoteNotificationId: 'failure-evidence-succeeded-notification',
      remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
        succeededNotification,
      ),
      taskId: 'failure-evidence-raced-task',
      targetType: 'thread',
      targetId: 'failure-evidence-thread',
      isTask: true,
    );
    final failed = PendingMessage(
      id: 'failure-evidence-failed-notification',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '回复失败',
      body: '可以重试。',
      state: PendingMessageState.failed,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      remoteNotificationId: 'failure-evidence-failed-notification',
      remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
        failedNotification,
      ),
      taskId: 'failure-evidence-failed-task',
      targetType: 'thread',
      targetId: 'failure-evidence-thread',
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => <PendingMessage>[succeeded, failed],
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'thread',
        targetId: 'failure-evidence-thread',
        matchingTaskIds: const <String>{
          'failure-evidence-raced-task',
          'failure-evidence-failed-task',
        },
      ),
      isTrue,
    );
    expect(controller.state.handledTaskIds, isEmpty);
    expect(api.markedIds, <String>['failure-evidence-failed-notification']);
    expect(api.listCalls, 1);
    expect(
      controller.state.items
          .singleWhere(
            (item) =>
                item.notificationId ==
                'failure-evidence-succeeded-notification',
          )
          .status,
      AppNotificationStatus.unread,
    );
  });

  test('read success cannot mask failed task receipt persistence', () async {
    const succeededNotification = AppNotification(
      notificationId: 'receipt-save-failure-notification-1',
      eventType: 'agent_run.succeeded',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'receipt-save-failure-thread-1',
      title: '回复已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'receipt-save-failure-task-1',
    );
    const failedNotification = AppNotification(
      notificationId: 'receipt-read-success-notification-1',
      eventType: 'agent_run.failed',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'receipt-save-failure-thread-1',
      title: '旧任务失败',
      body: '可以重试。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.failed,
      taskId: 'receipt-read-success-task-1',
    );
    final api = _StaticNotificationApi(const <AppNotification>[
      succeededNotification,
      failedNotification,
    ]);
    final resolution = _FailingTaskResolutionPort();
    final controller = NotificationController(api: api, resolution: resolution);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final terminal = PendingMessage(
      id: 'receipt-save-failure-notification-1',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '回复已完成',
      body: '可以查看结果。',
      state: PendingMessageState.succeeded,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      remoteNotificationId: 'receipt-save-failure-notification-1',
      remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
        succeededNotification,
      ),
      taskId: 'receipt-save-failure-task-1',
      targetType: 'thread',
      targetId: 'receipt-save-failure-thread-1',
      isTask: true,
    );
    final failed = PendingMessage(
      id: 'receipt-read-success-notification-1',
      source: PendingMessageSource.remote,
      scene: 'chat',
      title: '旧任务失败',
      body: '可以重试。',
      state: PendingMessageState.failed,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      remoteNotificationId: 'receipt-read-success-notification-1',
      remoteDeliveryResolutionKey: notificationDeliveryResolutionKey(
        failedNotification,
      ),
      taskId: 'receipt-read-success-task-1',
      targetType: 'thread',
      targetId: 'receipt-save-failure-thread-1',
      isTask: true,
    );
    final actions = PendingMessageActions(
      controller,
      items: () => <PendingMessage>[terminal, failed],
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'thread',
        targetId: 'receipt-save-failure-thread-1',
        matchingTaskIds: const <String>{
          'receipt-save-failure-task-1',
          'receipt-read-success-task-1',
        },
        durableSucceededTaskIds: const <String>{'receipt-save-failure-task-1'},
      ),
      isFalse,
    );
    expect(controller.state.handledTaskIds, isEmpty);
    expect(api.markedIds, <String>['receipt-read-success-notification-1']);
    expect(api.listCalls, 1);
    expect(
      controller.state.items
          .singleWhere(
            (item) =>
                item.notificationId == 'receipt-save-failure-notification-1',
          )
          .status,
      AppNotificationStatus.unread,
    );
  });

  test(
    'persists a recording receipt before its deposit notification arrives',
    () async {
      const notification = AppNotification(
        notificationId: 'late-recording-notification-1',
        eventType: 'recording.deposit.succeeded',
        scene: 'recording',
        targetType: 'recording',
        targetId: 'late-recording-1',
        title: '录音已沉淀',
        body: '转写已写入笔记。',
        status: AppNotificationStatus.unread,
      );
      final api = _DelayedNotificationApi(<List<AppNotification>>[
        const <AppNotification>[],
        const <AppNotification>[notification],
      ]);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      final now = DateTime.utc(2026, 9, 2, 10);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      PendingMessageProjection projection() => buildPendingMessageProjection(
        notifications: controller.state,
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );
      var actionProjectionReads = 0;
      var rejectPostRefreshRead = true;
      final actions = PendingMessageActions(
        controller,
        items: () {
          actionProjectionReads += 1;
          if (rejectPostRefreshRead && actionProjectionReads > 1) {
            throw StateError('STALE_PROJECTION_READ_AFTER_REFRESH');
          }
          return projection().items;
        },
      );

      expect(
        await actions.acknowledgeResultShown(
          targetType: 'recording',
          targetId: 'late-recording-1',
          stage: 'recording_processing',
        ),
        isTrue,
      );
      expect(actionProjectionReads, 1);
      expect(
        controller.state.handledTaskIds,
        contains('recording:late-recording-1'),
      );
      expect(api.listCalls, 1);
      await controller.load(forceRemote: true);
      expect(api.listCalls, 2);
      expect(projection().items, isEmpty);
      rejectPostRefreshRead = false;
      expect(
        await actions.acknowledgeResultShown(
          targetType: 'recording',
          targetId: 'late-recording-1',
          stage: 'recording_processing',
        ),
        isTrue,
      );
      expect(api.listCalls, 2);
    },
  );

  test('empty late-delivery refresh remains retryable', () async {
    const notification = AppNotification(
      notificationId: 'retry-late-notification-1',
      eventType: 'note.outline.succeeded',
      scene: 'outline',
      targetType: 'asset',
      targetId: 'retry-late-asset-1',
      title: '纲要已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'retry-late-agent-run-1',
    );
    final api = _DelayedNotificationApi(<List<AppNotification>>[
      const <AppNotification>[],
      const <AppNotification>[],
      const <AppNotification>[notification],
    ]);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[],
    );

    expect(
      await actions.acknowledgeResultShown(
        targetType: 'asset',
        targetId: 'retry-late-asset-1',
        stage: 'outline',
        matchingTaskIds: const <String>{'retry-late-agent-run-1'},
        durableSucceededTaskIds: const <String>{'retry-late-agent-run-1'},
      ),
      isFalse,
    );
    expect(api.listCalls, 2);
    expect(
      await actions.acknowledgeResultShown(
        targetType: 'asset',
        targetId: 'retry-late-asset-1',
        stage: 'outline',
        matchingTaskIds: const <String>{'retry-late-agent-run-1'},
        durableSucceededTaskIds: const <String>{'retry-late-agent-run-1'},
      ),
      isTrue,
    );
    expect(api.listCalls, 3);
    expect(controller.state.handledTaskIds, contains('retry-late-agent-run-1'));
  });

  test('concurrent late receipts share one target refresh', () async {
    const notification = AppNotification(
      notificationId: 'coalesced-late-notification-1',
      eventType: 'note.outline.succeeded',
      scene: 'outline',
      targetType: 'asset',
      targetId: 'coalesced-late-asset-1',
      title: '纲要已完成',
      body: '可以查看结果。',
      status: AppNotificationStatus.unread,
      taskStatus: AppNotificationTaskStatus.succeeded,
      taskId: 'coalesced-late-task-1',
    );
    final api = _ControlledLateNotificationApi(notification);
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    await controller.load(forceRemote: true);
    final actions = PendingMessageActions(
      controller,
      items: () => const <PendingMessage>[],
    );

    final first = actions.acknowledgeResultShown(
      targetType: 'asset',
      targetId: 'coalesced-late-asset-1',
      stage: 'outline',
      matchingTaskIds: const <String>{'coalesced-late-task-1'},
      durableSucceededTaskIds: const <String>{'coalesced-late-task-1'},
    );
    final second = actions.acknowledgeResultShown(
      targetType: 'asset',
      targetId: 'coalesced-late-asset-1',
      stage: 'outline',
      matchingTaskIds: const <String>{'coalesced-late-task-1'},
      durableSucceededTaskIds: const <String>{'coalesced-late-task-1'},
    );
    await Future<void>.delayed(Duration.zero);
    expect(api.listCalls, 2);

    api.completeRefresh();
    expect(await Future.wait<bool>(<Future<bool>>[first, second]), <bool>[
      true,
      true,
    ]);
    expect(api.listCalls, 2);
    expect(controller.state.handledTaskIds, contains('coalesced-late-task-1'));
  });

  test(
    'routes a tracked deep-positioning chat task to its own chat controller',
    () {
      final now = DateTime.utc(2026, 8, 15, 9);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        taskTracker: _TaskLedgerTracker(<AgentTaskLedgerEntry>[
          AgentTaskLedgerEntry.chat(
            taskId: 'agent-run-deep-positioning-1',
            threadId: 'deep-thread-1',
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.deepPositioning,
            status: 'running',
            createdAt: now,
          ),
        ]),
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items, hasLength(1));
      expect(
        projection.items.single.route,
        '/v3/feed/chat?threadId=deep-thread-1&purpose=deep-positioning',
      );
    },
  );

  test(
    'preserves a remote sync error while cached messages remain visible',
    () {
      final now = DateTime.utc(2026, 8, 13, 10);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
          lastErrorCode: 'NOTIFICATION_LOAD_FAILED',
          items: <AppNotification>[
            AppNotification(
              notificationId: 'cached-notice-1',
              eventType: 'agent_run.succeeded',
              scene: 'chat',
              targetType: 'thread',
              targetId: 'thread-1',
              title: '缓存提醒',
              body: '内容仍可查看。',
              status: AppNotificationStatus.unread,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );

      expect(projection.items, isNotEmpty);
      expect(projection.remoteErrorCode, 'NOTIFICATION_LOAD_FAILED');
    },
  );

  test(
    'projects every latched recording lifecycle phase and terminal failure',
    () {
      final now = DateTime.utc(2026, 8, 19, 9);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final draft = _uploadDraft(
        now,
      ).copyWith(stage: UploadDraftStage.asrQueued);

      PendingMessageProjection project(
        RecordingProcessingPhase phase, {
        String? errorCode,
      }) {
        return buildPendingMessageProjection(
          notifications: NotificationControllerState.initial(),
          aggregation: aggregation,
          knowledge: knowledge,
          ingestionDrafts: const <MaterialIngestionDraft>[],
          documentImport: const V3DocumentImportState.initial(),
          recordingUpload: RecordingUploadState.initial(),
          recordingProcessing: RecordingProcessingState(
            tasks: <RecordingProcessingTask>[
              RecordingProcessingTask(
                draft: draft,
                phase: phase,
                updatedAt: now,
                errorCode: errorCode,
              ),
            ],
          ),
        );
      }

      for (final phase in <RecordingProcessingPhase>[
        RecordingProcessingPhase.transcribing,
        RecordingProcessingPhase.storingCloudNote,
      ]) {
        final sharedState = RecordingProcessingTask(
          draft: draft,
          phase: phase,
          updatedAt: now,
        ).appTaskState;
        final processing = project(phase).items.single;
        expect(sharedState, isA<AppTaskRunning>());
        expect(processing.state, PendingMessageState.processing);
        expect(processing.shouldShowOpenAction, isTrue);
        expect(processing.shouldShowHandledAction, isFalse);
        expect(processing.body, '正在转写并保存到我的资产。');
        expect(
          deriveAssetProjectionFreshness(<PendingMessage>[
            processing,
          ]).hasActiveWork,
          isTrue,
        );
      }

      for (final entry in <(RecordingProcessingPhase, String)>[
        (RecordingProcessingPhase.completed, '转写完成，结果已保存到我的资产。'),
        (RecordingProcessingPhase.failed, '转写并保存到我的资产失败。'),
      ]) {
        final sharedState = RecordingProcessingTask(
          draft: draft,
          phase: entry.$1,
          updatedAt: now,
          errorCode: entry.$1 == RecordingProcessingPhase.failed
              ? 'RECORDING_TRANSCRIPTION_FAILED'
              : null,
        ).appTaskState;
        final errorCode = entry.$1 == RecordingProcessingPhase.failed
            ? 'RECORDING_TRANSCRIPTION_FAILED'
            : null;
        final terminal = project(entry.$1, errorCode: errorCode).items.single;
        expect(
          sharedState,
          entry.$1 == RecordingProcessingPhase.completed
              ? isA<AppTaskSucceeded>()
              : isA<AppTaskFailed>(),
        );
        expect(terminal.shouldShowOpenAction, isFalse);
        expect(terminal.shouldShowHandledAction, isFalse);
        expect(
          terminal.copyWith(isUnread: false).shouldShowHandledAction,
          isTrue,
        );
        expect(terminal.body, entry.$2);
        expect(
          deriveAssetProjectionFreshness(<PendingMessage>[
            terminal,
          ]).hasActiveWork,
          isFalse,
        );
      }

      final backendTimeout = project(
        RecordingProcessingPhase.failed,
        errorCode: 'RECORDING_TRANSCRIPTION_TIMEOUT',
      ).items.single;
      expect(backendTimeout.state, PendingMessageState.failed);
      expect(backendTimeout.body, '转写并保存到我的资产失败。');
      expect(backendTimeout.errorCode, 'RECORDING_TRANSCRIPTION_TIMEOUT');

      final postprocessFailure = project(
        RecordingProcessingPhase.failed,
        errorCode: 'RECORDING_NOTE_STORAGE_FAILED',
      ).items.single;
      expect(postprocessFailure.body, '转写并保存到我的资产失败。');
    },
  );

  test(
    'remote lifecycle uses exact signals and treats deposit as a result',
    () {
      final now = DateTime.utc(2026, 9, 2, 8);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            AppNotification(
              notificationId: 'recording-deposit-1',
              eventType: 'recording.deposit.succeeded',
              scene: 'recording',
              targetType: 'recording',
              targetId: 'recording-1',
              title: '录音已沉淀',
              body: '转写已写入笔记。',
              status: AppNotificationStatus.unread,
            ),
            AppNotification(
              notificationId: 'quota-1',
              eventType: 'quota.action_required',
              scene: 'billing',
              targetType: 'notification',
              targetId: 'quota-1',
              title: '需要处理',
              body: '请检查额度。',
              status: AppNotificationStatus.unread,
            ),
            AppNotification(
              notificationId: 'informational-1',
              eventType: 'system.errorless.readying',
              scene: 'notification',
              targetType: 'notification',
              targetId: 'informational-1',
              title: '普通通知',
              body: '不包含明确生命周期。',
              status: AppNotificationStatus.unread,
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
      );
      final byId = <String, PendingMessage>{
        for (final item in projection.items) item.id: item,
      };

      expect(byId['recording-deposit-1']?.state, PendingMessageState.succeeded);
      expect(byId['recording-deposit-1']?.isTask, isTrue);
      expect(byId['recording-deposit-1']?.taskId, 'recording:recording-1');
      expect(byId['recording-deposit-1']?.stage, 'recording_processing');
      expect(byId['quota-1']?.state, PendingMessageState.actionRequired);
      expect(byId['informational-1']?.state, PendingMessageState.informational);
    },
  );

  test(
    'active recording batch aggregates only object-upload item progress',
    () {
      final now = DateTime.utc(2026, 9, 5, 10);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final batch = _notificationBatch(<RecordingBatchTranscriptionItem>[
        RecordingBatchTranscriptionItem(
          itemId: 'uploading',
          title: 'Uploading recording',
          fileIdentity: 'file-uploading',
          localRecordingId: 'local-uploading',
          jobId: 'job-uploading',
          status: RecordingBatchTranscriptionItemStatus.submitting,
          phase: RecordingBatchTranscriptionPhase.uploading,
          outlineStatus: RecordingBatchOutlineStatus.notStarted,
          retryable: false,
          attemptCount: 1,
          createdAt: now,
          updatedAt: now,
        ),
        RecordingBatchTranscriptionItem(
          itemId: 'transcribing',
          title: 'Transcribing recording',
          fileIdentity: 'file-transcribing',
          localRecordingId: 'local-transcribing',
          jobId: 'job-transcribing',
          remoteRecordingId: 'remote-transcribing',
          status: RecordingBatchTranscriptionItemStatus.processing,
          phase: RecordingBatchTranscriptionPhase.transcribing,
          outlineStatus: RecordingBatchOutlineStatus.notStarted,
          progress: 20,
          retryable: false,
          attemptCount: 1,
          createdAt: now,
          updatedAt: now,
        ),
      ], updatedAt: now);

      final projection = buildPendingMessageProjection(
        notifications: const NotificationControllerState(
          status: NotificationControllerStatus.ready,
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: const RecordingUploadState(
          uploadProgressByDraftId: <String, RecordingObjectUploadProgress>{
            'job-uploading': RecordingObjectUploadProgress(
              draftId: 'job-uploading',
              bytesSent: 512,
              totalBytes: 2048,
              bytesPerSecond: 256,
              estimatedRemainingSeconds: 6,
            ),
            'job-transcribing': RecordingObjectUploadProgress(
              draftId: 'job-transcribing',
              bytesSent: 2048,
              totalBytes: 4096,
              bytesPerSecond: 1024,
              estimatedRemainingSeconds: 2,
            ),
          },
        ),
        recordingBatches: <RecordingBatchTranscriptionSnapshot>[batch],
      );

      final aggregate = projection.items.singleWhere(
        (item) => item.targetType == 'recording_batch',
      );
      expect(aggregate.recordingUploadProgress?.bytesSent, 512);
      expect(aggregate.recordingUploadProgress?.totalBytes, 2048);
      expect(aggregate.recordingUploadProgress?.bytesPerSecond, 256);
      expect(aggregate.recordingUploadProgress?.estimatedRemainingSeconds, 6);
    },
  );

  test(
    'active recording batch suppresses server progress and owns newer terminal routes',
    () {
      final now = DateTime.utc(2026, 9, 4, 10);
      final knowledge = KnowledgeLibraryController(initialNotes: const []);
      addTearDown(knowledge.dispose);
      final aggregation = _aggregationController(now);
      addTearDown(aggregation.dispose);
      final batch = _notificationBatch(<RecordingBatchTranscriptionItem>[
        _notificationBatchItem(
          'completed',
          remoteRecordingId: 'remote-completed',
          status: RecordingBatchTranscriptionItemStatus.completed,
        ),
        _notificationBatchItem(
          'processing',
          remoteRecordingId: 'remote-processing',
          status: RecordingBatchTranscriptionItemStatus.processing,
        ),
        _notificationBatchItem(
          'failed',
          remoteRecordingId: 'remote-failed',
          status: RecordingBatchTranscriptionItemStatus.failed,
        ),
        _notificationBatchItem(
          'timeout',
          remoteRecordingId: 'remote-timeout',
          status: RecordingBatchTranscriptionItemStatus.timedOut,
        ),
        _notificationBatchItem(
          'outline',
          remoteRecordingId: 'remote-outline',
          status: RecordingBatchTranscriptionItemStatus.completed,
        ),
      ], updatedAt: now);
      final serverAt = now.add(const Duration(minutes: 2));
      final projection = buildPendingMessageProjection(
        notifications: NotificationControllerState(
          status: NotificationControllerStatus.ready,
          items: <AppNotification>[
            _recordingServerNotification(
              id: 'server-completed',
              recordingId: 'remote-completed',
              status: AppNotificationTaskStatus.succeeded,
              createdAt: serverAt,
              eventType: 'recording.deposit.succeeded',
            ),
            _recordingServerNotification(
              id: 'server-processing',
              recordingId: 'remote-processing',
              status: AppNotificationTaskStatus.running,
              createdAt: serverAt,
            ),
            _recordingServerNotification(
              id: 'server-failed',
              recordingId: 'remote-failed',
              status: AppNotificationTaskStatus.failed,
              createdAt: serverAt,
            ),
            _recordingServerNotification(
              id: 'server-timeout',
              recordingId: 'remote-timeout',
              status: AppNotificationTaskStatus.timeout,
              createdAt: serverAt,
            ),
            _recordingServerNotification(
              id: 'server-outline',
              recordingId: 'remote-outline',
              status: AppNotificationTaskStatus.succeeded,
              createdAt: serverAt,
              eventType: 'recording.outline.completed',
            ),
          ],
        ),
        aggregation: aggregation,
        knowledge: knowledge,
        ingestionDrafts: const <MaterialIngestionDraft>[],
        documentImport: const V3DocumentImportState.initial(),
        recordingUpload: RecordingUploadState.initial(),
        recordingBatches: <RecordingBatchTranscriptionSnapshot>[batch],
      );

      expect(
        projection.items.where((item) => item.id == 'server-processing'),
        isEmpty,
      );
      expect(
        projection.items
            .singleWhere((item) => item.id == 'server-outline')
            .route,
        isNot(contains('/transcription-batches/')),
      );
      for (final entry in const <(String, String)>[
        ('remote-completed', 'completed'),
        ('remote-failed', 'failed'),
        ('remote-timeout', 'timeout'),
      ]) {
        final server = projection.items.singleWhere(
          (item) =>
              item.source == PendingMessageSource.remote &&
              item.targetId == entry.$1,
        );
        expect(
          server.route,
          '/v3/feed/transcription-batches/batch-notifications?focusItem=${entry.$2}',
        );
      }

      final canonical = const NotificationCenterPolicyRegistry().canonicalItems(
        projection.items,
      );
      for (final entry in const <(String, String)>[
        ('remote-completed', 'completed'),
        ('remote-failed', 'failed'),
        ('remote-timeout', 'timeout'),
      ]) {
        final rows = canonical
            .where((item) => item.targetId == entry.$1)
            .toList(growable: false);
        expect(rows, hasLength(1));
        expect(
          rows.single.route,
          '/v3/feed/transcription-batches/batch-notifications?focusItem=${entry.$2}',
        );
      }
    },
  );

  test('settled batch sends only successful items to the recording result', () {
    final now = DateTime.utc(2026, 9, 4, 11);
    final knowledge = KnowledgeLibraryController(initialNotes: const []);
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final batch = _notificationBatch(<RecordingBatchTranscriptionItem>[
      _notificationBatchItem(
        'completed',
        remoteRecordingId: 'remote-settled-completed',
        status: RecordingBatchTranscriptionItemStatus.completed,
        jobId: 'upload-1',
      ),
      _notificationBatchItem(
        'failed',
        remoteRecordingId: 'remote-settled-failed',
        status: RecordingBatchTranscriptionItemStatus.failed,
      ),
    ], updatedAt: now);
    final projection = buildPendingMessageProjection(
      notifications: NotificationControllerState(
        status: NotificationControllerStatus.ready,
        items: <AppNotification>[
          _recordingServerNotification(
            id: 'server-settled-completed',
            recordingId: 'remote-settled-completed',
            status: AppNotificationTaskStatus.succeeded,
            createdAt: now.add(const Duration(minutes: 1)),
            eventType: 'recording.deposit.succeeded',
          ),
          _recordingServerNotification(
            id: 'server-settled-failed',
            recordingId: 'remote-settled-failed',
            status: AppNotificationTaskStatus.failed,
            createdAt: now.add(const Duration(minutes: 1)),
          ),
        ],
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState(
        status: RecordingFileJobStatus.failed,
        activeDraft: _uploadDraft(
          now,
          recordingId: 'remote-settled-completed',
          stage: UploadDraftStage.asrFailed,
        ),
        lastErrorCode: 'STALE_UPLOAD_FAILURE',
      ),
      recordingProcessing: RecordingProcessingState(
        tasks: <RecordingProcessingTask>[
          RecordingProcessingTask(
            draft: _uploadDraft(
              now,
              recordingId: 'remote-settled-completed',
              stage: UploadDraftStage.asrFailed,
            ),
            phase: RecordingProcessingPhase.failed,
            updatedAt: now.add(const Duration(minutes: 2)),
            errorCode: 'STALE_TRACKER_FAILURE',
          ),
        ],
      ),
      recordingBatches: <RecordingBatchTranscriptionSnapshot>[batch],
    );
    final canonical = const NotificationCenterPolicyRegistry().canonicalItems(
      projection.items,
    );

    expect(
      canonical
          .singleWhere((item) => item.targetId == 'remote-settled-completed')
          .route,
      '/v3/feed/transcription-done/remote-settled-completed?destination=raw',
    );
    expect(
      canonical
          .singleWhere((item) => item.targetId == 'remote-settled-failed')
          .route,
      '/v3/feed/transcription-batches/batch-notifications?focusItem=failed',
    );
    expect(
      projection.items.where(
        (item) =>
            item.source == PendingMessageSource.recordingTranscription &&
            item.targetId == 'remote-settled-completed',
      ),
      hasLength(1),
    );
    expect(
      projection.items.any(
        (item) =>
            item.errorCode == 'STALE_UPLOAD_FAILURE' ||
            item.errorCode == 'STALE_TRACKER_FAILURE',
      ),
      isFalse,
    );
  });

  test('recording outline failure only navigates to its Note detail', () {
    final now = DateTime.utc(2026, 9, 4, 12);
    final note = V3FeedItem(
      id: 'recording-outline-failed-note',
      title: '独白转写笔记',
      source: V3MaterialSource.monologue,
      createdAt: now,
      rawBody: '已经保留的原始转写。',
      recordingId: 'recording-outline-failed-1',
    );
    final knowledge = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    addTearDown(knowledge.dispose);
    final aggregation = _aggregationController(now);
    addTearDown(aggregation.dispose);
    final projection = buildPendingMessageProjection(
      notifications: const NotificationControllerState(
        status: NotificationControllerStatus.ready,
      ),
      aggregation: aggregation,
      knowledge: knowledge,
      taskTracker: _TaskLedgerTracker(<AgentTaskLedgerEntry>[
        AgentTaskLedgerEntry.recordingOutline(
          taskId: 'recording-outline-tracker-failed-1',
          publicTaskId: 'recording-outline-subtask-failed-1',
          recordingId: 'recording-outline-failed-1',
          localNoteId: note.id,
          remoteNoteId: 'remote-recording-outline-failed-note',
          status: 'failed',
          failureCode: 'WORKSPACE_NOT_READY',
          createdAt: now,
        ),
      ]),
      ingestionDrafts: const <MaterialIngestionDraft>[],
      documentImport: const V3DocumentImportState.initial(),
      recordingUpload: RecordingUploadState.initial(),
    );

    final message = projection.items.singleWhere(
      (item) => item.taskId == 'recording-outline-tracker-failed-1',
    );
    expect(message.state, PendingMessageState.failed);
    expect(message.errorCode, 'WORKSPACE_NOT_READY');
    expect(message.body, contains('工作空间尚未准备完成'));
    expect(
      message.route,
      '/v3/feed/items/recording-outline-failed-note?stage=summary',
    );
    expect(pendingMessageOpenActionLabel(message), '查看失败详情');
  });
}

RecordingBatchTranscriptionSnapshot _notificationBatch(
  List<RecordingBatchTranscriptionItem> items, {
  required DateTime updatedAt,
}) => RecordingBatchTranscriptionSnapshot(
  batchId: 'batch-notifications',
  accountScope: 'account-notifications',
  workspaceScope: 'workspace-notifications',
  primaryItemId: items.first.itemId,
  items: items,
  createdAt: updatedAt.subtract(const Duration(minutes: 5)),
  updatedAt: updatedAt,
);

RecordingBatchTranscriptionItem _notificationBatchItem(
  String id, {
  required String remoteRecordingId,
  required RecordingBatchTranscriptionItemStatus status,
  String? jobId,
}) {
  final now = DateTime.utc(2026, 9, 4, 10);
  final completed = status == RecordingBatchTranscriptionItemStatus.completed;
  final failed = status == RecordingBatchTranscriptionItemStatus.failed;
  final timedOut = status == RecordingBatchTranscriptionItemStatus.timedOut;
  return RecordingBatchTranscriptionItem(
    itemId: id,
    title: 'Recording $id',
    fileIdentity: 'file-$id',
    localRecordingId: 'local-$id',
    jobId: jobId ?? 'job-$id',
    remoteRecordingId: remoteRecordingId,
    noteId: completed ? 'note-$id' : null,
    status: status,
    phase: completed ? RecordingBatchTranscriptionPhase.assetReady : null,
    outlineStatus: RecordingBatchOutlineStatus.notStarted,
    progress: completed ? 100 : null,
    retryable: failed || timedOut,
    attemptCount: 1,
    errorCode: failed
        ? 'RECORDING_TRANSCRIPTION_FAILED'
        : timedOut
        ? 'RECORDING_TRANSCRIPTION_TIMEOUT'
        : null,
    failureCategory: failed || timedOut
        ? RecordingBatchFailureCategory.remote
        : null,
    transcriptCompletedAt: completed ? now : null,
    assetReadyAt: completed ? now : null,
    createdAt: now,
    updatedAt: now,
  );
}

AppNotification _recordingServerNotification({
  required String id,
  required String recordingId,
  required AppNotificationTaskStatus status,
  required DateTime createdAt,
  String eventType = 'recording.transcription.updated',
}) => AppNotification(
  notificationId: id,
  eventType: eventType,
  scene: 'recording',
  targetType: 'recording',
  targetId: recordingId,
  title: 'Recording update',
  body: 'Recording state changed.',
  status: AppNotificationStatus.unread,
  taskStatus: status,
  taskId: 'task-$id',
  createdAt: createdAt,
);

PendingMessageProjection _projectAggregation(
  NotificationControllerState notifications,
  FeedAggregationController aggregation,
  KnowledgeLibraryController knowledge,
) {
  return buildPendingMessageProjection(
    notifications: notifications,
    aggregation: aggregation,
    knowledge: knowledge,
    ingestionDrafts: const <MaterialIngestionDraft>[],
    documentImport: const V3DocumentImportState.initial(),
    recordingUpload: RecordingUploadState.initial(),
  );
}

FeedAggregationController _aggregationController(DateTime now) {
  final notes = <V3FeedItem>[
    for (var index = 0; index < 4; index++)
      V3FeedItem(
        id: 'asset-$index',
        title: '资产 $index',
        source: V3MaterialSource.note,
        createdAt: now.subtract(Duration(days: index + 1)),
        rawBody: '正文',
      ),
    V3FeedItem(
      id: 'hotspot',
      title: '热点',
      source: V3MaterialSource.hotspot,
      ownership: V3NoteOwnership.hotspot,
      createdAt: now,
      rawBody: '热点正文',
    ),
  ];
  final library = KnowledgeLibraryController(initialNotes: notes);
  return FeedAggregationController(
    library: library,
    profileHub: ProfileHubController(referenceDay: now),
    repository: const FeedAggregationMockRepository(
      delay: Duration(milliseconds: 20),
    ),
    now: () => now.subtract(const Duration(minutes: 1)),
  );
}

FeedAggregationController _productionAggregationController(
  DateTime now,
  TopicCollisionRunPort runs,
  KnowledgeLibraryController library,
) => FeedAggregationController(
  library: _populateAggregationSources(library, now),
  profileHub: ProfileHubController(referenceDay: now),
  repository: const UnavailableFeedAggregationRepository(),
  preferences: AppPreferencesDao(AppDatabase()),
  topicCollisionRuns: runs,
  workspaceId: () => 'workspace-production',
  workspaceReady: () => true,
  now: () => now,
);

TopicCollisionRun _topicCollisionRun(String status, {String? failureCode}) =>
    TopicCollisionRun(
      workspaceId: 'workspace-production',
      stage: status,
      topicCollisionRunId: 'topic-collision-projection',
      status: status,
      selectedNoteCount: 4,
      sources: const <TopicCollisionSource>[
        TopicCollisionSource(inputRef: 'note-01'),
        TopicCollisionSource(inputRef: 'note-02'),
        TopicCollisionSource(inputRef: 'note-03'),
        TopicCollisionSource(inputRef: 'note-04'),
      ],
      failureCode: failureCode,
    );

final class _AggregationOutputGate
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  final started = Completer<void>();
  final result = Completer<KnowledgeNoteRemoteLoadResult>();
  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _FixedTopicCollisionRunPort implements TopicCollisionRunPort {
  const _FixedTopicCollisionRunPort(this.run);

  final TopicCollisionRun run;

  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) async => _topicCollisionResult(run);

  @override
  Future<ApiResult<TopicCollisionRun>> get(
    String workspaceId,
    String runId,
  ) async => _topicCollisionResult(run);
}

final class _SingleNotificationApi implements NotificationApiPort {
  const _SingleNotificationApi(this.notification);

  final AppNotification notification;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.success(
    data: AppNotificationPage(items: <AppNotification>[notification]),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.success(
    data: notification.copyWith(status: AppNotificationStatus.read),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _PagedNotificationApi implements NotificationApiPort {
  final List<String?> listCursors = <String?>[];
  final List<String> markedIds = <String>[];

  static const first = AppNotification(
    notificationId: 'notice-1',
    eventType: 'note.ready',
    scene: 'notification',
    targetType: 'note',
    targetId: 'note-1',
    title: '第一条',
    body: '第一条通知',
    status: AppNotificationStatus.unread,
  );
  static const second = AppNotification(
    notificationId: 'notice-2',
    eventType: 'note.ready',
    scene: 'notification',
    targetType: 'note',
    targetId: 'note-2',
    title: '第二条',
    body: '第二条通知',
    status: AppNotificationStatus.unread,
  );

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCursors.add(cursor);
    return ApiResult<AppNotificationPage>.success(
      data: cursor == null
          ? const AppNotificationPage(
              items: <AppNotification>[first],
              nextCursor: 'page-2',
            )
          : const AppNotificationPage(items: <AppNotification>[second]),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    markedIds.add(notificationId);
    final source = notificationId == first.notificationId ? first : second;
    return ApiResult<AppNotification>.success(
      data: source.copyWith(status: AppNotificationStatus.read),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
}

final class _StaticNotificationApi implements NotificationApiPort {
  _StaticNotificationApi(this.notifications, {this.rejectedItemCount = 0});

  final List<AppNotification> notifications;
  final int rejectedItemCount;
  final List<String> markedIds = <String>[];
  int listCalls = 0;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
    return ApiResult<AppNotificationPage>.success(
      data: AppNotificationPage(
        items: notifications,
        rejectedItemCount: rejectedItemCount,
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    markedIds.add(notificationId);
    final notification = notifications.singleWhere(
      (candidate) => candidate.notificationId == notificationId,
    );
    return ApiResult<AppNotification>.success(
      data: notification.copyWith(status: AppNotificationStatus.read),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
}

final class _ControlledLateNotificationApi implements NotificationApiPort {
  _ControlledLateNotificationApi(this.notification);

  final AppNotification notification;
  final Completer<void> _refreshRelease = Completer<void>();
  int listCalls = 0;

  void completeRefresh() => _refreshRelease.complete();

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
    if (listCalls > 1) await _refreshRelease.future;
    return ApiResult<AppNotificationPage>.success(
      data: AppNotificationPage(
        items: listCalls == 1
            ? const <AppNotification>[]
            : <AppNotification>[notification],
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.success(
    data: notification.copyWith(status: AppNotificationStatus.read),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _DelayedNotificationApi implements NotificationApiPort {
  _DelayedNotificationApi(this._pages);

  final List<List<AppNotification>> _pages;
  int listCalls = 0;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    final index = listCalls < _pages.length ? listCalls : _pages.length - 1;
    listCalls += 1;
    return ApiResult<AppNotificationPage>.success(
      data: AppNotificationPage(items: _pages[index]),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.failure(
    error: const AppFailure(
      code: 'NOT_EXPECTED',
      category: AppFailureCategory.api,
      message: 'not expected',
      userMessageKey: 'notExpected',
    ),
    idempotencyStore: idempotencyStore,
  );
}

final class _ReadFailureNotificationApi implements NotificationApiPort {
  const _ReadFailureNotificationApi(this.notification);

  final AppNotification notification;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.success(
    data: AppNotificationPage(items: <AppNotification>[notification]),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.failure(
    error: const AppFailure(
      code: 'NOTIFICATION_WRITE_FAILED',
      category: AppFailureCategory.api,
      message: 'read mutation unavailable',
      userMessageKey: 'notificationWriteFailed',
    ),
    idempotencyStore: idempotencyStore,
  );
}

final class _FailingTaskResolutionPort
    implements NotificationResolutionPort, TaskNotificationResolutionPort {
  final Set<String> _handledIds = <String>{};
  final Set<String> _locallyReadIds = <String>{};

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(_handledIds);

  @override
  Set<String> loadHandledTaskIds() => const <String>{};

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(_locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) async {
    _handledIds.add(notificationId);
    return true;
  }

  @override
  Future<bool> markLocallyRead(String notificationId) async {
    _locallyReadIds.add(notificationId);
    return true;
  }

  @override
  Future<bool> markTaskHandled(String taskId) async => false;
}

const _taskUnread = AppNotification(
  notificationId: 'notice-task-read-failure',
  eventType: 'agent_run.running',
  scene: 'chat',
  targetType: 'thread',
  targetId: 'thread-read-failure',
  title: '聊一聊处理中',
  body: '正在处理。',
  status: AppNotificationStatus.unread,
  taskStatus: AppNotificationTaskStatus.running,
  taskId: 'agent-task-read-failure',
);

ApiResult<TopicCollisionRun> _topicCollisionResult(TopicCollisionRun run) =>
    ApiResult<TopicCollisionRun>.success(
      data: run,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );

UploadDraft _uploadDraft(
  DateTime updatedAt, {
  String draftId = 'upload-1',
  String? recordingId = 'recording-1',
  UploadDraftStage stage = UploadDraftStage.uploaded,
  String? entrySource,
  String title = '录音转写',
}) => UploadDraft(
  draftId: draftId,
  localRecordingId: 'local-1',
  appPrivateUri: 'app-private://recordings/local-1.m4a',
  fileName: '录音.m4a',
  mimeType: 'audio/mp4',
  sizeBytes: 1024,
  durationSeconds: 15,
  sourceScene: 'monologue',
  entrySource: entrySource,
  stage: stage,
  updatedAt: updatedAt,
  uploadTokenKey: 'upload-token-1',
  completeUploadKey: 'upload-complete-1',
  createRecordingKey: 'recording-create-1',
  recordingId: recordingId,
  asrTaskId: 'asr-1',
  title: title,
);

AgentRunSnapshot _run({required String status}) => AgentRunSnapshot(
  agentRunId: 'agent_run_ledger_1',
  workspaceId: 'workspace-1',
  threadId: 'thread-ledger-1',
  status: status,
  workspaceVersion: 1,
  workspaceBindingVersion: 1,
  contextGeneration: 1,
  usage: const AgentRunUsage(
    measurementStatus: 'unavailable',
    inputTokens: null,
    outputTokens: null,
    imageCount: null,
    videoSeconds: null,
    accountedCredits: null,
    policyVersion: null,
  ),
  toolTrace: const <AgentRunToolTrace>[],
  createdAt: DateTime.utc(2026, 8, 14, 9),
  updatedAt: DateTime.utc(2026, 8, 14, 10),
);

final class _StableRunPort implements ProjectRunFixture {
  const _StableRunPort(this._run);

  final AgentRunSnapshot _run;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({required String agentRunId}) =>
      Future<ApiResult<AgentRunSnapshot>>.value(
        ApiResult<AgentRunSnapshot>.success(
          data: _run,
          status: 200,
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
}

final class _TaskLedgerTracker
    implements
        DerivedPartRunTrackingPort,
        AgentTaskLedgerPort,
        AgentTaskSubjectLookupPort {
  const _TaskLedgerTracker(
    this.taskLedger, {
    this.chatSubjects = const <String, String>{},
  });

  @override
  final List<AgentTaskLedgerEntry> taskLedger;
  final Map<String, String> chatSubjects;

  @override
  int get taskSubjectRevision => 0;

  @override
  String? chatThreadSubject(String threadId) => chatSubjects[threadId];

  @override
  String? knowledgeAssetSubject(String localNoteId) => null;

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

String _identifierOfLength(String prefix, int length) =>
    '$prefix${List<String>.filled(length - prefix.length, 'a').join()}';

KnowledgeLibraryController _populateAggregationSources(
  KnowledgeLibraryController library,
  DateTime now,
) {
  for (var index = 0; index < 4; index++) {
    library.updateNote(
      V3FeedItem(
        id: 'production-$index',
        remoteNoteId: 'remote-$index',
        remoteSourceKind: 'manual',
        rawPartRevisionId: 'raw-$index',
        title: '来源 $index',
        source: V3MaterialSource.note,
        createdAt: now,
        rawBody: '正文',
      ),
    );
  }
  return library;
}
