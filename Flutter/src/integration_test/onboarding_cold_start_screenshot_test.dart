import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/presentation/content_line_onboarding_page.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_notifications_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:integration_test/integration_test.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the resumable cold-start card on iOS', (tester) async {
    final session = await _onboardingSession();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sessionStoreProvider.overrideWith((ref) => session),
          onboardingApiProvider.overrideWithValue(
            const _NoSubmitOnboardingApi(),
          ),
          appDatabaseProvider.overrideWithValue(AppDatabase()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.light(),
          home: const ContentLineOnboardingPage(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('先选一下你的当前状态'), findsOneWidget);
    expect(find.text('有业务'), findsOneWidget);
    expect(find.text('没业务'), findsOneWidget);
    await _capture(binding, tester, 'onboarding_01_mode_choice');

    await tester.tap(find.byKey(const ValueKey('onboarding-mode-business')));
    await _settle(tester);
    final primary = tester.widget<V3PrimaryButton>(
      find.byKey(const ValueKey('onboarding-primary')),
    );
    expect(primary.enabled, isFalse);
    await tester.tap(
      find.byKey(const ValueKey('onboarding-option-customerScope-本地客户')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
    await _settle(tester);
    expect(find.text('简单描述一下你的产品或服务'), findsOneWidget);
    await _capture(binding, tester, 'onboarding_02_business_question');

    await tester.tap(find.byKey(const ValueKey('onboarding-defer')));
    await tester.pumpAndSettle();
    expect(find.text('稍后再填写？'), findsOneWidget);
    expect(find.textContaining('消息提醒'), findsOneWidget);
    await _capture(binding, tester, 'onboarding_03_defer_dialog');

    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('稍后填写')),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ContentLineOnboardingPage)),
    );
    expect(
      container
          .read(onboardingContinuationControllerProvider)
          .isDeferredFor('screenshot-user'),
      isTrue,
    );
    expect(session.state.onboardingRequired, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    const reminder = PendingMessage(
      id: 'local:onboarding:screenshot',
      source: PendingMessageSource.onboarding,
      scene: 'onboarding',
      title: '完善初步了解',
      body: '继续填写你的业务现状和内容方向，完成后这条提醒会自动消失。',
      state: PendingMessageState.actionRequired,
      isUnread: true,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      route: '/onboarding',
      canMarkHandled: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          notificationControllerProvider.overrideWith(
            (ref) => NotificationController(api: const _EmptyNotificationApi()),
          ),
          pendingMessageProjectionProvider.overrideWithValue(
            const PendingMessageProjection(
              items: <PendingMessage>[reminder],
              isLoading: false,
              resolutionIsDemo: false,
            ),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.light(),
          home: const ColoredBox(
            color: Colors.white,
            child: V3NotificationsPage(),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('完善初步了解'), findsOneWidget);
    expect(find.text('继续填写'), findsOneWidget);
    expect(find.text('处理完成'), findsNothing);
    await _capture(binding, tester, 'onboarding_04_notification_reminder');
  });
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await _settle(tester);
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty, reason: name);
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<SessionStore> _onboardingSession() async {
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _ScreenshotTokenDriver()),
  );
  await session.applyLoginSuccess(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    snapshot: SafeAuthSessionSnapshot(
      user: const SessionUser(
        userId: 'screenshot-user',
        maskedPhoneNumber: '138****8000',
      ),
      expiresAt: DateTime.utc(2027, 1, 1),
      workspaceStatus: SessionWorkspaceStatus.ready,
      onboardingRequired: true,
    ),
    updatedAt: DateTime.utc(2026, 8, 1),
  );
  return session;
}

final class _NoSubmitOnboardingApi implements OnboardingApiPort {
  const _NoSubmitOnboardingApi();

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    throw StateError('Screenshot flow must not submit onboarding');
  }
}

final class _EmptyNotificationApi implements NotificationApiPort {
  const _EmptyNotificationApi();

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
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
  }) {
    throw StateError('Screenshot reminder is local');
  }
}

final class _ScreenshotTokenDriver implements SecureTokenDriver {
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
