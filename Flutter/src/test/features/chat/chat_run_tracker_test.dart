import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_reconciliation.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'assistant_runtime_test_adapter.dart';

void main() {
  test(
    'terminal reconciliation has bounded recoverable and restart-safe transitions',
    () {
      final now = DateTime.utc(2026, 9, 10);
      final state = ChatRunReconciliation();
      for (
        var attempt = 0;
        attempt < ChatRunReconciliation.maximumAutomaticFailures;
        attempt++
      ) {
        final time = now.add(Duration(seconds: attempt));
        expect(state.beginAttempt(time), isTrue);
        expect(state.beginAttempt(time), isFalse);
        state.fail(
          code: 'API_RESPONSE_INVALID',
          retryAt: time.add(const Duration(seconds: 1)),
        );
        expect(state.snapshot.failures, attempt + 1);
        expect(state.beginAttempt(time), isFalse);
      }
      expect(state.snapshot.phase, ChatRunReconciliationPhase.recoveryRequired);
      final restored = ChatRunReconciliation.fromJson(state.toJson());
      expect(restored.canScheduleAutomatically, isFalse);
      expect(restored.beginAttempt(now.add(const Duration(days: 1))), isFalse);
      expect(restored.beginAttempt(now, userInitiated: true), isTrue);
      expect(restored.snapshot.failures, 0);
      final interrupted = ChatRunReconciliation.fromJson(restored.toJson());
      expect(
        interrupted.snapshot.phase,
        ChatRunReconciliationPhase.awaitingReadback,
      );
      expect(interrupted.beginAttempt(now), isTrue);
      interrupted.cancelAttempt();
      expect(interrupted.snapshot.failures, 0);
      expect(interrupted.beginAttempt(now), isTrue);
      interrupted.settle();
      expect(interrupted.beginAttempt(now, userInitiated: true), isFalse);
      expect(
        ChatRunReconciliation.fromJson({'phase': 'settled'}).snapshot.phase,
        ChatRunReconciliationPhase.awaitingReadback,
      );
    },
  );

  test(
    'restored succeeded checkpoint settles fractional video result without reopening SSE',
    () async {
      const scope = 'account-video-terminal-recovery';
      final worker = _CheckpointWorker()
        ..seed(
          ChatRunCheckpoint(
            userScope: scope,
            runId: 'agent_run_tracker_1',
            kind: ChatRunCheckpointKind.chat,
            role: ChatRunCheckpointRole.active,
            status: 'succeeded',
            eventSequence: 77,
            threadId: 'thread-a',
            scene: 'feed_ai',
            purpose: 'general',
            createdAt: DateTime.utc(2026, 9, 10),
            updatedAt: DateTime.utc(2026, 9, 10),
            publicState: <String, Object?>{
              'kind': 'chat',
              'agentRunId': 'agent_run_tracker_1',
              'threadId': 'thread-a',
              'scene': 'feed_ai',
              'purpose': 'general',
              'status': 'succeeded',
              'createdAt': '2026-09-10T00:00:00Z',
              'lastStreamSequence': 77,
              'toolTrace': <Object?>[],
            },
          ),
        );
      final response = AgentRunSnapshot.fromValue(<String, Object?>{
        'agentRunId': 'agent_run_tracker_1',
        'threadId': 'thread-a',
        'workspaceId': 'workspace-1',
        'status': 'succeeded',
        'workspaceVersion': 1,
        'workspaceBindingVersion': 1,
        'contextGeneration': 1,
        'assistantMessageId': 'assistant-video-result',
        'completionMode': 'normal',
        'result': {
          'assistantMessageId': 'assistant-video-result',
          'completionMode': 'normal',
          'finalAnswer': 'video analysis completed',
        },
        'usage': {
          'measurementStatus': 'measured',
          'inputTokens': 135890,
          'outputTokens': 19174,
          'imageCount': null,
          'videoSeconds': 36.734,
          'accountedCredits': 225323,
          'policyVersion': 'credit-policy-v1',
        },
        'toolTrace': <Object?>[],
        'createdAt': '2026-09-10T00:00:00Z',
        'updatedAt': '2026-09-10T00:03:27Z',
      });
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      final runs = _StreamingRunPort(
        events: events,
        results: [_success(response)],
      );
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: scope,
        checkpointPersistence: persistence,
      );
      addTearDown(() async {
        tracker.dispose();
        await events.close();
        queue.dispose();
      });
      await tracker.start();
      await tracker.recoverThread('thread-a');
      await tracker.flushCheckpointPersistence();
      expect(runs.streamLastEventIds, isEmpty);
      expect(runs.pollCalls, hasLength(1));
      expect(tracker.needsThreadReconciliation('thread-a'), isFalse);
      expect(
        tracker.lastCompletion?.assistantMessageId,
        'assistant-video-result',
      );
      final persisted = worker.rowsFor(scope).single;
      expect(persisted.role, ChatRunCheckpointRole.ledger);
      expect(
        (persisted.publicState['completion'] as Map)['assistantMessageId'],
        'assistant-video-result',
      );
      expect(
        persisted.publicState.toString(),
        isNot(contains('video analysis completed')),
      );
    },
  );

  testWidgets(
    'terminal readback exhausts automatic retries and joins manual recovery',
    (tester) async {
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      final recovered = Completer<ApiResult<AgentRunSnapshot>>();
      final failure = ApiResult<AgentRunSnapshot>.failure(
        error: const AppFailure(
          code: 'API_RESPONSE_INVALID',
          category: AppFailureCategory.api,
          message: 'invalid result',
          userMessageKey: 'error.api.responseInvalid',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
      final runs = _StreamingRunPort(
        events: events,
        results: [
          _success(_run(status: 'running')),
          failure,
          failure,
          failure,
          failure,
          recovered.future,
        ],
      );
      final orchestrator = TaskOrchestrator();
      final preferences = AppPreferencesDao(AppDatabase());
      ChatRunTracker createTracker() => ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: preferences,
        userScope: 'account-bounded-recovery',
        taskOrchestrator: orchestrator,
        pollInterval: const Duration(milliseconds: 10),
        fallbackMaximumDelay: const Duration(milliseconds: 40),
        eventStreamSilentTimeout: const Duration(days: 1),
        now: () => tester.binding.clock.now().toUtc(),
        randomDouble: () => 0.5,
      );
      var tracker = createTracker();
      addTearDown(() async {
        tracker.dispose();
        orchestrator.dispose();
        await events.close();
      });
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await tester.pump();
      expect(runs.pollCalls, hasLength(1));
      events.add(
        _streamEvent({
          'sequence': 77,
          'eventType': 'succeeded',
          'status': 'succeeded',
          'data': {'status': 'succeeded'},
          'createdAt': '2026-09-10T00:00:00Z',
        }),
      );
      await tester.pump();
      for (final milliseconds in [10, 20, 40, 80, 160]) {
        await tester.pump(Duration(milliseconds: milliseconds));
      }
      expect(runs.pollCalls, hasLength(5));
      expect(tracker.isThreadPending('thread-a'), isFalse);
      expect(tracker.needsThreadReconciliation('thread-a'), isTrue);
      expect(
        tracker.reconciliationForThread('thread-a')?.phase,
        ChatRunReconciliationPhase.recoveryRequired,
      );
      final serialized = preferences
          .listPreferences()
          .map((row) => row['value'])
          .whereType<String>()
          .firstWhere((value) => value.contains('reconciliation'));
      final persisted = jsonDecode(serialized) as Map;
      final active = (persisted['active'] as List).single as Map;
      expect(
        (active['reconciliation'] as Map)['failureCode'],
        'API_RESPONSE_INVALID',
      );
      await tester.pump(const Duration(minutes: 1));
      expect(runs.pollCalls, hasLength(5));
      expect(runs.streamLastEventIds, hasLength(1));
      tracker.dispose();
      tracker = createTracker();
      await tracker.start();
      await tester.pump(const Duration(minutes: 1));
      expect(runs.pollCalls, hasLength(5));
      expect(runs.streamLastEventIds, hasLength(1));
      expect(
        tracker.reconciliationForThread('thread-a')?.phase,
        ChatRunReconciliationPhase.recoveryRequired,
      );
      final first = tracker.recoverThread('thread-a');
      final second = tracker.recoverThread('thread-a');
      await tester.pump();
      expect(runs.pollCalls, hasLength(6));
      recovered.complete(
        _success(
          _run(
            status: 'succeeded',
            assistantMessageId: 'assistant-recovered',
            completionMode: 'normal',
          ),
        ),
      );
      await tester.pump();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(tracker.needsThreadReconciliation('thread-a'), isFalse);
      expect(tracker.completionSequence, 1);
    },
  );

  test('old terminal read cannot settle or displace a resumed read', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    final stale = Completer<ApiResult<AgentRunSnapshot>>();
    final current = Completer<ApiResult<AgentRunSnapshot>>();
    final runs = _StreamingRunPort(
      events: events,
      results: [stale.future, current.future],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-terminal-generation',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(() async {
      tracker.dispose();
      await events.close();
    });
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);
    events.add(
      _streamEvent({
        'sequence': 77,
        'eventType': 'succeeded',
        'status': 'succeeded',
        'data': {'status': 'succeeded'},
        'createdAt': '2026-09-10T00:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    tracker.pause();
    await tracker.resume();
    await Future<void>.delayed(Duration.zero);
    expect(runs.pollCalls, hasLength(2));
    stale.complete(
      _success(
        _run(
          status: 'succeeded',
          assistantMessageId: 'assistant-stale',
          completionMode: 'normal',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(tracker.lastCompletion, isNull);
    final recovery = tracker.recoverThread('thread-a');
    expect(runs.pollCalls, hasLength(2));
    current.complete(
      _success(
        _run(
          status: 'succeeded',
          assistantMessageId: 'assistant-current',
          completionMode: 'normal',
        ),
      ),
    );
    expect(await recovery, isTrue);
    expect(tracker.lastCompletion?.assistantMessageId, 'assistant-current');
    expect(runs.streamLastEventIds, hasLength(1));
  });

  test('publishes one ID-keyed ledger delta per task mutation', () async {
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-ledger-delta',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);

    await tracker.track(
      agentRunId: 'agent_run_delta_1',
      threadId: 'thread-delta',
      scene: ChatScene.feedAi,
    );

    expect(tracker.taskLedgerDeltaSequence, 1);
    expect(tracker.lastTaskLedgerDelta!.reset, isFalse);
    expect(tracker.lastTaskLedgerDelta!.upserts.keys, <String>{
      'agent_run_delta_1',
    });
    expect(tracker.lastTaskLedgerDelta!.removedTaskIds, isEmpty);

    await tracker.track(
      agentRunId: 'agent_run_delta_1',
      threadId: 'thread-delta',
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    expect(tracker.taskLedgerDeltaSequence, 2);
    expect(
      tracker.lastTaskLedgerDelta!.upserts['agent_run_delta_1']?.purpose,
      ChatConversationPurpose.deepPositioning,
    );

    await tracker.track(
      agentRunId: 'agent_run_delta_1',
      threadId: 'thread-delta',
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    expect(tracker.taskLedgerDeltaSequence, 2);

    tracker.clearForLogout();
    expect(tracker.taskLedgerDeltaSequence, 3);
    expect(tracker.lastTaskLedgerDelta!.reset, isTrue);
  });

  test('thread Run family ignores mutations for another thread', () async {
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-thread-family',
      pollInterval: const Duration(days: 1),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        chatRunTrackerProvider.overrideWith((ref) => tracker),
      ],
    );
    addTearDown(container.dispose);
    var threadANotifications = 0;
    var threadBNotifications = 0;
    final threadA = container.listen<ChatThreadRunState>(
      chatThreadRunStateProvider('thread-a'),
      (_, __) => threadANotifications += 1,
    );
    final threadB = container.listen<ChatThreadRunState>(
      chatThreadRunStateProvider('thread-b'),
      (_, __) => threadBNotifications += 1,
    );
    addTearDown(threadA.close);
    addTearDown(threadB.close);

    await tracker.track(
      agentRunId: 'agent_run_family_a_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await container.pump();
    expect(threadANotifications, 1);
    expect(threadBNotifications, 0);
    expect(threadA.read().activities.single.agentRunId, 'agent_run_family_a_1');
    expect(
      container
          .read(
            chatRunActivityProvider((
              threadId: 'thread-a',
              agentRunId: 'agent_run_family_a_1',
            )),
          )
          ?.status,
      'queued',
    );

    await tracker.track(
      agentRunId: 'agent_run_family_b_1',
      threadId: 'thread-b',
      scene: ChatScene.feedAi,
    );
    await container.pump();
    expect(threadANotifications, 1);
    expect(threadBNotifications, 1);
  });

  test('restores one content-free Run row from worker persistence', () async {
    final worker = _CheckpointWorker();
    final queue = DatabaseWriteQueue();
    final persistence = ChatRunCheckpointPersistence(
      worker: worker,
      writeQueue: queue,
    );
    addTearDown(queue.dispose);
    final admitted = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-worker-restore',
      checkpointPersistence: persistence,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(admitted.dispose);

    await admitted.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    await admitted.flushCheckpointPersistence();

    final row = worker.rowsFor('account-worker-restore').single;
    expect(row.runId, 'agent_run_tracker_1');
    expect(row.role, ChatRunCheckpointRole.active);
    expect(row.publicState['threadId'], 'thread-a');
    expect(row.publicState['purpose'], 'deep_positioning');
    expect(row.publicState.toString(), isNot(contains('assistantMessage')));
    expect(row.publicState.toString(), isNot(contains('deltaText')));
    expect(row.publicState.toString(), isNot(contains('ledger')));

    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-worker-restore',
      checkpointPersistence: persistence,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);
    await restored.start();

    expect(restored.hasPendingRuns, isTrue);
    expect(
      restored
          .activityFor(threadId: 'thread-a', agentRunId: 'agent_run_tracker_1')
          ?.status,
      'queued',
    );
  });

  test(
    'retries failed initial worker restore before replacing checkpoints',
    () async {
      const scope = 'account-worker-restore-retry';
      final worker = _CheckpointWorker(remainingLoadFailures: 1)
        ..seed(_checkpointFor(scope, runId: 'agent_run_restored_1'));
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: scope,
        checkpointPersistence: persistence,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(() async {
        tracker.dispose();
        await queue.dispose();
      });

      await tracker.start();
      expect(worker.loadAttempts, 1);
      expect(tracker.hasPendingRuns, isFalse);
      expect(tracker.canTrackAcceptedRuns, isFalse);

      await tracker.trackAcceptedRun(
        agentRunId: 'agent_run_new_1',
        publicTaskId: null,
        threadId: 'thread-new-1',
        scene: ChatScene.feedAi,
      );
      await tracker.flushCheckpointPersistence();

      expect(worker.loadAttempts, greaterThanOrEqualTo(2));
      expect(tracker.canTrackAcceptedRuns, isTrue);
      expect(
        worker.rowsFor(scope).map((checkpoint) => checkpoint.runId).toSet(),
        <String>{'agent_run_restored_1', 'agent_run_new_1'},
      );
    },
  );

  test('derived enrollment waits for its exact durable checkpoint', () async {
    const scope = 'account-derived-durable-admission';
    final changeGate = Completer<void>();
    final worker = _CheckpointWorker(changeGate: changeGate);
    final queue = DatabaseWriteQueue();
    final persistence = ChatRunCheckpointPersistence(
      worker: worker,
      writeQueue: queue,
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: scope,
      checkpointPersistence: persistence,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(() async {
      tracker.dispose();
      await queue.dispose();
    });
    await tracker.start();

    var completed = false;
    final enrollment = tracker
        .trackDerivedPart(
          fileAgentRunId: 'file-run-durable-outline',
          agentRunId: 'agent-run-durable-outline',
          status: 'queued',
          localNoteId: 'local-note-durable-outline',
          remoteNoteId: 'remote-note-durable-outline',
          targetPart: NoteFileAgentPart.outline,
          inputPartRevisionId: 'raw-revision-durable-outline',
          targetPartRevisionId: 'outline-revision-durable-outline',
          operationId: 'operation-durable-outline',
        )
        .then((_) => completed = true);

    await worker.firstChangeStarted;
    expect(completed, isFalse);
    expect(worker.rowsFor(scope), isEmpty);

    changeGate.complete();
    await enrollment;

    final checkpoint = worker.rowsFor(scope).single;
    expect(checkpoint.runId, 'file-run-durable-outline');
    expect(checkpoint.role, ChatRunCheckpointRole.active);
    expect(
      checkpoint.publicState['remoteNoteId'],
      'remote-note-durable-outline',
    );
    expect(
      checkpoint.publicState['inputPartRevisionId'],
      'raw-revision-durable-outline',
    );
    expect(
      checkpoint.publicState['targetPartRevisionId'],
      'outline-revision-durable-outline',
    );
    expect(checkpoint.publicState['operationId'], 'operation-durable-outline');
    expect(checkpoint.publicState['agentRunId'], 'agent-run-durable-outline');
  });

  test('disposed tracker does not publish after durable enrollment', () async {
    const scope = 'account-derived-dispose-during-admission';
    final changeGate = Completer<void>();
    final worker = _CheckpointWorker(changeGate: changeGate);
    final queue = DatabaseWriteQueue();
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: scope,
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      ),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(() async {
      if (!changeGate.isCompleted) changeGate.complete();
      await queue.dispose();
    });
    await tracker.start();
    var notifications = 0;
    tracker.addListener(() => notifications += 1);

    final enrollment = tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-disposed-outline',
      agentRunId: 'agent-run-disposed-outline',
      status: 'queued',
      localNoteId: 'local-note-disposed-outline',
      remoteNoteId: 'remote-note-disposed-outline',
      targetPart: NoteFileAgentPart.outline,
    );
    await worker.firstChangeStarted;

    tracker.dispose();
    changeGate.complete();

    await expectLater(enrollment, completes);
    expect(notifications, 0);
  });

  test('accepted Chat enrollment waits for its named checkpoint', () async {
    const scope = 'account-chat-durable-admission';
    final changeGate = Completer<void>();
    final worker = _CheckpointWorker(changeGate: changeGate);
    final queue = DatabaseWriteQueue();
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: scope,
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      ),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(() async {
      if (!changeGate.isCompleted) changeGate.complete();
      tracker.dispose();
      await queue.dispose();
    });
    await tracker.start();
    await tracker.rememberChatThreadSubject(
      threadId: 'thread-a',
      subjectTitle: '客户回访复盘',
    );

    var completed = false;
    final enrollment = tracker
        .trackAcceptedRun(
          agentRunId: 'agent_run_tracker_1',
          publicTaskId: 'public_chat_durable_1',
          threadId: 'thread-a',
          scene: ChatScene.feedAi,
        )
        .then((_) => completed = true);

    await worker.firstChangeStarted;
    expect(completed, isFalse);
    expect(worker.rowsFor(scope), isEmpty);

    changeGate.complete();
    await enrollment;

    final checkpoint = worker.rowsFor(scope).single;
    expect(checkpoint.runId, 'agent_run_tracker_1');
    expect(checkpoint.publicState['publicTaskId'], 'public_chat_durable_1');
    expect(checkpoint.publicState['subjectTitle'], '客户回访复盘');
  });

  test(
    'derived enrollment completes its legacy fallback on the shared queue',
    () async {
      const scope = 'account-derived-shared-queue-fallback';
      final checkpointWorker = _CheckpointWorker(failChanges: true);
      final preferenceWorker = _PreferenceWorker();
      final queue = DatabaseWriteQueue();
      final preferences = AppPreferencesDao(
        AppDatabase(),
        worker: preferenceWorker,
        writeQueue: queue,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: scope,
        checkpointPersistence: ChatRunCheckpointPersistence(
          worker: checkpointWorker,
          writeQueue: queue,
        ),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(() async {
        tracker.dispose();
        await queue.dispose();
      });
      await tracker.start();

      await tracker
          .trackDerivedPart(
            fileAgentRunId: 'file-run-shared-queue-outline',
            agentRunId: 'agent-run-shared-queue-outline',
            status: 'queued',
            localNoteId: 'local-note-shared-queue-outline',
            remoteNoteId: 'remote-note-shared-queue-outline',
            targetPart: NoteFileAgentPart.outline,
            inputPartRevisionId: 'raw-revision-shared-queue-outline',
            targetPartRevisionId: 'outline-revision-shared-queue-outline',
            operationId: 'operation-shared-queue-outline',
          )
          .timeout(const Duration(seconds: 1));

      expect(checkpointWorker.changeAttempts, 1);
      expect(preferenceWorker.upsertAttempts, 1);
      final legacyRecord = preferenceWorker.records.single;
      expect(legacyRecord['preference_key'], startsWith('chat-run-pending-'));
      final checkpoint = jsonDecode(legacyRecord['value']! as String);
      expect(
        checkpoint['active'].single['fileAgentRunId'],
        'file-run-shared-queue-outline',
      );
    },
  );

  test(
    'logout tombstone follows an in-flight failed checkpoint fallback',
    () async {
      const scope = 'account-checkpoint-logout-race';
      final changeGate = Completer<void>();
      final checkpointWorker = _CheckpointWorker(
        failChanges: true,
        changeGate: changeGate,
      );
      final preferenceWorker = _PreferenceWorker();
      final queue = DatabaseWriteQueue();
      final preferences = AppPreferencesDao(
        AppDatabase(),
        worker: preferenceWorker,
        writeQueue: queue,
      );
      final persistence = ChatRunCheckpointPersistence(
        worker: checkpointWorker,
        writeQueue: queue,
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: scope,
        checkpointPersistence: persistence,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(() async {
        tracker.dispose();
        await queue.dispose();
      });
      await tracker.start();

      final enrollment = tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-before-logout',
        agentRunId: 'agent-run-before-logout',
        status: 'queued',
        localNoteId: 'local-note-before-logout',
        remoteNoteId: 'remote-note-before-logout',
        targetPart: NoteFileAgentPart.outline,
        inputPartRevisionId: 'raw-revision-before-logout',
        targetPartRevisionId: 'outline-revision-before-logout',
        operationId: 'operation-before-logout',
      );
      await checkpointWorker.firstChangeStarted;

      var notifications = 0;
      tracker.addListener(() => notifications += 1);
      tracker.clearForLogout();
      final logoutNotifications = notifications;
      changeGate.complete();
      await enrollment;
      await tracker.flushCheckpointPersistence();

      expect(notifications, logoutNotifications);
      expect(tracker.taskLedger, isEmpty);
      final legacyRecord = preferenceWorker.records.single;
      final checkpoint = jsonDecode(legacyRecord['value']! as String);
      expect(checkpoint['active'], isEmpty);
      expect(checkpoint['ledger'], isEmpty);

      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: scope,
        checkpointPersistence: persistence,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();
      expect(restored.hasPendingRuns, isFalse);
      expect(restored.taskLedger, isEmpty);
    },
  );

  test(
    'worker clear enumerates persisted rows before the first load',
    () async {
      const scope = 'account-worker-clear-before-load';
      final worker = _CheckpointWorker()
        ..seed(_checkpointFor(scope, runId: 'persisted-before-load'));
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      var fallbackCalls = 0;

      await persistence.clear(
        userScope: scope,
        legacyFallback: () => fallbackCalls += 1,
      );
      await persistence.flush();

      expect(worker.rowsFor(scope), isEmpty);
      expect(fallbackCalls, 1);
    },
  );

  test('worker restore compares each row with the legacy snapshot', () async {
    const scope = 'account-worker-per-row-freshness';
    final preferences = AppPreferencesDao(AppDatabase());
    final legacy = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: scope,
      now: () => DateTime.utc(2026, 9, 2, 10),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(legacy.dispose);
    await legacy.track(
      agentRunId: 'agent_run_legacy_current',
      threadId: 'thread-legacy-current',
      scene: ChatScene.feedAi,
    );

    final worker = _CheckpointWorker()
      ..seed(
        _checkpointFor(
          scope,
          runId: 'agent_run_stale_worker',
          updatedAt: DateTime.utc(2026, 9, 2, 9),
        ),
      )
      ..seed(
        _checkpointFor(
          scope,
          runId: 'agent_run_fresh_worker',
          updatedAt: DateTime.utc(2026, 9, 2, 11),
        ),
      );
    final queue = DatabaseWriteQueue();
    final persistence = ChatRunCheckpointPersistence(
      worker: worker,
      writeQueue: queue,
    );
    addTearDown(queue.dispose);
    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: scope,
      checkpointPersistence: persistence,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);

    await restored.start();

    final taskIds = restored.taskLedger.map((entry) => entry.taskId).toSet();
    expect(
      taskIds,
      containsAll(<String>[
        'agent_run_legacy_current',
        'agent_run_fresh_worker',
      ]),
    );
    expect(taskIds, isNot(contains('agent_run_stale_worker')));
  });

  test('accepted Run waits for worker hydration before enrollment', () async {
    const scope = 'account-worker-live-terminal';
    final loadGate = Completer<void>();
    final worker = _CheckpointWorker(loadGate: loadGate)
      ..seed(_checkpointFor(scope, runId: 'agent_run_tracker_1'));
    final queue = DatabaseWriteQueue();
    final persistence = ChatRunCheckpointPersistence(
      worker: worker,
      writeQueue: queue,
    );
    addTearDown(queue.dispose);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'succeeded')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: scope,
      checkpointPersistence: persistence,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);

    final started = tracker.start();
    await worker.firstLoadStarted;
    final accepted = tracker.trackAcceptedRun(
      agentRunId: 'agent_run_tracker_1',
      publicTaskId: 'public-task-live-terminal',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);
    loadGate.complete();
    await Future.wait(<Future<void>>[started, accepted]);
    await Future<void>.delayed(Duration.zero);
    await tracker.flushCheckpointPersistence();

    expect(tracker.hasPendingRuns, isFalse);
    expect(tracker.taskLedger, hasLength(1));
    expect(tracker.taskLedger.single.status, 'succeeded');
    expect(tracker.taskLedger.single.publicTaskId, 'public-task-live-terminal');
  });

  test('pre-start Chat replay cannot revive a terminal Run', () async {
    const scope = 'account-pre-start-chat-terminal';
    final preferences = AppPreferencesDao(AppDatabase());
    final first = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'succeeded')),
      ),
      preferences: preferences,
      userScope: scope,
      pollInterval: const Duration(days: 1),
    );
    await first.start();
    await first.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.taskLedger.single.status, 'succeeded');
    first.dispose();

    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: scope,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);

    await restored.trackAcceptedRun(
      agentRunId: 'agent_run_tracker_1',
      publicTaskId: 'public-task-restored-terminal',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await restored.trackServerActiveRuns(
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
      runs: const <ChatActiveRun>[
        ChatActiveRun(agentRunId: 'agent_run_tracker_1', status: 'running'),
      ],
    );

    expect(restored.hasPendingRuns, isFalse);
    expect(restored.taskLedger, hasLength(1));
    expect(restored.taskLedger.single.status, 'succeeded');
    expect(
      restored.taskLedger.single.publicTaskId,
      'public-task-restored-terminal',
    );
    await restored.start();
    expect(restored.hasPendingRuns, isFalse);
  });

  test('pre-start derived replay cannot revive a terminal file Run', () async {
    const scope = 'account-pre-start-derived-terminal';
    final preferences = AppPreferencesDao(AppDatabase());
    const terminal = NoteFileAgentRunStatus(
      fileAgentRunId: 'file-run-pre-start-terminal',
      noteId: 'remote-note-pre-start-terminal',
      status: 'succeeded',
      outputPartRevisionId: 'outline-pre-start-r2',
    );
    final first = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      fileAgentRuns: const _PublicFileAgentRunPort(terminal),
      preferences: preferences,
      userScope: scope,
      pollInterval: const Duration(days: 1),
      onDerivedPartTerminal: (_) async => true,
    );
    await first.start();
    await first.trackDerivedPart(
      fileAgentRunId: terminal.fileAgentRunId,
      localNoteId: 'local-note-pre-start-terminal',
      remoteNoteId: terminal.noteId,
      targetPart: NoteFileAgentPart.outline,
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.taskLedger.single.status, 'succeeded');
    first.dispose();

    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: scope,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);

    await restored.trackDerivedPart(
      fileAgentRunId: terminal.fileAgentRunId,
      status: 'running',
      localNoteId: 'local-note-pre-start-terminal',
      remoteNoteId: terminal.noteId,
      targetPart: NoteFileAgentPart.outline,
    );

    expect(restored.hasPendingRuns, isFalse);
    expect(restored.taskLedger, hasLength(1));
    expect(restored.taskLedger.single.status, 'succeeded');
    expect(
      restored.taskLedger.single.outputPartRevisionId,
      'outline-pre-start-r2',
    );
    await restored.start();
    expect(restored.hasPendingRuns, isFalse);
  });

  test(
    'logout tombstone blocks a worker row when clear persistence fails',
    () async {
      const scope = 'account-worker-logout-tombstone';
      final worker = _CheckpointWorker(failChanges: true)
        ..seed(
          _checkpointFor(
            scope,
            runId: 'pre-logout-worker-run',
            updatedAt: DateTime.utc(2026, 9, 2, 9),
          ),
        );
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      final preferences = AppPreferencesDao(AppDatabase());
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: scope,
        checkpointPersistence: persistence,
        now: () => DateTime.utc(2026, 9, 2, 10),
      );
      addTearDown(tracker.dispose);

      tracker.clearForLogout();
      await tracker.flushCheckpointPersistence();
      expect(worker.rowsFor(scope), hasLength(1));

      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: scope,
        checkpointPersistence: persistence,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();

      expect(restored.hasPendingRuns, isFalse);
      expect(restored.taskLedger, isEmpty);
    },
  );

  test(
    'failed worker checkpoint diff invokes the captured legacy fallback',
    () async {
      final worker = _CheckpointWorker(failChanges: true);
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      var fallbackCalls = 0;

      await persistence.replace(
        userScope: 'account-worker-fallback',
        checkpoints: <ChatRunCheckpoint>[
          _checkpoint('account-worker-fallback'),
        ],
        legacyFallback: () => fallbackCalls += 1,
      );
      await persistence.flush();

      expect(worker.changeAttempts, 1);
      expect(worker.rowsFor('account-worker-fallback'), isEmpty);
      expect(fallbackCalls, 1);
    },
  );

  test(
    'restores only the matching account pending Run without reply content',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(first.dispose);
      await first.start();
      await first.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.deepPositioning,
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.hasPendingRuns, isTrue);
      final persisted = preferences
          .listPreferences()
          .map((record) => record['value'])
          .join();
      expect(persisted, contains('agent_run_tracker_1'));
      expect(persisted, contains('thread-a'));
      expect(persisted, contains('deep_positioning'));
      expect(persisted, isNot(contains('assistant reply')));

      final otherAccount = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'succeeded')),
        ),
        preferences: preferences,
        userScope: 'account-b',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(otherAccount.dispose);
      await otherAccount.start();
      expect(otherAccount.hasPendingRuns, isFalse);

      var notificationRefreshes = 0;
      final recovered = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(
            _run(
              status: 'succeeded',
              assistantMessageId: 'assistant-thread-a',
              completionMode: 'normal',
            ),
          ),
        ),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
        onTerminal: () async => notificationRefreshes += 1,
      );
      addTearDown(recovered.dispose);
      await recovered.start();
      await Future<void>.delayed(Duration.zero);

      expect(recovered.hasPendingRuns, isFalse);
      expect(recovered.lastCompletion?.threadId, 'thread-a');
      expect(recovered.lastCompletion?.status, 'succeeded');
      expect(
        recovered.lastCompletion?.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(
        recovered.lastCompletion?.assistantMessageId,
        'assistant-thread-a',
      );
      expect(recovered.lastCompletion?.completionMode, 'normal');
      expect(
        recovered.taskLedger.single.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(notificationRefreshes, 1);
    },
  );

  test('retains a failed poll for the next foreground refresh', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    final runs = _QueuedRunPort(<ApiResult<AgentRunSnapshot>>[
      ApiResult<AgentRunSnapshot>.failure(
        error: const AppFailure(
          code: 'NETWORK_UNAVAILABLE',
          category: AppFailureCategory.network,
          message: 'temporary',
          userMessageKey: 'temporary',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      ),
      _success(_run(status: 'succeeded')),
    ]);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: preferences,
      userScope: 'account-a',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);

    expect(tracker.hasPendingRuns, isTrue);
    await tracker.refresh();
    expect(tracker.hasPendingRuns, isFalse);
    expect(runs.calls, <String>['agent_run_tracker_1', 'agent_run_tracker_1']);
  });

  test('pause cancels an AgentRun read and drops its late result', () async {
    final runs = _CancellableRunPort();
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-cancellable-run',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.started.future;

    tracker.pause();
    expect(runs.cancelCalls, 1);

    runs.completeLate(
      _success(
        _run(
          status: 'succeeded',
          assistantMessageId: 'assistant-late',
          completionMode: 'normal',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tracker.threadRunStatus('thread-a'), 'queued');
    expect(tracker.lastCompletion, isNull);
    expect(tracker.hasPendingRuns, isTrue);
  });

  test('retains a backend-public workspace_list Tool trace', () async {
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(
          _run(
            status: 'running',
            toolTrace: <AgentRunToolTrace>[
              AgentRunToolTrace(
                invocationId: 'invocation_workspace_list',
                toolName: 'workspace_list',
                state: 'started',
                createdAt: DateTime.utc(2026, 8, 17, 8),
                outputFiles: const <AgentRunOutputFile>[],
              ),
            ],
          ),
        ),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-a',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      tracker.threadToolTrace('thread-a').single.toolName,
      'workspace_list',
    );
  });

  test(
    'projects activity only for the exact pending thread and Agent Run',
    () async {
      final trace = AgentRunToolTrace(
        invocationId: 'invocation-exact-activity',
        toolName: 'workspace_search',
        state: 'finished',
        outcome: 'succeeded',
        createdAt: DateTime.utc(2026, 8, 19, 8),
        completedAt: DateTime.utc(2026, 8, 19, 8, 0, 1),
        outputFiles: const <AgentRunOutputFile>[],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running', toolTrace: [trace])),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await Future<void>.delayed(Duration.zero);

      final activity = tracker.activityFor(
        threadId: 'thread-a',
        agentRunId: 'agent_run_tracker_1',
      );
      expect(activity, isNotNull);
      expect(activity!.status, 'running');
      expect(activity.toolTrace, hasLength(1));
      expect(activity.toolTrace.single.invocationId, trace.invocationId);
      expect(() => activity.toolTrace.add(trace), throwsUnsupportedError);
      expect(
        tracker.activityFor(
          threadId: 'other-thread',
          agentRunId: 'agent_run_tracker_1',
        ),
        isNull,
      );
      expect(
        tracker.activityFor(
          threadId: 'thread-a',
          agentRunId: 'other-agent-run',
        ),
        isNull,
      );
    },
  );

  test('replaces the provisional activity start with Run createdAt', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    final startedAt = DateTime.utc(2026, 8, 19, 7, 45);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running', createdAt: startedAt)),
      ),
      preferences: preferences,
      userScope: 'account-created-at',
      now: () => DateTime.utc(2026, 8, 19, 8),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      tracker
          .activityFor(threadId: 'thread-a', agentRunId: 'agent_run_tracker_1')
          ?.createdAt,
      startedAt,
    );
    expect(
      preferences.listPreferences().map((record) => record['value']).join(),
      contains(startedAt.toIso8601String()),
    );
  });

  test('uses Run createdAt after restoring a pending active run', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    final admitted = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: 'account-restored-created-at',
      pollInterval: const Duration(days: 1),
    );
    await admitted.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    admitted.dispose();

    final startedAt = DateTime.utc(2026, 8, 19, 7, 45);
    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running', createdAt: startedAt)),
      ),
      preferences: preferences,
      userScope: 'account-restored-created-at',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);
    await restored.start();
    await Future<void>.delayed(Duration.zero);

    expect(
      restored
          .activityFor(threadId: 'thread-a', agentRunId: 'agent_run_tracker_1')
          ?.createdAt,
      startedAt,
    );
  });

  test('uses Agent Run SSE for immediate public lifecycle activity', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    final runs = _StreamingRunPort(
      events: events,
      results: <ApiResult<AgentRunSnapshot>>[
        _success(
          _run(
            status: 'succeeded',
            assistantMessageId: 'assistant-streamed-1',
            completionMode: 'normal',
          ),
        ),
      ],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-a',
      pollInterval: const Duration(days: 1),
      draftEventInterval: Duration.zero,
    );
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);

    expect(runs.pollCalls, isEmpty);

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 1,
        'eventType': 'tool_started',
        'status': 'running',
        'data': <String, Object?>{
          'status': 'running',
          'invocationId': 'invocation-stream-1',
          'toolName': 'workspace_search',
          'state': 'started',
        },
        'createdAt': '2026-08-18T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(tracker.threadRunStatus('thread-a'), 'running');
    expect(
      tracker.threadToolTrace('thread-a').single.toolName,
      'workspace_search',
    );

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 2,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '第一段流式回复', 'replace': true},
        'createdAt': '2026-08-18T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(tracker.draftDeltaSequence, 1);
    expect(tracker.lastDraftDelta?.agentRunId, 'agent_run_tracker_1');
    expect(tracker.lastDraftDelta?.threadId, 'thread-a');
    expect(tracker.lastDraftDelta?.deltaText, '第一段流式回复');
    expect(tracker.lastDraftDelta?.replace, isTrue);
    expect(
      tracker
          .draftSnapshotFor(
            threadId: 'thread-a',
            agentRunId: 'agent_run_tracker_1',
          )
          ?.text,
      '第一段流式回复',
    );

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 2,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '不应重复'},
        'createdAt': '2026-08-18T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(tracker.draftDeltaSequence, 1);
    expect(tracker.lastDraftDelta?.deltaText, '第一段流式回复');

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 3,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '，第二段'},
        'createdAt': '2026-08-18T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final assembled = tracker.draftSnapshotFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(assembled?.eventSequence, 3);
    expect(assembled?.text, '第一段流式回复，第二段');

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 4,
        'eventType': 'succeeded',
        'status': 'succeeded',
        'data': <String, Object?>{'status': 'succeeded'},
        'createdAt': '2026-08-18T08:00:01Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tracker.hasPendingRuns, isFalse);
    expect(tracker.lastCompletion?.assistantMessageId, 'assistant-streamed-1');
    expect(
      tracker.completionsForThread('thread-a').single.assistantMessageId,
      'assistant-streamed-1',
    );
    expect(
      tracker
          .activityFor(threadId: 'thread-a', agentRunId: 'agent_run_tracker_1')
          ?.isTerminal,
      isTrue,
    );
    expect(runs.pollCalls, <String>['agent_run_tracker_1']);
  });

  test('coalesces 1000 healthy SSE deltas without fallback polling', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(events.close);
    final runs = _StreamingRunPort(
      events: events,
      results: const <ApiResult<AgentRunSnapshot>>[],
    );
    var checkpointWrites = 0;
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-stream-budget',
      pollInterval: const Duration(milliseconds: 1),
      eventStreamReconnectDelay: const Duration(days: 1),
      eventStreamSilentTimeout: const Duration(days: 1),
      checkpointInterval: const Duration(milliseconds: 10),
      draftEventInterval: const Duration(milliseconds: 10),
      randomDouble: () => 0.5,
      onCheckpointPersisted: () => checkpointWrites += 1,
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 1,
        'eventType': 'run_started',
        'status': 'running',
        'data': <String, Object?>{'status': 'running'},
        'createdAt': '2026-08-31T08:00:00Z',
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 25));

    checkpointWrites = 0;
    var notifications = 0;
    tracker.addListener(() => notifications += 1);
    for (var index = 0; index < 1000; index += 1) {
      events.add(
        _streamEvent(<String, Object?>{
          'sequence': index + 2,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{
            'deltaText': 'x',
            if (index == 0) 'replace': true,
          },
          'createdAt': '2026-08-31T08:00:01Z',
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(runs.pollCalls, isEmpty);
    expect(tracker.draftDeltaSequence, 1);
    expect(tracker.lastDraftDelta?.eventSequence, 1001);
    expect(tracker.lastDraftDelta?.deltaText.length, 1000);
    expect(tracker.lastDraftDelta?.replace, isTrue);
    expect(notifications, 1);
    expect(checkpointWrites, 1);
  });

  test('healthy SSE refreshes public tool trace from Run snapshots', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(events.close);
    final createdAt = DateTime.utc(2026, 9, 1, 8);
    final runs = _SnapshotStreamingRunPort(
      events: events,
      snapshots: <AgentRunSnapshot>[
        _run(
          status: 'running',
          toolTrace: <AgentRunToolTrace>[
            AgentRunToolTrace(
              invocationId: 'tool_public_snapshot',
              toolName: 'workspace_search',
              state: 'started',
              createdAt: createdAt,
              outputFiles: const <AgentRunOutputFile>[],
            ),
          ],
        ),
        _run(
          status: 'running',
          toolTrace: <AgentRunToolTrace>[
            AgentRunToolTrace(
              invocationId: 'tool_public_snapshot',
              toolName: 'workspace_search',
              state: 'finished',
              outcome: 'succeeded',
              createdAt: createdAt,
              completedAt: createdAt.add(const Duration(seconds: 1)),
              outputFiles: const <AgentRunOutputFile>[],
            ),
          ],
        ),
      ],
    );
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-tool-snapshot',
      pollInterval: const Duration(milliseconds: 5),
      eventStreamSilentTimeout: const Duration(days: 1),
      fallbackMaximumDelay: const Duration(milliseconds: 5),
      taskOrchestrator: orchestrator,
      randomDouble: () => 0.5,
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    for (var attempt = 0; attempt < 20; attempt += 1) {
      final state = tracker
          .activityFor(threadId: 'thread-a', agentRunId: 'agent_run_tracker_1')
          ?.toolTrace
          .singleOrNull
          ?.state;
      if (state == 'finished') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final activity = tracker.activityFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(runs.pollCalls, greaterThanOrEqualTo(2));
    expect(activity?.toolTrace.single.state, 'finished');
    expect(activity?.toolTrace.single.outcome, 'succeeded');

    tracker.pause();
    final pausedCalls = runs.pollCalls;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(runs.pollCalls, pausedCalls);
  });

  test(
    'in-flight Run snapshot cannot regress newer SSE state or tool',
    () async {
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(events.close);
      final staleReadback = Completer<ApiResult<AgentRunSnapshot>>();
      final createdAt = DateTime.utc(2026, 9, 2, 8);
      final runs = _StreamingRunPort(
        events: events,
        results: <FutureOr<ApiResult<AgentRunSnapshot>>>[staleReadback.future],
      );
      final orchestrator = TaskOrchestrator();
      addTearDown(orchestrator.dispose);
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-monotonic-run-snapshot',
        pollInterval: const Duration(days: 1),
        eventStreamSilentTimeout: const Duration(days: 1),
        taskOrchestrator: orchestrator,
        randomDouble: () => 0.5,
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await runs.streamOpened.future;
      await Future<void>.delayed(Duration.zero);
      for (
        var attempt = 0;
        attempt < 20 && runs.pollCalls.isEmpty;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(runs.pollCalls, <String>['agent_run_tracker_1']);

      events
        ..add(
          _streamEvent(<String, Object?>{
            'sequence': 1,
            'eventType': 'tool_started',
            'status': 'running',
            'data': <String, Object?>{
              'invocationId': 'tool-racing-snapshot',
              'toolName': 'workspace_search',
              'state': 'started',
            },
            'createdAt': '2026-09-02T08:00:00Z',
          }),
        )
        ..add(
          _streamEvent(<String, Object?>{
            'sequence': 2,
            'eventType': 'tool_finished',
            'status': 'running',
            'data': <String, Object?>{
              'invocationId': 'tool-racing-snapshot',
              'toolName': 'workspace_search',
              'state': 'finished',
              'outcome': 'succeeded',
            },
            'createdAt': '2026-09-02T08:00:01Z',
          }),
        )
        ..add(
          _streamEvent(<String, Object?>{
            'sequence': 3,
            'eventType': 'tool_rejected',
            'status': 'running',
            'data': <String, Object?>{
              'invocationId': 'tool-terminal-enrichment',
              'toolName': 'workspace_search',
              'state': 'rejected',
            },
            'createdAt': '2026-09-02T08:00:02Z',
          }),
        );
      await Future<void>.delayed(Duration.zero);

      staleReadback.complete(
        _success(
          _run(
            status: 'planning',
            toolTrace: <AgentRunToolTrace>[
              AgentRunToolTrace(
                invocationId: 'tool-racing-snapshot',
                toolName: 'workspace_search',
                state: 'started',
                createdAt: createdAt,
                outputFiles: const <AgentRunOutputFile>[],
              ),
              AgentRunToolTrace(
                invocationId: 'tool-terminal-enrichment',
                toolName: 'workspace_search',
                state: 'rejected',
                outcome: 'failed',
                createdAt: createdAt,
                completedAt: createdAt.add(const Duration(seconds: 2)),
                outputFiles: const <AgentRunOutputFile>[
                  AgentRunOutputFile(
                    resourceId: 'resource-tool-receipt',
                    fileName: 'receipt.txt',
                    mimeType: 'text/plain',
                    sizeBytes: 12,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final activity = tracker.activityFor(
        threadId: 'thread-a',
        agentRunId: 'agent_run_tracker_1',
      );
      expect(activity?.status, 'running');
      expect(activity?.toolTrace, hasLength(2));
      final racingReceipt = activity!.toolTrace.singleWhere(
        (trace) => trace.invocationId == 'tool-racing-snapshot',
      );
      expect(racingReceipt.state, 'finished');
      expect(racingReceipt.outcome, 'succeeded');
      final enrichedReceipt = activity.toolTrace.singleWhere(
        (trace) => trace.invocationId == 'tool-terminal-enrichment',
      );
      expect(enrichedReceipt.state, 'rejected');
      expect(enrichedReceipt.outcome, 'failed');
      expect(
        enrichedReceipt.completedAt,
        createdAt.add(const Duration(seconds: 2)),
      );
      expect(
        enrichedReceipt.outputFiles.single.resourceId,
        'resource-tool-receipt',
      );
    },
  );

  test(
    'stale fallback GET cannot lower status after SSE disconnects',
    () async {
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(() async {
        if (!events.isClosed) await events.close();
      });
      final staleReadback = Completer<ApiResult<AgentRunSnapshot>>();
      final runs = _StreamingRunPort(
        events: events,
        results: <FutureOr<ApiResult<AgentRunSnapshot>>>[staleReadback.future],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-disconnected-monotonic-status',
        pollInterval: const Duration(days: 1),
        eventStreamReconnectDelay: const Duration(days: 1),
        eventStreamSilentTimeout: const Duration(days: 1),
        randomDouble: () => 0.5,
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await runs.streamOpened.future;
      await Future<void>.delayed(Duration.zero);

      events.add(
        _streamEvent(<String, Object?>{
          'sequence': 1,
          'eventType': 'run_started',
          'status': 'running',
          'data': <String, Object?>{'status': 'running'},
          'createdAt': '2026-09-02T08:00:00Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await events.close();
      for (
        var attempt = 0;
        attempt < 20 && runs.pollCalls.isEmpty;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(runs.pollCalls, <String>['agent_run_tracker_1']);

      staleReadback.complete(_success(_run(status: 'planning')));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        tracker
            .activityFor(
              threadId: 'thread-a',
              agentRunId: 'agent_run_tracker_1',
            )
            ?.status,
        'running',
      );
    },
  );

  test('reports SSE fallback activity and clears owners on pause', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(events.close);
    final runs = _DeferredStreamRunPort(events);
    final metrics = RuntimeActivityMetrics();
    addTearDown(metrics.dispose);
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-runtime-metrics',
      pollInterval: const Duration(days: 1),
      eventStreamReconnectDelay: const Duration(days: 1),
      eventStreamSilentTimeout: const Duration(days: 1),
      runtimeActivityMetrics: metrics,
      taskOrchestrator: orchestrator,
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );

    expect(metrics.current.sseState, RuntimeSseState.connecting);
    expect(metrics.current.activePollers, 0);

    runs.openStream();
    await Future<void>.delayed(Duration.zero);
    expect(metrics.current.sseState, RuntimeSseState.healthy);
    expect(metrics.current.activePollers, 1);

    final snapshotCalls = runs.pollCalls.length;

    events.add(
      _streamEvent(<String, Object?>{
        'error': <String, Object?>{
          'code': 'RUNTIME_EVENT_GAP',
          'retryable': false,
          'oldestAvailableSequence': 4,
          'latestSequence': 7,
          'resumeAfterSequence': 3,
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(runs.pollCalls.length, greaterThan(snapshotCalls));
    expect(metrics.current.sseState, RuntimeSseState.fallbackPolling);
    expect(metrics.current.activePollers, 1);
    final fallbackTask = orchestrator.snapshot.projections.singleWhere(
      (task) => task.spec.owner == 'chat.run-fallback',
    );
    expect(fallbackTask.spec.key, isNot(contains('agent_run_tracker_1')));

    tracker.pause();
    expect(metrics.current.sseState, RuntimeSseState.disconnected);
    expect(metrics.current.activePollers, 0);
    expect(orchestrator.snapshot.running, 0);
  });

  test(
    'SSE rollback flag uses fallback GET without opening a stream',
    () async {
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(events.close);
      final runs = _StreamingRunPort(
        events: events,
        results: <ApiResult<AgentRunSnapshot>>[
          _success(_run(status: 'running')),
        ],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-sse-rollback',
        chatSseAuthoritative: false,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);

      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await Future<void>.delayed(Duration.zero);

      expect(runs.streamLastEventIds, isEmpty);
      expect(runs.pollCalls, <String>['agent_run_tracker_1']);
    },
  );

  test('falls back to one Run GET after an SSE sequence gap', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(events.close);
    final runs = _StreamingRunPort(
      events: events,
      results: <ApiResult<AgentRunSnapshot>>[_success(_run(status: 'running'))],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-stream-gap',
      pollInterval: const Duration(days: 1),
      eventStreamReconnectDelay: const Duration(days: 1),
      eventStreamSilentTimeout: const Duration(days: 1),
      randomDouble: () => 0.5,
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);

    events.add(
      _streamEvent(<String, Object?>{
        'error': <String, Object?>{
          'code': 'RUNTIME_EVENT_GAP',
          'retryable': false,
          'oldestAvailableSequence': 4,
          'latestSequence': 7,
          'resumeAfterSequence': 3,
        },
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(runs.pollCalls, <String>['agent_run_tracker_1']);
  });

  test('retention gap freezes draft until replacement or terminal', () async {
    final firstEvents =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    final resumedEvents =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(firstEvents.close);
    addTearDown(resumedEvents.close);
    final terminalReadback = Completer<ApiResult<AgentRunSnapshot>>();
    final runs = _StreamingRunPort(
      events: firstEvents,
      streams: <Stream<ApiServerSentEvent<AgentRunStreamPayload>>>[
        firstEvents.stream,
        resumedEvents.stream,
      ],
      results: <FutureOr<ApiResult<AgentRunSnapshot>>>[terminalReadback.future],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-retention-gap-draft',
      pollInterval: const Duration(days: 1),
      eventStreamReconnectDelay: Duration.zero,
      eventStreamSilentTimeout: const Duration(days: 1),
      draftEventInterval: Duration.zero,
      randomDouble: () => 0.5,
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);

    firstEvents.add(
      _streamEvent(<String, Object?>{
        'sequence': 1,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '已显示草稿', 'replace': true},
        'createdAt': '2026-09-02T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final publishedDraftSequence = tracker.draftDeltaSequence;

    firstEvents.add(
      _streamEvent(<String, Object?>{
        'error': <String, Object?>{
          'code': 'RUNTIME_EVENT_GAP',
          'retryable': false,
          'oldestAvailableSequence': 4,
          'latestSequence': 7,
          'resumeAfterSequence': 3,
        },
      }),
    );
    await runs.reconnectOpened.future;
    await Future<void>.delayed(Duration.zero);

    var snapshot = tracker.draftSnapshotFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(runs.streamLastEventIds, <String?>[null, '3']);
    expect(snapshot?.text, '已显示草稿');
    expect(snapshot?.state, ChatRunDraftState.awaitingRecovery);
    expect(tracker.draftDeltaSequence, publishedDraftSequence);
    expect(tracker.lastDraftDelta?.deltaText, '已显示草稿');
    expect(tracker.lastDraftDelta?.replace, isTrue);

    resumedEvents.add(
      _streamEvent(<String, Object?>{
        'sequence': 4,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '不连续追加'},
        'createdAt': '2026-09-02T08:00:01Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    snapshot = tracker.draftSnapshotFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(snapshot?.text, '已显示草稿');
    expect(snapshot?.state, ChatRunDraftState.awaitingRecovery);
    expect(tracker.draftDeltaSequence, publishedDraftSequence);

    resumedEvents.add(
      _streamEvent(<String, Object?>{
        'sequence': 5,
        'eventType': 'draft_delta',
        'status': 'running',
        'data': <String, Object?>{'deltaText': '完整恢复草稿', 'replace': true},
        'createdAt': '2026-09-02T08:00:02Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    snapshot = tracker.draftSnapshotFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(snapshot?.text, '完整恢复草稿');
    expect(snapshot?.state, ChatRunDraftState.streaming);

    resumedEvents.add(
      _streamEvent(<String, Object?>{
        'sequence': 6,
        'eventType': 'succeeded',
        'status': 'succeeded',
        'data': <String, Object?>{'status': 'succeeded'},
        'createdAt': '2026-09-02T08:00:03Z',
      }),
    );
    terminalReadback.complete(
      _success(
        _run(
          status: 'succeeded',
          assistantMessageId: 'assistant-gap-recovered',
          completionMode: 'normal',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    snapshot = tracker.draftSnapshotFor(
      threadId: 'thread-a',
      agentRunId: 'agent_run_tracker_1',
    );
    expect(tracker.hasPendingRuns, isFalse);
    expect(tracker.lastCompletion?.status, 'succeeded');
    expect(snapshot?.text, '完整恢复草稿');
    expect(snapshot?.state, ChatRunDraftState.settled);
  });

  testWidgets('refreshes the silent deadline before falling back to Run GET', (
    tester,
  ) async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    final runs = _StreamingRunPort(
      events: events,
      results: <ApiResult<AgentRunSnapshot>>[_success(_run(status: 'running'))],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-stream-silent',
      pollInterval: const Duration(days: 1),
      eventStreamReconnectDelay: const Duration(days: 1),
      eventStreamSilentTimeout: const Duration(milliseconds: 5),
      randomDouble: () => 0.5,
    );
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await tester.pump(const Duration(milliseconds: 3));

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 1,
        'eventType': 'run_started',
        'status': 'running',
        'data': <String, Object?>{'status': 'running'},
        'createdAt': '2026-08-31T08:00:00Z',
      }),
    );
    await tester.pump(const Duration(milliseconds: 3));
    expect(runs.pollCalls, isEmpty);

    await tester.pump(const Duration(milliseconds: 3));

    expect(runs.pollCalls, <String>['agent_run_tracker_1']);
    tracker.dispose();
    await events.close();
  });

  test(
    'reconnects a running Agent Run SSE from its last public sequence',
    () async {
      final firstEvents =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      final secondEvents =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(firstEvents.close);
      addTearDown(secondEvents.close);
      final runs = _StreamingRunPort(
        events: firstEvents,
        streams: <Stream<ApiServerSentEvent<AgentRunStreamPayload>>>[
          firstEvents.stream,
          secondEvents.stream,
        ],
        results: <ApiResult<AgentRunSnapshot>>[
          _success(_run(status: 'running')),
        ],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-reconnect',
        pollInterval: const Duration(days: 1),
        eventStreamReconnectDelay: Duration.zero,
        draftEventInterval: Duration.zero,
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await runs.streamOpened.future;
      await Future<void>.delayed(Duration.zero);

      firstEvents.add(
        _streamEvent(<String, Object?>{
          'sequence': 1,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{'deltaText': '第一段'},
          'createdAt': '2026-08-19T08:00:00Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await firstEvents.close();
      await runs.reconnectOpened.future;
      await Future<void>.delayed(Duration.zero);

      expect(runs.streamLastEventIds, <String?>[null, '1']);
      secondEvents.add(
        _streamEvent(<String, Object?>{
          'sequence': 2,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{'deltaText': '第二段'},
          'createdAt': '2026-08-19T08:00:01Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tracker.draftDeltaSequence, 2);
      expect(tracker.lastDraftDelta?.deltaText, '第二段');
    },
  );

  test(
    'restores the durable SSE cursor before reopening after process recreation',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final firstEvents =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(firstEvents.close);
      final firstRuns = _StreamingRunPort(
        events: firstEvents,
        results: const <ApiResult<AgentRunSnapshot>>[],
      );
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(firstRuns),
        preferences: preferences,
        userScope: 'account-stream-cursor-restart',
        pollInterval: const Duration(days: 1),
        checkpointInterval: const Duration(days: 1),
        draftEventInterval: Duration.zero,
      );
      await first.start();
      await first.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await firstRuns.streamOpened.future;
      await Future<void>.delayed(Duration.zero);
      firstEvents.add(
        _streamEvent(<String, Object?>{
          'sequence': 1,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{'deltaText': '已送达的第一段'},
          'createdAt': '2026-08-19T08:00:00Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        preferences.listPreferences().single['value'],
        isNot(contains('"lastStreamSequence":1')),
      );
      first.dispose();
      expect(
        preferences.listPreferences().single['value'],
        contains('"lastStreamSequence":1'),
      );

      final restoredEvents =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(restoredEvents.close);
      final restoredRuns = _StreamingRunPort(
        events: restoredEvents,
        results: const <ApiResult<AgentRunSnapshot>>[],
      );
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(restoredRuns),
        preferences: preferences,
        userScope: 'account-stream-cursor-restart',
        pollInterval: const Duration(days: 1),
        draftEventInterval: Duration.zero,
      );
      addTearDown(restored.dispose);
      await restored.start();
      await restoredRuns.streamOpened.future;
      await Future<void>.delayed(Duration.zero);

      expect(restoredRuns.streamLastEventIds, <String?>['1']);
      expect(restored.draftDeltaSequence, 0);
      expect(restored.lastDraftDelta, isNull);

      // The backend excludes #1 because of Last-Event-ID. Keep the local
      // sequence guard covered too, so a duplicated transport frame is silent.
      restoredEvents.add(
        _streamEvent(<String, Object?>{
          'sequence': 1,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{'deltaText': '不应再次展示'},
          'createdAt': '2026-08-19T08:00:00Z',
        }),
      );
      restoredEvents.add(
        _streamEvent(<String, Object?>{
          'sequence': 2,
          'eventType': 'draft_delta',
          'status': 'running',
          'data': <String, Object?>{'deltaText': '仅展示第二段'},
          'createdAt': '2026-08-19T08:00:01Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(restored.draftDeltaSequence, 1);
      expect(restored.lastDraftDelta?.deltaText, '仅展示第二段');
    },
  );

  test(
    'terminal SSE stops exact activity before delayed Run readback',
    () async {
      final events =
          StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
            sync: true,
          );
      addTearDown(events.close);
      final terminalReadback = Completer<ApiResult<AgentRunSnapshot>>();
      final runs = _StreamingRunPort(
        events: events,
        results: <FutureOr<ApiResult<AgentRunSnapshot>>>[
          terminalReadback.future,
        ],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runs),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-terminal-sse',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await runs.streamOpened.future;
      await Future<void>.delayed(Duration.zero);

      events.add(
        _streamEvent(<String, Object?>{
          'sequence': 1,
          'eventType': 'failed',
          'status': 'failed',
          'data': <String, Object?>{'status': 'failed'},
          'createdAt': '2026-08-19T08:00:00Z',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      final activity = tracker.activityFor(
        threadId: 'thread-a',
        agentRunId: 'agent_run_tracker_1',
      );
      expect(activity?.isTerminal, isTrue);
      expect(tracker.isThreadPending('thread-a'), isFalse);
      expect(tracker.needsThreadReconciliation('thread-a'), isTrue);
      expect(tracker.lastCompletion?.status, 'failed');
      expect(tracker.hasPendingRuns, isTrue);
      expect(tracker.taskLedger, hasLength(1));
      expect(tracker.taskLedger.single.status, 'failed');

      terminalReadback.complete(_success(_run(status: 'failed')));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(tracker.hasPendingRuns, isFalse);
      expect(tracker.isThreadPending('thread-a'), isFalse);
      expect(tracker.needsThreadReconciliation('thread-a'), isFalse);
      expect(
        tracker
            .activityFor(
              threadId: 'thread-a',
              agentRunId: 'agent_run_tracker_1',
            )
            ?.isTerminal,
        isTrue,
      );
      expect(tracker.completionsForThread('thread-a'), hasLength(1));
    },
  );

  test('detached Run GET cannot overwrite terminal reconciliation', () async {
    final events =
        StreamController<ApiServerSentEvent<AgentRunStreamPayload>>.broadcast(
          sync: true,
        );
    addTearDown(events.close);
    final terminalReadback = Completer<ApiResult<AgentRunSnapshot>>();
    final runs = _StreamingRunPort(
      events: events,
      results: <FutureOr<ApiResult<AgentRunSnapshot>>>[terminalReadback.future],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(runs),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-detached-terminal-readback',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.track(
      agentRunId: 'agent_run_tracker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    await runs.streamOpened.future;
    await Future<void>.delayed(Duration.zero);

    events.add(
      _streamEvent(<String, Object?>{
        'sequence': 1,
        'eventType': 'failed',
        'status': 'failed',
        'data': <String, Object?>{'status': 'failed'},
        'createdAt': '2026-09-02T08:00:00Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final completionSequence = tracker.completionSequence;

    await tracker.trackAcceptedRun(
      agentRunId: 'agent_run_tracker_1',
      publicTaskId: 'public-task-detached-terminal',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
    );
    expect(tracker.hasPendingRuns, isFalse);
    expect(tracker.taskLedger, hasLength(1));
    expect(tracker.taskLedger.single.status, 'failed');
    expect(
      tracker.taskLedger.single.publicTaskId,
      'public-task-detached-terminal',
    );

    terminalReadback.complete(_success(_run(status: 'succeeded')));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tracker.completionSequence, completionSequence);
    expect(tracker.taskLedger, hasLength(1));
    expect(tracker.taskLedger.single.status, 'failed');
    expect(
      tracker.taskLedger.single.publicTaskId,
      'public-task-detached-terminal',
    );
  });

  test('settles a public derived task without an agent run id', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    var refreshed = 0;
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      fileAgentRuns: const _PublicFileAgentRunPort(
        NoteFileAgentRunStatus(
          fileAgentRunId: 'file-run-1',
          noteId: 'remote-note-1',
          status: 'succeeded',
          outputPartRevisionId: 'outline-r2',
        ),
      ),
      preferences: preferences,
      userScope: 'account-a',
      pollInterval: const Duration(days: 1),
      onDerivedPartTerminal: (_) async {
        refreshed += 1;
        return true;
      },
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-1',
      localNoteId: 'local-note-1',
      remoteNoteId: 'remote-note-1',
      targetPart: NoteFileAgentPart.outline,
    );
    await Future<void>.delayed(Duration.zero);

    expect(refreshed, 1);
    expect(tracker.hasPendingRuns, isFalse);
    expect(tracker.lastDerivedCompletion?.fileAgentRunId, 'file-run-1');
    expect(tracker.lastDerivedCompletion?.agentRunId, isNull);
    expect(tracker.lastDerivedCompletion?.outputPartRevisionId, 'outline-r2');
  });

  test(
    'does not settle a stale derived completion after identity enrichment',
    () async {
      final firstCallbackStarted = Completer<void>();
      final releaseFirstCallback = Completer<void>();
      final secondCallbackStarted = Completer<void>();
      final releaseSecondCallback = Completer<void>();
      final completions = <DerivedPartRunCompletion>[];
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(
            _run(
              status: 'succeeded',
              agentRunId: 'agent-run-terminal-enriched',
            ),
          ),
        ),
        fileAgentRuns: const _PublicFileAgentRunPort(
          NoteFileAgentRunStatus(
            fileAgentRunId: 'file-run-terminal-enriched',
            noteId: 'remote-note-terminal-enriched',
            status: 'succeeded',
            targetPart: NoteFileAgentPart.outline,
            outputPartRevisionId: 'outline-enriched-r2',
          ),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-derived-terminal-enrichment',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (completion) async {
          completions.add(completion);
          if (completions.length == 1) {
            firstCallbackStarted.complete();
            await releaseFirstCallback.future;
          } else {
            secondCallbackStarted.complete();
            await releaseSecondCallback.future;
          }
          return true;
        },
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-terminal-enriched',
        localNoteId: 'local-note-terminal-enriched',
        remoteNoteId: 'remote-note-terminal-enriched',
        targetPart: NoteFileAgentPart.outline,
      );
      await firstCallbackStarted.future;

      await tracker.rememberKnowledgeAssetSubject(
        localNoteId: 'local-note-terminal-enriched',
        subjectTitle: '外部文章：终态身份补齐',
      );
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-terminal-enriched',
        agentRunId: 'agent-run-terminal-enriched',
        localNoteId: 'local-note-terminal-enriched',
        remoteNoteId: 'remote-note-terminal-enriched',
        targetPart: NoteFileAgentPart.outline,
        inputPartRevisionId: 'raw-enriched-r1',
        targetPartRevisionId: 'outline-enriched-r1',
        operationId: 'auto-outline-terminal-enriched',
      );
      releaseFirstCallback.complete();
      await secondCallbackStarted.future;

      expect(completions, hasLength(2));
      expect(completions.first.agentRunId, isNull);
      expect(completions.first.subjectTitle, isNull);
      expect(completions.first.operationId, isNull);
      expect(tracker.hasPendingRuns, isTrue);
      expect(tracker.lastDerivedCompletion, isNull);
      expect(completions.last.agentRunId, 'agent-run-terminal-enriched');
      expect(completions.last.subjectTitle, '外部文章：终态身份补齐');
      expect(completions.last.inputPartRevisionId, 'raw-enriched-r1');
      expect(completions.last.targetPartRevisionId, 'outline-enriched-r1');
      expect(completions.last.operationId, 'auto-outline-terminal-enriched');
      expect(completions.last.outputPartRevisionId, 'outline-enriched-r2');

      releaseSecondCallback.complete();
      for (
        var attempt = 0;
        attempt < 40 && tracker.hasPendingRuns;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(tracker.hasPendingRuns, isFalse);
      expect(
        tracker.lastDerivedCompletion?.agentRunId,
        'agent-run-terminal-enriched',
      );
      expect(tracker.lastDerivedCompletion?.subjectTitle, '外部文章：终态身份补齐');
      expect(tracker.taskLedger.single.status, 'succeeded');
      expect(
        tracker.taskLedger.single.resultTaskIds,
        containsAll(<String>[
          'file-run-terminal-enriched',
          'agent-run-terminal-enriched',
        ]),
      );
      expect(tracker.taskLedger.single.inputPartRevisionId, 'raw-enriched-r1');
      expect(
        tracker.taskLedger.single.targetPartRevisionId,
        'outline-enriched-r1',
      );
      expect(
        tracker.taskLedger.single.operationId,
        'auto-outline-terminal-enriched',
      );
    },
  );

  test(
    'follows a successor Agent Run for one retried File-Agent Run',
    () async {
      final fileRuns = _MutablePublicFileAgentRunPort(
        const NoteFileAgentRunStatus(
          fileAgentRunId: 'file-run-retry-1',
          noteId: 'remote-note-retry-1',
          status: 'retry_wait',
          agentRunId: 'agent-run-attempt-1',
          targetPart: NoteFileAgentPart.outline,
        ),
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        fileAgentRuns: fileRuns,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-file-agent-retry',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (_) async => true,
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-retry-1',
        agentRunId: 'agent-run-attempt-1',
        status: 'running',
        localNoteId: 'local-note-retry-1',
        remoteNoteId: 'remote-note-retry-1',
        targetPart: NoteFileAgentPart.outline,
        inputPartRevisionId: 'raw-retry-r1',
        targetPartRevisionId: 'outline-retry-r1',
        operationId: 'auto-outline-v1-file-agent-retry',
      );
      await tracker.refresh();
      expect(tracker.taskLedger.single.status, 'retry_wait');
      await Future<void>.delayed(Duration.zero);

      fileRuns.result = const NoteFileAgentRunStatus(
        fileAgentRunId: 'file-run-retry-1',
        noteId: 'remote-note-retry-1',
        status: 'queued',
        agentRunId: 'agent-run-attempt-2',
        targetPart: NoteFileAgentPart.outline,
      );
      await tracker.refresh();
      await Future<void>.delayed(Duration.zero);
      await tracker.refresh();

      expect(tracker.taskLedger, hasLength(1));
      expect(tracker.taskLedger.single.taskId, 'file-run-retry-1');
      expect(tracker.taskLedger.single.agentRunId, 'agent-run-attempt-2');
      expect(tracker.taskLedger.single.status, 'queued');

      fileRuns.result = const NoteFileAgentRunStatus(
        fileAgentRunId: 'file-run-retry-1',
        noteId: 'remote-note-retry-1',
        status: 'succeeded',
        agentRunId: 'agent-run-attempt-2',
        targetPart: NoteFileAgentPart.outline,
        outputPartRevisionId: 'outline-retry-r2',
      );
      await tracker.refresh();
      await Future<void>.delayed(Duration.zero);
      await tracker.refresh();

      expect(tracker.hasPendingRuns, isFalse);
      expect(tracker.taskLedger.single.status, 'succeeded');
      expect(tracker.taskLedger.single.agentRunId, 'agent-run-attempt-2');
    },
  );

  test(
    'discards a delayed File-Agent attempt after learning a newer attempt',
    () async {
      final staleFileRun = Completer<NoteFileAgentRunStatus>();
      final fileRuns =
          _QueuedPublicFileAgentRunPort(<FutureOr<NoteFileAgentRunStatus>>[
            staleFileRun.future,
            const NoteFileAgentRunStatus(
              fileAgentRunId: 'file-run-delayed-retry',
              noteId: 'remote-note-delayed-retry',
              status: 'running',
              agentRunId: 'agent-run-attempt-2',
              targetPart: NoteFileAgentPart.outline,
            ),
          ]);
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(
            _run(status: 'running', agentRunId: 'agent-run-attempt-2'),
          ),
        ),
        fileAgentRuns: fileRuns,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-file-agent-delayed-retry',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-delayed-retry',
        status: 'queued',
        localNoteId: 'local-note-delayed-retry',
        remoteNoteId: 'remote-note-delayed-retry',
        targetPart: NoteFileAgentPart.outline,
      );
      await fileRuns.firstCallStarted;

      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-delayed-retry',
        agentRunId: 'agent-run-attempt-2',
        status: 'running',
        localNoteId: 'local-note-delayed-retry',
        remoteNoteId: 'remote-note-delayed-retry',
        targetPart: NoteFileAgentPart.outline,
      );
      staleFileRun.complete(
        const NoteFileAgentRunStatus(
          fileAgentRunId: 'file-run-delayed-retry',
          noteId: 'remote-note-delayed-retry',
          status: 'retry_wait',
          agentRunId: 'agent-run-attempt-1',
          targetPart: NoteFileAgentPart.outline,
        ),
      );
      await _waitForCallCount(fileRuns.calls, 2);

      expect(fileRuns.calls, hasLength(2));
      expect(tracker.taskLedger.single.agentRunId, 'agent-run-attempt-2');
      expect(tracker.taskLedger.single.status, 'running');
    },
  );

  test('restored successor ignores a stale external attempt', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    final first = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: 'account-restored-derived-successor',
      pollInterval: const Duration(days: 1),
    );
    await first.start();
    await first.trackDerivedPart(
      fileAgentRunId: 'file-run-restored-successor',
      agentRunId: 'agent-run-attempt-2',
      status: 'running',
      localNoteId: 'local-note-restored-successor',
      remoteNoteId: 'remote-note-restored-successor',
      targetPart: NoteFileAgentPart.outline,
    );
    first.dispose();

    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: preferences,
      userScope: 'account-restored-derived-successor',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);
    await restored.start();
    await restored.trackDerivedPart(
      fileAgentRunId: 'file-run-restored-successor',
      agentRunId: 'agent-run-attempt-1',
      status: 'retry_wait',
      localNoteId: 'local-note-restored-successor',
      remoteNoteId: 'remote-note-restored-successor',
      targetPart: NoteFileAgentPart.outline,
    );

    expect(restored.taskLedger.single.agentRunId, 'agent-run-attempt-2');
    expect(restored.taskLedger.single.status, 'running');
  });

  test('does not attach an old Agent trace after successor refresh', () async {
    final staleAgentRun = Completer<ApiResult<AgentRunSnapshot>>();
    final oldTrace = AgentRunToolTrace(
      invocationId: 'old-attempt-tool',
      toolName: 'workspace_search',
      state: 'finished',
      outcome: 'succeeded',
      createdAt: DateTime.utc(2026, 9, 15, 8),
      completedAt: DateTime.utc(2026, 9, 15, 8, 0, 1),
      outputFiles: const <AgentRunOutputFile>[],
    );
    final newTrace = AgentRunToolTrace(
      invocationId: 'new-attempt-tool',
      toolName: 'workspace_search',
      state: 'started',
      createdAt: DateTime.utc(2026, 9, 15, 8, 0, 2),
      outputFiles: const <AgentRunOutputFile>[],
    );
    final agentRuns = _QueuedRunPort(<FutureOr<ApiResult<AgentRunSnapshot>>>[
      staleAgentRun.future,
      _success(
        _run(
          status: 'running',
          agentRunId: 'agent-run-trace-attempt-2',
          toolTrace: <AgentRunToolTrace>[newTrace],
        ),
      ),
    ]);
    final fileRuns = _MutablePublicFileAgentRunPort(
      const NoteFileAgentRunStatus(
        fileAgentRunId: 'file-run-trace-retry',
        noteId: 'remote-note-trace-retry',
        status: 'running',
        agentRunId: 'agent-run-trace-attempt-1',
        targetPart: NoteFileAgentPart.outline,
      ),
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(agentRuns),
      fileAgentRuns: fileRuns,
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-file-agent-trace-retry',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();
    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-trace-retry',
      agentRunId: 'agent-run-trace-attempt-1',
      status: 'running',
      localNoteId: 'local-note-trace-retry',
      remoteNoteId: 'remote-note-trace-retry',
      targetPart: NoteFileAgentPart.outline,
    );
    await _waitForCallCount(agentRuns.calls, 1);

    fileRuns.result = const NoteFileAgentRunStatus(
      fileAgentRunId: 'file-run-trace-retry',
      noteId: 'remote-note-trace-retry',
      status: 'running',
      agentRunId: 'agent-run-trace-attempt-2',
      targetPart: NoteFileAgentPart.outline,
    );
    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-trace-retry',
      agentRunId: 'agent-run-trace-attempt-2',
      status: 'running',
      localNoteId: 'local-note-trace-retry',
      remoteNoteId: 'remote-note-trace-retry',
      targetPart: NoteFileAgentPart.outline,
    );
    staleAgentRun.complete(
      _success(
        _run(
          status: 'running',
          agentRunId: 'agent-run-trace-attempt-1',
          toolTrace: <AgentRunToolTrace>[oldTrace],
        ),
      ),
    );
    await _waitForCallCount(agentRuns.calls, 2);

    expect(agentRuns.calls, <String>[
      'agent-run-trace-attempt-1',
      'agent-run-trace-attempt-2',
    ]);
    expect(tracker.taskLedger.single.agentRunId, 'agent-run-trace-attempt-2');
    final derivedTrace = tracker.derivedPartToolTrace(
      'local-note-trace-retry',
      NoteFileAgentPart.outline,
    );
    expect(derivedTrace, hasLength(1));
    expect(derivedTrace.single.invocationId, newTrace.invocationId);
  });

  test('immediately terminal derived enrollment is never pending', () async {
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-terminal-derived-enrollment',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.start();

    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-immediate-failure',
      localNoteId: 'local-note-immediate-failure',
      remoteNoteId: 'remote-note-immediate-failure',
      targetPart: NoteFileAgentPart.germination,
      status: 'failed',
    );

    expect(
      tracker.isDerivedPartPending(
        'local-note-immediate-failure',
        NoteFileAgentPart.germination,
      ),
      isFalse,
    );
    expect(
      tracker.derivedPartStatus(
        'local-note-immediate-failure',
        NoteFileAgentPart.germination,
      ),
      'failed',
    );
    expect(
      tracker.taskLedger
          .singleWhere((entry) => entry.taskId == 'file-run-immediate-failure')
          .isTerminal,
      isTrue,
    );
  });

  test(
    'Outline succeeded receipt waits for its output revision and readback',
    () async {
      final fileRuns = _MutablePublicFileAgentRunPort(
        const NoteFileAgentRunStatus(
          fileAgentRunId: 'file-outline-pending-output',
          noteId: 'remote-note-1',
          status: 'succeeded',
        ),
      );
      var readbacks = 0;
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        fileAgentRuns: fileRuns,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-outline-pending-output',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (_) async {
          readbacks++;
          return true;
        },
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-outline-pending-output',
        localNoteId: 'local-note-1',
        remoteNoteId: 'remote-note-1',
        targetPart: NoteFileAgentPart.outline,
        status: 'succeeded',
      );
      await tracker.refresh();
      expect(
        tracker.isDerivedPartPending('local-note-1', NoteFileAgentPart.outline),
        isTrue,
      );
      expect(tracker.taskLedger.single.status, 'finalizing');
      expect(tracker.lastDerivedCompletion, isNull);
      expect(readbacks, 0);
      fileRuns.result = const NoteFileAgentRunStatus(
        fileAgentRunId: 'file-outline-pending-output',
        noteId: 'remote-note-1',
        status: 'succeeded',
        outputPartRevisionId: 'outline-output-1',
      );
      await tracker.refresh();
      expect(readbacks, 1);
      expect(tracker.taskLedger.single.status, 'succeeded');
      expect(
        tracker.lastDerivedCompletion?.outputPartRevisionId,
        'outline-output-1',
      );
    },
  );

  test(
    'restores the output revision while exact derived readback is pending',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final worker = _CheckpointWorker();
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      const terminal = NoteFileAgentRunStatus(
        fileAgentRunId: 'file-run-restored',
        noteId: 'remote-note-1',
        status: 'succeeded',
        outputPartRevisionId: 'outline-r3',
      );
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        fileAgentRuns: const _PublicFileAgentRunPort(terminal),
        preferences: preferences,
        checkpointPersistence: persistence,
        userScope: 'account-derived-restored',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (_) async => false,
      );
      await first.start();
      await first.rememberKnowledgeAssetSubject(
        localNoteId: 'local-note-1',
        subjectTitle: '外部文章：增长复盘',
      );
      await first.trackDerivedPart(
        fileAgentRunId: 'file-run-restored',
        agentRunId: 'agent-run-restored',
        localNoteId: 'local-note-1',
        remoteNoteId: 'remote-note-1',
        targetPart: NoteFileAgentPart.outline,
        inputPartRevisionId: 'raw-r1',
        targetPartRevisionId: 'outline-r1',
        operationId: 'auto-outline-op-1',
      );
      await Future<void>.delayed(Duration.zero);
      await first.flushCheckpointPersistence();

      expect(first.hasPendingRuns, isTrue);
      expect(
        preferences.listPreferences().map((entry) => entry['value']).join(),
        contains('outline-r3'),
      );
      final checkpoint = worker.rowsFor('account-derived-restored').single;
      expect(checkpoint.role, ChatRunCheckpointRole.active);
      expect(checkpoint.status, 'finalizing');
      expect(checkpoint.publicState['subjectTitle'], '外部文章：增长复盘');
      expect(checkpoint.publicState['agentRunId'], 'agent-run-restored');
      expect(checkpoint.publicState['inputPartRevisionId'], 'raw-r1');
      expect(checkpoint.publicState['targetPartRevisionId'], 'outline-r1');
      expect(checkpoint.publicState['operationId'], 'auto-outline-op-1');
      first.dispose();

      DerivedPartRunCompletion? completion;
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        fileAgentRuns: const _PublicFileAgentRunPort(terminal),
        preferences: preferences,
        checkpointPersistence: persistence,
        userScope: 'account-derived-restored',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (value) async {
          completion = value;
          return true;
        },
      );
      addTearDown(restored.dispose);
      await restored.start();
      await Future<void>.delayed(Duration.zero);

      expect(restored.hasPendingRuns, isFalse);
      expect(completion?.outputPartRevisionId, 'outline-r3');
      expect(completion?.subjectTitle, '外部文章：增长复盘');
      expect(completion?.inputPartRevisionId, 'raw-r1');
      expect(completion?.targetPartRevisionId, 'outline-r1');
      expect(completion?.operationId, 'auto-outline-op-1');
      expect(restored.taskLedger.single.subjectTitle, '外部文章：增长复盘');
      expect(
        restored.taskLedger.single.resultTaskIds,
        containsAll(<String>['file-run-restored', 'agent-run-restored']),
      );
      expect(restored.taskLedger.single.inputPartRevisionId, 'raw-r1');
      expect(restored.taskLedger.single.targetPartRevisionId, 'outline-r1');
      expect(restored.taskLedger.single.operationId, 'auto-outline-op-1');
    },
  );

  test('derived task evidence cannot be rebound for one file run', () async {
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(_run(status: 'running')),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'account-derived-evidence-conflict',
      pollInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);
    await tracker.rememberKnowledgeAssetSubject(
      localNoteId: 'local-note-evidence',
      subjectTitle: '第一版资产标题',
    );
    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-evidence',
      localNoteId: 'local-note-evidence',
      remoteNoteId: 'remote-note-evidence',
      targetPart: NoteFileAgentPart.outline,
      status: 'running',
      inputPartRevisionId: 'raw-r1',
      targetPartRevisionId: 'outline-r1',
      operationId: 'auto-outline-op-1',
    );

    await tracker.trackDerivedPart(
      fileAgentRunId: 'file-run-evidence',
      localNoteId: 'local-note-evidence',
      remoteNoteId: 'remote-note-evidence',
      targetPart: NoteFileAgentPart.outline,
      status: 'finalizing',
      inputPartRevisionId: 'raw-r2',
      targetPartRevisionId: 'outline-r2',
      operationId: 'auto-outline-op-2',
    );

    final entry = tracker.taskLedger.single;
    expect(entry.taskId, 'file-run-evidence');
    expect(entry.status, 'running');
    expect(entry.subjectTitle, '第一版资产标题');
    expect(entry.inputPartRevisionId, 'raw-r1');
    expect(entry.targetPartRevisionId, 'outline-r1');
    expect(entry.operationId, 'auto-outline-op-1');
  });

  test('normalizes and truncates a long multiline task subject', () {
    final entry = AgentTaskLedgerEntry.derivedPart(
      taskId: 'file-run-long-subject',
      localNoteId: 'local-note-long-subject',
      remoteNoteId: 'remote-note-long-subject',
      targetPart: NoteFileAgentPart.outline,
      status: 'running',
      createdAt: DateTime.utc(2026, 9, 15, 8),
      subjectTitle: '  外部文章\n\t${List<String>.filled(170, '界').join()}\u0000  ',
    );

    expect(entry.subjectTitle, startsWith('外部文章 '));
    expect(entry.subjectTitle!.runes.length, 160);
    expect(entry.subjectTitle, isNot(contains(RegExp(r'[\x00-\x1F\x7F]'))));
  });

  test(
    'restores a remembered chat subject without a task ledger row',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: 'account-subject-index',
        pollInterval: const Duration(days: 1),
      );
      await first.rememberChatThreadSubject(
        threadId: 'thread-delayed-notification',
        subjectTitle: '客户续约复盘',
      );
      expect(first.taskLedger, isEmpty);
      first.dispose();

      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: 'account-subject-index',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();

      expect(
        restored.chatThreadSubject('thread-delayed-notification'),
        '客户续约复盘',
      );
    },
  );

  test(
    'persists a failed derived terminal state before clearing the spinner',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      DerivedPartRunCompletion? callbackCompletion;
      var terminalPersisted = false;
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        fileAgentRuns: const _PublicFileAgentRunPort(
          NoteFileAgentRunStatus(
            fileAgentRunId: 'file-run-failed',
            noteId: 'remote-note-1',
            status: 'failed',
            failureCode: 'FILE_AGENT_FAILED',
          ),
        ),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
        onDerivedPartTerminal: (completion) async {
          callbackCompletion = completion;
          return terminalPersisted;
        },
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackDerivedPart(
        fileAgentRunId: 'file-run-failed',
        localNoteId: 'local-note-1',
        remoteNoteId: 'remote-note-1',
        targetPart: NoteFileAgentPart.outline,
      );
      await Future<void>.delayed(Duration.zero);

      expect(callbackCompletion?.status, 'failed');
      expect(callbackCompletion?.failureCode, 'FILE_AGENT_FAILED');
      expect(tracker.hasPendingRuns, isTrue);
      expect(tracker.lastDerivedCompletion, isNull);

      terminalPersisted = true;
      await tracker.refresh();

      expect(tracker.hasPendingRuns, isFalse);
      expect(tracker.lastDerivedCompletion?.status, 'failed');
      expect(tracker.taskLedger, hasLength(1));
      expect(tracker.taskLedger.single.localNoteId, 'local-note-1');
      expect(tracker.taskLedger.single.targetPart, NoteFileAgentPart.outline);
      expect(tracker.taskLedger.single.failureCode, 'FILE_AGENT_FAILED');

      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();

      expect(restored.lastDerivedCompletion, isNull);
      expect(restored.taskLedger, hasLength(1));
      expect(restored.taskLedger.single.taskId, 'file-run-failed');
      expect(restored.taskLedger.single.localNoteId, 'local-note-1');
      expect(restored.taskLedger.single.targetPart, NoteFileAgentPart.outline);
      expect(restored.taskLedger.single.status, 'failed');
      expect(restored.taskLedger.single.failureCode, 'FILE_AGENT_FAILED');
    },
  );

  test(
    'owns accepted Runs for an authenticated account before and after start',
    () async {
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);

      expect(tracker.canTrackAcceptedRuns, isFalse);
      await tracker.start();
      expect(tracker.canTrackAcceptedRuns, isTrue);

      final anonymous = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'anonymous',
      );
      addTearDown(anonymous.dispose);
      expect(anonymous.canTrackAcceptedRuns, isFalse);
    },
  );

  test(
    'persists a public terminal ledger entry without reply content',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(
            _run(
              status: 'succeeded',
              assistantMessageId: 'assistant-thread-a',
              completionMode: 'normal',
            ),
          ),
        ),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.rememberChatThreadSubject(
        threadId: 'thread-a',
        subjectTitle: '离开页面后继续处理',
      );
      await tracker.trackAcceptedRun(
        agentRunId: 'agent_run_tracker_1',
        publicTaskId: 'public_chat_task_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
      );
      await Future<void>.delayed(Duration.zero);

      expect(tracker.hasPendingRuns, isFalse);
      expect(tracker.taskLedger, hasLength(1));
      expect(tracker.taskLedger.single.taskId, 'agent_run_tracker_1');
      expect(tracker.taskLedger.single.publicTaskId, 'public_chat_task_1');
      expect(tracker.taskLedger.single.resultTaskIds, <String>[
        'agent_run_tracker_1',
        'public_chat_task_1',
      ]);
      expect(tracker.taskLedger.single.status, 'succeeded');
      expect(tracker.taskLedger.single.subjectTitle, '离开页面后继续处理');
      final persisted = preferences
          .listPreferences()
          .map((record) => record['value'])
          .join();
      expect(persisted, contains('agent_run_tracker_1'));
      expect(persisted, contains('public_chat_task_1'));
      expect(persisted, contains('"ledger"'));
      expect(persisted, isNot(contains('assistant reply')));

      final restoredRuns = _QueuedRunPort(<ApiResult<AgentRunSnapshot>>[]);
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(restoredRuns),
        preferences: preferences,
        userScope: 'account-a',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      var restoreNotifications = 0;
      restored.addListener(() => restoreNotifications += 1);
      await restored.start();
      expect(restored.taskLedger.single.taskId, 'agent_run_tracker_1');
      expect(restored.taskLedger.single.publicTaskId, 'public_chat_task_1');
      expect(restored.taskLedger.single.subjectTitle, '离开页面后继续处理');
      expect(restored.taskLedger.single.resultTaskIds, <String>[
        'agent_run_tracker_1',
        'public_chat_task_1',
      ]);
      expect(restored.taskLedger.single.isTerminal, isTrue);
      expect(restored.hasPendingRuns, isFalse);
      expect(restoredRuns.calls, isEmpty);
      final completion = restored.completionsForThread('thread-a').single;
      expect(completion.agentRunId, 'agent_run_tracker_1');
      expect(completion.scene, ChatScene.feedAi);
      expect(completion.purpose, ChatConversationPurpose.general);
      expect(completion.status, 'succeeded');
      expect(completion.completionMode, 'normal');
      expect(completion.assistantMessageId, 'assistant-thread-a');
      expect(completion.completedAt, DateTime.utc(2026, 8, 13, 8, 0, 1));
      expect(restored.lastCompletion?.agentRunId, completion.agentRunId);
      expect(restoreNotifications, 1);
      expect(restored.taskLedgerDeltaSequence, 1);
      expect(restored.lastTaskLedgerDelta?.reset, isTrue);

      final taskId = restored.taskLedger.single.taskId;
      final status = restored.taskLedger.single.status;
      await restored.rememberChatThreadSubject(
        threadId: 'thread-a',
        subjectTitle: '客户回访复盘',
      );
      expect(restored.taskLedger.single.taskId, taskId);
      expect(restored.taskLedger.single.status, status);
      expect(restored.taskLedger.single.subjectTitle, '客户回访复盘');
    },
  );

  test('restores the terminal Chat hand-off from a worker row', () async {
    const scope = 'account-worker-terminal-completion';
    final worker = _CheckpointWorker();
    final queue = DatabaseWriteQueue();
    final persistence = ChatRunCheckpointPersistence(
      worker: worker,
      writeQueue: queue,
    );
    addTearDown(queue.dispose);
    final first = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _StableRunPort(
          _run(
            status: 'succeeded',
            assistantMessageId: 'assistant-thread-a',
            completionMode: 'normal',
          ),
        ),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      checkpointPersistence: persistence,
      userScope: scope,
      pollInterval: const Duration(days: 1),
    );
    await first.start();
    await first.rememberChatThreadSubject(
      threadId: 'thread-a',
      subjectTitle: '深度定位对话',
    );
    await first.trackAcceptedRun(
      agentRunId: 'agent_run_tracker_1',
      publicTaskId: 'public_chat_task_worker_1',
      threadId: 'thread-a',
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.deepPositioning,
    );
    await Future<void>.delayed(Duration.zero);
    await first.flushCheckpointPersistence();
    first.dispose();

    final restoredRuns = _QueuedRunPort(<ApiResult<AgentRunSnapshot>>[]);
    final restored = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(restoredRuns),
      preferences: AppPreferencesDao(AppDatabase()),
      checkpointPersistence: persistence,
      userScope: scope,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);
    await restored.start();

    expect(restoredRuns.calls, isEmpty);
    final completion = restored.completionsForThread('thread-a').single;
    expect(completion.agentRunId, 'agent_run_tracker_1');
    expect(completion.purpose, ChatConversationPurpose.deepPositioning);
    expect(completion.status, 'succeeded');
    expect(completion.completionMode, 'normal');
    expect(completion.assistantMessageId, 'assistant-thread-a');
    expect(restored.taskLedger.single.subjectTitle, '深度定位对话');
    expect(completion.completedAt, DateTime.utc(2026, 8, 13, 8, 0, 1));
    expect(restored.lastCompletion?.agentRunId, completion.agentRunId);
  });

  test(
    'terminal purpose enrichment preserves the completion across restart',
    () async {
      const scope = 'account-terminal-purpose-enrichment';
      final worker = _CheckpointWorker();
      final queue = DatabaseWriteQueue();
      final persistence = ChatRunCheckpointPersistence(
        worker: worker,
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(
            _run(
              status: 'succeeded',
              assistantMessageId: 'assistant-thread-a',
              completionMode: 'normal',
            ),
          ),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        checkpointPersistence: persistence,
        userScope: scope,
        pollInterval: const Duration(days: 1),
      );
      await first.start();
      await first.track(
        agentRunId: 'agent_run_tracker_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        first.completionsForThread('thread-a').single.purpose,
        ChatConversationPurpose.general,
      );
      final completionSequence = first.completionSequence;
      await first.trackAcceptedRun(
        agentRunId: 'agent_run_tracker_1',
        publicTaskId: 'public_chat_task_enriched_1',
        threadId: 'thread-a',
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.deepPositioning,
      );

      expect(first.taskLedger.single.isTerminal, isTrue);
      expect(
        first.taskLedger.single.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(
        first.completionsForThread('thread-a').single.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(
        first.lastCompletion?.purpose,
        ChatConversationPurpose.deepPositioning,
      );
      expect(first.completionSequence, completionSequence + 1);
      await first.flushCheckpointPersistence();
      final row = worker.rowsFor(scope).single;
      expect(row.purpose, ChatConversationPurpose.deepPositioning.apiValue);
      expect(
        (row.publicState['completion'] as Map<String, Object?>)['purpose'],
        ChatConversationPurpose.deepPositioning.apiValue,
      );
      first.dispose();

      final restoredRuns = _QueuedRunPort(<ApiResult<AgentRunSnapshot>>[]);
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(restoredRuns),
        preferences: AppPreferencesDao(AppDatabase()),
        checkpointPersistence: persistence,
        userScope: scope,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();

      expect(restoredRuns.calls, isEmpty);
      final completion = restored.completionsForThread('thread-a').single;
      expect(completion.purpose, ChatConversationPurpose.deepPositioning);
      expect(completion.assistantMessageId, 'assistant-thread-a');
      expect(completion.completionMode, 'normal');
    },
  );

  test(
    'restores recording outline and waits for exact terminal verification',
    () async {
      const scope = 'account-recording-outline-restore';
      const recordingId = 'recording-outline-restore-1';
      const localNoteId = 'local-recording-outline-note-1';
      const remoteNoteId = 'remote-recording-outline-note-1';
      const outputRevision = 'recording-outline-revision-2';
      final database = AppDatabase();
      final firstPreferences = AppPreferencesDao(database);
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: _RecordingOutlineApi(
          _recordingOutlineDetail(
            status: RecordingNoteOutlineTaskStatus.running,
          ),
        ),
        preferences: firstPreferences,
        userScope: scope,
        checkpointInterval: Duration.zero,
        pollInterval: const Duration(days: 1),
      );

      await first.rememberKnowledgeAssetSubject(
        localNoteId: localNoteId,
        subjectTitle: '访谈录音：年度规划',
      );
      await first.trackRecordingOutline(
        recordingId: recordingId,
        localNoteId: localNoteId,
        remoteNoteId: remoteNoteId,
      );
      expect(first.taskLedger.single.kind, 'recording_outline');
      expect(first.taskLedger.single.status, 'queued');
      expect(first.taskLedger.single.subjectTitle, '访谈录音：年度规划');
      first.dispose();

      var allowVerification = false;
      var verificationCalls = 0;
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: _RecordingOutlineApi(
          _recordingOutlineDetail(
            status: RecordingNoteOutlineTaskStatus.succeeded,
            outputRevision: outputRevision,
          ),
        ),
        preferences: AppPreferencesDao(database),
        userScope: scope,
        checkpointInterval: Duration.zero,
        pollInterval: const Duration(days: 1),
        onRecordingOutlineTerminal: (completion) async {
          verificationCalls += 1;
          expect(completion.recordingId, recordingId);
          expect(completion.remoteNoteId, remoteNoteId);
          expect(completion.outputPartRevisionId, outputRevision);
          expect(completion.subjectTitle, '访谈录音：年度规划');
          return allowVerification;
        },
      );
      addTearDown(restored.dispose);
      await restored.start();
      for (
        var attempt = 0;
        attempt < 20 && verificationCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(verificationCalls, 1);
      expect(restored.taskLedger.single.status, 'finalizing');
      expect(restored.taskLedger.single.publicTaskId, 'outline-subtask-1');
      expect(restored.taskLedger.single.subjectTitle, '访谈录音：年度规划');

      allowVerification = true;
      await restored.refresh();

      final terminal = restored.taskLedger.single;
      expect(terminal.kind, 'recording_outline');
      expect(terminal.status, 'succeeded');
      expect(terminal.publicTaskId, 'outline-subtask-1');
      expect(terminal.outputPartRevisionId, outputRevision);
      expect(terminal.subjectTitle, '访谈录音：年度规划');
      expect(restored.isRecordingOutlinePending(localNoteId), isFalse);
    },
  );

  test(
    'retains the recording outline failure code in completion and ledger',
    () async {
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: _RecordingOutlineApi(
          _recordingOutlineDetail(
            status: RecordingNoteOutlineTaskStatus.failed,
            failureCode: 'WORKSPACE_NOT_READY',
          ),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-recording-outline-failure-code',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();
      await tracker.trackRecordingOutline(
        recordingId: 'recording-outline-restore-1',
        localNoteId: 'local-recording-outline-note-1',
        remoteNoteId: 'remote-recording-outline-note-1',
      );
      for (
        var attempt = 0;
        attempt < 20 && tracker.lastRecordingOutlineCompletion == null;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(tracker.lastRecordingOutlineCompletion?.status, 'failed');
      expect(
        tracker.lastRecordingOutlineCompletion?.failureCode,
        'WORKSPACE_NOT_READY',
      );
      expect(tracker.taskLedger.single.status, 'failed');
      expect(tracker.taskLedger.single.failureCode, 'WORKSPACE_NOT_READY');
    },
  );

  test(
    'direct recording outline retry accepts only its expected task',
    () async {
      const localNoteId = 'local-recording-outline-note-1';
      final recordingApi = _MutableRecordingOutlineApi(
        _recordingOutlineDetail(
          taskId: 'outline-predecessor-1',
          status: RecordingNoteOutlineTaskStatus.failed,
          failureCode: 'OLD_FAILURE',
        ),
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: recordingApi,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-recording-outline-direct-fence',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();

      await tracker.trackRecordingOutline(
        recordingId: 'recording-outline-restore-1',
        localNoteId: localNoteId,
        remoteNoteId: 'remote-recording-outline-note-1',
        restart: true,
        expectedPublicTaskId: 'outline-retry-1',
        supersededPublicTaskId: 'outline-predecessor-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(tracker.lastRecordingOutlineCompletion, isNull);
      expect(tracker.isRecordingOutlinePending(localNoteId), isTrue);
      expect(
        tracker.acceptsRecordingOutlineTask(
          localNoteId,
          'outline-predecessor-1',
        ),
        isFalse,
      );
      expect(
        tracker.acceptsRecordingOutlineTask(localNoteId, 'outline-retry-1'),
        isTrue,
      );

      recordingApi.detail = _recordingOutlineDetail(
        taskId: 'outline-retry-1',
        status: RecordingNoteOutlineTaskStatus.failed,
        failureCode: 'RETRY_FAILURE',
      );
      await tracker.refresh();

      expect(
        tracker.lastRecordingOutlineCompletion?.publicTaskId,
        'outline-retry-1',
      );
      expect(
        tracker.lastRecordingOutlineCompletion?.failureCode,
        'RETRY_FAILURE',
      );
      expect(tracker.isRecordingOutlinePending(localNoteId), isFalse);
    },
  );

  test(
    'predecessor recording outline retry ignores old terminal projections',
    () async {
      const localNoteId = 'local-recording-outline-note-1';
      final recordingApi = _MutableRecordingOutlineApi(
        _recordingOutlineDetail(
          taskId: 'outline-predecessor-1',
          status: RecordingNoteOutlineTaskStatus.failed,
          failureCode: 'OLD_FAILURE',
        ),
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: recordingApi,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'account-recording-outline-predecessor-fence',
        pollInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      await tracker.start();

      await tracker.trackRecordingOutline(
        recordingId: 'recording-outline-restore-1',
        localNoteId: localNoteId,
        remoteNoteId: 'remote-recording-outline-note-1',
        restart: true,
        supersededPublicTaskId: 'outline-predecessor-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(tracker.lastRecordingOutlineCompletion, isNull);
      expect(tracker.isRecordingOutlinePending(localNoteId), isTrue);
      expect(
        tracker.acceptsRecordingOutlineTask(
          localNoteId,
          'outline-predecessor-1',
        ),
        isFalse,
      );
      expect(tracker.acceptsRecordingOutlineTask(localNoteId, null), isFalse);

      recordingApi.detail = _recordingOutlineDetail(
        taskId: 'outline-retry-2',
        status: RecordingNoteOutlineTaskStatus.running,
      );
      await tracker.refresh();

      expect(tracker.recordingOutlineStatus(localNoteId), 'running');
      expect(
        tracker.acceptsRecordingOutlineTask(localNoteId, 'outline-retry-2'),
        isTrue,
      );
      expect(
        tracker.acceptsRecordingOutlineTask(localNoteId, 'outline-other-2'),
        isFalse,
      );

      recordingApi.detail = _recordingOutlineDetail(
        taskId: 'outline-predecessor-1',
        status: RecordingNoteOutlineTaskStatus.failed,
        failureCode: 'OLD_FAILURE',
      );
      await tracker.refresh();
      expect(tracker.lastRecordingOutlineCompletion, isNull);
      expect(tracker.recordingOutlineStatus(localNoteId), 'running');

      recordingApi.detail = _recordingOutlineDetail(
        taskId: 'outline-retry-2',
        status: RecordingNoteOutlineTaskStatus.failed,
        failureCode: 'NEW_FAILURE',
      );
      await tracker.refresh();

      expect(
        tracker.lastRecordingOutlineCompletion?.publicTaskId,
        'outline-retry-2',
      );
      expect(
        tracker.lastRecordingOutlineCompletion?.failureCode,
        'NEW_FAILURE',
      );
      expect(tracker.isRecordingOutlinePending(localNoteId), isFalse);
    },
  );

  test(
    'restart replaces and restores the recording outline task fence',
    () async {
      const scope = 'account-recording-outline-restart-fence';
      const localNoteId = 'local-recording-outline-note-1';
      final database = AppDatabase();
      final first = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: _RecordingOutlineApi(
          _recordingOutlineDetail(
            status: RecordingNoteOutlineTaskStatus.running,
          ),
        ),
        preferences: AppPreferencesDao(database),
        userScope: scope,
        checkpointInterval: Duration.zero,
        pollInterval: const Duration(days: 1),
      );

      await first.trackRecordingOutline(
        recordingId: 'recording-outline-restore-1',
        localNoteId: localNoteId,
        remoteNoteId: 'remote-recording-outline-note-1',
        supersededPublicTaskId: 'outline-predecessor-1',
      );
      expect(
        first.acceptsRecordingOutlineTask(localNoteId, 'outline-other-3'),
        isTrue,
      );
      await first.trackRecordingOutline(
        recordingId: 'recording-outline-restore-1',
        localNoteId: localNoteId,
        remoteNoteId: 'remote-recording-outline-note-1',
        restart: true,
        expectedPublicTaskId: 'outline-retry-3',
        supersededPublicTaskId: 'outline-predecessor-1',
      );
      expect(
        first.acceptsRecordingOutlineTask(localNoteId, 'outline-other-3'),
        isFalse,
      );
      first.dispose();

      final recordingApi = _MutableRecordingOutlineApi(
        _recordingOutlineDetail(
          taskId: 'outline-other-3',
          status: RecordingNoteOutlineTaskStatus.failed,
          failureCode: 'UNRELATED_FAILURE',
        ),
      );
      final restored = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _StableRunPort(_run(status: 'running')),
        ),
        recordingApi: recordingApi,
        preferences: AppPreferencesDao(database),
        userScope: scope,
        checkpointInterval: Duration.zero,
        pollInterval: const Duration(days: 1),
      );
      addTearDown(restored.dispose);
      await restored.start();
      await Future<void>.delayed(Duration.zero);

      expect(restored.lastRecordingOutlineCompletion, isNull);
      expect(restored.isRecordingOutlinePending(localNoteId), isTrue);
      expect(
        restored.acceptsRecordingOutlineTask(localNoteId, 'outline-other-3'),
        isFalse,
      );
      expect(
        restored.acceptsRecordingOutlineTask(localNoteId, 'outline-retry-3'),
        isTrue,
      );

      recordingApi.detail = _recordingOutlineDetail(
        taskId: 'outline-retry-3',
        status: RecordingNoteOutlineTaskStatus.failed,
        failureCode: 'RESTORED_RETRY_FAILURE',
      );
      await restored.refresh();

      expect(
        restored.lastRecordingOutlineCompletion?.publicTaskId,
        'outline-retry-3',
      );
      expect(
        restored.lastRecordingOutlineCompletion?.failureCode,
        'RESTORED_RETRY_FAILURE',
      );
    },
  );
}

RecordingDetail _recordingOutlineDetail({
  required RecordingNoteOutlineTaskStatus status,
  String taskId = 'outline-subtask-1',
  String? outputRevision,
  String? failureCode,
}) => RecordingDetail(
  recording: const RecordingAsset(
    recordingId: 'recording-outline-restore-1',
    title: '录音纲要恢复',
    status: RecordingRemoteStatus.generatingSummary,
    transcriptStatus: 'final_transcript_generated',
    minutesStatus: 'succeeded',
    summaryStatus: 'succeeded',
  ),
  finalTranscript: '已完成的录音转写',
  finalTranscriptConfirmed: true,
  noteRef: RecordingNoteRef(
    noteId: 'remote-recording-outline-note-1',
    rawPartRevisionId: 'raw-recording-outline-revision-1',
    outlinePartRevisionId: outputRevision,
  ),
  noteOutlineTask: RecordingNoteOutlineTask(
    taskId: taskId,
    status: status,
    failureCode: failureCode,
  ),
);

ChatRunCheckpoint _checkpoint(String userScope) => ChatRunCheckpoint(
  userScope: userScope,
  runId: 'agent_run_tracker_1',
  kind: ChatRunCheckpointKind.chat,
  status: 'queued',
  eventSequence: 0,
  threadId: 'thread-a',
  scene: ChatScene.feedAi.apiValue,
  purpose: ChatConversationPurpose.general.apiValue,
  createdAt: DateTime.utc(2026, 8, 31, 9),
  updatedAt: DateTime.utc(2026, 8, 31, 9),
  publicState: <String, Object?>{
    'kind': 'chat',
    'agentRunId': 'agent_run_tracker_1',
    'threadId': 'thread-a',
    'scene': ChatScene.feedAi.apiValue,
    'purpose': ChatConversationPurpose.general.apiValue,
    'status': 'queued',
    'createdAt': DateTime.utc(2026, 8, 31, 9).toIso8601String(),
    'toolTrace': const <Object?>[],
  },
);

ChatRunCheckpoint _checkpointFor(
  String userScope, {
  required String runId,
  DateTime? updatedAt,
}) => ChatRunCheckpoint(
  userScope: userScope,
  runId: runId,
  kind: ChatRunCheckpointKind.chat,
  status: 'queued',
  eventSequence: 0,
  threadId: runId == 'agent_run_tracker_1' ? 'thread-a' : 'thread-$runId',
  scene: ChatScene.feedAi.apiValue,
  purpose: ChatConversationPurpose.general.apiValue,
  createdAt: DateTime.utc(2026, 9, 2, 8),
  updatedAt: updatedAt ?? DateTime.utc(2026, 9, 2, 8),
  publicState: <String, Object?>{
    'kind': 'chat',
    'agentRunId': runId,
    'threadId': runId == 'agent_run_tracker_1' ? 'thread-a' : 'thread-$runId',
    'scene': ChatScene.feedAi.apiValue,
    'purpose': ChatConversationPurpose.general.apiValue,
    'status': 'queued',
    'createdAt': DateTime.utc(2026, 9, 2, 8).toIso8601String(),
    'toolTrace': const <Object?>[],
  },
);

final class _CheckpointWorker implements ChatRunCheckpointWorkerPort {
  _CheckpointWorker({
    this.failChanges = false,
    this.loadGate,
    this.changeGate,
    this.remainingLoadFailures = 0,
  });

  final bool failChanges;
  final Completer<void>? loadGate;
  final Completer<void>? changeGate;
  int remainingLoadFailures;
  final Completer<void> _firstLoadStarted = Completer<void>();
  final Completer<void> _firstChangeStarted = Completer<void>();
  final Map<String, Map<String, ChatRunCheckpoint>> _rows =
      <String, Map<String, ChatRunCheckpoint>>{};
  var changeAttempts = 0;
  var loadAttempts = 0;

  Future<void> get firstLoadStarted => _firstLoadStarted.future;
  Future<void> get firstChangeStarted => _firstChangeStarted.future;

  void seed(ChatRunCheckpoint checkpoint) {
    (_rows[checkpoint.userScope] ??=
            <String, ChatRunCheckpoint>{})[checkpoint.runId] =
        checkpoint;
  }

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  List<ChatRunCheckpoint> rowsFor(String userScope) =>
      List<ChatRunCheckpoint>.unmodifiable(
        _rows[userScope]?.values ?? const <ChatRunCheckpoint>[],
      );

  @override
  Future<void> applyChatRunCheckpointChanges({
    required String userScope,
    required Iterable<ChatRunCheckpoint> upserts,
    required Iterable<String> deletions,
  }) async {
    changeAttempts += 1;
    if (!_firstChangeStarted.isCompleted) _firstChangeStarted.complete();
    final gate = changeGate;
    if (gate != null) await gate.future;
    if (failChanges) throw StateError('injected checkpoint failure');
    final next = Map<String, ChatRunCheckpoint>.of(
      _rows[userScope] ?? const <String, ChatRunCheckpoint>{},
    );
    for (final checkpoint in upserts) {
      next[checkpoint.runId] = checkpoint;
    }
    for (final runId in deletions) {
      next.remove(runId);
    }
    _rows[userScope] = next;
  }

  @override
  Future<bool> deleteChatRunCheckpoint({
    required String userScope,
    required String runId,
  }) async {
    final existed = _rows[userScope]?.containsKey(runId) == true;
    await applyChatRunCheckpointChanges(
      userScope: userScope,
      upserts: const <ChatRunCheckpoint>[],
      deletions: <String>[runId],
    );
    return existed;
  }

  @override
  Future<List<ChatRunCheckpoint>> listChatRunCheckpoints(
    String userScope,
  ) async {
    loadAttempts += 1;
    final captured = rowsFor(userScope);
    if (!_firstLoadStarted.isCompleted) _firstLoadStarted.complete();
    final gate = loadGate;
    if (gate != null) await gate.future;
    if (remainingLoadFailures > 0) {
      remainingLoadFailures -= 1;
      throw StateError('injected checkpoint load failure');
    }
    return captured;
  }

  @override
  Future<void> upsertChatRunCheckpoint(ChatRunCheckpoint checkpoint) {
    return applyChatRunCheckpointChanges(
      userScope: checkpoint.userScope,
      upserts: <ChatRunCheckpoint>[checkpoint],
      deletions: const <String>[],
    );
  }
}

final class _PreferenceWorker implements DatabaseRecordWorkerPort {
  final Map<String, LocalDatabaseRecord> _records =
      <String, LocalDatabaseRecord>{};
  var upsertAttempts = 0;

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  List<LocalDatabaseRecord> get records =>
      List<LocalDatabaseRecord>.unmodifiable(_records.values);

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => _records.remove('${table.dbName}:$key') != null;

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      List<LocalDatabaseRecord>.unmodifiable(
        _records.entries
            .where((entry) => entry.key.startsWith('${table.dbName}:'))
            .map((entry) => entry.value),
      );

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async {
    upsertAttempts += 1;
    _records['${table.dbName}:$key'] = Map<String, Object?>.unmodifiable(
      record,
    );
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    for (final entry in records.entries) {
      await upsertRecord(table: table, key: entry.key, record: entry.value);
    }
  }
}

Future<void> _waitForCallCount(List<Object?> calls, int expected) async {
  for (var attempt = 0; attempt < 40 && calls.length < expected; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(calls.length, greaterThanOrEqualTo(expected));
}

AgentRunSnapshot _run({
  required String status,
  String agentRunId = 'agent_run_tracker_1',
  String? assistantMessageId,
  String? completionMode,
  DateTime? createdAt,
  List<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
}) => AgentRunSnapshot(
  agentRunId: agentRunId,
  workspaceId: 'workspace-1',
  threadId: 'thread-a',
  status: status,
  workspaceVersion: 1,
  workspaceBindingVersion: 1,
  contextGeneration: 1,
  assistantMessageId: assistantMessageId,
  completionMode: completionMode,
  usage: const AgentRunUsage(
    measurementStatus: 'unavailable',
    inputTokens: null,
    outputTokens: null,
    imageCount: null,
    videoSeconds: null,
    accountedCredits: null,
    policyVersion: null,
  ),
  toolTrace: toolTrace,
  createdAt: createdAt ?? DateTime.utc(2026, 8, 13, 8),
  updatedAt: DateTime.utc(2026, 8, 13, 8, 0, 1),
);

ApiResult<AgentRunSnapshot> _success(AgentRunSnapshot run) =>
    ApiResult<AgentRunSnapshot>.success(
      data: run,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );

final class _StableRunPort implements ProjectRunFixture {
  const _StableRunPort(this.result);

  final AgentRunSnapshot result;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async => _success(result);
}

final class _QueuedRunPort implements ProjectRunFixture {
  _QueuedRunPort(Iterable<FutureOr<ApiResult<AgentRunSnapshot>>> results)
    : _results = List<FutureOr<ApiResult<AgentRunSnapshot>>>.of(results);

  final List<FutureOr<ApiResult<AgentRunSnapshot>>> _results;
  final calls = <String>[];

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    calls.add(agentRunId);
    return await _results.removeAt(0);
  }
}

final class _CancellableRunPort
    implements ProjectRunFixture, ProjectRunLeaseFixture {
  final Completer<void> started = Completer<void>();
  final Completer<ApiResult<AgentRunSnapshot>> _result =
      Completer<ApiResult<AgentRunSnapshot>>();
  int cancelCalls = 0;

  void completeLate(ApiResult<AgentRunSnapshot> result) {
    if (!_result.isCompleted) _result.complete(result);
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({required String agentRunId}) =>
      _result.future;

  @override
  LegacyAssistantReadLease leaseGetRun({required String agentRunId}) {
    if (!started.isCompleted) started.complete();
    return LegacyAssistantReadLease(
      result: _result.future,
      cancel: () => cancelCalls += 1,
    );
  }
}

final class _StreamingRunPort
    implements ProjectRunFixture, ProjectRunStreamFixture {
  _StreamingRunPort({
    required this.events,
    Iterable<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>? streams,
    required Iterable<FutureOr<ApiResult<AgentRunSnapshot>>> results,
  }) : streams = streams == null
           ? null
           : List<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>.of(
               streams,
             ),
       results = List<FutureOr<ApiResult<AgentRunSnapshot>>>.of(results);

  final StreamController<ApiServerSentEvent<AgentRunStreamPayload>> events;
  final List<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>? streams;
  final List<FutureOr<ApiResult<AgentRunSnapshot>>> results;
  final streamOpened = Completer<void>();
  final reconnectOpened = Completer<void>();
  final pollCalls = <String>[];
  final streamLastEventIds = <String?>[];

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    pollCalls.add(agentRunId);
    return await results.removeAt(0);
  }

  @override
  Future<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  streamEvents({required String agentRunId, String? lastEventId}) async {
    streamLastEventIds.add(lastEventId);
    if (streamLastEventIds.length == 1 && !streamOpened.isCompleted) {
      streamOpened.complete();
    }
    if (streamLastEventIds.length == 2 && !reconnectOpened.isCompleted) {
      reconnectOpened.complete();
    }
    return ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>.success(
      data: streams == null || streams!.isEmpty
          ? events.stream
          : streams!.removeAt(0),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _SnapshotStreamingRunPort
    implements ProjectRunFixture, ProjectRunStreamFixture {
  _SnapshotStreamingRunPort({required this.events, required this.snapshots});

  final StreamController<ApiServerSentEvent<AgentRunStreamPayload>> events;
  final List<AgentRunSnapshot> snapshots;
  final streamOpened = Completer<void>();
  var pollCalls = 0;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    final index = pollCalls.clamp(0, snapshots.length - 1);
    pollCalls += 1;
    return _success(snapshots[index]);
  }

  @override
  Future<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  streamEvents({required String agentRunId, String? lastEventId}) async {
    if (!streamOpened.isCompleted) streamOpened.complete();
    return ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>.success(
      data: events.stream,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _DeferredStreamRunPort
    implements ProjectRunFixture, ProjectRunStreamFixture {
  _DeferredStreamRunPort(this.events);

  final StreamController<ApiServerSentEvent<AgentRunStreamPayload>> events;
  final Completer<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  _streamResult =
      Completer<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>();
  final List<String> pollCalls = <String>[];

  void openStream() {
    _streamResult.complete(
      ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>.success(
        data: events.stream,
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    pollCalls.add(agentRunId);
    return _success(_run(status: 'running'));
  }

  @override
  Future<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  streamEvents({required String agentRunId, String? lastEventId}) =>
      _streamResult.future;
}

ApiServerSentEvent<AgentRunStreamPayload> _streamEvent(
  Map<String, Object?> value,
) => ApiServerSentEvent<AgentRunStreamPayload>(
  event: value['eventType'] as String? ?? 'error',
  data: AgentRunStreamPayload.fromValue(value),
);

final class _PublicFileAgentRunPort implements NoteFileAgentRunStatusPort {
  const _PublicFileAgentRunPort(this.result);

  final NoteFileAgentRunStatus result;

  @override
  Future<NoteFileAgentRunStatus> getRun({
    required String noteId,
    required String fileAgentRunId,
  }) async => result;
}

final class _MutablePublicFileAgentRunPort
    implements NoteFileAgentRunStatusPort {
  _MutablePublicFileAgentRunPort(this.result);

  NoteFileAgentRunStatus result;

  @override
  Future<NoteFileAgentRunStatus> getRun({
    required String noteId,
    required String fileAgentRunId,
  }) async => result;
}

final class _QueuedPublicFileAgentRunPort
    implements NoteFileAgentRunStatusPort {
  _QueuedPublicFileAgentRunPort(
    Iterable<FutureOr<NoteFileAgentRunStatus>> results,
  ) : _results = List<FutureOr<NoteFileAgentRunStatus>>.of(results);

  final List<FutureOr<NoteFileAgentRunStatus>> _results;
  final List<String> calls = <String>[];
  final Completer<void> _firstCallStarted = Completer<void>();

  Future<void> get firstCallStarted => _firstCallStarted.future;

  @override
  Future<NoteFileAgentRunStatus> getRun({
    required String noteId,
    required String fileAgentRunId,
  }) async {
    calls.add(fileAgentRunId);
    if (!_firstCallStarted.isCompleted) _firstCallStarted.complete();
    return await _results.removeAt(0);
  }
}

final class _RecordingOutlineApi implements RecordingApiPort {
  const _RecordingOutlineApi(this.detail);

  final RecordingDetail detail;

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async => ApiResult<RecordingDetail>.success(
    data: detail,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _MutableRecordingOutlineApi implements RecordingApiPort {
  _MutableRecordingOutlineApi(this.detail);

  RecordingDetail detail;

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async => ApiResult<RecordingDetail>.success(
    data: detail,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
