import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/notifications/application/push_registration_controller.dart';
import 'package:huahuoai_app/features/notifications/data/push_device_api.dart';
import 'package:huahuoai_app/features/notifications/domain/push_registration.dart';
import 'package:huahuoai_app/features/notifications/infrastructure/push_provider.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_profile_side_panel.dart';

void main() {
  testWidgets(
    'profile side panel projects the session and performs real logout',
    (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reduceMotion = ValueNotifier<bool>(false);
      addTearDown(reduceMotion.dispose);
      final driver = _FakeSecureTokenDriver(
        credential: const SecureTokenCredential(
          username: 'access-token',
          password: 'refresh-token', // secret-scan: allow
        ),
      );
      final sessionStore =
          SessionStore(
            secureTokenStore: SecureTokenStore(driver: driver),
          )..refreshUserStatus(
            status: const SessionUserStatus(
              user: SessionUser(
                userId: 'user-1',
                maskedPhoneNumber: '138****8000',
              ),
              workspace: SessionWorkspace(status: SessionWorkspaceStatus.ready),
            ),
            updatedAt: DateTime.utc(2026, 7, 10),
          );

      final api = _LogoutApi();
      final registration = PushRegistrationController(
        provider: _LogoutProvider(),
        api: api,
        sessionStore: sessionStore,
        deviceId: 'device-1',
        platform: 'ios',
        appVersion: () async => '1',
        unregisterTimeout: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            sessionStoreProvider.overrideWith((ref) => sessionStore),
            pushRegistrationControllerProvider.overrideWith(
              (ref) => registration,
            ),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/home',
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (context, state) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => showV3ProfileSidePanel(context),
                        child: const Text('open-profile'),
                      ),
                    ),
                  ),
                ),
                GoRoute(
                  path: '/auth',
                  builder: (context, state) => const Text('auth-screen'),
                ),
              ],
            ),
            builder: (context, child) => ValueListenableBuilder<bool>(
              valueListenable: reduceMotion,
              builder: (context, disableAnimations, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: disableAnimations,
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: child!,
              ),
            ),
          ),
        ),
      );

      expect(sessionStore.state.authState, SessionAuthState.authenticated);
      expect(driver.credential, isNotNull);

      await tester.tap(find.text('open-profile'));
      await tester.pump();
      final profilePanel = find.byKey(
        const ValueKey<String>('v3-profile-side-panel'),
      );
      expect(profilePanel, findsOneWidget);
      final profileRoute = ModalRoute.of(tester.element(profilePanel))!;
      expect(
        profileRoute.transitionDuration,
        const Duration(milliseconds: 170),
      );
      expect(
        profileRoute.reverseTransitionDuration,
        const Duration(milliseconds: 170),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(profilePanel).left, 0);
      final profileHeader = find.byKey(
        const ValueKey('profile-header-account-entry'),
      );
      final closeButton = find.byKey(
        const ValueKey<String>('profile-panel-close'),
      );
      expect(
        tester.getRect(profileHeader).right,
        lessThanOrEqualTo(tester.getRect(closeButton).left),
      );
      expect(tester.takeException(), isNull);

      await tester.fling(profilePanel, const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(profilePanel, findsNothing);

      reduceMotion.value = true;
      await tester.pump();
      await tester.tap(find.text('open-profile'));
      await tester.pump();
      final reducedProfileRoute = ModalRoute.of(tester.element(profilePanel))!;
      expect(reducedProfileRoute.transitionDuration, Duration.zero);
      expect(reducedProfileRoute.reverseTransitionDuration, Duration.zero);
      await tester.pumpAndSettle();
      expect(find.text('138****8000'), findsOneWidget);
      expect(find.textContaining('当前等级 Lv.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('我的资产'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('我的资产'), findsOneWidget);
      expect(find.text('声纹管理'), findsNothing);
      expect(find.text('声纹识别'), findsNothing);
      expect(find.text('花火 Spark'), findsNothing);
      expect(find.text('花火商学院'), findsOneWidget);
      expect(find.text('日报'), findsNothing);
      expect(find.text('本地录音库'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('退出登录'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('退出登录'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -80));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('确认退出登录？'), findsOneWidget);

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(sessionStore.state.authState, SessionAuthState.authenticated);
      expect(driver.credential, isNotNull);
      expect(find.textContaining('登录状态已保留'), findsOneWidget);
      api.gate.complete();
      await tester.pump();
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(sessionStore.state.authState, SessionAuthState.anonymous);
      expect(driver.credential, isNull);
      expect(find.text('auth-screen'), findsOneWidget);
      expect(find.text('已退出（mock）'), findsNothing);
    },
  );
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({this.credential});

  SecureTokenCredential? credential;

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
    credential = null;
    return true;
  }
}

final class _LogoutProvider implements PushProvider {
  @override
  bool get isConfigured => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _LogoutApi implements PushDeviceApiPort {
  final gate = Completer<void>();

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    await gate.future;
    return ApiResult<PushDeviceMutationReceipt>.success(
      data: PushDeviceMutationReceipt(
        deviceId: deviceId,
        status: 'revoked',
        updatedAt: '2026-09-05T00:00:00Z',
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
