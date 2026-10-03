import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/onboarding/presentation/content_line_onboarding_page.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';

import 'package:huahuoai_app/app/di/onboarding_providers.dart';
import '../../support/figma_golden_test_support.dart';

Widget onboardingPageTestApp(GoRouter router, OnboardingPageFixture fixture) {
  return ProviderScope(
    overrides: onboardingPageOverrides(fixture),
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: figmaGoldenTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 54, bottom: 18),
          viewPadding: const EdgeInsets.only(top: 54, bottom: 18),
        ),
        child: child!,
      ),
      routerConfig: router,
    ),
  );
}

GoRouter onboardingPageTestRouter({
  SessionStore? guardedSession,
  OnboardingContinuationController? continuation,
}) => GoRouter(
  initialLocation: '/onboarding',
  refreshListenable: guardedSession == null
      ? null
      : Listenable.merge(<Listenable>[
          guardedSession,
          if (continuation != null) continuation,
        ]),
  redirect: guardedSession == null
      ? null
      : (context, state) {
          if (guardedSession.state.requiresInitialPositioning) {
            if (continuation?.hasRegisteredRunFor(
                      guardedSession.state.user?.userId,
                      guardedSession.state.workspace?.workspaceId,
                    ) ==
                    true &&
                (state.uri.path == '/onboarding' ||
                    state.uri.path.startsWith('/v3'))) {
              return null;
            }
            return state.uri.path == '/onboarding' ? null : '/onboarding';
          }
          return state.uri.path == '/v3' ? null : '/v3';
        },
  routes: <RouteBase>[
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const ContentLineOnboardingPage(),
    ),
    GoRoute(
      path: '/v3',
      builder: (context, state) => const Scaffold(body: Text('v3-home')),
    ),
    GoRoute(
      path: '/v3/positioning/progress',
      builder: (context, state) =>
          const Scaffold(body: Text('positioning-progress')),
    ),
    GoRoute(
      path: '/v3/notifications',
      builder: (context, state) => const Scaffold(body: Text('notifications')),
    ),
    GoRoute(
      path: AppRoutePaths.firstLaunchDeviceSetup,
      builder: (context, state) =>
          const Scaffold(body: Text('mandatory-setup')),
    ),
  ],
);

Future<OnboardingPageFixture> createOnboardingPageFixture({
  OnboardingApiPort? api,
  InitialPositioningAgentPort? agent,
  bool firstLogin = true,
}) async {
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
    firstLoginThisSession: firstLogin,
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
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
    updatedAt: DateTime.utc(2026, 8, 9),
  );
  final continuation = OnboardingContinuationController(
    repository: OnboardingProgressRepository(
      dao: AppPreferencesDao(AppDatabase()),
    ),
  );
  final controller = ContentLineOnboardingController(
    api: api ?? _NoopOnboardingApi(),
    initialPositioningAgent: agent ?? _NoopAgent(),
    sessionStore: session,
    continuation: continuation,
  );
  final journey = FirstLaunchDeviceSetupController(
    repository: FirstLaunchDeviceSetupRepository(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'user-1',
    ),
  );
  final chat = ChatController(api: _UnusedChatApi(), scene: ChatScene.feedAi);
  final voice = VoiceMessageController(
    recorder: const UnavailableVoiceRecorderPort(),
    uploader: _UnusedVoiceUploader(),
    localRecordingRepository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: const UnavailableFileStoragePort(),
    ),
    chatController: chat,
    recordingApi: _UnusedRecordingApi(),
  );
  return OnboardingPageFixture(
    session,
    continuation,
    controller,
    journey,
    chat,
    voice,
  );
}

final class OnboardingPageFixture {
  const OnboardingPageFixture(
    this.session,
    this.continuation,
    this.controller,
    this.journey,
    this.chat,
    this.voice,
  );

  final SessionStore session;
  final OnboardingContinuationController continuation;
  final ContentLineOnboardingController controller;
  final FirstLaunchDeviceSetupController journey;
  final ChatController chat;
  final VoiceMessageController voice;

  void dispose() {
    continuation.dispose();
    chat.dispose();
  }
}

bool confirmOnboardingRegistration(
  OnboardingPageFixture fixture,
  String runId,
) => fixture.continuation.recordRunRegistration(
  'user-1',
  agentRunId: runId,
  workspaceId: 'workspace-1',
  attemptId: 'attempt_$runId',
);

List<Override> onboardingPageOverrides(
  OnboardingPageFixture fixture, {
  InitialPositioningRunRegistrar? registrar,
}) => <Override>[
  sessionStoreProvider.overrideWith((ref) => fixture.session),
  // Intake presentation is tested independently of remote report recovery.
  positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
  initialPositioningTaskStateProvider.overrideWithValue(
    const InitialPositioningTaskState(),
  ),
  initialPositioningRunRegistrarProvider.overrideWithValue(
    registrar ?? (runId) async => confirmOnboardingRegistration(fixture, runId),
  ),
  contentLineOnboardingControllerProvider.overrideWith(
    (ref) => fixture.controller,
  ),
  firstLaunchDeviceSetupControllerProvider.overrideWith(
    (ref) => fixture.journey,
  ),
  feedAiVoiceMessageControllerProvider.overrideWith((ref) => fixture.voice),
];

final class _UnusedChatApi implements ChatRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _UnusedVoiceUploader implements ChatVoiceUploadPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _UnusedRecordingApi implements RecordingApiPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _NoopOnboardingApi implements OnboardingApiPort {
  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => throw UnimplementedError();
}

final class _NoopAgent implements InitialPositioningAgentPort {
  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) =>
      throw UnimplementedError();

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() =>
      throw UnimplementedError();
}

final class CompletedPositioningAgent
    implements
        InitialPositioningAgentPort,
        InitialPositioningAgentAcceptedRunPort {
  int submitCalls = 0;
  int startCalls = 0;

  static const _receipt = InitialPositioningRunReceipt(
    threadId: 'thread-positioning-1',
    agentRunId: 'agent_run_positioning_1',
    taskId: 'ai_task_positioning_1',
    messageId: 'message_positioning_1',
    status: 'sent',
  );

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) async {
    submitCalls += 1;
    return InitialPositioningAgentSubmission.success(
      InitialPositioningAgentResult(
        threadId: 'thread-positioning-1',
        report: '## 初步定位判断\n从访谈创业者开始。',
        receipt: _receipt,
        savedProfile: InitialPositioningProfile(
          workspaceId: 'workspace-1',
          overview: '',
          selfDescription: '',
          positioning: '## 正式基础定位报告\n\n面向本地创业者。',
          positioningProgress: parseLatestPositioningProgress('''
```huahuo-positioning-progress
{
  "completedPercent": 72,
  "visibleSubject": "本地创业者经营复盘",
  "consultationState": {"expertJudgment":"基础定位已形成"},
  "modules": [
    {"moduleId":"credible_self", "score":8, "weight":10, "state":"rich"}
  ]
}
```
'''),
          conclusions: const <InitialPositioningProfileConclusion>[],
        ),
      ),
    );
  }

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() async =>
      InitialPositioningProfileRead.failure('UNEXPECTED_PROFILE_READ');

  @override
  Future<InitialPositioningAgentAcceptance> start(String prompt) async {
    startCalls += 1;
    return InitialPositioningAgentAcceptance.success(_receipt);
  }

  @override
  Future<InitialPositioningAgentSubmission> completeAccepted(
    InitialPositioningRunReceipt receipt,
  ) => submit('');
}

final class PendingPositioningAgent implements InitialPositioningAgentPort {
  final Completer<InitialPositioningAgentSubmission> _completion =
      Completer<InitialPositioningAgentSubmission>();
  int submitCalls = 0;

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) {
    submitCalls += 1;
    return _completion.future;
  }

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() async =>
      InitialPositioningProfileRead.failure('UNEXPECTED_PROFILE_READ');

  void complete(InitialPositioningAgentSubmission result) {
    _completion.complete(result);
  }
}

final class CompletedOnboardingApi implements OnboardingApiPort {
  int createCalls = 0;

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createCalls += 1;
    return ApiResult<CreateFirstContentLineResult>.success(
      data: const CreateFirstContentLineResult(
        contentLine: OnboardingContentLine(
          contentLineId: 'line-1',
          name: 'Retail voice',
          industry: 'Retail',
          status: 'active',
          version: 1,
          isDefault: true,
          isPlaceholder: false,
        ),
        onboardingCompleted: true,
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
}

void answerBusinessQuestionnaire(ContentLineOnboardingController controller) {
  controller.selectMode(OnboardingIntakeMode.business);
  controller.updateAnswer('customerScope', '全国客户');
  controller.goNext();
  controller.updateAnswer('productDescription', 'Retail voice');
  controller.goNext();
  controller.updateAnswer('desiredCustomer', 'Store owners');
  controller.goNext();
  controller.updateAnswer('customerTalkValue', <String>['行业信息差']);
}

final class _TokenDriver implements SecureTokenDriver {
  final Map<String, SecureTokenCredential> values =
      <String, SecureTokenCredential>{};

  @override
  Future<bool> clear({required String service}) async {
    values.remove(service);
    return true;
  }

  @override
  Future<SecureTokenCredential?> read({required String service}) async =>
      values[service];

  @override
  Future<bool> write({
    required String service,
    required String username,
    required String password,
  }) async {
    values[service] = SecureTokenCredential(
      username: username,
      password: password,
    );
    return true;
  }
}
