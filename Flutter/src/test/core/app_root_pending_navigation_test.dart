import 'dart:async';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:huahuoai_app/app/di/native_port_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/billing_providers.dart';
import 'package:huahuoai_app/app/bootstrap/app_root.dart';
import 'package:huahuoai_app/app/bootstrap/push_runtime_activation.dart';
import 'package:huahuoai_app/app/bootstrap/recovery_runtime_activation.dart';
import 'package:huahuoai_app/app/bootstrap/upload_recovery_bootstrap.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/route_guards.dart';
import 'package:huahuoai_app/app/navigation/pending_navigation_controller.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/api/app_cache_policy.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/native/incoming_material_port.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';
import 'package:huahuoai_app/features/billing/application/billing_controller.dart';
import 'package:huahuoai_app/features/billing/data/android_payment_port.dart';
import 'package:huahuoai_app/features/billing/data/billing_api.dart';
import 'package:huahuoai_app/features/billing/data/billing_pending_order_store.dart';
import 'package:huahuoai_app/features/billing/data/ios_store_purchase_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_navigation_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_registration_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_runtime_controller.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';
import 'package:huahuoai_app/features/notifications/data/push_device_api.dart';
import 'package:huahuoai_app/features/notifications/infrastructure/push_provider.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/onboarding/presentation/content_line_onboarding_page.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/daily_topic_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/outline_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';

final _useReplacementTrackerProvider = StateProvider<bool>((ref) => false);
final _useReplacementAggregationProvider = StateProvider<bool>((ref) => false);
final _knowledgeGenerationProvider = StateProvider<int>((ref) => 0);
final _knowledgeGenerationProjectionProvider = Provider<int>(
  (ref) => ref.watch(_knowledgeGenerationProvider),
);

void main() {
  testWidgets('Knowledge replacement waits for notification to unwind', (
    tester,
  ) async {
    final fixture = await _RootFixture.create();
    final activity = AppActivityCoordinator();
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    final libraries = <KnowledgeLibraryController>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue(
            'notification-replacement-device',
          ),
          appBootstrapControllerProvider.overrideWith(
            (ref) => fixture.bootstrap,
          ),
          sessionStoreProvider.overrideWith((ref) => fixture.session),
          chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
          pushRuntimeControllerProvider.overrideWith(
            (ref) => fixture.pushRuntime,
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
          taskOrchestratorProvider.overrideWith((ref) => orchestrator),
          knowledgeLibraryControllerProvider.overrideWith((ref) {
            ref.watch(_knowledgeGenerationProjectionProvider);
            final library = KnowledgeLibraryController(
              initialNotes: const [],
              includeDemoFixtures: false,
            );
            if (libraries.isEmpty) {
              library.addListener(() {
                ref.read(_knowledgeGenerationProvider.notifier).state += 1;
              });
            }
            libraries.add(library);
            return library;
          }),
        ],
        child: const PushRuntimeActivation(child: SizedBox()),
      ),
    );
    for (var frame = 0; frame < 12; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PushRuntimeActivation)),
    );
    final original = container.read(knowledgeLibraryControllerProvider);
    original.notifyListeners();
    await tester.pump();
    expect(
      container.read(knowledgeLibraryControllerProvider),
      isNot(same(original)),
    );
    expect(libraries, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('chat tracker workspace scope is bounded and identity isolated', () {
    const accountId = 'account-sensitive-123';
    const workspaceId = 'workspace-sensitive-456';
    final scope = chatRunTrackerWorkspaceScope(
      accountScope: accountId,
      workspaceScope: workspaceId,
    );

    expect(scope, matches(RegExp(r'^chat-workspace-sha256-v1:[a-f0-9]{64}$')));
    expect(scope, hasLength('chat-workspace-sha256-v1:'.length + 64));
    expect(scope, isNot(contains(accountId)));
    expect(scope, isNot(contains(workspaceId)));
    expect(
      chatRunTrackerWorkspaceScope(
        accountScope: accountId,
        workspaceScope: workspaceId,
      ),
      scope,
    );
    expect(
      chatRunTrackerWorkspaceScope(
        accountScope: accountId,
        workspaceScope: 'workspace-sensitive-789',
      ),
      isNot(scope),
    );
    expect(
      chatRunTrackerWorkspaceScope(
        accountScope: 'account-sensitive-789',
        workspaceScope: workspaceId,
      ),
      isNot(scope),
    );
    expect(
      chatRunTrackerWorkspaceScope(
        accountScope: 'anonymous',
        workspaceScope: workspaceId,
      ),
      'anonymous',
    );
  });

  for (final backgroundReplacement in [false, true]) {
    testWidgets(
      'positioning runtime replaces its notifier background=$backgroundReplacement',
      (tester) async {
        final fixture = await _RootFixture.create();
        final router = _router(fixture);
        addTearDown(router.dispose);
        final activity = AppActivityCoordinator();
        final replacement = InitialPositioningTaskCoordinator(
          onboardingApi: const _UnusedOnboardingApi(),
          positioningAgent: const _UnusedInitialPositioningAgent(),
          sessionStore: fixture.session,
          reportSink: const _NoopInitialPositioningReportSink(),
          continuation: fixture.continuation,
          taskTracker: fixture.tracker,
        );
        var current = fixture.initialPositioning;
        const receipt = InitialPositioningRunReceipt(
          threadId: 'thread_positioning_replacement',
          agentRunId: 'agent_run_positioning_replacement',
          taskId: 'task_positioning_replacement',
          messageId: 'message_positioning_replacement',
          status: 'sent',
        );
        expect(fixture.continuation.acceptRun('user-1', receipt), isTrue);
        expect(
          fixture.continuation.recordRunRegistration(
            'user-1',
            agentRunId: receipt.agentRunId,
            workspaceId: 'workspace-1',
            attemptId: 'attempt_positioning_replacement',
          ),
          isTrue,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...fixture.overrides(router, resolvePositioning: () => current),
              appActivityCoordinatorProvider.overrideWith((ref) => activity),
              dailyTopicControllerProvider.overrideWith(
                (ref) => DailyTopicController(
                  port: _EmptyDailyTopicPort(),
                  preferences: AppPreferencesDao(AppDatabase()),
                  userScope: 'user-1',
                  workspaceId: () => 'workspace-1',
                  workspaceReady: () => true,
                  cacheTtl: () => const Duration(minutes: 5),
                ),
              ),
            ],
            child: const AppRoot(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(current.state.status, InitialPositioningTaskStatus.running);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppRoot)),
          listen: false,
        );
        final previousValues = <InitialPositioningTaskCoordinator?>[];
        final subscription = container.listen(
          initialPositioningTaskCoordinatorProvider.notifier,
          (previous, next) => previousValues.add(previous),
        );
        addTearDown(subscription.close);
        if (backgroundReplacement) {
          activity.updateLifecycle(AppLifecycleState.paused);
        }
        current = replacement;
        container.invalidate(initialPositioningTaskCoordinatorProvider);
        expect(
          container.read(initialPositioningTaskCoordinatorProvider),
          same(replacement),
        );
        await tester.pump();
        expect(previousValues, <InitialPositioningTaskCoordinator?>[null]);
        if (backgroundReplacement) {
          await tester.pump(const Duration(milliseconds: 500));
          expect(replacement.state.status, InitialPositioningTaskStatus.idle);
          activity.updateLifecycle(AppLifecycleState.resumed);
        }
        await tester.pump(const Duration(milliseconds: 500));

        expect(replacement.state.status, InitialPositioningTaskStatus.running);
        expect(replacement.state.agentRunId, receipt.agentRunId);
        expect(
          fixture.continuation.acceptedRunFor('user-1')?.agentRunId,
          receipt.agentRunId,
        );
        expect(
          container.read(initialPositioningTaskCoordinatorProvider),
          same(replacement),
        );
        expect(previousValues, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final replacementState in <AppLifecycleState?>[
    null,
    AppLifecycleState.inactive,
    AppLifecycleState.paused,
  ]) {
    final backgroundReplacement = replacementState == AppLifecycleState.paused;
    final inactiveReplacement = replacementState == AppLifecycleState.inactive;
    testWidgets(
      'aggregation runtime follows replacement controller state=${replacementState?.name ?? 'foreground'}',
      (tester) async {
        final fixture = await _RootFixture.create();
        final activity = AppActivityCoordinator();
        final orchestrator = TaskOrchestrator();
        addTearDown(orchestrator.dispose);
        final library = KnowledgeLibraryController(
          includeDemoFixtures: false,
          initialNotes: List.generate(
            4,
            (index) => V3FeedItem(
              id: 'note-$index',
              remoteNoteId: 'remote-$index',
              remoteSourceKind: 'manual',
              rawPartRevisionId: 'raw-$index',
              title: '来源 $index',
              source: V3MaterialSource.note,
              rawBody: '有效正文 $index',
              syncState: NoteSyncState.synced,
              createdAt: DateTime.utc(2026, 9, 6),
            ),
          ),
        );
        for (final note in library.notes) {
          library.depositContent(note.id);
        }
        final profile = ProfileHubController(
          referenceDay: DateTime.utc(2026, 9, 6),
        );
        final initial = FeedAggregationController(
          library: library,
          profileHub: profile,
          repository: const UnavailableFeedAggregationRepository(),
        );
        final remote = _AggregationRuntimePort();
        final diagnosticDao = DiagnosticLogDao(AppDatabase());
        final diagnosticLogger = DiagnosticLogger(dao: diagnosticDao);
        addTearDown(diagnosticLogger.dispose);
        final replacement = FeedAggregationController(
          library: library,
          profileHub: profile,
          repository: const UnavailableFeedAggregationRepository(),
          topicCollisionRuns: remote,
          diagnosticLogger: diagnosticLogger,
          preferences: AppPreferencesDao(AppDatabase()),
          userScope: 'user-1',
          workspaceId: () => 'workspace-1',
          workspaceReady: () => true,
          productionPollInterval: const Duration(milliseconds: 30),
        );
        if (replacementState != null) {
          replacement.startSelection();
          await replacement.confirm();
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              resolvedDeviceIdProvider.overrideWithValue('test-device'),
              appBootstrapControllerProvider.overrideWith(
                (ref) => fixture.bootstrap,
              ),
              sessionStoreProvider.overrideWith((ref) => fixture.session),
              chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
              pushRuntimeControllerProvider.overrideWith(
                (ref) => fixture.pushRuntime,
              ),
              pushRegistrationControllerProvider.overrideWith(
                (ref) => PushRegistrationController(
                  provider: const UnavailablePushProvider(),
                  api: const UnavailablePushDeviceApi(),
                  sessionStore: fixture.session,
                  deviceId: 'test-device',
                  platform: 'ios',
                  appVersion: () async => 'test',
                ),
              ),
              appCachePolicyProvider.overrideWithValue(AppCachePolicy()),
              dailyTopicControllerProvider.overrideWith(
                (ref) => DailyTopicController(
                  port: _EmptyDailyTopicPort(),
                  preferences: AppPreferencesDao(AppDatabase()),
                  userScope: 'user-1',
                  workspaceId: () => 'workspace-1',
                  workspaceReady: () => true,
                  cacheTtl: () => const Duration(minutes: 5),
                ),
              ),
              knowledgeLibraryControllerProvider.overrideWith((ref) => library),
              feedAggregationControllerProvider.overrideWith(
                (ref) => ref.watch(_useReplacementAggregationProvider)
                    ? replacement
                    : initial,
              ),
              appActivityCoordinatorProvider.overrideWith((ref) => activity),
              taskOrchestratorProvider.overrideWith((ref) => orchestrator),
            ],
            child: const PushRuntimeActivation(child: SizedBox()),
          ),
        );
        await tester.pump();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PushRuntimeActivation)),
        );
        if (replacementState != null) {
          activity.updateLifecycle(replacementState);
        }
        container.read(_useReplacementAggregationProvider.notifier).state =
            true;
        await tester.pump();
        if (backgroundReplacement) {
          await tester.pump(const Duration(milliseconds: 350));
          expect(remote.readRunIds, isEmpty);
          activity.updateLifecycle(AppLifecycleState.resumed);
        } else if (inactiveReplacement) {
          activity.updateLifecycle(AppLifecycleState.resumed);
        } else {
          expect(replacement.startSelection(), isTrue);
          await replacement.confirm();
        }
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          remote.readRunIds,
          isNotEmpty,
          reason:
              '${replacement.productionPhase} ${replacement.errorCode} foreground=${activity.state.isForeground} task=${orchestrator.projectionFor('feed-aggregation:production-run-poll')?.state}',
        );
        expect(remote.readRunIds.toSet(), {'aggregation-runtime-run'});
        expect(remote.readWorkspaces.toSet(), {'workspace-1'});
        expect(remote.submissions, 1);
        remote.status = 'dead_letter';
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          replacement.productionPhase,
          FeedAggregationPhase.failed,
          reason:
              '${replacement.errorCode} reads=${remote.readRunIds.length} tasks=${orchestrator.snapshot.projections.map((task) => '${task.spec.key}:${task.state}').join(',')}',
        );
        expect(replacement.errorCode, 'NOTE_TOPIC_COLLISION_OUTPUT_INVALID');
        expect(replacement.taskMessage, contains('未通过校验'));
        expect(replacement.generatedNote, isNull);
        expect(remote.submissions, 1);
        final events = diagnosticDao.query();
        final attachments = events.where(
          (event) =>
              event.safeSummary == 'Aggregation polling runtime attached',
        );
        expect(attachments, hasLength(1));
        expect(attachments.single.redactedMetadata['aggregate_count'], 1);
        final read = events.singleWhere(
          (event) => event.safeSummary == 'Aggregation task query received',
        );
        expect(read.redactedMetadata['polling_attached'], isTrue);
        expect(read.redactedMetadata['polling_paused'], isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'protected deep link waits through startup setup after questionnaire deferral',
    (tester) async {
      final fixture = await _RootFixture.create();
      final router = _router(fixture);
      addTearDown(router.dispose);
      expect(
        fixture.pending.stage(
          location: '/v3/feed/items/note-deep-link',
          reason: PendingNavigationReason.deepLink,
        ),
        isTrue,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides(router),
          child: const AppRoot(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('基础定位'), findsOneWidget);
      expect(
        fixture.pending.pending?.location,
        '/v3/feed/items/note-deep-link',
      );

      await tester.tap(find.byKey(const ValueKey('onboarding-defer')));
      await tester.pumpAndSettle();
      expect(find.text('mandatory-setup'), findsOneWidget);
      expect(
        fixture.journey.snapshot.positioning.status,
        FirstLaunchStepStatus.deferred,
      );
      expect(fixture.journey.requiresBlockingJourney, isTrue);

      expect(
        fixture.pending.pending?.location,
        '/v3/feed/items/note-deep-link',
      );
      await _finishDeviceSetup(tester, fixture);
      expect(find.text('deep-link-target'), findsOneWidget);
      expect(fixture.pending.pending, isNull);
      expect(fixture.continuation.isDeferredFor('user-1'), isFalse);
    },
  );

  testWidgets(
    'cold-start inbox Push waits through startup setup after questionnaire deferral',
    (tester) async {
      final fixture = await _RootFixture.create();
      final router = _router(fixture);
      addTearDown(router.dispose);
      fixture.pushNavigation.receive(
        const InboxPushMessage(
          notificationId: 'notice-guarded-1',
          eventType: 'hotspot_suggestion',
          receiveType: PushReceiveType.coldStart,
        ),
        PushReceiveType.coldStart,
      );
      final commandId = fixture.pushNavigation.pendingCommand!.id;

      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides(router),
          child: const AppRoot(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('基础定位'), findsOneWidget);
      expect(fixture.pushNavigation.pendingCommand?.id, commandId);

      await tester.tap(find.byKey(const ValueKey('onboarding-defer')));
      await tester.pumpAndSettle();
      expect(find.text('mandatory-setup'), findsOneWidget);
      expect(
        fixture.journey.snapshot.positioning.status,
        FirstLaunchStepStatus.deferred,
      );
      expect(fixture.journey.requiresBlockingJourney, isTrue);
      expect(fixture.pushNavigation.pendingCommand?.id, commandId);
      await _finishDeviceSetup(tester, fixture);

      expect(find.text('notifications-target'), findsOneWidget);
      expect(fixture.pushNavigation.pendingCommand, isNull);
    },
  );

  testWidgets(
    'push activation keeps one lifecycle key and cancels owned queued work',
    (tester) async {
      final fixture = await _RootFixture.create();
      final activity = AppActivityCoordinator();
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      final blocker = Completer<void>();
      final blockerFuture = orchestrator.schedule<void>(
        TaskSpec(
          key: 'test:network-blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => blocker.future,
      );
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
      );
      final feed = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(
          referenceDay: DateTime.utc(2026, 8, 31),
        ),
        repository: const UnavailableFeedAggregationRepository(),
      );
      addTearDown(() {
        orchestrator.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
            pushRuntimeControllerProvider.overrideWith(
              (ref) => fixture.pushRuntime,
            ),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedAggregationControllerProvider.overrideWith((ref) => feed),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            taskOrchestratorProvider.overrideWith((ref) => orchestrator),
          ],
          child: const PushRuntimeActivation(child: SizedBox()),
        ),
      );
      await tester.pump();

      expect(
        orchestrator.projectionFor('runtime:push:lifecycle')?.state,
        isA<AppTaskQueued>(),
      );
      expect(orchestrator.projectionFor('runtime:push:start'), isNull);
      expect(orchestrator.projectionFor('runtime:push:resume'), isNull);
      expect(
        orchestrator.projectionFor('runtime:feed-aggregation:resume'),
        isNull,
      );

      activity.updateLifecycle(AppLifecycleState.inactive);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        orchestrator.projectionFor('runtime:push:lifecycle')?.state,
        isA<AppTaskQueued>(),
      );
      await tester.pumpWidget(const SizedBox());

      for (final key in const <String>{
        'runtime:account-binding',
        'runtime:push:lifecycle',
        'runtime:notifications:reconcile',
        'runtime:daily-topic:refresh',
        'runtime:chat-run-tracker:resume',
        'runtime:cache-policy:refresh',
        'runtime:bootstrap-status:refresh',
      }) {
        expect(
          orchestrator.projectionFor(key)?.state,
          isA<AppTaskCancelled>(),
          reason: key,
        );
      }

      blocker.complete();
      await blockerFuture;
    },
  );

  testWidgets(
    'notification reconciliation ignores inactive and follows real background',
    (tester) async {
      final fixture = await _RootFixture.create();
      final activity = AppActivityCoordinator()
        ..updateLifecycle(AppLifecycleState.resumed);
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 8},
      );
      final notificationApi = _CountingNotificationApi();
      final notifications = NotificationController(api: notificationApi);
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        includeDemoFixtures: false,
      );
      final feed = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(
          referenceDay: DateTime.utc(2026, 8, 31),
        ),
        repository: const UnavailableFeedAggregationRepository(),
      );
      addTearDown(orchestrator.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
            pushRuntimeControllerProvider.overrideWith(
              (ref) => fixture.pushRuntime,
            ),
            pushRegistrationControllerProvider.overrideWith(
              (ref) => PushRegistrationController(
                provider: const UnavailablePushProvider(),
                api: const UnavailablePushDeviceApi(),
                sessionStore: fixture.session,
                deviceId: 'test-device',
                platform: 'ios',
                appVersion: () async => 'test',
              ),
            ),
            notificationControllerProvider.overrideWith((ref) => notifications),
            appCachePolicyProvider.overrideWithValue(AppCachePolicy()),
            dailyTopicControllerProvider.overrideWith(
              (ref) => DailyTopicController(
                port: _EmptyDailyTopicPort(),
                preferences: AppPreferencesDao(AppDatabase()),
                userScope: 'user-1',
                workspaceId: () => 'workspace-1',
                workspaceReady: () => true,
                cacheTtl: () => const Duration(minutes: 5),
              ),
            ),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedAggregationControllerProvider.overrideWith((ref) => feed),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            taskOrchestratorProvider.overrideWith((ref) => orchestrator),
          ],
          child: const PushRuntimeActivation(child: SizedBox()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(notificationApi.listCalls, 1);

      notificationApi.failNextList = true;
      activity.updateLifecycle(AppLifecycleState.paused);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 20));
      expect(notificationApi.listCalls, 2);
      expect(notifications.state.lastErrorCode, 'NOTIFICATION_LOAD_FAILED');

      activity.updateLifecycle(AppLifecycleState.inactive);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 20));
      expect(notificationApi.listCalls, 2);

      activity.updateLifecycle(AppLifecycleState.paused);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 20));
      expect(notificationApi.listCalls, 3);
      expect(notifications.state.lastErrorCode, isNull);

      activity.updateLifecycle(AppLifecycleState.inactive);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 20));
      expect(notificationApi.listCalls, 3);
    },
  );

  testWidgets('queued push activation resolves the latest chat tracker', (
    tester,
  ) async {
    final fixture = await _RootFixture.create();
    final activity = AppActivityCoordinator();
    final orchestrator = TaskOrchestrator(
      resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
    );
    final blocker = Completer<void>();
    final blockerFuture = orchestrator.schedule<void>(
      TaskSpec(
        key: 'test:tracker-network-blocker',
        owner: 'test',
        priority: TaskPriority.userBlocking,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => blocker.future,
    );
    final firstWorker = _CountingCheckpointWorker();
    final replacementWorker = _CountingCheckpointWorker();
    final firstTracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user-1',
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: firstWorker,
        writeQueue: DatabaseWriteQueue(),
      ),
    );
    final replacementTracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user-1',
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: replacementWorker,
        writeQueue: DatabaseWriteQueue(),
      ),
    );
    final registration = PushRegistrationController(
      provider: const UnavailablePushProvider(),
      api: const UnavailablePushDeviceApi(),
      sessionStore: fixture.session,
      deviceId: 'test-device',
      platform: 'ios',
      appVersion: () async => 'test',
    );
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      includeDemoFixtures: false,
    );
    final feed = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime.utc(2026, 8, 31)),
      repository: const UnavailableFeedAggregationRepository(),
    );
    addTearDown(orchestrator.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          appBootstrapControllerProvider.overrideWith(
            (ref) => fixture.bootstrap,
          ),
          sessionStoreProvider.overrideWith((ref) => fixture.session),
          _useReplacementTrackerProvider.overrideWith((ref) => false),
          chatRunTrackerProvider.overrideWith((ref) {
            return ref.watch(_useReplacementTrackerProvider)
                ? replacementTracker
                : firstTracker;
          }),
          pushRegistrationControllerProvider.overrideWith(
            (ref) => registration,
          ),
          pushRuntimeControllerProvider.overrideWith(
            (ref) => fixture.pushRuntime,
          ),
          appCachePolicyProvider.overrideWithValue(AppCachePolicy()),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith((ref) => feed),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
          taskOrchestratorProvider.overrideWith((ref) => orchestrator),
        ],
        child: const PushRuntimeActivation(child: SizedBox()),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PushRuntimeActivation)),
    );
    container.read(_useReplacementTrackerProvider.notifier).state = true;
    await tester.pump();

    blocker.complete();
    await blockerFuture;
    for (var index = 0; index < 8; index += 1) {
      await tester.pump();
    }

    expect(firstWorker.listCalls, 0);
    expect(replacementWorker.listCalls, 1);
    expect(orchestrator.projectionFor('runtime:push:start'), isNull);
    expect(orchestrator.projectionFor('runtime:push:resume'), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logout clears chat trackers from every visited workspace', (
    tester,
  ) async {
    final fixture = await _RootFixture.create();
    final activity = AppActivityCoordinator()
      ..updateLifecycle(AppLifecycleState.resumed);
    final orchestrator = TaskOrchestrator();
    final workspaceOneWorker = _CountingCheckpointWorker();
    final workspaceOneQueue = DatabaseWriteQueue();
    final workspaceOneTracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user-1-workspace-1',
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: workspaceOneWorker,
        writeQueue: workspaceOneQueue,
      ),
    );
    final workspaceTwoWorker = _CountingCheckpointWorker();
    final workspaceTwoQueue = DatabaseWriteQueue();
    final workspaceTwoTracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user-1-workspace-2',
      checkpointPersistence: ChatRunCheckpointPersistence(
        worker: workspaceTwoWorker,
        writeQueue: workspaceTwoQueue,
      ),
    );
    final anonymousTracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'anonymous',
    );
    final registration = PushRegistrationController(
      provider: const UnavailablePushProvider(),
      api: const UnavailablePushDeviceApi(),
      sessionStore: fixture.session,
      deviceId: 'test-device',
      platform: 'ios',
      appVersion: () async => 'test',
    );
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      includeDemoFixtures: false,
    );
    final feed = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime.utc(2026, 9, 15)),
      repository: const UnavailableFeedAggregationRepository(),
    );
    addTearDown(() async {
      await workspaceOneQueue.dispose();
      await workspaceTwoQueue.dispose();
      orchestrator.dispose();
    });
    await workspaceOneTracker.trackAcceptedRun(
      agentRunId: 'agent_run_logout_workspace_1',
      publicTaskId: 'public_logout_workspace_1',
      threadId: 'thread-logout-workspace-1',
      scene: ChatScene.feedAi,
    );
    await workspaceTwoTracker.trackAcceptedRun(
      agentRunId: 'agent_run_logout_workspace_2',
      publicTaskId: 'public_logout_workspace_2',
      threadId: 'thread-logout-workspace-2',
      scene: ChatScene.feedAi,
    );
    expect(workspaceOneWorker.rowsFor('user-1-workspace-1'), hasLength(1));
    expect(workspaceTwoWorker.rowsFor('user-1-workspace-2'), hasLength(1));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          appBootstrapControllerProvider.overrideWith(
            (ref) => fixture.bootstrap,
          ),
          sessionStoreProvider.overrideWith((ref) => fixture.session),
          chatRunTrackerProvider.overrideWith((ref) {
            final workspaceId = ref.watch(
              sessionStoreProvider.select(
                (store) => readyWorkspaceId(store.state),
              ),
            );
            return switch (workspaceId) {
              'workspace-1' => workspaceOneTracker,
              'workspace-2' => workspaceTwoTracker,
              _ => anonymousTracker,
            };
          }),
          pushRegistrationControllerProvider.overrideWith(
            (ref) => registration,
          ),
          pushRuntimeControllerProvider.overrideWith(
            (ref) => fixture.pushRuntime,
          ),
          appCachePolicyProvider.overrideWithValue(AppCachePolicy()),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith((ref) => feed),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
          taskOrchestratorProvider.overrideWith((ref) => orchestrator),
        ],
        child: const PushRuntimeActivation(child: SizedBox()),
      ),
    );
    await tester.pump();

    fixture.session.refreshUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-2',
        ),
      ),
      updatedAt: DateTime.utc(2026, 9, 15, 9, 58),
    );
    await tester.pump();
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(PushRuntimeActivation)),
      ).read(chatRunTrackerProvider),
      same(workspaceTwoTracker),
    );

    fixture.session.restoreFromUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(status: SessionWorkspaceStatus.syncFailed),
      ),
      restoredAt: DateTime.utc(2026, 9, 15, 9, 59),
    );
    await tester.pump();
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(PushRuntimeActivation)),
      ).read(chatRunTrackerProvider),
      same(anonymousTracker),
    );

    await fixture.session.logout(loggedOutAt: DateTime.utc(2026, 9, 15, 10));
    for (var index = 0; index < 8; index += 1) {
      await tester.pump();
    }
    await workspaceOneTracker.flushCheckpointPersistence();
    await workspaceTwoTracker.flushCheckpointPersistence();

    expect(workspaceOneTracker.hasPendingRuns, isFalse);
    expect(workspaceTwoTracker.hasPendingRuns, isFalse);
    expect(workspaceOneWorker.rowsFor('user-1-workspace-1'), isEmpty);
    expect(workspaceTwoWorker.rowsFor('user-1-workspace-2'), isEmpty);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(PushRuntimeActivation)),
      ).read(chatRunTrackerProvider),
      same(anonymousTracker),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'workspace replacement starts its tracker without a lifecycle transition',
    (tester) async {
      final fixture = await _RootFixture.create();
      final activity = AppActivityCoordinator()
        ..updateLifecycle(AppLifecycleState.resumed);
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      final firstRestore = Completer<void>();
      final replacementRestore = Completer<void>();
      final firstWorker = _CountingCheckpointWorker(listBlocker: firstRestore);
      final replacementWorker = _CountingCheckpointWorker(
        listBlocker: replacementRestore,
      );
      final firstTracker = ChatRunTracker(
        assistantRuntime: const UnavailableAssistantRuntime(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'scope-workspace-1',
        checkpointPersistence: ChatRunCheckpointPersistence(
          worker: firstWorker,
          writeQueue: DatabaseWriteQueue(),
        ),
      );
      final replacementTracker = ChatRunTracker(
        assistantRuntime: const UnavailableAssistantRuntime(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'scope-workspace-2',
        checkpointPersistence: ChatRunCheckpointPersistence(
          worker: replacementWorker,
          writeQueue: DatabaseWriteQueue(),
        ),
      );
      final note = V3FeedItem(
        id: 'workspace-race-note',
        remoteNoteId: 'remote-workspace-race-note',
        remoteSourceKind: 'manual',
        rawPartRevisionId: 'raw-workspace-race-note',
        outlinePartRevisionId: 'outline-empty-workspace-race-note',
        title: 'Workspace race note',
        source: V3MaterialSource.note,
        rawBody: 'Durable source content',
        syncState: NoteSyncState.synced,
        createdAt: DateTime.utc(2026, 9, 15),
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final outlineRepository = _CountingAcceptedOutlineRepository();
      final feed = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(
          referenceDay: DateTime.utc(2026, 8, 31),
        ),
        repository: const UnavailableFeedAggregationRepository(),
      );
      addTearDown(orchestrator.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            chatRunTrackerProvider.overrideWith((ref) {
              final workspaceId = ref.watch(
                sessionStoreProvider.select(
                  (store) => readyWorkspaceId(store.state),
                ),
              );
              return workspaceId == 'workspace-2'
                  ? replacementTracker
                  : firstTracker;
            }),
            pushRuntimeControllerProvider.overrideWith(
              (ref) => fixture.pushRuntime,
            ),
            pushRegistrationControllerProvider.overrideWith(
              (ref) => PushRegistrationController(
                provider: const UnavailablePushProvider(),
                api: const UnavailablePushDeviceApi(),
                sessionStore: fixture.session,
                deviceId: 'test-device',
                platform: 'ios',
                appVersion: () async => 'test',
              ),
            ),
            notificationControllerProvider.overrideWith(
              (ref) => NotificationController(api: _CountingNotificationApi()),
            ),
            appCachePolicyProvider.overrideWithValue(AppCachePolicy()),
            outlineRepositoryProvider.overrideWithValue(outlineRepository),
            dailyTopicControllerProvider.overrideWith(
              (ref) => DailyTopicController(
                port: _EmptyDailyTopicPort(),
                preferences: AppPreferencesDao(AppDatabase()),
                userScope: 'user-1',
                workspaceId: () =>
                    readyWorkspaceId(fixture.session.state) ?? 'unavailable',
                workspaceReady: () =>
                    readyWorkspaceId(fixture.session.state) != null,
                cacheTtl: () => const Duration(minutes: 5),
              ),
            ),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedAggregationControllerProvider.overrideWith((ref) => feed),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            taskOrchestratorProvider.overrideWith((ref) => orchestrator),
          ],
          child: const PushRuntimeActivation(child: SizedBox()),
        ),
      );
      for (
        var index = 0;
        index < 40 && firstWorker.listCalls == 0;
        index += 1
      ) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(firstWorker.listCalls, 1);
      final foregroundGeneration = activity.state.foregroundGeneration;

      fixture.session.refreshUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'workspace-2',
          ),
        ),
        updatedAt: DateTime.utc(2026, 9, 15),
      );
      await tester.pump();
      expect(replacementWorker.listCalls, 0);

      firstRestore.complete();
      for (
        var index = 0;
        index < 40 && replacementWorker.listCalls == 0;
        index += 1
      ) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      expect(activity.state.foregroundGeneration, foregroundGeneration);
      expect(firstWorker.listCalls, 1);
      expect(replacementWorker.listCalls, 1);
      library.updateNote(note.copyWith(title: 'Workspace race note updated'));
      await tester.pump(const Duration(milliseconds: 10));
      expect(outlineRepository.submissions, 0);

      replacementRestore.complete();
      for (
        var index = 0;
        index < 40 && outlineRepository.submissions == 0;
        index += 1
      ) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(
        outlineRepository.submissions,
        1,
        reason: 'operations=${outlineRepository.operationIds}',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recovery activation replaces account wave and cancels it on dispose',
    (tester) async {
      final fixture = await _RootFixture.create();
      final activity = AppActivityCoordinator();
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      final blocker = Completer<void>();
      final blockerFuture = orchestrator.schedule<void>(
        TaskSpec(
          key: 'test:recovery-network-blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => blocker.future,
      );
      final uploadRecovery = UploadRecoveryBootstrap(
        bootstrapController: fixture.bootstrap,
        sessionStore: fixture.session,
        recoverDrafts: () async {},
      );
      final materialRecovery = UploadRecoveryBootstrap(
        bootstrapController: fixture.bootstrap,
        sessionStore: fixture.session,
        recoverDrafts: () async {},
      );
      addTearDown(() {
        uploadRecovery.dispose();
        materialRecovery.dispose();
        orchestrator.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
            taskOrchestratorProvider.overrideWith((ref) => orchestrator),
            uploadRecoveryBootstrapProvider.overrideWithValue(uploadRecovery),
            materialIngestionRecoveryBootstrapProvider.overrideWithValue(
              materialRecovery,
            ),
          ],
          child: const RecoveryRuntimeActivation(child: SizedBox()),
        ),
      );
      await tester.pump();

      for (final key in const <String>{
        'recovery:material-ingestion',
        'recovery:recording-processing',
        'recovery:voiceprint-profiles',
      }) {
        expect(
          orchestrator.projectionFor(key)?.state,
          isA<AppTaskQueued>(),
          reason: key,
        );
      }

      activity.updateLifecycle(AppLifecycleState.inactive);
      activity.updateLifecycle(AppLifecycleState.resumed);
      await tester.pump();
      for (final key in const <String>{
        'recovery:material-ingestion',
        'recovery:recording-processing',
        'recovery:voiceprint-profiles',
      }) {
        expect(
          orchestrator.projectionFor(key)?.state,
          isA<AppTaskQueued>(),
          reason: key,
        );
      }

      fixture.session.refreshUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(userId: 'user-2', maskedPhoneNumber: '139****9000'),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'workspace-2',
          ),
        ),
        updatedAt: DateTime.utc(2026, 8, 31),
      );
      await tester.pump();

      expect(orchestrator.snapshot.cancelled, greaterThanOrEqualTo(3));
      for (final key in const <String>{
        'recovery:material-ingestion',
        'recovery:recording-processing',
        'recovery:voiceprint-profiles',
      }) {
        expect(
          orchestrator.projectionFor(key)?.state,
          isA<AppTaskQueued>(),
          reason: key,
        );
      }

      await tester.pumpWidget(const SizedBox());
      for (final key in const <String>{
        'recovery:material-ingestion',
        'recovery:recording-processing',
        'recovery:voiceprint-profiles',
      }) {
        expect(
          orchestrator.projectionFor(key)?.state,
          isA<AppTaskCancelled>(),
          reason: key,
        );
      }

      blocker.complete();
      await blockerFuture;
    },
  );
}

Future<void> _finishDeviceSetup(
  WidgetTester tester,
  _RootFixture fixture,
) async {
  // Device setup UI has its own suite; this suite verifies AppRoot ingress gates.
  expect(
    fixture.journey.finishVoiceprint(FirstLaunchStepStatus.deferred),
    isTrue,
  );
  expect(
    fixture.journey.finishRecordingCard(FirstLaunchStepStatus.deferred),
    isTrue,
  );
  expect(fixture.journey.requiresChatGuide, isTrue);
  expect(fixture.journey.requiresBlockingJourney, isFalse);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

GoRouter _router(_RootFixture fixture) => GoRouter(
  initialLocation: '/v3/feed/items/note-deep-link',
  refreshListenable: Listenable.merge(<Listenable>[
    fixture.session,
    fixture.continuation,
    fixture.journey,
    fixture.pending,
  ]),
  redirect: (context, state) => redirectForAppRoute(
    currentLocation: state.uri.path,
    bootstrap: fixture.bootstrap.state,
    session: fixture.session.state,
    onboardingDeferred: fixture.continuation.isDeferredFor('user-1'),
    onboardingRunAccepted: fixture.continuation.hasRegisteredRunFor(
      'user-1',
      'workspace-1',
    ),
    startupJourneyBlocking: fixture.journey.requiresBlockingJourney,
    startupJourneyPositioningRequired: fixture.journey.requiresPositioning,
    startupJourneyPositioningHandled:
        fixture.journey.snapshot.positioning.hasExited,
    startupJourneyVoiceprintAllowed: fixture.journey.allowsVoiceprintEnrollment,
  ),
  routes: <RouteBase>[
    GoRoute(
      path: AppRoutePaths.firstLaunchDeviceSetup,
      builder: (context, state) =>
          const Scaffold(body: Text('mandatory-setup')),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const ContentLineOnboardingPage(),
    ),
    GoRoute(
      path: '/v3',
      builder: (context, state) => const Scaffold(body: Text('v3-home')),
    ),
    GoRoute(
      path: '/v3/feed/items/:noteId',
      builder: (context, state) =>
          const Scaffold(body: Text('deep-link-target')),
    ),
    GoRoute(
      path: '/v3/notifications',
      builder: (context, state) =>
          const Scaffold(body: Text('notifications-target')),
    ),
  ],
);

final class _EmptyDailyTopicPort extends Fake implements DailyTopicPort {
  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async => ApiResult.success(
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
    data: const DailyTopicRecommendationPage(items: []),
  );
}

final class _RootFixture {
  _RootFixture._({
    required this.session,
    required this.bootstrap,
    required this.continuation,
    required this.pending,
    required this.tracker,
    required this.initialPositioning,
    required this.onboarding,
    required this.journey,
    required this.billing,
    required this.recordingAutoSync,
    required this.pushNavigation,
    required this.pushRuntime,
    required this.appearance,
  });

  final SessionStore session;
  final AppBootstrapController bootstrap;
  final OnboardingContinuationController continuation;
  final PendingNavigationController pending;
  final ChatRunTracker tracker;
  final InitialPositioningTaskCoordinator initialPositioning;
  final ContentLineOnboardingController onboarding;
  final FirstLaunchDeviceSetupController journey;
  final BillingController billing;
  final RecordingCardAutoSyncCoordinator recordingAutoSync;
  final PushNavigationController pushNavigation;
  final PushRuntimeController pushRuntime;
  final AppAppearanceController appearance;

  static Future<_RootFixture> create() async {
    final database = AppDatabase();
    final tokenStore = SecureTokenStore(driver: _MemorySecureTokenDriver());
    final session = SessionStore(secureTokenStore: tokenStore);
    final bootstrap = AppBootstrapController(
      secureTokenStore: tokenStore,
      sessionStore: session,
      authApi: const _UnusedAuthApi(),
    );
    await bootstrap.resetToLogin();
    final login = await session.applyLoginSuccess(
      tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      firstLoginThisSession: true,
      snapshot: SafeAuthSessionSnapshot(
        user: const SessionUser(
          userId: 'user-1',
          maskedPhoneNumber: '138****8000',
        ),
        expiresAt: DateTime.utc(2027, 1, 1),
        workspaceStatus: SessionWorkspaceStatus.ready,
        onboardingRequired: true,
      ),
      verifiedStatus: const SessionUserStatus(
        user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-1',
        ),
        onboardingRequired: true,
      ),
      updatedAt: DateTime.utc(2026, 8, 17),
    );
    if (!login.ok) throw StateError('TEST_LOGIN_FAILED');

    final preferences = AppPreferencesDao(database);
    final continuation = OnboardingContinuationController(
      repository: OnboardingProgressRepository(dao: preferences),
      now: () => DateTime.utc(2026, 8, 17),
    );
    final onboarding = ContentLineOnboardingController(
      api: const _UnusedOnboardingApi(),
      initialPositioningAgent: const _UnusedInitialPositioningAgent(),
      sessionStore: session,
      continuation: continuation,
    );
    final journey = FirstLaunchDeviceSetupController(
      repository: FirstLaunchDeviceSetupRepository(
        dao: preferences,
        userScope: 'user-1',
      ),
    )..beginPositioning(includeChatGuide: true);
    final tracker = ChatRunTracker(
      assistantRuntime: const UnavailableAssistantRuntime(),
      preferences: preferences,
      userScope: 'user-1',
    );
    final initialPositioning = InitialPositioningTaskCoordinator(
      onboardingApi: const _UnusedOnboardingApi(),
      positioningAgent: const _UnusedInitialPositioningAgent(),
      sessionStore: session,
      reportSink: const _NoopInitialPositioningReportSink(),
      continuation: continuation,
      taskTracker: tracker,
    );
    final billing = BillingController(
      api: const UnavailableBillingApi(),
      androidPayment: const _NoopAndroidPayment(),
      iosStore: const _NoopIosStore(),
      pendingOrders: _MemoryBillingOrders(),
      platform: BillingPlatform.android,
      userScope: 'user-1',
    );
    final recordingAutoSync = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryRecordingAutoSyncPersistence(),
      actions: _NoopRecordingAutoSyncActions(),
    );
    final pushNavigation = PushNavigationController();
    final pushRuntime = PushRuntimeController(
      provider: const UnavailablePushProvider(),
      notifications: NotificationController(
        api: const UnavailableNotificationApi(),
      ),
      navigation: pushNavigation,
      registration: PushRegistrationController(
        provider: const UnavailablePushProvider(),
        api: const UnavailablePushDeviceApi(),
        sessionStore: session,
        deviceId: 'test-device',
        platform: 'ios',
        appVersion: () async => 'test',
      ),
      sessionStore: session,
    );

    return _RootFixture._(
      session: session,
      bootstrap: bootstrap,
      continuation: continuation,
      pending: PendingNavigationController(),
      tracker: tracker,
      initialPositioning: initialPositioning,
      onboarding: onboarding,
      journey: journey,
      billing: billing,
      recordingAutoSync: recordingAutoSync,
      pushNavigation: pushNavigation,
      pushRuntime: pushRuntime,
      appearance: AppAppearanceController()..restore(),
    );
  }

  List<Override> overrides(
    GoRouter router, {
    InitialPositioningTaskCoordinator Function()? resolvePositioning,
  }) => <Override>[
    appRouterProvider.overrideWith((ref) => router),
    resolvedDeviceIdProvider.overrideWithValue('test-device'),
    appBootstrapControllerProvider.overrideWith((ref) => bootstrap),
    sessionStoreProvider.overrideWith((ref) => session),
    onboardingContinuationControllerProvider.overrideWith(
      (ref) => continuation,
    ),
    contentLineOnboardingControllerProvider.overrideWith((ref) => onboarding),
    firstLaunchDeviceSetupControllerProvider.overrideWith((ref) => journey),
    positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
    onboardingApiProvider.overrideWithValue(const _UnusedOnboardingApi()),
    initialPositioningAgentProvider.overrideWithValue(
      const _UnusedInitialPositioningAgent(),
    ),
    chatRunTrackerProvider.overrideWith((ref) => tracker),
    initialPositioningTaskCoordinatorProvider.overrideWith(
      (ref) => resolvePositioning?.call() ?? initialPositioning,
    ),
    pendingNavigationControllerProvider.overrideWith((ref) => pending),
    billingControllerProvider.overrideWith((ref) => billing),
    recordingCardAutoSyncCoordinatorProvider.overrideWith(
      (ref) => recordingAutoSync,
    ),
    pushNavigationControllerProvider.overrideWith((ref) => pushNavigation),
    pushRuntimeControllerProvider.overrideWith((ref) => pushRuntime),
    incomingMaterialPortProvider.overrideWithValue(
      const _NoopIncomingMaterialPort(),
    ),
    appAppearanceControllerProvider.overrideWith((ref) => appearance),
  ];
}

final class _CountingNotificationApi implements NotificationApiPort {
  int listCalls = 0;
  bool failNextList = false;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
    if (failNextList) {
      failNextList = false;
      return ApiResult<AppNotificationPage>.failure(
        error: const AppFailure(
          code: 'NOTIFICATION_LOAD_FAILED',
          category: AppFailureCategory.network,
          message: 'offline',
          userMessageKey: 'notification.offline',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<AppNotificationPage>.success(
      data: const AppNotificationPage(items: <AppNotification>[]),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => throw UnsupportedError('No read mutation in lifecycle coverage');
}

final class _AggregationRuntimePort implements TopicCollisionRunPort {
  String status = 'queued';
  int submissions = 0;
  final List<String> readRunIds = [];
  final List<String> readWorkspaces = [];
  ApiResult<TopicCollisionRun> _response() => ApiResult.success(
    data: TopicCollisionRun(
      topicCollisionRunId: 'aggregation-runtime-run',
      workspaceId: 'workspace-1',
      status: status,
      stage: status == 'queued' ? 'source_frozen' : 'output_validation',
      selectedNoteCount: 4,
      attempt: status == 'dead_letter' ? 3 : 0,
      retryable: status == 'dead_letter',
      failureStage: status == 'dead_letter' ? 'output_validation' : null,
      failureCode: status == 'dead_letter'
          ? 'NOTE_TOPIC_COLLISION_OUTPUT_INVALID'
          : null,
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) async {
    submissions++;
    expect(noteIds.toSet(), {'remote-0', 'remote-1', 'remote-2', 'remote-3'});
    return _response();
  }

  @override
  Future<ApiResult<TopicCollisionRun>> get(
    String workspaceId,
    String runId,
  ) async {
    readWorkspaces.add(workspaceId);
    readRunIds.add(runId);
    return _response();
  }
}

final class _CountingCheckpointWorker implements ChatRunCheckpointWorkerPort {
  _CountingCheckpointWorker({this.listBlocker});

  final Completer<void>? listBlocker;
  final Map<String, Map<String, ChatRunCheckpoint>> _rows =
      <String, Map<String, ChatRunCheckpoint>>{};
  var listCalls = 0;

  List<ChatRunCheckpoint> rowsFor(String userScope) =>
      List<ChatRunCheckpoint>.unmodifiable(
        _rows[userScope]?.values ?? const <ChatRunCheckpoint>[],
      );

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> applyChatRunCheckpointChanges({
    required String userScope,
    required Iterable<ChatRunCheckpoint> upserts,
    required Iterable<String> deletions,
  }) async {
    final rows = _rows[userScope] ??= <String, ChatRunCheckpoint>{};
    for (final checkpoint in upserts) {
      rows[checkpoint.runId] = checkpoint;
    }
    for (final runId in deletions) {
      rows.remove(runId);
    }
  }

  @override
  Future<bool> deleteChatRunCheckpoint({
    required String userScope,
    required String runId,
  }) async => _rows[userScope]?.remove(runId) != null;

  @override
  Future<List<ChatRunCheckpoint>> listChatRunCheckpoints(
    String userScope,
  ) async {
    listCalls += 1;
    final blocker = listBlocker;
    if (blocker != null) await blocker.future;
    return rowsFor(userScope);
  }

  @override
  Future<void> upsertChatRunCheckpoint(ChatRunCheckpoint checkpoint) async {
    await applyChatRunCheckpointChanges(
      userScope: checkpoint.userScope,
      upserts: <ChatRunCheckpoint>[checkpoint],
      deletions: const <String>[],
    );
  }
}

final class _CountingAcceptedOutlineRepository
    implements OutlineRepository, AcceptedOutlineRunRepository {
  final operationIds = <String>[];

  int get submissions => operationIds.length;

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async => 'unused';

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    operationIds.add(operationId);
    return NoteFileAgentRunSnapshot(
      fileAgentRunId: 'file-outline-test',
      noteId: note.remoteNoteId!,
      status: 'queued',
      agentRunId: 'agent-run-outline-test',
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: note.rawPartRevisionId!,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId:
          note.outlinePartRevisionId ?? 'outline-empty-${note.id}',
    );
  }
}

final class _MemorySecureTokenDriver implements SecureTokenDriver {
  SecureTokenCredential? credential;

  @override
  bool clear({required String service}) {
    credential = null;
    return true;
  }

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    credential = SecureTokenCredential(username: username, password: password);
    return true;
  }
}

final class _UnusedAuthApi implements AuthApiPort {
  const _UnusedAuthApi();

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) => throw UnimplementedError();

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) => throw UnimplementedError();

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) => throw UnimplementedError();

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) => throw UnimplementedError();
}

final class _UnusedOnboardingApi implements OnboardingApiPort {
  const _UnusedOnboardingApi();

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => throw UnimplementedError();
}

final class _UnusedInitialPositioningAgent
    implements InitialPositioningAgentPort {
  const _UnusedInitialPositioningAgent();

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() =>
      throw UnimplementedError();

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) =>
      throw UnimplementedError();
}

final class _NoopInitialPositioningReportSink
    implements InitialPositioningReportSink {
  const _NoopInitialPositioningReportSink();

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async => true;
}

final class _NoopAndroidPayment implements AndroidPaymentPort {
  const _NoopAndroidPayment();

  @override
  Stream<AndroidPaymentEvent> get events =>
      const Stream<AndroidPaymentEvent>.empty();

  @override
  Future<bool> isAvailable(BillingProvider provider) async => false;

  @override
  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  }) async => AndroidPaymentClientResult.unavailable;
}

final class _NoopIosStore implements IOSStorePurchasePort {
  const _NoopIosStore();

  @override
  Stream<IOSPurchaseUpdate> get purchaseUpdates =>
      const Stream<IOSPurchaseUpdate>.empty();

  @override
  Future<void> completePurchase(String purchaseKey) async {}

  @override
  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds) async =>
      const <IOSStoreProduct>[];

  @override
  Future<bool> purchase({
    required String productId,
    required String appAccountToken,
  }) async => false;

  @override
  Future<void> restorePurchases() async {}
}

final class _MemoryBillingOrders implements BillingPendingOrderStore {
  final Map<String, String> _values = <String, String>{};

  @override
  void clear(String userScope) => _values.remove(userScope);

  @override
  String? read(String userScope) => _values[userScope];

  @override
  void save(String userScope, String orderId) {
    _values[userScope] = orderId;
  }
}

final class _MemoryRecordingAutoSyncPersistence
    implements RecordingCardAutoSyncPersistencePort {
  RecordingCardAutoSyncPreferences _preferences =
      const RecordingCardAutoSyncPreferences();

  @override
  RecordingCardAutoSyncPreferences loadPreferences() => _preferences;

  @override
  List<RecordingCardAutoSyncTask> loadTasks() =>
      const <RecordingCardAutoSyncTask>[];

  @override
  void savePreferences(RecordingCardAutoSyncPreferences preferences) {
    _preferences = preferences;
  }

  @override
  void saveTask(RecordingCardAutoSyncTask task) {}
}

final class _NoopRecordingAutoSyncActions extends ChangeNotifier
    implements RecordingCardAutoSyncActions {
  @override
  bool get hasActiveTransfer => false;

  @override
  RecordingCardRuntimeSnapshot get snapshot =>
      RecordingCardRuntimeSnapshot.initial();

  @override
  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  ) => throw UnsupportedError('Not used by app-root navigation tests');

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false}) =>
      throw UnsupportedError('Not used by app-root navigation tests');
}

final class _NoopIncomingMaterialPort implements IncomingMaterialPort {
  const _NoopIncomingMaterialPort();

  @override
  Stream<void> get pendingMaterials => const Stream<void>.empty();

  @override
  Future<NativeFileResult<bool>> acknowledgePendingMaterials(
    Iterable<String> opaqueRefs, {
    bool discardFiles = true,
  }) async => NativeFileResult<bool>.success(true);

  @override
  Future<NativeFileResult<List<IncomingMaterialDraft>>>
  consumePendingMaterials() async =>
      NativeFileResult<List<IncomingMaterialDraft>>.success(
        const <IncomingMaterialDraft>[],
      );

  @override
  Future<NativeFileResult<List<String>>> consumePendingMaterialErrors() async =>
      NativeFileResult<List<String>>.success(const <String>[]);
}
