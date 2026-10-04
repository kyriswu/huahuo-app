import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/application/auth_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

const _phone = String.fromEnvironment('HUAHUO_LIVE_E2E_PHONE');
const _code = String.fromEnvironment('HUAHUO_LIVE_E2E_CODE');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real iOS simulator presents a mandatory resumable startup journey',
    (tester) async {
      expect(
        _phone,
        isNotEmpty,
        reason: 'Pass HUAHUO_LIVE_E2E_PHONE as a Dart define.',
      );
      expect(
        _code,
        isNotEmpty,
        reason: 'Pass HUAHUO_LIVE_E2E_CODE as a Dart define.',
      );

      await app.main();
      await _waitForAny(tester, <Finder>[
        find.byKey(const ValueKey<String>('auth-login')),
        ..._journeyControls(),
        find.byKey(const ValueKey<String>('home-profile-menu')),
        find.byKey(const ValueKey<String>('onboarding-mode-business')),
      ]);

      if (find
          .byKey(const ValueKey<String>('auth-login'))
          .evaluate()
          .isNotEmpty) {
        await _login(tester);
      }

      final session = _container(tester).read(sessionStoreProvider).state;
      expect(
        session.authState,
        SessionAuthState.authenticated,
        reason:
            'The real SMS login did not establish an authenticated session.',
      );
      await _waitForAny(tester, <Finder>[
        ..._journeyControls(),
        find.byKey(const ValueKey<String>('home-profile-menu')),
        find.byKey(const ValueKey<String>('onboarding-mode-business')),
        find.text('正在创建你的工作空间'),
        find.text('工作空间暂不可用'),
      ], timeout: const Duration(seconds: 20));

      if (find
          .byKey(const ValueKey<String>('onboarding-mode-business'))
          .evaluate()
          .isNotEmpty) {
        fail(
          'LIVE_STARTUP_JOURNEY_PRECONDITION_UNMET: the supplied account '
          'still requires first-positioning intake.',
        );
      }
      if (find.text('正在创建你的工作空间').evaluate().isNotEmpty ||
          find.text('工作空间暂不可用').evaluate().isNotEmpty) {
        fail(
          'LIVE_STARTUP_JOURNEY_WORKSPACE_UNAVAILABLE: '
          '${_sessionSummary(session)}',
        );
      }

      final controller = _container(
        tester,
      ).read(firstLaunchDeviceSetupControllerProvider);
      if (controller.phase == FirstLaunchJourneyPhase.notStarted) {
        fail(
          'LIVE_STARTUP_JOURNEY_POSITIONING_NOT_ACCEPTED: the account has no '
          'verified initial-positioning completion for this startup journey.',
        );
      }
      if (controller.phase == FirstLaunchJourneyPhase.completed) {
        fail(
          'LIVE_STARTUP_JOURNEY_ALREADY_COMPLETED: reset this simulator app '
          'data before rerunning the mandatory journey test.',
        );
      }
      if (controller.phase == FirstLaunchJourneyPhase.chatRequired) {
        fail(
          'LIVE_STARTUP_JOURNEY_DEVICE_SETUP_COMPLETED: this account has '
          'reached the chat guide, which permits home access. Use an account '
          'that still requires voiceprint or recording-card setup.',
        );
      }

      final visibleControl = await _verifyVisibleIncompletePhase(
        tester,
        controller,
      );
      _expectSequentialControls();
      await binding.takeScreenshot(
        'live_first_launch_${controller.phase.name}',
      );

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(visibleControl, findsOneWidget);
      expect(controller.requiresBlockingJourney, isTrue);
    },
  );
}

List<Finder> _journeyControls() => <Finder>[
  find.byKey(const ValueKey<String>('first-launch-report-notice-continue')),
  find.byKey(const ValueKey<String>('first-launch-voiceprint-enroll')),
  find.byKey(const ValueKey<String>('first-launch-recording-card-search')),
  find.byKey(const ValueKey<String>('first-launch-device-setup-finish')),
];

Future<Finder> _verifyVisibleIncompletePhase(
  WidgetTester tester,
  FirstLaunchDeviceSetupController controller,
) async {
  final control = switch (controller.phase) {
    FirstLaunchJourneyPhase.voiceprintRequired => find.byKey(
      const ValueKey<String>('first-launch-voiceprint-enroll'),
    ),
    FirstLaunchJourneyPhase.recordingCardRequired => find.byKey(
      const ValueKey<String>('first-launch-recording-card-search'),
    ),
    FirstLaunchJourneyPhase.notStarted ||
    FirstLaunchJourneyPhase.positioningRequired ||
    FirstLaunchJourneyPhase.chatRequired ||
    FirstLaunchJourneyPhase.completed => throw StateError(
      'Expected a blocking device-setup phase; chat guide permits home access.',
    ),
  };
  await _waitFor(tester, control);

  switch (controller.phase) {
    case FirstLaunchJourneyPhase.voiceprintRequired:
      expect(find.text('录入你的声纹'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('first-launch-recording-card-search'),
        ),
        findsNothing,
      );
    case FirstLaunchJourneyPhase.recordingCardRequired:
      expect(find.text('连接录音卡'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('first-launch-device-setup-finish')),
        findsNothing,
      );
    case FirstLaunchJourneyPhase.notStarted:
    case FirstLaunchJourneyPhase.positioningRequired:
    case FirstLaunchJourneyPhase.chatRequired:
    case FirstLaunchJourneyPhase.completed:
      throw StateError('Unexpected startup phase after route settlement.');
  }
  return control;
}

void _expectSequentialControls() {
  expect(find.byTooltip('返回'), findsNothing);
  expect(
    find
            .byKey(const ValueKey<String>('first-launch-voiceprint-skip'))
            .evaluate()
            .isNotEmpty ||
        find
            .byKey(const ValueKey<String>('first-launch-recording-card-skip'))
            .evaluate()
            .isNotEmpty,
    isTrue,
  );
}

Future<void> _login(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('auth-phone-input')),
    _phone,
  );
  await tester.tap(find.byKey(const ValueKey<String>('auth-send-code')));
  await _waitForSmsRequestAcceptance(tester);
  await tester.enterText(
    find.byKey(const ValueKey<String>('auth-code-input')),
    _code,
  );
  await tester.tap(find.byKey(const ValueKey<String>('auth-agreement')));
  await tester.tap(find.byKey(const ValueKey<String>('auth-login')));
  await _waitUntil(
    tester,
    () =>
        _container(tester).read(sessionStoreProvider).state.authState ==
        SessionAuthState.authenticated,
    timeout: const Duration(seconds: 20),
    timeoutMessage: () {
      final auth = _container(tester).read(authControllerProvider).state;
      return 'LIVE_LOGIN_FAILED: ${auth.lastErrorCode ?? 'unknown'}';
    },
  );
}

Future<void> _waitForSmsRequestAcceptance(WidgetTester tester) async {
  const step = Duration(milliseconds: 200);
  const timeout = Duration(seconds: 20);
  var elapsed = Duration.zero;

  while (elapsed < timeout) {
    final auth = _container(tester).read(authControllerProvider).state;
    if (auth.status == AuthSubmissionStatus.idle &&
        auth.smsRequestId != null &&
        auth.lastErrorCode == null) {
      return;
    }
    if (auth.status == AuthSubmissionStatus.idle &&
        auth.lastErrorCode != null) {
      fail('LIVE_SMS_REQUEST_FAILED: ${_smsRequestSummary(auth)}');
    }
    await _pumpFor(tester, step);
    elapsed += step;
  }

  final auth = _container(tester).read(authControllerProvider).state;
  fail('LIVE_SMS_REQUEST_ACCEPTANCE_TIMEOUT: ${_smsRequestSummary(auth)}');
}

String _smsRequestSummary(AuthControllerState state) => <String>[
  'status=${state.status.name}',
  'ticket=${state.smsRequestId == null ? 'absent' : 'present'}',
  'error=${state.lastErrorCode ?? 'none'}',
].join(', ');

ProviderContainer _container(WidgetTester tester) {
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

String _sessionSummary(SessionState state) => <String>[
  'user=${state.user?.userId ?? 'none'}',
  'workspace=${state.workspaceStatus?.name ?? 'none'}',
  'onboardingRequired=${state.onboardingRequired}',
].join(', ');

Future<void> _waitForAny(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 12),
}) => _waitUntil(
  tester,
  () => finders.any((finder) => finder.evaluate().isNotEmpty),
  timeout: timeout,
  timeoutMessage: () => 'Timed out waiting for a recognized app startup state.',
);

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 12),
}) => _waitUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  timeout: timeout,
  timeoutMessage: () => 'Timed out waiting for the expected product control.',
);

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required Duration timeout,
  required String Function() timeoutMessage,
}) async {
  const step = Duration(milliseconds: 200);
  var elapsed = Duration.zero;
  while (elapsed < timeout) {
    if (predicate()) return;
    await _pumpFor(tester, step);
    elapsed += step;
  }
  fail(timeoutMessage());
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    await Future<void>.delayed(step);
    await tester.pump();
    elapsed += step;
  }
}
