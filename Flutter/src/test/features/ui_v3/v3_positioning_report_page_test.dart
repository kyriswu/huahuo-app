import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_positioning_report_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

void main() {
  testWidgets(
    'readable profile report suppresses stale task loading and shows dashboard',
    (tester) async {
      final session = await _authenticatedSession();
      final report = _report();
      final controller = DeepPositioningController(_StaticRepository(report));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
            sessionStoreProvider.overrideWith((ref) => session),
            authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
            deepPositioningControllerProvider.overrideWith((ref) => controller),
            digitalTwinControllerProvider.overrideWith(
              (ref) => throw StateError(
                'positioning report must not read Digital Twin state',
              ),
            ),
            initialPositioningTaskStateProvider.overrideWithValue(
              const InitialPositioningTaskState(
                status: InitialPositioningTaskStatus.running,
                workspaceId: 'report-workspace',
                agentRunId: 'agent_run_stale',
              ),
            ),
            initialPositioningServerStateReaderProvider.overrideWithValue(
              ({required workspaceId}) async => InitialPositioningServerState(
                workspaceId: workspaceId,
                phase: InitialPositioningServerPhase.running,
                attemptId: 'attempt-1',
                agentRunId: 'agent_run_stale',
              ),
            ),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.dark(),
            home: const V3PositioningReportPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('positioning-report-content')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('positioning-dashboard-full')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('positioning-task-awaiting-server')),
        findsNothing,
      );
      expect(find.text('内容定位'), findsOneWidget);
      expect(find.text('继续深度定位'), findsOneWidget);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .every((indicator) => indicator.value != null),
        isTrue,
      );
    },
  );

  testWidgets('absent running report shows the active generation state', (
    tester,
  ) async {
    final session = await _authenticatedSession();
    final controller = DeepPositioningController(const _StaticRepository(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
          sessionStoreProvider.overrideWith((ref) => session),
          authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
          deepPositioningControllerProvider.overrideWith((ref) => controller),
          initialPositioningTaskStateProvider.overrideWithValue(
            const InitialPositioningTaskState(
              status: InitialPositioningTaskStatus.running,
              workspaceId: 'report-workspace',
              agentRunId: 'agent_run_active',
            ),
          ),
          initialPositioningServerStateReaderProvider.overrideWithValue(
            ({required workspaceId}) async => InitialPositioningServerState(
              workspaceId: workspaceId,
              phase: InitialPositioningServerPhase.running,
              attemptId: 'attempt-active',
              agentRunId: 'agent_run_active',
            ),
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3PositioningReportPage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在生成基础定位报告'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('positioning-task-awaiting-server')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('positioning-report-content')),
      findsNothing,
    );
  });

  testWidgets(
    'same-run server transition stops stale local generation without report',
    (tester) async {
      final session = await _authenticatedSession();
      final controller = DeepPositioningController(
        const _StaticRepository(null),
      );
      var serverReads = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
            sessionStoreProvider.overrideWith((ref) => session),
            authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
            deepPositioningControllerProvider.overrideWith((ref) => controller),
            initialPositioningTaskStateProvider.overrideWithValue(
              const InitialPositioningTaskState(
                status: InitialPositioningTaskStatus.running,
                workspaceId: 'report-workspace',
                agentRunId: 'agent_run_complete',
              ),
            ),
            initialPositioningServerStateReaderProvider.overrideWithValue(({
              required workspaceId,
            }) async {
              serverReads += 1;
              return InitialPositioningServerState(
                workspaceId: workspaceId,
                phase: serverReads == 1
                    ? InitialPositioningServerPhase.running
                    : InitialPositioningServerPhase.completed,
                attemptId: 'attempt-complete',
                agentRunId: 'agent_run_complete',
              );
            }),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.dark(),
            home: const V3PositioningReportPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('正在生成基础定位报告'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(find.text('报告已完成，但暂时无法读取'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('positioning-task-awaiting-server')),
        findsNothing,
      );
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .where((indicator) => indicator.value == null),
        isEmpty,
      );
    },
  );

  testWidgets('requested Run never adopts another current server attempt', (
    tester,
  ) async {
    final session = await _authenticatedSession();
    final controller = DeepPositioningController(const _StaticRepository(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
          sessionStoreProvider.overrideWith((ref) => session),
          authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
          deepPositioningControllerProvider.overrideWith((ref) => controller),
          initialPositioningTaskStateProvider.overrideWithValue(
            const InitialPositioningTaskState(
              status: InitialPositioningTaskStatus.running,
              workspaceId: 'report-workspace',
              agentRunId: 'agent_run_requested',
            ),
          ),
          initialPositioningServerStateReaderProvider.overrideWithValue(
            ({required workspaceId}) async => InitialPositioningServerState(
              workspaceId: workspaceId,
              phase: InitialPositioningServerPhase.running,
              attemptId: 'attempt-other',
              agentRunId: 'agent_run_other',
            ),
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3PositioningReportPage(taskId: 'agent_run_requested'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂时无法读取定位状态'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('positioning-task-awaiting-server')),
      findsNothing,
    );
  });

  testWidgets('direct entry never merges different local and server Runs', (
    tester,
  ) async {
    final session = await _authenticatedSession();
    final controller = DeepPositioningController(const _StaticRepository(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
          sessionStoreProvider.overrideWith((ref) => session),
          authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
          deepPositioningControllerProvider.overrideWith((ref) => controller),
          initialPositioningTaskStateProvider.overrideWithValue(
            const InitialPositioningTaskState(
              status: InitialPositioningTaskStatus.running,
              workspaceId: 'report-workspace',
              agentRunId: 'agent_run_local',
            ),
          ),
          initialPositioningServerStateReaderProvider.overrideWithValue(
            ({required workspaceId}) async => InitialPositioningServerState(
              workspaceId: workspaceId,
              phase: InitialPositioningServerPhase.completed,
              attemptId: 'attempt-server',
              agentRunId: 'agent_run_server',
            ),
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3PositioningReportPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂时无法读取定位状态'), findsOneWidget);
    expect(find.text('报告已完成，但暂时无法读取'), findsNothing);
    expect(
      find.byKey(const ValueKey('positioning-task-awaiting-server')),
      findsNothing,
    );
  });

  testWidgets('task route rejects a server state without Run identity', (
    tester,
  ) async {
    final session = await _authenticatedSession();
    final controller = DeepPositioningController(const _StaticRepository(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
          sessionStoreProvider.overrideWith((ref) => session),
          authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
          deepPositioningControllerProvider.overrideWith((ref) => controller),
          initialPositioningTaskStateProvider.overrideWithValue(
            const InitialPositioningTaskState(),
          ),
          initialPositioningServerStateReaderProvider.overrideWithValue(
            ({required workspaceId}) async => InitialPositioningServerState(
              workspaceId: workspaceId,
              phase: InitialPositioningServerPhase.notStarted,
            ),
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3PositioningReportPage(taskId: 'agent_run_requested'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂时无法读取定位状态'), findsOneWidget);
    expect(find.text('尚未生成基础定位报告'), findsNothing);
  });

  testWidgets('local activity from another Workspace is ignored', (
    tester,
  ) async {
    final session = await _authenticatedSession();
    final controller = DeepPositioningController(const _StaticRepository(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
          sessionStoreProvider.overrideWith((ref) => session),
          authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
          deepPositioningControllerProvider.overrideWith((ref) => controller),
          initialPositioningTaskStateProvider.overrideWithValue(
            const InitialPositioningTaskState(
              status: InitialPositioningTaskStatus.running,
              workspaceId: 'other-workspace',
              agentRunId: 'agent_run_other_workspace',
            ),
          ),
          initialPositioningServerStateReaderProvider.overrideWithValue(
            ({required workspaceId}) async => InitialPositioningServerState(
              workspaceId: workspaceId,
              phase: InitialPositioningServerPhase.notStarted,
            ),
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3PositioningReportPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('尚未生成基础定位报告'), findsOneWidget);
    expect(find.text('正在生成基础定位报告'), findsNothing);
  });

  testWidgets(
    'server-completed report settles cross-device notification only',
    (tester) async {
      final session = await _authenticatedSession();
      final controller = DeepPositioningController(
        _StaticRepository(_report()),
      );
      final resolution = _TaskResolution();
      final notifications = NotificationController(
        api: const UnavailableNotificationApi(),
        resolution: resolution,
      );
      addTearDown(notifications.dispose);
      var localCheckpointAcknowledgements = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
            sessionStoreProvider.overrideWith((ref) => session),
            authenticatedUserDataScopeProvider.overrideWithValue('report-user'),
            deepPositioningControllerProvider.overrideWith((ref) => controller),
            initialPositioningTaskStateProvider.overrideWithValue(
              const InitialPositioningTaskState(),
            ),
            initialPositioningServerStateReaderProvider.overrideWithValue(
              ({required workspaceId}) async => InitialPositioningServerState(
                workspaceId: workspaceId,
                phase: InitialPositioningServerPhase.completed,
                attemptId: 'attempt-cross-device',
                agentRunId: 'agent_run_cross_device',
              ),
            ),
            pendingMessageActionsProvider.overrideWithValue(
              PendingMessageActions(
                notifications,
                items: () => const <PendingMessage>[],
              ),
            ),
            initialPositioningReportAcknowledgerProvider.overrideWithValue((_) {
              localCheckpointAcknowledgements += 1;
              return true;
            }),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.dark(),
            home: const V3PositioningReportPage(
              taskId: 'agent_run_cross_device',
            ),
          ),
        ),
      );
      for (
        var attempt = 0;
        attempt < 20 && resolution.taskSaveAttempts == 0;
        attempt += 1
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(resolution.taskSaveAttempts, 1);
      expect(resolution.handledTaskIds, contains('agent_run_cross_device'));
      expect(localCheckpointAcknowledgements, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

DeepPositioningResult _report() {
  const markdown = '''# 基础定位报告

这是已经写入 Workspace Profile 的正式报告。

```huahuo-positioning-progress
{
  "completedPercent": 23,
  "visibleSubject": "内容定位",
  "consultationState": {"expertJudgment":"已形成基础定位判断"},
  "modules": [
    {"moduleId":"credible_self", "score":6, "weight":10, "state":"forming"}
  ]
}
```''';
  return DeepPositioningResult(
    markdown: markdown,
    savedAt: DateTime.utc(2026, 9, 12, 1, 30),
    initialCompletedAt: DateTime.utc(2026, 9, 12, 1, 30),
    progress: parseLatestPositioningProgress(markdown),
  );
}

Future<SessionStore> _authenticatedSession() async {
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    snapshot: SafeAuthSessionSnapshot(
      user: const SessionUser(
        userId: 'report-user',
        maskedPhoneNumber: '188****0996',
      ),
      expiresAt: DateTime.utc(2027),
      workspaceStatus: SessionWorkspaceStatus.ready,
      onboardingRequired: false,
    ),
    verifiedStatus: const SessionUserStatus(
      user: SessionUser(
        userId: 'report-user',
        maskedPhoneNumber: '188****0996',
      ),
      workspace: SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'report-workspace',
      ),
      onboardingRequired: false,
    ),
    updatedAt: DateTime.utc(2026, 9, 12),
  );
  return session;
}

final class _StaticRepository
    implements DeepPositioningRepository, PositioningReportReadPort {
  const _StaticRepository(this.report);

  final DeepPositioningResult? report;

  @override
  Future<PositioningReportRead> readReport() async => PositioningReportRead(
    report == null
        ? PositioningReportOrigin.absent
        : PositioningReportOrigin.remote,
    report: report,
  );

  @override
  bool get isDemo => false;

  @override
  DeepPositioningResult? load() => report;

  @override
  Future<DeepPositioningResult?> refresh() async => report;

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) =>
      throw UnimplementedError();

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) => throw UnimplementedError();

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) => throw UnimplementedError();
}

final class _TokenDriver implements SecureTokenDriver {
  @override
  Future<bool> clear({required String service}) async => true;

  @override
  Future<SecureTokenCredential?> read({required String service}) async => null;

  @override
  Future<bool> write({
    required String service,
    required String username,
    required String password,
  }) async => true;
}

final class _TaskResolution
    implements NotificationResolutionPort, TaskNotificationResolutionPort {
  int taskSaveAttempts = 0;
  final Set<String> handledTaskIds = <String>{};
  final Set<String> _handledIds = <String>{};
  final Set<String> _locallyReadIds = <String>{};

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(_handledIds);

  @override
  Set<String> loadHandledTaskIds() => Set<String>.from(handledTaskIds);

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(_locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) async =>
      _handledIds.add(notificationId);

  @override
  Future<bool> markLocallyRead(String notificationId) async =>
      _locallyReadIds.add(notificationId);

  @override
  Future<bool> markTaskHandled(String taskId) async {
    taskSaveAttempts += 1;
    handledTaskIds.add(taskId);
    return true;
  }
}
