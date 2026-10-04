import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/data/chat_thread_alias_repository.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/positioning_lifecycle.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

void main() {
  for (final access in [
    InitialPositioningAccess.completed,
    InitialPositioningAccess.running,
    InitialPositioningAccess.recovering,
    InitialPositioningAccess.unavailable,
  ]) {
    test(
      'independent positioning gate preserves answers and blocks both submit paths: ${access.name}',
      () async {
        final fixture = await _fixture(
          apiResults: [],
          checkPositioningAccess: () async => access,
        );
        _answerBusiness(fixture.controller);
        final answers = Map.of(fixture.controller.state.answers);
        expect(await fixture.controller.startBackground(), isNull);
        expect(await fixture.controller.submit(), isNull);
        expect(fixture.agent.prompts, isEmpty);
        expect(fixture.api.requests, isEmpty);
        expect(fixture.controller.state.answers, answers);
      },
    );
  }
  test(
    'registration receipt persists without granting admission to a bare Run',
    () {
      final repository = OnboardingProgressRepository(
        dao: AppPreferencesDao(AppDatabase()),
      );
      final continuation = OnboardingContinuationController(
        repository: repository,
      );
      addTearDown(continuation.dispose);
      expect(
        continuation.acceptRun(
          'user-1',
          const InitialPositioningRunReceipt(
            threadId: 'thread-1',
            agentRunId: 'agent_run_1',
            taskId: 'task-1',
            messageId: 'message-1',
            status: 'accepted',
          ),
          workspaceId: 'workspace-1',
        ),
        isTrue,
      );
      expect(
        continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isFalse,
      );
      expect(
        continuation.recordRunRegistration(
          'user-1',
          agentRunId: 'wrong-run',
          workspaceId: 'workspace-1',
          attemptId: 'attempt-1',
        ),
        isFalse,
      );
      expect(
        continuation.recordRunRegistration(
          'user-1',
          agentRunId: 'agent_run_1',
          workspaceId: 'workspace-2',
          attemptId: 'attempt-1',
        ),
        isFalse,
      );
      expect(
        continuation.recordRunRegistration(
          'user-1',
          agentRunId: 'agent_run_1',
          workspaceId: 'workspace-1',
          errorCode: 'NETWORK_UNAVAILABLE',
        ),
        isTrue,
      );
      expect(
        repository.load('user-1').acceptedRun?.registrationErrorCode,
        'NETWORK_UNAVAILABLE',
      );
      expect(
        continuation.recordRunRegistration(
          'user-1',
          agentRunId: 'agent_run_1',
          workspaceId: 'workspace-1',
          attemptId: 'attempt-1',
        ),
        isTrue,
      );
      final restored = OnboardingContinuationController(repository: repository);
      addTearDown(restored.dispose);
      expect(restored.hasRegisteredRunFor('user-1', 'workspace-1'), isTrue);
      expect(restored.hasRegisteredRunFor('user-1', 'workspace-2'), isFalse);
      expect(restored.hasRegisteredRunFor('user-2', 'workspace-1'), isFalse);
      expect(
        repository.load('user-1').acceptedRun?.registrationErrorCode,
        isNull,
      );
    },
  );

  test(
    'accepted receipt survives deferral and questionnaire disposal',
    () async {
      final session = await _onboardingSession();
      final continuation = OnboardingContinuationController(
        repository: OnboardingProgressRepository(
          dao: AppPreferencesDao(AppDatabase()),
        ),
      );
      addTearDown(continuation.dispose);
      final controller = ContentLineOnboardingController(
        api: _OnboardingApi(const <ApiResult<CreateFirstContentLineResult>>[]),
        initialPositioningAgent: const _AcceptedRunPositioningAgent(),
        sessionStore: session,
        continuation: continuation,
      );
      _answerBusiness(controller);
      final submission = controller.startBackground();
      await Future<void>.delayed(Duration.zero);
      expect(controller.defer(), isTrue);
      controller.dispose();
      final receipt = await submission;
      expect(receipt?.agentRunId, 'agent_run_accepted_positioning');
      expect(
        continuation.acceptedRunFor('user-1')?.agentRunId,
        'agent_run_accepted_positioning',
      );
      expect(continuation.isDeferredFor('user-1'), isTrue);
      expect(session.state.requiresInitialPositioning, isTrue);
    },
  );

  test('no-business cards build the reference LV1 prompt exactly', () async {
    final fixture = await _fixture(
      apiResults: <ApiResult<CreateFirstContentLineResult>>[],
    );
    _answerNoBusiness(fixture.controller);

    final prompt = buildInitialPositioningPrompt(fixture.controller.state);

    expect(prompt, contains('用户当前状态：没业务'));
    expect(prompt, contains('- 你是否有明确的用户画像？：Local founders'));
    expect(prompt, contains('- 上学期间学过什么专业？：Marketing'));
    expect(prompt, contains('1. 初步定位判断'));
    expect(prompt, contains('5. 账号内容方向和表达建议'));
  });

  test(
    'initial positioning follows the Position LV1 run and profile sequence',
    () async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'user-1',
      );
      final chat = _InitialPositioningChatApi(
        threadDetails: <ChatThreadDetail>[
          _positioningThreadDetail(messages: const <ChatMessage>[]),
          _positioningThreadDetail(
            messages: <ChatMessage>[
              _positioningAssistantMessage(
                textPreview:
                    '这是 Lv1 定位报告。\n\n'
                    '```huahuo-positioning-progress\n'
                    '{"coldStartPercent":60,"coldStartCompleted":false}\n'
                    '```',
              ),
            ],
          ),
        ],
      );
      final runApi = _InitialPositioningRunApi(<AssistantRunSnapshot>[
        _positioningRun(status: AssistantRunStatus.queued),
        _positioningRun(
          status: AssistantRunStatus.succeeded,
          assistantMessageId: 'lv1-assistant-1',
          completionQuality: AssistantCompletionQuality.normal,
        ),
      ]);
      final profileApi = _InitialPositioningProfileApi(<ApiContractObject>[
        _profileSnapshot(),
      ]);
      final waits = <Duration>[];
      final agent = InitialPositioningAgent(
        chatRepository: chat,
        assistantRuntime: runApi,
        threadAliasRepository: repository,
        profileApi: profileApi,
        delay: (duration) async {
          waits.add(duration);
        },
      );

      final submission = await agent.submit('完整的基础定位问卷');

      expect(submission.ok, isTrue);
      expect(submission.data?.threadId, 'lv1-thread-1');
      expect(submission.data?.report, contains('这是 Lv1 定位报告。'));
      expect(
        submission.data?.report,
        contains('```huahuo-positioning-progress'),
      );
      expect(submission.data?.receipt.agentRunId, 'agent_run_lv1_1');
      expect(submission.data?.receipt.taskId, 'ai_task_lv1_1');
      expect(submission.data?.receipt.messageId, 'message_lv1_1');
      expect(submission.data?.receipt.status, 'sent');
      expect(submission.data?.savedProfile?.positioning, '面向本地创业者。');
      expect(
        submission.data?.savedProfile?.positioningProgress?.completedPercent,
        72,
      );
      expect(agent.pollAttempts, 180);
      expect(agent.threadReadbackRetries, 10);
      expect(chat.sentContents, <String>['完整的基础定位问卷']);
      expect(chat.sentAgentProfileIds, <String>['positioning_lv1']);
      expect(
        chat.createIdempotencyKeys.single,
        startsWith('positioning-thread-'),
      );
      expect(
        chat.messageIdempotencyKeys.single,
        startsWith('positioning-message-'),
      );
      expect(runApi.calls, <String>['agent_run_lv1_1', 'agent_run_lv1_1']);
      expect(chat.detailCalls, <String>['lv1-thread-1', 'lv1-thread-1']);
      expect(waits, <Duration>[
        const Duration(seconds: 2),
        const Duration(seconds: 2),
        const Duration(seconds: 1),
      ]);
      expect(profileApi.calls, 1);
      expect(
        repository.threadIdsForPurpose(
          scene: ChatScene.workAi,
          purpose: ChatConversationPurpose.deepPositioning,
        ),
        contains('lv1-thread-1'),
      );
    },
  );

  test(
    'terminal Position LV1 failure exposes its server error and never reads a report',
    () async {
      final database = AppDatabase();
      final chat = _InitialPositioningChatApi(
        threadDetails: const <ChatThreadDetail>[],
      );
      final profileApi = _InitialPositioningProfileApi(
        const <ApiContractObject>[],
      );
      final agent = InitialPositioningAgent(
        chatRepository: chat,
        assistantRuntime: _InitialPositioningRunApi(<AssistantRunSnapshot>[
          _positioningRun(
            status: AssistantRunStatus.failed,
            failure: const AssistantRunFailure(
              code: 'POSITIONING_INPUT_REJECTED',
            ),
          ),
        ]),
        threadAliasRepository: ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'user-1',
        ),
        profileApi: profileApi,
        delay: (_) async {},
      );

      final submission = await agent.submit('完整的基础定位问卷');

      expect(submission.ok, isFalse);
      expect(submission.errorCode, 'POSITIONING_INPUT_REJECTED');
      expect(chat.detailCalls, isEmpty);
      expect(profileApi.calls, 0);
    },
  );

  test('submits one report then confirms onboarding with backend', () async {
    final fixture = await _fixture(
      apiResults: <ApiResult<CreateFirstContentLineResult>>[_completed()],
      agentResults: <InitialPositioningAgentSubmission>[
        InitialPositioningAgentSubmission.success(
          _agentResult(
            threadId: 'thread-lv1-1',
            report: '## 初步定位判断\n从访谈创业者开始。',
          ),
        ),
      ],
    );
    _answerBusiness(fixture.controller);

    final line = await fixture.controller.submit();

    expect(line?.contentLineId, 'line-1');
    expect(fixture.agent.prompts, hasLength(1));
    expect(fixture.agent.prompts.single, contains('用户当前状态：有业务'));
    expect(fixture.api.requests, hasLength(1));
    expect(fixture.controller.state.serverReport, contains('初步定位判断'));
    expect(fixture.controller.state.reportThreadId, 'thread-lv1-1');
    expect(fixture.controller.state.isReportReady, isTrue);
    expect(
      fixture.controller.state.confirmedContentLine?.contentLineId,
      'line-1',
    );
    expect(fixture.session.state.onboardingRequired, isTrue);
    expect(fixture.session.selectRoute().type, SessionRouteType.onboarding);
    expect(
      fixture.continuation.snapshotFor('user-1').mode,
      onboardingBusinessMode,
    );

    final repeatedLine = await fixture.controller.submit();
    expect(repeatedLine?.contentLineId, 'line-1');
    expect(fixture.agent.prompts, hasLength(1));
    expect(fixture.api.requests, hasLength(1));

    expect(await fixture.controller.enterWorkspace(), isTrue);
    expect(fixture.session.state.onboardingRequired, isFalse);
    expect(fixture.session.selectRoute().type, SessionRouteType.v3);
    expect(fixture.continuation.snapshotFor('user-1').mode, isEmpty);
  });

  test('completion-write retry retains the durable Agent report', () async {
    final fixture = await _fixture(
      apiResults: <ApiResult<CreateFirstContentLineResult>>[
        _failure('NETWORK_UNAVAILABLE'),
        _completed(),
      ],
      agentResults: <InitialPositioningAgentSubmission>[
        InitialPositioningAgentSubmission.success(
          _agentResult(threadId: 'thread-lv1-2', report: '报告内容'),
        ),
      ],
    );
    _answerBusiness(fixture.controller);

    await fixture.controller.submit();
    expect(fixture.controller.state.hasServerReport, isTrue);
    expect(fixture.session.state.onboardingRequired, isTrue);
    await fixture.controller.submit();

    expect(fixture.agent.prompts, hasLength(1));
    expect(fixture.api.idempotencies, hasLength(2));
    expect(fixture.api.idempotencies[1].automaticRetry, isTrue);
    expect(fixture.session.state.onboardingRequired, isTrue);
    expect(await fixture.controller.enterWorkspace(), isTrue);
    expect(fixture.session.state.onboardingRequired, isFalse);
  });

  test(
    'resolves an existing default line after a positioning write conflict',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[
          _failure('POSITIONING_VERSION_CONFLICT'),
        ],
        existingDefaultContentLine: const OnboardingContentLine(
          contentLineId: 'existing-positioning',
          name: '已有内容方向',
          industry: '咨询',
          status: 'active',
          version: 3,
          isDefault: true,
          isPlaceholder: false,
        ),
        agentResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.success(
            _agentResult(threadId: 'thread-lv1-conflict', report: '报告内容'),
          ),
        ],
      );
      _answerBusiness(fixture.controller);

      final line = await fixture.controller.submit();

      expect(line?.contentLineId, 'existing-positioning');
      expect(fixture.agent.prompts, hasLength(1));
      expect(fixture.api.requests, hasLength(1));
      expect(fixture.api.defaultLineReads, 1);
      expect(fixture.controller.state.isReportReady, isTrue);
      expect(fixture.controller.state.errorCode, isNull);
      expect(await fixture.controller.enterWorkspace(), isTrue);
      expect(fixture.session.state.requiresInitialPositioning, isFalse);
    },
  );

  test(
    'entering the workspace stores the exact Lv1 report before Session completion',
    () async {
      final sink = _PositioningReportSink();
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[_completed()],
        agentResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.success(
            _agentResult(
              threadId: 'thread-lv1-handoff',
              report: '## 完整基础定位报告\n\n保留这份完整结论。',
            ),
          ),
        ],
        positioningReportSink: sink,
      );
      _answerBusiness(fixture.controller);

      await fixture.controller.submit();
      expect(fixture.session.state.onboardingRequired, isTrue);

      expect(await fixture.controller.enterWorkspace(), isTrue);
      expect(sink.markdown, '## 完整基础定位报告\n\n保留这份完整结论。');
      expect(sink.savedAt, isNotNull);
      expect(fixture.session.state.onboardingRequired, isFalse);
    },
  );

  test(
    'report-handoff failure keeps the completed onboarding retryable',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[_completed()],
        agentResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.success(
            _agentResult(threadId: 'thread-lv1-handoff-fail', report: '报告内容'),
          ),
        ],
        positioningReportSink: _PositioningReportSink(succeeds: false),
      );
      _answerBusiness(fixture.controller);

      await fixture.controller.submit();

      expect(await fixture.controller.enterWorkspace(), isFalse);
      expect(fixture.controller.state.isReportReady, isTrue);
      expect(
        fixture.controller.state.errorCode,
        'ONBOARDING_REPORT_SAVE_FAILED',
      );
      expect(fixture.session.state.onboardingRequired, isTrue);
    },
  );

  test(
    'profile retry keeps the durable report and does not resubmit Lv1',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[_completed()],
        agentResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.success(
            _agentResult(
              threadId: 'thread-lv1-profile',
              report: '## 已生成的定位报告',
              profileErrorCode: 'WORKSPACE_SYNC_FAILED',
            ),
          ),
        ],
        profileReads: <InitialPositioningProfileRead>[
          InitialPositioningProfileRead.success(
            InitialPositioningProfile(
              workspaceId: 'workspace-1',
              overview: '创业者访谈',
              selfDescription: '',
              positioning: '面向本地创业者。',
              conclusions: const <InitialPositioningProfileConclusion>[],
            ),
          ),
        ],
      );
      _answerBusiness(fixture.controller);

      await fixture.controller.submit();
      expect(fixture.controller.state.hasServerReport, isTrue);
      expect(
        fixture.controller.state.profileErrorCode,
        'WORKSPACE_SYNC_FAILED',
      );

      await fixture.controller.retrySavedProfile();

      expect(fixture.agent.prompts, hasLength(1));
      expect(fixture.agent.profileReads, 1);
      expect(fixture.controller.state.savedProfile?.positioning, '面向本地创业者。');
      expect(fixture.controller.state.profileErrorCode, isNull);
    },
  );

  test(
    'Agent failure leaves the cards and server onboarding state intact',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[],
        agentResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.failure(
            'CHAT_AGENT_CATALOG_UNAVAILABLE',
          ),
        ],
      );
      _answerBusiness(fixture.controller);

      expect(await fixture.controller.submit(), isNull);

      expect(fixture.api.requests, isEmpty);
      expect(fixture.session.state.onboardingRequired, isTrue);
      expect(
        fixture.controller.state.errorCode,
        'CHAT_AGENT_CATALOG_UNAVAILABLE',
      );
      expect(fixture.continuation.snapshotFor('user-1').mode, isNotEmpty);
    },
  );

  test(
    'only a nonterminal accepted Run temporarily relaxes the route gate',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[],
      );
      const receipt = InitialPositioningRunReceipt(
        threadId: 'thread_positioning_1',
        agentRunId: 'agent_run_positioning_1',
        taskId: 'task_positioning_1',
        messageId: 'message_positioning_1',
        status: 'accepted',
      );

      expect(fixture.continuation.acceptRun('user-1', receipt), isTrue);
      expect(fixture.continuation.hasActiveAcceptedRunFor('user-1'), isTrue);
      expect(fixture.continuation.markRunFinalizing('user-1'), isTrue);
      expect(fixture.continuation.hasActiveAcceptedRunFor('user-1'), isTrue);

      expect(
        fixture.continuation.markRunFailed(
          'user-1',
          'ONBOARDING_AGENT_REPORT_UNAVAILABLE',
        ),
        isTrue,
      );
      expect(fixture.continuation.hasAcceptedRunFor('user-1'), isTrue);
      expect(fixture.continuation.hasActiveAcceptedRunFor('user-1'), isFalse);
    },
  );

  test(
    'accepted Run does not wait for foreground tracker registration',
    () async {
      final database = AppDatabase();
      final session = await _onboardingSession();
      final continuation = OnboardingContinuationController(
        repository: OnboardingProgressRepository(
          dao: AppPreferencesDao(database),
        ),
      );
      final tracker = _PendingRunTracker();
      final controller = ContentLineOnboardingController(
        api: _OnboardingApi(const <ApiResult<CreateFirstContentLineResult>>[]),
        initialPositioningAgent: const _AcceptedRunPositioningAgent(),
        sessionStore: session,
        continuation: continuation,
        runTracker: tracker,
      );
      addTearDown(controller.dispose);
      addTearDown(continuation.dispose);
      _answerBusiness(controller);

      final receipt = await controller.startBackground();

      expect(receipt?.agentRunId, 'agent_run_accepted_positioning');
      expect(tracker.calls, 1);
      expect(continuation.hasActiveAcceptedRunFor('user-1'), isTrue);

      tracker.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'concurrent report commands share one in-flight Agent submission',
    () async {
      final database = AppDatabase();
      final session = await _onboardingSession();
      final continuation = OnboardingContinuationController(
        repository: OnboardingProgressRepository(
          dao: AppPreferencesDao(database),
        ),
      );
      final agent = _PendingInitialPositioningAgent();
      final controller = ContentLineOnboardingController(
        api: _OnboardingApi(const <ApiResult<CreateFirstContentLineResult>>[]),
        initialPositioningAgent: agent,
        sessionStore: session,
        continuation: continuation,
      );
      addTearDown(controller.dispose);
      addTearDown(continuation.dispose);
      _answerBusiness(controller);

      final firstSubmission = controller.submit();
      final secondSubmission = controller.submit();
      await Future<void>.delayed(Duration.zero);

      expect(identical(firstSubmission, secondSubmission), isTrue);
      expect(controller.state.isSubmitting, isTrue);
      expect(agent.submitCalls, 1);

      agent.complete(
        InitialPositioningAgentSubmission.failure('AGENT_PLAN_INVALID'),
      );
      expect(await firstSubmission, isNull);
      expect(controller.state.errorCode, 'AGENT_PLAN_INVALID');
    },
  );

  test(
    'provider preserves one pending submission across notifications and re-entry',
    () async {
      final database = AppDatabase();
      final session = await _onboardingSession();
      final continuation = OnboardingContinuationController(
        repository: OnboardingProgressRepository(
          dao: AppPreferencesDao(database),
        ),
      );
      final agent = _PendingInitialPositioningAgent();
      final container = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => session),
          onboardingApiProvider.overrideWithValue(
            _OnboardingApi(const <ApiResult<CreateFirstContentLineResult>>[]),
          ),
          initialPositioningAgentProvider.overrideWithValue(agent),
          initialPositioningAccessCheckProvider.overrideWithValue(
            () async => InitialPositioningAccess.notStarted,
          ),
          onboardingContinuationControllerProvider.overrideWith(
            (ref) => continuation,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen<ContentLineOnboardingController>(
        contentLineOnboardingControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );

      final controller = container.read(
        contentLineOnboardingControllerProvider,
      );
      _answerBusiness(controller);
      expect(
        identical(
          container.read(contentLineOnboardingControllerProvider),
          controller,
        ),
        isTrue,
      );

      final firstSubmission = controller.submit();
      subscription.close();
      await Future<void>.delayed(Duration.zero);
      final reentrySubscription = container
          .listen<ContentLineOnboardingController>(
            contentLineOnboardingControllerProvider,
            (previous, next) {},
            fireImmediately: true,
          );
      final reenteredController = container.read(
        contentLineOnboardingControllerProvider,
      );
      final secondSubmission = reenteredController.submit();

      expect(identical(reenteredController, controller), isTrue);
      expect(identical(secondSubmission, firstSubmission), isTrue);
      expect(agent.submitCalls, 1);

      agent.complete(
        InitialPositioningAgentSubmission.failure('AGENT_PLAN_INVALID'),
      );
      expect(await firstSubmission, isNull);
      expect(reenteredController.state.errorCode, 'AGENT_PLAN_INVALID');
      reentrySubscription.close();
    },
  );

  test(
    'defer persists and restores normalized custom-choice answers',
    () async {
      final fixture = await _fixture(
        apiResults: <ApiResult<CreateFirstContentLineResult>>[],
      );
      fixture.controller.selectMode(OnboardingIntakeMode.business);
      fixture.controller.updateAnswer('customerScope', ' 海外华人市场 ');
      fixture.controller.updateAnswer('customerTalkValue', <String>[
        '客户案例复盘',
        '行业信息差',
        '客户案例复盘',
      ]);

      expect(fixture.controller.state.answers['customerScope'], '海外华人市场');
      expect(fixture.controller.state.answers['customerTalkValue'], <String>[
        '行业信息差',
        '客户案例复盘',
      ]);

      expect(fixture.controller.defer(), isTrue);

      final restored = ContentLineOnboardingController(
        api: fixture.api,
        initialPositioningAgent: fixture.agent,
        sessionStore: fixture.session,
        continuation: fixture.continuation,
      );
      addTearDown(restored.dispose);
      expect(fixture.continuation.isDeferredFor('user-1'), isTrue);
      expect(restored.state.mode, OnboardingIntakeMode.business);
      expect(restored.state.answers['customerScope'], '海外华人市场');
      expect(restored.state.answers['customerTalkValue'], <String>[
        '行业信息差',
        '客户案例复盘',
      ]);
    },
  );

  test(
    'defer during report generation preserves cards and ignores late reply',
    () async {
      final database = AppDatabase();
      final session = await _onboardingSession();
      final continuation = OnboardingContinuationController(
        repository: OnboardingProgressRepository(
          dao: AppPreferencesDao(database),
        ),
        now: () => DateTime.utc(2026, 8, 9, 10),
      );
      final api = _OnboardingApi(
        const <ApiResult<CreateFirstContentLineResult>>[],
      );
      final agent = _PendingInitialPositioningAgent();
      final controller = ContentLineOnboardingController(
        api: api,
        initialPositioningAgent: agent,
        sessionStore: session,
        continuation: continuation,
      );
      addTearDown(controller.dispose);
      _answerBusiness(controller);
      final savedAnswers = Map<String, Object>.from(controller.state.answers);

      final submission = controller.submit();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isSubmitting, isTrue);
      expect(controller.defer(), isTrue);
      expect(controller.state.isSubmitting, isFalse);
      expect(continuation.isDeferredFor('user-1'), isTrue);

      agent.complete(
        InitialPositioningAgentSubmission.success(
          _agentResult(threadId: 'late-lv1-thread', report: '不应在延后填写后保存的报告'),
        ),
      );

      expect(await submission, isNull);
      expect(api.requests, isEmpty);
      expect(session.state.onboardingRequired, isTrue);
      final resumed = ContentLineOnboardingController(
        api: api,
        initialPositioningAgent: agent,
        sessionStore: session,
        continuation: continuation,
      );
      addTearDown(resumed.dispose);
      expect(resumed.state.stepIndex, 3);
      expect(resumed.state.answers, savedAnswers);
    },
  );
}

void _answerBusiness(ContentLineOnboardingController controller) {
  controller.selectMode(OnboardingIntakeMode.business);
  controller.updateAnswer('customerScope', '全国客户');
  controller.goNext();
  controller.updateAnswer('productDescription', 'Retail voice');
  controller.goNext();
  controller.updateAnswer('desiredCustomer', 'Store owners');
  controller.goNext();
  controller.updateAnswer('customerTalkValue', <String>['行业信息差', '有自己的观点']);
}

void _answerNoBusiness(ContentLineOnboardingController controller) {
  controller.selectMode(OnboardingIntakeMode.noBusiness);
  const answers = <String, String>{
    'userProfile': 'Local founders',
    'direction': 'Founder interviews',
    'strengths': 'Asking practical questions',
    'dailyConcerns': 'Small business growth',
    'readingHabit': 'Business biographies',
    'workHistory': 'Retail operations',
    'schoolMajor': 'Marketing',
  };
  for (final question in controller.state.questions) {
    controller.updateAnswer(question.id, answers[question.id]!);
    if (!controller.state.isLastQuestion) controller.goNext();
  }
}

Future<_Fixture> _fixture({
  required List<ApiResult<CreateFirstContentLineResult>> apiResults,
  List<InitialPositioningAgentSubmission> agentResults =
      const <InitialPositioningAgentSubmission>[],
  List<InitialPositioningProfileRead> profileReads =
      const <InitialPositioningProfileRead>[],
  InitialPositioningReportSink? positioningReportSink,
  OnboardingContentLine? existingDefaultContentLine,
  Future<InitialPositioningAccess> Function()? checkPositioningAccess,
}) async {
  final session = await _onboardingSession();
  final api = _OnboardingApi(
    apiResults,
    existingDefaultContentLine: existingDefaultContentLine,
  );
  final agent = _InitialPositioningAgent(agentResults, profileReads);
  final continuation = OnboardingContinuationController(
    repository: OnboardingProgressRepository(
      dao: AppPreferencesDao(AppDatabase()),
    ),
    now: () => DateTime.utc(2026, 8, 9, 10),
  );
  final controller = ContentLineOnboardingController(
    checkPositioningAccess: checkPositioningAccess,
    api: api,
    initialPositioningAgent: agent,
    sessionStore: session,
    positioningReportSink: positioningReportSink,
    continuation: continuation,
  );
  addTearDown(controller.dispose);
  addTearDown(continuation.dispose);
  return _Fixture(
    session: session,
    api: api,
    agent: agent,
    continuation: continuation,
    controller: controller,
  );
}

Future<SessionStore> _onboardingSession() async {
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
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
    updatedAt: DateTime.utc(2026, 8, 9),
  );
  return session;
}

ApiResult<CreateFirstContentLineResult> _completed() =>
    ApiResult<CreateFirstContentLineResult>.success(
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
      idempotencyStore: SubmissionKeyStore.empty,
    );

ApiResult<CreateFirstContentLineResult> _failure(String code) =>
    ApiResult<CreateFirstContentLineResult>.failure(
      error: AppFailure(
        code: code,
        category: AppFailureCategory.network,
        message: 'unavailable',
        userMessageKey: 'network.unavailable',
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );

ApiResult<T> _apiFailure<T>(String code) => ApiResult<T>.failure(
  error: AppFailure(
    code: code,
    category: AppFailureCategory.network,
    message: 'unavailable',
    userMessageKey: 'network.unavailable',
  ),
  idempotencyStore: SubmissionKeyStore.empty,
);

InitialPositioningAgentResult _agentResult({
  required String threadId,
  required String report,
  InitialPositioningProfile? savedProfile,
  String? profileErrorCode,
}) => InitialPositioningAgentResult(
  threadId: threadId,
  report: report,
  receipt: InitialPositioningRunReceipt(
    threadId: threadId,
    agentRunId: 'agent_run_${threadId.replaceAll('-', '_')}',
    taskId: 'ai_task_${threadId.replaceAll('-', '_')}',
    messageId: 'message_${threadId.replaceAll('-', '_')}',
    status: 'sent',
  ),
  savedProfile: savedProfile,
  profileErrorCode: profileErrorCode,
);

final class _Fixture {
  const _Fixture({
    required this.session,
    required this.api,
    required this.agent,
    required this.continuation,
    required this.controller,
  });

  final SessionStore session;
  final _OnboardingApi api;
  final _InitialPositioningAgent agent;
  final OnboardingContinuationController continuation;
  final ContentLineOnboardingController controller;
}

final class _PositioningReportSink implements InitialPositioningReportSink {
  _PositioningReportSink({this.succeeds = true});

  final bool succeeds;
  String? markdown;
  DateTime? savedAt;

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    if (!succeeds) return false;
    this.markdown = markdown;
    this.savedAt = savedAt;
    return true;
  }
}

final class _OnboardingApi
    implements OnboardingApiPort, OnboardingDefaultContentLineReadPort {
  _OnboardingApi(
    List<ApiResult<CreateFirstContentLineResult>> results, {
    this.existingDefaultContentLine,
  }) : _results = List<ApiResult<CreateFirstContentLineResult>>.of(results);

  final List<ApiResult<CreateFirstContentLineResult>> _results;
  final List<CreateFirstContentLineRequest> requests =
      <CreateFirstContentLineRequest>[];
  final List<IdempotencyRequestContext> idempotencies =
      <IdempotencyRequestContext>[];
  final OnboardingContentLine? existingDefaultContentLine;
  int defaultLineReads = 0;

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    requests.add(request);
    idempotencies.add(idempotency);
    if (_results.isEmpty) return _failure('UNEXPECTED_ONBOARDING_REQUEST');
    return _results.removeAt(0);
  }

  @override
  Future<ApiResult<OnboardingDefaultContentLineRead>>
  readDefaultContentLine() async {
    defaultLineReads += 1;
    return ApiResult<OnboardingDefaultContentLineRead>.success(
      data: OnboardingDefaultContentLineRead(
        contentLine: existingDefaultContentLine,
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _InitialPositioningAgent implements InitialPositioningAgentPort {
  _InitialPositioningAgent(
    List<InitialPositioningAgentSubmission> results,
    List<InitialPositioningProfileRead> profileResults,
  ) : _results = List<InitialPositioningAgentSubmission>.of(results),
      _profileResults = List<InitialPositioningProfileRead>.of(profileResults);

  final List<InitialPositioningAgentSubmission> _results;
  final List<InitialPositioningProfileRead> _profileResults;
  final List<String> prompts = <String>[];
  int profileReads = 0;

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) async {
    prompts.add(prompt);
    if (_results.isEmpty) {
      return InitialPositioningAgentSubmission.failure(
        'UNEXPECTED_AGENT_REQUEST',
      );
    }
    return _results.removeAt(0);
  }

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() async {
    profileReads += 1;
    if (_profileResults.isEmpty) {
      return InitialPositioningProfileRead.failure(
        'UNEXPECTED_PROFILE_REQUEST',
      );
    }
    return _profileResults.removeAt(0);
  }
}

final class _PendingInitialPositioningAgent
    implements InitialPositioningAgentPort {
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
      InitialPositioningProfileRead.failure('UNEXPECTED_PROFILE_REQUEST');

  void complete(InitialPositioningAgentSubmission result) {
    _completion.complete(result);
  }
}

final class _AcceptedRunPositioningAgent
    implements
        InitialPositioningAgentPort,
        InitialPositioningAgentAcceptedRunPort {
  const _AcceptedRunPositioningAgent();

  static const _receipt = InitialPositioningRunReceipt(
    threadId: 'accepted-positioning-thread',
    agentRunId: 'agent_run_accepted_positioning',
    taskId: 'accepted-positioning-task',
    messageId: 'accepted-positioning-message',
    status: 'accepted',
  );

  @override
  Future<InitialPositioningAgentAcceptance> start(String prompt) async =>
      InitialPositioningAgentAcceptance.success(_receipt);

  @override
  Future<InitialPositioningAgentSubmission> completeAccepted(
    InitialPositioningRunReceipt receipt,
  ) => throw UnimplementedError();

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() =>
      throw UnimplementedError();

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) =>
      throw UnimplementedError();
}

final class _PendingRunTracker implements ChatRunTrackingPort {
  final Completer<void> _completion = Completer<void>();
  var calls = 0;

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) {
    calls += 1;
    return _completion.future;
  }

  void complete() => _completion.complete();
}

final class _InitialPositioningChatApi implements ChatRepository {
  _InitialPositioningChatApi({required List<ChatThreadDetail> threadDetails})
    : _threadDetails = List<ChatThreadDetail>.of(threadDetails);

  final List<ChatThreadDetail> _threadDetails;
  final sentContents = <String>[];
  final sentAgentProfileIds = <String>[];
  final createIdempotencyKeys = <String>[];
  final messageIdempotencyKeys = <String>[];
  final detailCalls = <String>[];
  int _threadDetailIndex = 0;

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createIdempotencyKeys.add(idempotency.explicitKey ?? '');
    return ApiResult<ChatThread>.success(
      data: ChatThread(
        threadId: 'lv1-thread-1',
        scene: scene,
        purpose: purpose,
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    detailCalls.add(threadId);
    if (_threadDetails.isEmpty) {
      return _apiFailure<ChatThreadDetail>('UNEXPECTED_THREAD_READ');
    }
    final index = _threadDetailIndex < _threadDetails.length
        ? _threadDetailIndex
        : _threadDetails.length - 1;
    _threadDetailIndex += 1;
    return ApiResult<ChatThreadDetail>.success(
      data: _threadDetails[index],
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    sentContents.add(content);
    sentAgentProfileIds.add(agentProfileId ?? '');
    messageIdempotencyKeys.add(idempotency.explicitKey ?? '');
    return ApiResult<ChatTextMutation>.success(
      data: ChatTextMutation(
        message: ChatMessage(
          messageId: 'message_lv1_1',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'accepted',
          textPreview: content,
        ),
        nextAction: const ChatNextAction(
          type: ChatNextActionType.pollAgentRun,
          agentRunId: 'agent_run_lv1_1',
          taskId: 'ai_task_lv1_1',
        ),
        receiptThreadId: threadId,
        receiptMessageId: 'message_lv1_1',
        receiptStatus: 'sent',
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => throw UnimplementedError();
}

final class _InitialPositioningRunApi implements AssistantRuntimePort {
  _InitialPositioningRunApi(List<AssistantRunSnapshot> results)
    : _results = List<AssistantRunSnapshot>.of(results);

  final List<AssistantRunSnapshot> _results;
  final calls = <String>[];

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) async {
    calls.add(handle.value);
    if (_results.isEmpty) {
      return const AssistantRuntimeRead<AssistantRunSnapshot>.failure(
        'UNEXPECTED_RUN_READ',
      );
    }
    return AssistantRuntimeRead.success(_results.removeAt(0));
  }
}

final class _InitialPositioningProfileApi
    implements InitialPositioningProfilePort {
  _InitialPositioningProfileApi(List<ApiContractObject> snapshots)
    : _snapshots = List<ApiContractObject>.of(snapshots);

  final List<ApiContractObject> _snapshots;
  int calls = 0;

  @override
  Future<ApiResult<ApiContractObject>> getCurrentProfile() async {
    calls += 1;
    if (_snapshots.isEmpty) {
      return ApiResult<ApiContractObject>.failure(
        error: AppFailure(
          code: 'UNEXPECTED_PROFILE_READ',
          category: AppFailureCategory.api,
          message: 'unavailable',
          userMessageKey: 'profile.unavailable',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<ApiContractObject>.success(
      data: _snapshots.removeAt(0),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

ChatThreadDetail _positioningThreadDetail({
  required List<ChatMessage> messages,
}) => ChatThreadDetail(
  thread: const ChatThread(
    threadId: 'lv1-thread-1',
    scene: ChatScene.workAi,
    purpose: ChatConversationPurpose.deepPositioning,
  ),
  messages: messages,
);

ChatMessage _positioningAssistantMessage({
  String textPreview = '这是 Lv1 定位报告。',
}) => ChatMessage(
  messageId: 'lv1-assistant-1',
  threadId: 'lv1-thread-1',
  scene: ChatScene.workAi,
  role: ChatMessageRole.assistant,
  contentType: ChatMessageContentType.text,
  status: 'sent',
  taskId: 'ai_task_lv1_1',
  agentRunId: 'agent_run_lv1_1',
  textPreview: textPreview,
);

AssistantRunSnapshot _positioningRun({
  required AssistantRunStatus status,
  String? assistantMessageId,
  AssistantCompletionQuality completionQuality =
      AssistantCompletionQuality.unknown,
  AssistantRunFailure? failure,
}) => AssistantRunSnapshot(
  handle: const AssistantRunHandle('agent_run_lv1_1'),
  conversationId: 'lv1-thread-1',
  correlationId: 'ai_task_lv1_1',
  status: status,
  output: assistantMessageId == null
      ? null
      : AssistantRunOutput(messageId: assistantMessageId, text: '报告'),
  completionQuality: completionQuality,
  failure: failure,
  createdAt: DateTime.utc(2026, 8, 10, 8),
  updatedAt: DateTime.utc(2026, 8, 10, 8, 0, 2),
);

ApiContractObject _profileSnapshot() =>
    ApiContractObject(const <String, Object?>{
      'workspaceId': 'workspace-1',
      'overview': '创业者访谈',
      'selfDescription': '',
      'positioning': '面向本地创业者。',
      'positioningProgress': <String, Object?>{
        'available': true,
        'coldStartPercent': 100,
        'coldStartCompleted': true,
        'completedPercent': 72,
        'consultingCompleted': false,
        'modules': <Object?>[],
      },
      'conclusions': <Object?>[],
    });

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
