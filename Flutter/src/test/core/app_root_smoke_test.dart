import 'dart:async';
import 'dart:io';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:huahuoai_app/app/di/native_port_providers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/billing_providers.dart';
import 'package:huahuoai_app/app/bootstrap/app_root.dart';
import 'package:huahuoai_app/app/bootstrap/app_visual_root.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/native/incoming_material_port.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';
import 'package:huahuoai_app/features/billing/application/billing_controller.dart';
import 'package:huahuoai_app/features/billing/data/android_payment_port.dart';
import 'package:huahuoai_app/features/billing/data/billing_api.dart';
import 'package:huahuoai_app/features/billing/data/billing_pending_order_store.dart';
import 'package:huahuoai_app/features/billing/data/ios_store_purchase_port.dart';
import 'package:huahuoai_app/features/notifications/application/push_navigation_controller.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/settings/domain/app_appearance_preset.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

void main() {
  test('iOS Flutter root participates in state restoration', () {
    final storyboard = File(
      'ios/Runner/Base.lproj/Main.storyboard',
    ).readAsStringSync();
    final flutterControllerTag = RegExp(
      r'<viewController[^>]*customClass="FlutterViewController"[^>]*>',
    ).firstMatch(storyboard)?.group(0);

    expect(flutterControllerTag, isNotNull);
    expect(
      flutterControllerTag,
      contains('restorationIdentifier="huahuo-flutter-root"'),
    );
  });

  test('app text scale stays inside the supported mobile range', () {
    expect(resolveAppTextScale(platformTextScale: 1, preferredTextScale: 1), 1);
    expect(
      resolveAppTextScale(platformTextScale: 1.3, preferredTextScale: 1.3),
      1.3,
    );
    expect(
      resolveAppTextScale(platformTextScale: 2, preferredTextScale: 1),
      1.3,
    );
    expect(
      resolveAppTextScale(platformTextScale: .7, preferredTextScale: .8),
      .8,
    );
  });

  testWidgets('AppRoot renders the configured router tree', (tester) async {
    final router = GoRouter(
      restorationScopeId: appRouterRestorationScopeId,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('app-root-smoke')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRouterProvider.overrideWith((ref) => router)],
        child: const AppRoot(),
      ),
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, '无限花火');
    expect(app.restorationScopeId, 'huahuo-app');
    expect(app.locale, const Locale('zh', 'CN'));
    expect(app.supportedLocales, const <Locale>[Locale('zh', 'CN')]);
    final materialLocalizations = MaterialLocalizations.of(
      tester.element(find.text('app-root-smoke')),
    );
    expect(materialLocalizations.copyButtonLabel, '复制');
    expect(materialLocalizations.pasteButtonLabel, '粘贴');
    expect(materialLocalizations.selectAllButtonLabel, '全选');
    expect(find.byType(ForegroundIngressScope), findsOneWidget);
    expect(find.byType(V3KeyboardDismissOnUpwardScroll), findsOneWidget);
    expect(find.text('app-root-smoke'), findsOneWidget);
    expect(
      tester.widget<Navigator>(find.byType(Navigator)).restorationScopeId,
      appRouterRestorationScopeId,
    );
  });

  testWidgets('AppRoot restores the active asset route after recreation', (
    tester,
  ) async {
    final refresh = ChangeNotifier();
    final router = GoRouter(
      restorationScopeId: appRouterRestorationScopeId,
      refreshListenable: refresh,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('route-home'))),
        ),
        GoRoute(
          path: '/v3/feed/assets/:assetId',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text('asset-${state.pathParameters['assetId']}'),
            ),
          ),
        ),
      ],
    );
    addTearDown(refresh.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRouterProvider.overrideWith((ref) => router)],
        child: const AppRoot(),
      ),
    );
    router.push<void>('/v3/feed/assets/asset-42');
    await tester.pumpAndSettle();
    expect(find.text('asset-asset-42'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('asset-asset-42'), findsOneWidget);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.text('asset-asset-42'), findsOneWidget);
    refresh.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('asset-asset-42'), findsOneWidget);
    expect(
      ModalRoute.of(
        tester.element(find.text('asset-asset-42')),
      )?.settings.arguments,
      containsPair('assetId', 'asset-42'),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('route-home'), findsOneWidget);
  });

  testWidgets('AppRoot uses platform page transitions for pushed routes', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('route-one'))),
        ),
        GoRoute(
          path: '/route-two',
          builder: (context, state) => const Material(
            type: MaterialType.transparency,
            child: Center(child: Text('route-two')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRouterProvider.overrideWith((ref) => router)],
        child: const AppRoot(),
      ),
    );
    await tester.pumpAndSettle();

    final transitions = Theme.of(
      tester.element(find.text('route-one')),
    ).pageTransitionsTheme.builders;
    expect(
      transitions[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      transitions[TargetPlatform.android],
      isA<FadeUpwardsPageTransitionsBuilder>(),
    );

    router.push<void>('/route-two');
    await tester.pumpAndSettle();

    expect(find.text('route-two'), findsOneWidget);
    expect(find.text('route-one').hitTestable(), findsNothing);
  });

  testWidgets('AppRoot applies only default light and dark appearances', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            key: ValueKey('appearance-route'),
            body: Text('appearance-route'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    final controller = AppAppearanceController()..restore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWith((ref) => router),
          appAppearanceControllerProvider.overrideWith((ref) => controller),
        ],
        child: const AppRoot(),
      ),
    );

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    BuildContext routeContext() =>
        tester.element(find.text('appearance-route'));

    expect(app().themeMode, ThemeMode.light);
    expect(Theme.of(routeContext()).brightness, Brightness.light);
    expect(
      Theme.of(routeContext()).extension<HuahuoV3ThemeTokens>()?.canvas,
      HuahuoV3Theme.lightTokens.canvas,
    );

    controller.selectPreset(AppAppearancePreset.dark);
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.dark);
    expect(Theme.of(routeContext()).brightness, Brightness.dark);
    expect(
      Theme.of(routeContext()).extension<HuahuoV3ThemeTokens>()?.canvas,
      HuahuoV3Theme.darkTokens.canvas,
    );
    expect(find.byKey(const ValueKey('appearance-route')), findsOneWidget);

    controller.selectPreset(AppAppearancePreset.mistBlue);
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.light);
    expect(Theme.of(routeContext()).brightness, Brightness.light);
    expect(
      Theme.of(routeContext()).extension<HuahuoV3ThemeTokens>()?.canvas,
      HuahuoV3Theme.lightTokens.canvas,
    );
    expect(find.byKey(const ValueKey('appearance-route')), findsOneWidget);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.light);
    expect(Theme.of(routeContext()).brightness, Brightness.light);
    expect(find.byKey(const ValueKey('appearance-route')), findsOneWidget);
  });

  testWidgets(
    'a newer foreground command survives a busy confirmation and Back restores its source',
    (tester) async {
      final fixture = await _readyRootFixture();
      final firstDecision = Completer<ForegroundIngressDecision>();
      var decisionCalls = 0;
      final pushNavigation = PushNavigationController();
      final router = GoRouter(
        observers: <NavigatorObserver>[foregroundIngressRouteObserver],
        initialLocation: '/source',
        routes: <RouteBase>[
          GoRoute(
            path: '/source',
            builder: (_, __) => _ForegroundIngressSource(
              onRequest: () {
                decisionCalls += 1;
                return decisionCalls == 1
                    ? firstDecision.future
                    : ForegroundIngressDecision.allow;
              },
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('目标 ${state.pathParameters['itemId']}')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appRouterProvider.overrideWith((ref) => router),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            pushNavigationControllerProvider.overrideWith(
              (ref) => pushNavigation,
            ),
            billingControllerProvider.overrideWith((ref) => fixture.billing),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => fixture.recordingAutoSync,
            ),
            incomingMaterialPortProvider.overrideWithValue(
              const _NoopIncomingMaterialPort(),
            ),
          ],
          child: const AppRoot(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('前台入口来源页'), findsOneWidget);

      pushNavigation.openForeground(_foregroundPush('a'));
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      pushNavigation.openForeground(_foregroundPush('b'));
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      firstDecision.complete(ForegroundIngressDecision.cancel);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(decisionCalls, 2);
      expect(find.text('目标 b'), findsOneWidget);
      expect(pushNavigation.pendingCommand, isNull);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('前台入口来源页'), findsOneWidget);
    },
  );

  testWidgets(
    'a foreground external share survives a busy Push confirmation and Back restores its source',
    (tester) async {
      final fixture = await _readyRootFixture();
      final firstDecision = Completer<ForegroundIngressDecision>();
      var decisionCalls = 0;
      final pushNavigation = PushNavigationController();
      final incomingMaterialPort = _TestIncomingMaterialPort();
      addTearDown(incomingMaterialPort.dispose);
      final router = GoRouter(
        observers: <NavigatorObserver>[foregroundIngressRouteObserver],
        initialLocation: '/source',
        routes: <RouteBase>[
          GoRoute(
            path: '/source',
            builder: (_, __) => _ForegroundIngressSource(
              onRequest: () {
                decisionCalls += 1;
                return decisionCalls == 1
                    ? firstDecision.future
                    : ForegroundIngressDecision.allow;
              },
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('目标 ${state.pathParameters['itemId']}')),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.documentImport,
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('外部分享导入页'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appRouterProvider.overrideWith((ref) => router),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            pushNavigationControllerProvider.overrideWith(
              (ref) => pushNavigation,
            ),
            billingControllerProvider.overrideWith((ref) => fixture.billing),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => fixture.recordingAutoSync,
            ),
            incomingMaterialPortProvider.overrideWithValue(
              incomingMaterialPort,
            ),
          ],
          child: const AppRoot(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('前台入口来源页'), findsOneWidget);

      pushNavigation.openForeground(_foregroundPush('a'));
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      incomingMaterialPort.signal();
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      firstDecision.complete(ForegroundIngressDecision.cancel);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(decisionCalls, 2);
      expect(find.text('外部分享导入页'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('前台入口来源页'), findsOneWidget);
    },
  );

  testWidgets(
    'an allowed Push commits before a busy foreground external share retries',
    (tester) async {
      final fixture = await _readyRootFixture();
      final firstDecision = Completer<ForegroundIngressDecision>();
      var decisionCalls = 0;
      final pushNavigation = PushNavigationController();
      final incomingMaterialPort = _TestIncomingMaterialPort();
      addTearDown(incomingMaterialPort.dispose);
      final router = GoRouter(
        observers: <NavigatorObserver>[foregroundIngressRouteObserver],
        initialLocation: '/source',
        routes: <RouteBase>[
          GoRoute(
            path: '/source',
            builder: (_, __) => _ForegroundIngressSource(
              onRequest: () {
                decisionCalls += 1;
                return decisionCalls == 1
                    ? firstDecision.future
                    : ForegroundIngressDecision.cancel;
              },
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('目标 ${state.pathParameters['itemId']}')),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.documentImport,
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('外部分享导入页'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appRouterProvider.overrideWith((ref) => router),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            pushNavigationControllerProvider.overrideWith(
              (ref) => pushNavigation,
            ),
            billingControllerProvider.overrideWith((ref) => fixture.billing),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => fixture.recordingAutoSync,
            ),
            incomingMaterialPortProvider.overrideWithValue(
              incomingMaterialPort,
            ),
          ],
          child: const AppRoot(),
        ),
      );
      await tester.pumpAndSettle();

      pushNavigation.openForeground(_foregroundPush('a'));
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      incomingMaterialPort.signal();
      await tester.pump();
      await tester.pump();
      expect(decisionCalls, 1);

      firstDecision.complete(ForegroundIngressDecision.allow);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(decisionCalls, 1);
      expect(pushNavigation.pendingCommand, isNull);
      expect(find.text('外部分享导入页'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('目标 a'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('前台入口来源页'), findsOneWidget);
    },
  );

  testWidgets(
    'a cancelled foreground external share is not retried without a new signal',
    (tester) async {
      final fixture = await _readyRootFixture();
      var decisionCalls = 0;
      final incomingMaterialPort = _TestIncomingMaterialPort();
      addTearDown(incomingMaterialPort.dispose);
      final router = GoRouter(
        observers: <NavigatorObserver>[foregroundIngressRouteObserver],
        initialLocation: '/source',
        routes: <RouteBase>[
          GoRoute(
            path: '/source',
            builder: (_, __) => _ForegroundIngressSource(
              onRequest: () {
                decisionCalls += 1;
                return ForegroundIngressDecision.cancel;
              },
            ),
          ),
          GoRoute(
            path: AppRoutePaths.documentImport,
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('外部分享导入页'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appRouterProvider.overrideWith((ref) => router),
            appBootstrapControllerProvider.overrideWith(
              (ref) => fixture.bootstrap,
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
            billingControllerProvider.overrideWith((ref) => fixture.billing),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => fixture.recordingAutoSync,
            ),
            incomingMaterialPortProvider.overrideWithValue(
              incomingMaterialPort,
            ),
          ],
          child: const AppRoot(),
        ),
      );
      await tester.pumpAndSettle();

      incomingMaterialPort.signal();
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(decisionCalls, 1);
      expect(find.text('前台入口来源页'), findsOneWidget);
      expect(find.text('外部分享导入页'), findsNothing);
    },
  );

  testWidgets('first interactive waits for a committed non-splash route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: AppRoutePaths.splash,
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutePaths.splash,
          builder: (_, __) => const Scaffold(body: Text('boot-splash')),
        ),
        GoRoute(
          path: '/ready',
          builder: (_, __) => const Scaffold(body: Text('interactive-ready')),
        ),
        GoRoute(
          path: '/next',
          builder: (_, __) => const Scaffold(body: Text('interactive-next')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRouterProvider.overrideWith((ref) => router)],
        child: const AppRoot(),
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.text('boot-splash')),
    );
    final runtime = container.read(appPerformanceRuntimeProvider);
    expect(runtime.capture().runtime['firstFrameMs'], isNotNull);
    expect(runtime.capture().runtime['firstInteractiveMs'], isNull);

    router.go('/ready');
    await tester.pumpAndSettle();
    final firstInteractive = runtime.capture().runtime['firstInteractiveMs'];
    expect(firstInteractive, isNotNull);

    await tester.pump(const Duration(milliseconds: 20));
    router.go('/next');
    await tester.pumpAndSettle();
    expect(runtime.capture().runtime['firstInteractiveMs'], firstInteractive);
  });
}

class _ForegroundIngressSource extends StatefulWidget {
  const _ForegroundIngressSource({required this.onRequest});

  final ForegroundIngressHandler onRequest;

  @override
  State<_ForegroundIngressSource> createState() =>
      _ForegroundIngressSourceState();
}

class _ForegroundIngressSourceState extends State<_ForegroundIngressSource> {
  VoidCallback? _unregister;
  ForegroundIngressCoordinator? _coordinator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coordinator = ForegroundIngressScope.maybeOf(context);
    if (identical(coordinator, _coordinator)) return;
    _unregister?.call();
    _coordinator = coordinator;
    _unregister = coordinator?.register(
      onRequest: widget.onRequest,
      isCurrent: () => ModalRoute.of(context)?.isCurrent ?? false,
    );
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('前台入口来源页')));
}

Future<_ReadyRootFixture> _readyRootFixture() async {
  const tokenStore = SecureTokenStore(driver: _NoopSecureTokenDriver());
  final session = SessionStore(secureTokenStore: tokenStore);
  final bootstrap = AppBootstrapController(
    secureTokenStore: tokenStore,
    sessionStore: session,
    authApi: AuthApi(
      apiClient: ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'test-device',
          platform: 'test',
          locale: 'zh-CN',
        ),
        transport: const _UnusedApiTransport(),
      ),
    ),
  );
  await bootstrap.restore();
  session.restoreFromUserStatus(
    status: const SessionUserStatus(
      user: SessionUser(userId: 'test-user', maskedPhoneNumber: '138****8000'),
      workspace: SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'test-workspace',
      ),
      onboardingRequired: false,
    ),
    restoredAt: DateTime.utc(2026, 8, 17),
  );
  final billing = BillingController(
    api: const UnavailableBillingApi(),
    androidPayment: const _NoopAndroidPayment(),
    iosStore: const _NoopIosStore(),
    pendingOrders: _MemoryBillingOrders(),
    platform: BillingPlatform.android,
    userScope: 'test-user',
  );
  final recordingAutoSync = RecordingCardAutoSyncCoordinator(
    persistence: _MemoryRecordingAutoSyncPersistence(),
    actions: _NoopRecordingAutoSyncActions(),
  );
  return _ReadyRootFixture(
    session: session,
    bootstrap: bootstrap,
    billing: billing,
    recordingAutoSync: recordingAutoSync,
  );
}

class _ReadyRootFixture {
  const _ReadyRootFixture({
    required this.session,
    required this.bootstrap,
    required this.billing,
    required this.recordingAutoSync,
  });

  final SessionStore session;
  final AppBootstrapController bootstrap;
  final BillingController billing;
  final RecordingCardAutoSyncCoordinator recordingAutoSync;
}

PushMessage _foregroundPush(String targetId) => PushMessage(
  notificationId: 'notice-$targetId',
  eventId: 'event-$targetId',
  eventType: 'note.updated',
  scene: 'feed',
  targetType: 'note',
  targetId: targetId,
  title: '前台通知',
  body: '查看更新',
  receiveType: PushReceiveType.foreground,
);

final class _NoopSecureTokenDriver implements SecureTokenDriver {
  const _NoopSecureTokenDriver();

  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) => true;

  @override
  bool clear({required String service}) => true;
}

final class _UnusedApiTransport implements ApiTransport {
  const _UnusedApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    throw StateError('unexpected API request');
  }
}

final class _TestIncomingMaterialPort implements IncomingMaterialPort {
  final StreamController<void> _signals = StreamController<void>.broadcast();

  @override
  Stream<void> get pendingMaterials => _signals.stream;

  void signal() => _signals.add(null);

  Future<void> dispose() => _signals.close();

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
