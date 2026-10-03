import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/presentation/content_line_onboarding_page.dart';
import 'package:huahuoai_app/features/onboarding/presentation/v3_initial_positioning_progress_page.dart';

import 'content_line_onboarding_test_support.dart';

void main() {
  for (final startedJourney in [false, true]) {
    testWidgets(
      'returning report recovery preserves startup origin, started=$startedJourney',
      (tester) async {
        final fixture = await createOnboardingPageFixture(
          agent: CompletedPositioningAgent(),
          firstLogin: false,
        );
        if (startedJourney) fixture.journey.beginPositioning();
        answerBusinessQuestionnaire(fixture.controller);
        await fixture.controller.startBackground();
        expect(
          confirmOnboardingRegistration(
            fixture,
            fixture.controller.acceptedRun!.agentRunId,
          ),
          isTrue,
        );
        final router = onboardingPageTestRouter();
        addTearDown(router.dispose);
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: onboardingPageOverrides(fixture),
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(startedJourney ? '继续完成设置' : '返回首页'));
        await tester.pumpAndSettle();
        expect(
          find.text(startedJourney ? 'mandatory-setup' : 'v3-home'),
          findsOneWidget,
        );
        expect(fixture.journey.snapshot.hasStarted, startedJourney);
        expect(fixture.controller.isBackendRegistered, isTrue);
      },
    );
  }
  testWidgets(
    'handoff failure stays in intake and retry confirms the same Run',
    (tester) async {
      final agent = CompletedPositioningAgent();
      final fixture = await createOnboardingPageFixture(agent: agent);
      final router = onboardingPageTestRouter(
        guardedSession: fixture.session,
        continuation: fixture.continuation,
      );
      addTearDown(router.dispose);
      addTearDown(fixture.dispose);
      answerBusinessQuestionnaire(fixture.controller);
      final gate = Completer<void>();
      var confirmations = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: onboardingPageOverrides(
            fixture,
            registrar: (runId) async {
              confirmations += 1;
              if (confirmations == 1) {
                fixture.continuation.recordRunRegistration(
                  'user-1',
                  agentRunId: runId,
                  workspaceId: 'workspace-1',
                  errorCode: 'NETWORK_UNAVAILABLE',
                );
                return false;
              }
              await gate.future;
              return confirmOnboardingRegistration(fixture, runId);
            },
          ),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/onboarding');
      expect(fixture.journey.snapshot.positioning.hasExited, isFalse);
      expect(find.text('重试确认提交'), findsOneWidget);
      await tester.tap(find.text('重试确认提交'));
      await tester.pump();
      expect(router.state.uri.path, '/onboarding');
      expect(agent.startCalls, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('mandatory-setup'), findsOneWidget);
      expect(fixture.controller.isBackendRegistered, isTrue);
      expect(agent.startCalls, 1);
      expect(confirmations, 2);
    },
  );

  testWidgets('failed startup submission advances without a false receipt', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    fixture.journey.beginPositioning(includeChatGuide: true);
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    fixture.controller.selectMode(OnboardingIntakeMode.business);
    fixture.controller.updateAnswer('customerScope', '全国客户');
    fixture.controller.updateAnswer('productDescription', '产品服务');
    fixture.controller.updateAnswer('desiredCustomer', '创业者');
    fixture.controller.updateAnswer('customerTalkValue', <String>['行业信息差']);
    fixture.controller.goNext();
    fixture.controller.goNext();
    fixture.controller.goNext();
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
    await tester.pumpAndSettle();
    expect(find.text('mandatory-setup'), findsOneWidget);
    expect(
      fixture.journey.snapshot.positioning.status,
      FirstLaunchStepStatus.failed,
    );
    expect(fixture.controller.acceptedRun, isNull);
    expect(fixture.session.state.requiresInitialPositioning, isTrue);
  });

  testWidgets('startup questionnaire deferral advances without submitting', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    fixture.journey.beginPositioning(includeChatGuide: true);
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(onboardingPageTestApp(router, fixture));
    await tester.pump();
    expect(find.byKey(const ValueKey('onboarding-defer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-defer')));
    await tester.pumpAndSettle();
    expect(find.text('mandatory-setup'), findsOneWidget);
    expect(
      fixture.journey.snapshot.positioning.status,
      FirstLaunchStepStatus.deferred,
    );
    expect(fixture.journey.phase, FirstLaunchJourneyPhase.voiceprintRequired);
    expect(fixture.continuation.isDeferredFor('user-1'), isFalse);
  });

  testWidgets('first positioning starts from cards and not an Lv1 chat route', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    expect(find.text('基础定位'), findsOneWidget);
    expect(find.text('先选一下你的当前状态'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-start-lv1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('onboarding-mode-no-business')));
    await tester.pump();

    expect(find.text('你是否有明确的用户画像？'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-progress')), findsOneWidget);
  });

  testWidgets('custom-choice plus and text microphone entries are actionable', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('onboarding-mode-business')));
    await tester.pump();
    final addCustom = find.byKey(
      const ValueKey('onboarding-add-custom-option'),
    );
    expect(addCustom, findsOneWidget);

    await tester.tap(addCustom);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('onboarding-custom-customerScope')),
      '海外华人市场',
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(fixture.controller.state.answers['customerScope'], '海外华人市场');
    expect(find.text('海外华人市场'), findsOneWidget);

    fixture.controller.goNext();
    await tester.pump();
    final microphone = find.byKey(
      const ValueKey('onboarding-voice-input-productDescription'),
    );
    expect(microphone, findsOneWidget);
    expect(tester.widget<IconButton>(microphone).onPressed, isNotNull);
    expect(find.byTooltip('语音输入'), findsOneWidget);
  });

  testWidgets('ignores a shared voice failure owned outside onboarding', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    fixture.controller.selectMode(OnboardingIntakeMode.business);
    fixture.controller.updateAnswer('customerScope', '本地客户');
    fixture.controller.goNext();
    await tester.pump();

    expect(
      await fixture.voice.startLiveTranscription(owner: 'chat:external'),
      isFalse,
    );
    await tester.pumpAndSettle();

    expect(find.text('实时转写启动失败'), findsNothing);
  });

  testWidgets('owned voice failure keeps text and opens one dialog', (
    tester,
  ) async {
    final fixture = await createOnboardingPageFixture();
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    fixture.controller.selectMode(OnboardingIntakeMode.business);
    fixture.controller.updateAnswer('customerScope', '本地客户');
    fixture.controller.goNext();
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), '已经写好的回答');
    await tester.tap(
      find.byKey(const ValueKey('onboarding-voice-input-productDescription')),
    );
    await tester.pumpAndSettle();

    expect(find.text('实时转写启动失败'), findsOneWidget);
    expect(fixture.controller.state.answers['productDescription'], '已经写好的回答');
    expect(find.text('已经写好的回答'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('去设置'), findsNothing);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('final card immediately shows report generation in progress', (
    tester,
  ) async {
    final agent = PendingPositioningAgent();
    final fixture = await createOnboardingPageFixture(agent: agent);
    final router = onboardingPageTestRouter();
    addTearDown(router.dispose);
    addTearDown(fixture.dispose);
    answerBusinessQuestionnaire(fixture.controller);
    await tester.pumpWidget(
      ProviderScope(
        overrides: onboardingPageOverrides(fixture),
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
    await tester.pump();

    expect(find.text('正在提交'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-submit-progress')),
      findsOneWidget,
    );
    expect(agent.submitCalls, 1);
    final button = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('onboarding-primary')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);

    agent.complete(
      InitialPositioningAgentSubmission.failure('AGENT_PLAN_INVALID'),
    );
    await tester.pump();

    expect(find.text('基础定位服务正在调整，请稍后重试。'), findsOneWidget);
    expect(find.text('重新生成报告'), findsOneWidget);
  });

  testWidgets(
    'accepted first-account command enters mandatory setup while report runs',
    (tester) async {
      final api = CompletedOnboardingApi();
      final agent = CompletedPositioningAgent();
      final fixture = await createOnboardingPageFixture(api: api, agent: agent);
      final router = onboardingPageTestRouter(
        guardedSession: fixture.session,
        continuation: fixture.continuation,
      );
      addTearDown(router.dispose);
      addTearDown(fixture.dispose);
      answerBusinessQuestionnaire(fixture.controller);
      await tester.pumpWidget(
        ProviderScope(
          overrides: onboardingPageOverrides(fixture),
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      final generate = find.byKey(const ValueKey('onboarding-primary'));
      await tester.tap(generate);
      await tester.tap(generate);
      await tester.pumpAndSettle();

      expect(agent.startCalls, 1);
      expect(agent.submitCalls, 0);
      expect(api.createCalls, 0);
      expect(fixture.controller.state.errorCode, isNull);
      expect(find.text('mandatory-setup'), findsOneWidget);
      expect(
        fixture.journey.snapshot.phase,
        FirstLaunchJourneyPhase.voiceprintRequired,
      );
      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(fixture.continuation.hasAcceptedRunFor('user-1'), isTrue);
    },
  );

  testWidgets(
    'legacy first result delegates rather than rendering Chat Markdown',
    (tester) async {
      final fixture = await createOnboardingPageFixture(
        api: CompletedOnboardingApi(),
        agent: CompletedPositioningAgent(),
      );
      addTearDown(fixture.dispose);
      answerBusinessQuestionnaire(fixture.controller);
      await fixture.controller.submit();
      Widget? report;
      await tester.pumpWidget(
        ProviderScope(
          overrides: onboardingPageOverrides(fixture),
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                report = const ContentLineOnboardingPage().build(context, ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(report, isA<V3InitialPositioningProgressPage>());
      expect(fixture.session.state.requiresInitialPositioning, isTrue);
    },
  );
}
