import 'dart:async';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_route_screens.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart' as app_router;
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/application/auth_controller.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';
import 'package:huahuoai_app/features/auth/presentation/auth_screen.dart';
import 'package:huahuoai_app/features/auth/presentation/legal_document_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_brand_mark.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_text_editing.dart';

import '../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('login text lines center inside phone and code controls', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scale in [1.0, 1.5]) {
      await _pumpAuthScreen(
        tester,
        errorCode: 'AUTH_SESSION_EXPIRED',
        theme: HuahuoV3Theme.light(),
        textScaler: TextScaler.linear(scale),
      );
      await tester.pumpAndSettle();
      for (final (name, value) in [
        ('phone', '13800138000'),
        ('code', '123456'),
      ]) {
        final input = find.byKey(ValueKey('auth-$name-input'));
        final shell = find.byKey(ValueKey('auth-$name-shell'));
        for (final text in ['', value]) {
          await tester.enterText(input, text);
          await tester.pump();
          final editable = tester
              .state<EditableTextState>(
                find.descendant(of: input, matching: find.byType(EditableText)),
              )
              .renderEditable;
          final line = editable.localToGlobal(
            editable.getLocalRectForCaret(const TextPosition(offset: 0)).center,
          );
          expect(line.dy, closeTo(tester.getCenter(shell).dy, 1));
        }
        tester.widget<TextField>(input).focusNode!.unfocus();
        await tester.pump();
        final target = tester.getRect(
          find.ancestor(of: input, matching: find.byType(V3CenteredInput)),
        );
        await tester.tapAt(Offset(target.center.dx, target.top + 2));
        await tester.pump();
        expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('M10 auth matches the curated V5 viewport', (tester) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAuthScreen(
      tester,
      errorCode: '',
      theme: figmaGoldenTheme(),
      mediaPadding: const EdgeInsets.only(top: 54, bottom: 24),
    );
    await tester.pumpAndSettle();
    await precacheFigmaFixtureImages(tester);

    expect(
      tester.getRect(find.byType(Image).first),
      const Rect.fromLTWH(164, 72, 74, 74),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-login-card'))),
      const Rect.fromLTWH(24, 236, 354, 336),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-phone-shell'))),
      const Rect.fromLTWH(48, 294, 306, 52),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-code-shell'))),
      const Rect.fromLTWH(48, 398, 172, 52),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('auth-phone-input'))).dy,
      tester.getCenter(find.byKey(const ValueKey('auth-phone-shell'))).dy,
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('auth-code-input'))).dy,
      tester.getCenter(find.byKey(const ValueKey('auth-code-shell'))).dy,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('auth-send-code'))),
      const Size(122, 52),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-login'))),
      const Rect.fromLTWH(48, 492, 306, 50),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-help-center'))),
      const Rect.fromLTWH(24, 592, 172, 50),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('auth-customer-service'))),
      const Rect.fromLTWH(206, 592, 172, 50),
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/auth_surface.png'),
    );
  });

  test('app_router keeps route-screen exports compatible', () {
    expect(const SplashScreen(), isA<app_router.SplashScreen>());
    expect(const RestoreFailedScreen(), isA<app_router.RestoreFailedScreen>());
    expect(
      const WorkspaceStatusScreen(),
      isA<app_router.WorkspaceStatusScreen>(),
    );
  });

  testWidgets('Workspace polling requires foreground current route', (
    tester,
  ) async {
    final driver = _StoredSecureTokenDriver();
    final tokenStore = SecureTokenStore(driver: driver);
    final stored = await tokenStore.setTokens(
      const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
    expect(stored.ok, isTrue);
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final authApi = _FakeAuthApi(
      loginSucceeds: true,
      workspaceStatus: SessionWorkspaceStatus.creating,
    );
    final bootstrap = AppBootstrapController(
      secureTokenStore: tokenStore,
      sessionStore: sessionStore,
      authApi: authApi,
      userTimeZoneIsFallback: true,
    );
    await bootstrap.restore();
    expect(bootstrap.state.status, AppBootstrapStatus.ready);
    expect(authApi.statusCalls, 1);

    final activity = AppActivityCoordinator(binding: tester.binding);
    activity.updateLifecycle(AppLifecycleState.resumed);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          appBootstrapControllerProvider.overrideWith((ref) => bootstrap),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const WorkspaceStatusScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(authApi.statusCalls, 2);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(authApi.statusCalls, 2);

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(authApi.statusCalls, 3);

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(authApi.statusCalls, 3);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(authApi.statusCalls, 4);
  });

  testWidgets(
    'login uses canonical flat surfaces without replacing primary action',
    (tester) async {
      await _pumpAuthScreen(tester, errorCode: '');

      final card = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('auth-login-card')),
      );
      final decoration = card.decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(26));
      expect(decoration.boxShadow, isNull);
      expect(find.text('登录 / 注册'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('输入任意数字即可登录'), findsNothing);
      expect(find.text('当前为数字登录模式，不发送短信'), findsNothing);
    },
  );

  testWidgets('expired session renders safe login copy', (tester) async {
    await _pumpAuthScreen(tester, errorCode: 'AUTH_SESSION_EXPIRED');

    expect(find.text('登录状态已失效，请重新登录。'), findsWidgets);
    expect(find.text('手机号'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
  });

  testWidgets('login canvas and brand follow dark semantic tokens', (
    tester,
  ) async {
    await _pumpAuthScreen(tester, errorCode: '', theme: HuahuoV3Theme.dark());

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final brand = tester.widget<Text>(find.text('无限花火'));
    expect(scaffold.backgroundColor, HuahuoV3Theme.darkTokens.canvas);
    expect(brand.style?.color, HuahuoV3Theme.darkTokens.ink);
  });

  testWidgets('public help actions navigate without dispatching login', (
    tester,
  ) async {
    final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final authApi = _FakeAuthApi();
    final authController = AuthController(
      authApi: authApi,
      sessionStore: sessionStore,
      deviceId: 'device-1',
      clientVersion: '0.1.0',
    );
    final router = GoRouter(
      initialLocation: '/auth',
      routes: [
        GoRoute(path: '/auth', builder: (_, __) => const AuthScreen()),
        GoRoute(
          path: '/help',
          builder: (_, __) => const Scaffold(body: Text('help-route')),
        ),
        GoRoute(
          path: '/help/customer-service',
          builder: (_, __) => const Scaffold(body: Text('customer-route')),
        ),
        GoRoute(
          path: '/legal/user-agreement',
          builder: (_, __) =>
              const Scaffold(body: Text('user-agreement-route')),
        ),
        GoRoute(
          path: '/legal/privacy-policy',
          builder: (_, __) =>
              const Scaffold(body: Text('privacy-policy-route')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          authControllerProvider.overrideWith((ref) => authController),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('auth-help-center')));
    await tester.tap(find.byKey(const ValueKey('auth-help-center')));
    await tester.pumpAndSettle();
    expect(find.text('help-route'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('auth-customer-service')),
    );
    await tester.tap(find.byKey(const ValueKey('auth-customer-service')));
    await tester.pumpAndSettle();
    expect(find.text('customer-route'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('auth-user-agreement-link')),
    );
    await tester.tap(find.byKey(const ValueKey('auth-user-agreement-link')));
    await tester.pumpAndSettle();
    expect(find.text('user-agreement-route'), findsOneWidget);
    expect(authController.state.agreementAccepted, isFalse);
    router.pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('auth-privacy-policy-link')),
    );
    await tester.tap(find.byKey(const ValueKey('auth-privacy-policy-link')));
    await tester.pumpAndSettle();
    expect(find.text('privacy-policy-route'), findsOneWidget);
    expect(authController.state.agreementAccepted, isFalse);
    expect(authApi.loginRequests, isEmpty);
    expect(sessionStore.state.authState, SessionAuthState.anonymous);
  });

  testWidgets('bundled reviewed legal documents render before login', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LegalDocumentPage(kind: LegalDocumentKind.privacyPolicy),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无限花火隐私政策'), findsWidgets);
    expect(find.textContaining('2026年08月20日'), findsWidgets);
    expect(find.textContaining('杭州触达科技有限公司'), findsWidgets);
    expect(find.textContaining('hhapp@chuda.cc'), findsWidgets);

    await tester.pumpWidget(
      const MaterialApp(
        home: LegalDocumentPage(kind: LegalDocumentKind.userAgreement),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无限花火用户服务协议'), findsWidgets);
    expect(find.textContaining('2026年08月20日'), findsWidgets);
    expect(find.textContaining('杭州触达科技有限公司'), findsWidgets);
    expect(find.textContaining('hhapp@chuda.cc'), findsWidgets);
  });

  testWidgets('unauthorized session renders safe login copy', (tester) async {
    await _pumpAuthScreen(tester, errorCode: 'UNAUTHORIZED');

    expect(find.text('登录状态已失效，请重新登录。'), findsWidgets);
    expect(find.text('手机号'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
  });

  testWidgets('secure token cleanup failure renders safe copy', (tester) async {
    await _pumpAuthScreen(tester, errorCode: 'SECURE_TOKEN_CLEAR_FAILED');

    expect(find.text('登录凭证清理失败，请重试或重新登录。'), findsOneWidget);
    expect(find.text('手机号'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
  });

  testWidgets('workspace recovery failure renders explicit guidance', (
    tester,
  ) async {
    await _pumpAuthScreen(tester, errorCode: 'WORKSPACE_NOT_READY');

    expect(find.text('个人空间正在恢复，请稍后刷新后重试。'), findsOneWidget);
  });

  testWidgets('startup splash presents the static Infinite Spark brand', (
    tester,
  ) async {
    final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final bootstrap = AppBootstrapController(
      secureTokenStore: tokenStore,
      sessionStore: sessionStore,
      authApi: _FakeAuthApi(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapControllerProvider.overrideWith((ref) => bootstrap),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const SplashScreen(),
        ),
      ),
    );

    final mark = tester.widget<Image>(
      find.byKey(const ValueKey<String>('splash-brand-mark')),
    );
    expect(
      (mark.image as AssetImage).assetName,
      V3LaunchBrandLockup.androidAssetPath,
    );
    expect(mark.width, V3LaunchBrandLockup.markDimension);
    expect(mark.height, V3LaunchBrandLockup.lockupHeight);
    expect(
      find.byKey(const ValueKey<String>('splash-brand-tagline')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('splash-brand-wordmark')),
      findsNothing,
    );
    expect(find.text('无限花火'), findsNothing);
    expect(find.text('你的个人AI助手'), findsNothing);
    expect(find.text('正在初始化'), findsNothing);
    expect(find.text('正在准备无限花火'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('restore failure can reset to phone login', (tester) async {
    final driver = _StoredSecureTokenDriver();
    final tokenStore = SecureTokenStore(driver: driver);
    final stored = await tokenStore.setTokens(
      const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
    expect(stored.ok, isTrue);
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final bootstrapController = AppBootstrapController(
      secureTokenStore: tokenStore,
      sessionStore: sessionStore,
      authApi: _FakeAuthApi(),
    )..markRestoreFailed('SESSION_RESTORE_FAILED');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapControllerProvider.overrideWith(
            (ref) => bootstrapController,
          ),
        ],
        child: const MaterialApp(home: RestoreFailedScreen()),
      ),
    );

    expect(find.text('会话恢复失败：SESSION_RESTORE_FAILED'), findsOneWidget);
    await tester.tap(find.text('使用手机号登录'));
    await tester.pumpAndSettle();

    expect(bootstrapController.state.status, AppBootstrapStatus.ready);
    expect(sessionStore.state.authState, SessionAuthState.anonymous);
    expect(driver.credential, isNull);
  });

  testWidgets('restore failure phone login escapes unreadable secure storage', (
    tester,
  ) async {
    final driver = _StoredSecureTokenDriver(clearSucceeds: false);
    final tokenStore = SecureTokenStore(driver: driver);
    final stored = await tokenStore.setTokens(
      const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    );
    expect(stored.ok, isTrue);
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final bootstrapController = AppBootstrapController(
      secureTokenStore: tokenStore,
      sessionStore: sessionStore,
      authApi: _FakeAuthApi(),
    )..markRestoreFailed('SECURE_TOKEN_READ_FAILED');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapControllerProvider.overrideWith(
            (ref) => bootstrapController,
          ),
        ],
        child: const MaterialApp(home: RestoreFailedScreen()),
      ),
    );

    expect(find.widgetWithText(FilledButton, '使用手机号登录'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试读取凭据'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '使用手机号登录'));
    await tester.pumpAndSettle();

    expect(bootstrapController.state.status, AppBootstrapStatus.ready);
    expect(sessionStore.state.authState, SessionAuthState.anonymous);
    expect(driver.credential, isNotNull);
  });

  testWidgets('SMS in progress renders safe copy', (tester) async {
    final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final smsCompleter = Completer<AuthApiResult<SendSmsCodeResponse>>();
    final authController = AuthController(
      authApi: _FakeAuthApi(smsCompleter: smsCompleter),
      sessionStore: sessionStore,
      deviceId: 'device-1',
      clientVersion: '0.1.0',
    )..setPhone('13812348000');
    final pendingSms = authController.sendSmsCode();
    await authController.sendSmsCode();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          authControllerProvider.overrideWith((ref) => authController),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );

    expect(find.text('验证码请求中，请稍候。'), findsOneWidget);

    smsCompleter.complete(
      AuthApiResult<SendSmsCodeResponse>.success(
        value: const SendSmsCodeResponse(
          smsRequestId: 'sms-1',
          cooldownSeconds: 75,
        ),
        status: 200,
      ),
    );
    await pendingSms;
  });

  testWidgets('unconfigured API origin renders explicit login copy', (
    tester,
  ) async {
    await _pumpSmsFailure(tester, 'API_BASE_URL_UNCONFIGURED');

    expect(find.text('登录服务未配置，请联系开发人员。'), findsOneWidget);
  });

  testWidgets('unconfigured SMS provider renders explicit server copy', (
    tester,
  ) async {
    await _pumpSmsFailure(tester, 'SMS_PROVIDER_NOT_CONFIGURED');

    expect(find.text('短信服务暂未配置，请联系运营。'), findsOneWidget);
  });

  testWidgets('SMS provider rejection renders operations guidance', (
    tester,
  ) async {
    await _pumpSmsFailure(tester, 'SMS_PROVIDER_REJECTED');

    expect(find.text('短信服务拒绝了本次请求，请联系运营检查签名、模板和账号资质。'), findsOneWidget);
  });

  testWidgets('server-rejected six-digit code is not shown as missing input', (
    tester,
  ) async {
    final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final authApi = _FakeAuthApi(loginFailureCode: 'SMS_CODE_INVALID');
    final authController = AuthController(
      authApi: authApi,
      sessionStore: sessionStore,
      deviceId: 'device-1',
      clientVersion: '0.1.0',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          authControllerProvider.overrideWith((ref) => authController),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );
    await tester.enterText(find.byType(TextField).at(0), '18800000010');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.byKey(const ValueKey('auth-agreement')));
    await tester.tap(find.text('登录 / 注册'));
    await tester.pumpAndSettle();

    expect(authApi.loginRequests.single.code, '123456');
    expect(find.text('验证码不正确或已失效，请重新获取后再试。'), findsOneWidget);
    expect(find.text('请输入 6 位验证码。'), findsNothing);
  });

  testWidgets('default V3 login dispatches real auth flow', (tester) async {
    final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final authApi = _FakeAuthApi(loginSucceeds: true);
    final authController = AuthController(
      authApi: authApi,
      sessionStore: sessionStore,
      deviceId: 'device-1',
      clientVersion: '0.1.0',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          authControllerProvider.overrideWith((ref) => authController),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), '13812348000');
    await tester.pump();
    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), '112233');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('auth-agreement')));
    await tester.pump();
    await tester.ensureVisible(find.text('登录 / 注册'));
    await tester.tap(find.text('登录 / 注册'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(authApi.loginRequests, hasLength(1));
    expect(authApi.loginRequests.single.phone, '13812348000');
    expect(authApi.loginRequests.single.code, '112233');
    expect(sessionStore.state.authState, SessionAuthState.authenticated);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('login committing renders safe wait copy and disables inputs', (
    tester,
  ) async {
    final tokenWrite = Completer<bool>();
    final tokenStore = SecureTokenStore(
      driver: _FakeSecureTokenDriver(writeCompleter: tokenWrite),
    );
    final sessionStore = SessionStore(secureTokenStore: tokenStore);
    final authController = AuthController(
      authApi: _FakeAuthApi(loginSucceeds: true),
      sessionStore: sessionStore,
      deviceId: 'device-1',
      clientVersion: '0.1.0',
    );

    authController.setPhone('13812348000');
    await authController.sendSmsCode();
    authController.setCode('112233');
    authController.setAgreementAccepted(true);
    final pendingLogin = authController.login();
    await tester.pump();
    authController.setCode('445566');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          authControllerProvider.overrideWith((ref) => authController),
        ],
        child: const MaterialApp(home: AuthScreen()),
      ),
    );

    expect(find.text('正在登录，请稍候。'), findsOneWidget);
    final textFields = tester.widgetList<TextField>(find.byType(TextField));
    expect(textFields.every((field) => field.enabled == false), isTrue);
    await tester.tap(find.byKey(const ValueKey('auth-agreement')));
    expect(authController.state.agreementAccepted, isTrue);

    tokenWrite.complete(true);
    await tester.pump();
    await pendingLogin;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pumpAuthScreen(
  WidgetTester tester, {
  required String errorCode,
  ThemeData? theme,
  EdgeInsets mediaPadding = EdgeInsets.zero,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
  final sessionStore = SessionStore(
    secureTokenStore: tokenStore,
    initialState: errorCode.isEmpty
        ? SessionState.anonymous()
        : SessionState.anonymous().copyWith(
            authState: SessionAuthState.expired,
            lastAuthErrorCode: errorCode,
          ),
  );
  final authController = AuthController(
    authApi: _FakeAuthApi(),
    sessionStore: sessionStore,
    deviceId: 'device-1',
    clientVersion: '0.1.0',
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWith((ref) => sessionStore),
        authControllerProvider.overrideWith((ref) => authController),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(402, 874),
            padding: mediaPadding,
            viewPadding: mediaPadding,
            textScaler: textScaler,
          ),
          child: const AuthScreen(),
        ),
      ),
    ),
  );
}

Future<void> _pumpSmsFailure(WidgetTester tester, String errorCode) async {
  final tokenStore = SecureTokenStore(driver: _FakeSecureTokenDriver());
  final sessionStore = SessionStore(secureTokenStore: tokenStore);
  final authController = AuthController(
    authApi: _FakeAuthApi(smsFailureCode: errorCode),
    sessionStore: sessionStore,
    deviceId: 'device-1',
    clientVersion: '0.1.0',
  )..setPhone('13812348000');
  await authController.sendSmsCode();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWith((ref) => sessionStore),
        authControllerProvider.overrideWith((ref) => authController),
      ],
      child: const MaterialApp(home: AuthScreen()),
    ),
  );
}

final class _FakeAuthApi implements AuthApiPort {
  _FakeAuthApi({
    this.smsCompleter,
    this.loginSucceeds = false,
    this.smsFailureCode,
    this.loginFailureCode,
    this.workspaceStatus = SessionWorkspaceStatus.ready,
  });

  final Completer<AuthApiResult<SendSmsCodeResponse>>? smsCompleter;
  final bool loginSucceeds;
  final String? smsFailureCode;
  final String? loginFailureCode;
  final SessionWorkspaceStatus workspaceStatus;
  final sentSmsRequests = <String>[];
  final loginRequests = <SmsLoginRequest>[];
  int statusCalls = 0;

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    sentSmsRequests.add(phone);
    final pending = smsCompleter;
    if (pending != null) {
      return await pending.future;
    }
    final failureCode = smsFailureCode;
    if (failureCode != null) {
      return AuthApiResult<SendSmsCodeResponse>.failure(
        error: AppFailure(
          code: failureCode,
          category: AppFailureCategory.api,
          message: 'configuration unavailable',
          userMessageKey: 'auth.configurationUnavailable',
        ),
      );
    }
    return AuthApiResult<SendSmsCodeResponse>.success(
      value: const SendSmsCodeResponse(
        smsRequestId: 'sms-1',
        cooldownSeconds: 75,
      ),
      status: 200,
    );
  }

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    loginRequests.add(request);
    if (loginSucceeds) {
      return AuthApiResult<SmsLoginResponse>.success(
        value: const SmsLoginResponse(
          tokens: AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
          user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
          workspaceStatus: SessionWorkspaceStatus.ready,
        ),
        status: 200,
      );
    }
    final failureCode = loginFailureCode;
    if (failureCode != null) {
      return AuthApiResult<SmsLoginResponse>.failure(
        error: AppFailure(
          code: failureCode,
          category: AppFailureCategory.auth,
          message: 'login rejected',
          userMessageKey: 'auth.loginRejected',
        ),
      );
    }
    return AuthApiResult<SmsLoginResponse>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    return AuthApiResult<RefreshTokenResponse>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) async {
    statusCalls += 1;
    if (loginSucceeds && accessToken == 'access') {
      return AuthApiResult<SessionUserStatus>.success(
        value: SessionUserStatus(
          user: const SessionUser(
            userId: 'user-1',
            maskedPhoneNumber: '138****8000',
          ),
          workspace: SessionWorkspace(
            status: workspaceStatus,
            workspaceId: 'workspace-1',
          ),
        ),
        status: 200,
      );
    }
    return AuthApiResult<SessionUserStatus>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({this.writeCompleter});

  final Completer<bool>? writeCompleter;
  var writeCalls = 0;

  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  FutureOr<bool> write({
    required String service,
    required String username,
    required String password,
  }) {
    writeCalls += 1;
    final pending = writeCompleter;
    if (pending != null) {
      return pending.future;
    }
    return true;
  }

  @override
  bool clear({required String service}) => true;
}

final class _StoredSecureTokenDriver implements SecureTokenDriver {
  _StoredSecureTokenDriver({this.clearSucceeds = true});

  SecureTokenCredential? credential;
  final bool clearSucceeds;

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

  @override
  bool clear({required String service}) {
    if (clearSucceeds) credential = null;
    return clearSucceeds;
  }
}
