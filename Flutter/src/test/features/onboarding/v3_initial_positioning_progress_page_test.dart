import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/di/database_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_positioning_task_progress.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';

void main() {
  const runningTask = InitialPositioningTaskState(
    status: InitialPositioningTaskStatus.running,
    workspaceId: 'progress-workspace',
    agentRunId: 'agent_run_progress',
  );

  for (final change in ['account', 'workspace']) {
    testWidgets(
      '$change switch replaces coverage and rejects the old response',
      (tester) async {
        final fixture = await _fixture();
        fixture.cachePositioningProgress(_rawPositioningProgress);
        final transport = fixture.apiClient.transport as _NotModifiedTransport;
        final oldResponse = Completer<ApiTransportResponse>();
        transport.nextResponse = oldResponse.future;
        final router = _router();
        addTearDown(router.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(_app(router, fixture, taskState: runningTask));
        await tester.pump();
        expect(find.text('定位内容覆盖度 50%'), findsOneWidget);
        expect(transport.sendCalls, 1);

        final user = change == 'account' ? 'next-user' : 'progress-page-user';
        final workspace = change == 'workspace'
            ? 'next-workspace'
            : 'progress-workspace';
        fixture.cachePositioningProgress(
          {..._rawPositioningProgress, 'completedPercent': 70},
          userScope: user,
          workspaceId: workspace,
        );
        transport.nextResponse = null;
        fixture.session.refreshUserStatus(
          status: SessionUserStatus(
            user: SessionUser(userId: user, maskedPhoneNumber: '138****9000'),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.ready,
              workspaceId: workspace,
            ),
            onboardingRequired: true,
          ),
          updatedAt: DateTime.utc(2026, 10, 4),
        );
        await tester.pumpWidget(_app(router, fixture, taskState: runningTask));
        await tester.pump();
        expect(find.text('定位内容覆盖度 70%'), findsOneWidget);
        expect(transport.sendCalls, 2);

        final latePayload = {
          ..._rawPositioningProgress,
          'completedPercent': 90,
        };
        oldResponse.complete(
          ApiTransportResponse(
            status: 200,
            headers: const {'ETag': 'late'},
            body: {'success': true, 'data': latePayload},
          ),
        );
        await tester.pump();
        expect(find.text('定位内容覆盖度 70%'), findsOneWidget);
        for (final scope in [
          ('progress-page-user', 'progress-workspace'),
          (user, workspace),
        ]) {
          final entry = ScopedReadCache(
            dao: fixture.preferences,
            userScope: scope.$1,
            workspaceScope: scope.$2,
          ).read('workspacePositioningProgress', scope.$2);
          expect(entry?.etag, 'progress-etag');
        }
      },
    );
  }

  testWidgets('unquantified work never invents a percentage', (tester) async {
    final fixture = await _fixture();
    final router = _router();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_app(router, fixture, taskState: runningTask));
    await tester.pump();
    final indicators = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicators, isNotEmpty);
    expect(indicators.every((indicator) => indicator.value == null), isTrue);
    expect(find.text('正在生成基础定位报告'), findsOneWidget);
    expect(find.textContaining('尚未提供可量化进度'), findsOneWidget);
  });

  testWidgets('server coverage is not the generation duration percentage', (
    tester,
  ) async {
    final fixture = await _fixture();
    fixture.cachePositioningProgress({
      ..._rawPositioningProgress,
      'coldStartPercent': 100,
      'coldStartCompleted': true,
    });
    final router = _router();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_app(router, fixture, taskState: runningTask));
    await tester.pump();
    expect(find.text('基础信息完整度 100%'), findsOneWidget);
    expect(find.text('定位内容覆盖度 50%'), findsOneWidget);
    expect(find.text('正在生成基础定位报告'), findsOneWidget);
    expect(
      tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .map((indicator) => indicator.value),
      [null, 1.0, 0.5],
    );
  });

  testWidgets('failed task stops polling and explicitly resumes intake', (
    tester,
  ) async {
    final fixture = await _fixture();
    final router = _router();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      _app(
        router,
        fixture,
        taskState: const InitialPositioningTaskState(
          status: InitialPositioningTaskStatus.failed,
          agentRunId: 'agent_run_progress',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect((fixture.apiClient.transport as _NotModifiedTransport).sendCalls, 0);
    expect(
      find.byKey(const ValueKey('positioning-task-awaiting-server')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('positioning-task-action')));
    await tester.pumpAndSettle();
    expect(router.state.uri.toString(), '/onboarding?resume=1');
  });

  testWidgets(
    'ready task stops the progress reader without forcing coverage to 100',
    (tester) async {
      final fixture = await _fixture();
      fixture.cachePositioningProgress(_rawPositioningProgress);
      final router = _router();
      addTearDown(router.dispose);
      addTearDown(fixture.dispose);
      await tester.pumpWidget(_app(router, fixture, taskState: runningTask));
      await tester.pump();
      final transport = fixture.apiClient.transport as _NotModifiedTransport;
      expect(transport.sendCalls, 1);
      await tester.pumpWidget(
        _app(
          router,
          fixture,
          taskState: const InitialPositioningTaskState(
            status: InitialPositioningTaskStatus.succeeded,
            agentRunId: 'agent_run_progress',
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 10));
      expect(transport.sendCalls, 1);
      expect(find.text('定位内容覆盖度 50%'), findsOneWidget);
      expect(find.text('基础定位报告已生成'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('positioning-task-awaiting-server')),
        findsNothing,
      );
    },
  );

  testWidgets('progress polling requires foreground current route', (
    tester,
  ) async {
    final fixture = await _fixture();
    final activity = AppActivityCoordinator(binding: tester.binding);
    activity.updateLifecycle(AppLifecycleState.resumed);
    final router = _router();
    final transport = fixture.apiClient.transport as _NotModifiedTransport;
    addTearDown(router.dispose);
    addTearDown(activity.dispose);
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      _app(router, fixture, taskState: runningTask, activity: activity),
    );
    await tester.pump();
    await tester.pump();
    expect(transport.sendCalls, 1);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(transport.sendCalls, 1);

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(transport.sendCalls, 2);

    unawaited(router.push<void>('/v3/notifications'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 4));
    expect(transport.sendCalls, 2);

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(transport.sendCalls, 3);
  });
}

Widget _app(
  GoRouter router,
  _Fixture fixture, {
  InitialPositioningTaskState? taskState,
  AppActivityCoordinator? activity,
}) {
  return ProviderScope(
    overrides: <Override>[
      sessionStoreProvider.overrideWith((ref) => fixture.session),
      onboardingContinuationControllerProvider.overrideWith(
        (ref) => fixture.continuation,
      ),
      initialPositioningTaskCoordinatorProvider.overrideWith(
        (ref) => fixture.coordinator,
      ),
      appPreferencesDaoProvider.overrideWithValue(fixture.preferences),
      apiClientProvider.overrideWithValue(fixture.apiClient),
      if (activity != null)
        appActivityCoordinatorProvider.overrideWith((ref) => activity),
      initialPositioningTaskStateProvider.overrideWithValue(
        taskState ?? fixture.coordinator.state,
      ),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    ),
  );
}

GoRouter _router() => GoRouter(
  initialLocation: '/progress',
  observers: <NavigatorObserver>[appRouteObserver],
  routes: <RouteBase>[
    GoRoute(
      path: '/progress',
      builder: (context, state) => Consumer(
        builder: (context, ref, _) => Scaffold(
          body: SingleChildScrollView(
            child: V3PositioningTaskProgress(
              task: ref.watch(initialPositioningTaskStateProvider),
            ),
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/v3/notifications',
      builder: (context, state) => const Scaffold(body: Text('待处理消息')),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const Scaffold(body: Text('保留的问卷')),
    ),
    GoRoute(
      path: '/v3/profile/digital-twin',
      builder: (context, state) => const Scaffold(body: Text('正式定位报告')),
    ),
  ],
);

Future<_Fixture> _fixture({
  OnboardingAcceptedRunLifecycle lifecycle =
      OnboardingAcceptedRunLifecycle.running,
}) async {
  final database = AppDatabase();
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    snapshot: SafeAuthSessionSnapshot(
      user: const SessionUser(
        userId: 'progress-page-user',
        maskedPhoneNumber: '138****9000',
      ),
      expiresAt: DateTime.utc(2027, 1, 1),
      workspaceStatus: SessionWorkspaceStatus.ready,
      onboardingRequired: true,
    ),
    verifiedStatus: const SessionUserStatus(
      user: SessionUser(
        userId: 'progress-page-user',
        maskedPhoneNumber: '138****9000',
      ),
      workspace: SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'progress-workspace',
      ),
      onboardingRequired: true,
    ),
    updatedAt: DateTime.utc(2026, 8, 17),
  );
  final preferences = AppPreferencesDao(database);
  final continuation = OnboardingContinuationController(
    repository: OnboardingProgressRepository(dao: preferences),
  );
  expect(
    continuation.acceptRun(
      'progress-page-user',
      const InitialPositioningRunReceipt(
        threadId: 'progress-thread',
        agentRunId: 'agent_run_progress',
        taskId: 'progress-task',
        messageId: 'progress-message',
        status: 'accepted',
      ),
    ),
    isTrue,
  );
  if (lifecycle == OnboardingAcceptedRunLifecycle.succeeded) {
    expect(continuation.markRunSucceeded('progress-page-user'), isTrue);
  }
  final taskTracker = ChatRunTracker(
    assistantRuntime: const UnavailableAssistantRuntime(),
    preferences: preferences,
    userScope: 'progress-page-user',
  );
  final coordinator = InitialPositioningTaskCoordinator(
    onboardingApi: const _UnusedOnboardingApi(),
    positioningAgent: const _UnusedInitialPositioningAgent(),
    sessionStore: session,
    reportSink: const _UnusedInitialPositioningReportSink(),
    continuation: continuation,
    taskTracker: taskTracker,
  );
  await coordinator.start();
  return _Fixture(
    session: session,
    continuation: continuation,
    coordinator: coordinator,
    taskTracker: taskTracker,
    preferences: preferences,
    apiClient: _notModifiedApiClient(session),
  );
}

final class _Fixture {
  const _Fixture({
    required this.session,
    required this.continuation,
    required this.coordinator,
    required this.taskTracker,
    required this.preferences,
    required this.apiClient,
  });

  final SessionStore session;
  final OnboardingContinuationController continuation;
  final InitialPositioningTaskCoordinator coordinator;
  final ChatRunTracker taskTracker;
  final AppPreferencesDao preferences;
  final ApiClient apiClient;

  void cachePositioningProgress(
    Map<String, Object?> payload, {
    String userScope = 'progress-page-user',
    String workspaceId = 'progress-workspace',
  }) {
    ScopedReadCache(
      dao: preferences,
      userScope: userScope,
      workspaceScope: workspaceId,
    ).write(
      'workspacePositioningProgress',
      workspaceId,
      etag: 'progress-etag',
      payload: payload,
    );
  }

  void dispose() {
    taskTracker.dispose();
  }
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

ApiClient _notModifiedApiClient(SessionStore session) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-1',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-${session.state.user?.userId}',
  ),
  transport: _NotModifiedTransport(),
);

final class _NotModifiedTransport implements ApiTransport {
  int sendCalls = 0;
  Future<ApiTransportResponse>? nextResponse;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    sendCalls += 1;
    if (nextResponse case final response?) return response;
    return const ApiTransportResponse(status: 304, body: null);
  }
}

const _rawPositioningProgress = <String, Object?>{
  'schemaVersion': 'huahuo.positioning-progress.v1',
  'source': 'workspace_file',
  'available': true,
  'projectionVersion': 1,
  'status': 'forming',
  'validationStatus': 'last_known_good',
  'completedPercent': 50,
  'coldStartPercent': 50,
  'coldStartCompleted': false,
  'modules': <Map<String, Object?>>[
    <String, Object?>{
      'id': 'credible_self',
      'label': 'Credible self',
      'weight': 10,
      'score': 5,
      'state': 'forming',
      'summary': '',
    },
    <String, Object?>{
      'id': 'future_module',
      'label': 'Future module',
      'weight': 10,
      'score': 10,
      'state': 'future_state',
      'summary': '',
    },
  ],
  'nextFocus': <Map<String, Object?>>[],
  'updatedFiles': <String>[],
};

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

final class _UnusedInitialPositioningReportSink
    implements InitialPositioningReportSink {
  const _UnusedInitialPositioningReportSink();

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async => true;
}
