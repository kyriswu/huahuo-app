import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:jpush_flutter/jpush_interface.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/features/notifications/infrastructure/jpush_provider.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_navigation_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_registration_controller.dart';
import 'package:huahuoai_app/features/notifications/application/push_runtime_controller.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/notifications/data/push_device_api.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';
import 'package:huahuoai_app/features/notifications/domain/push_registration.dart';
import 'package:huahuoai_app/features/notifications/infrastructure/push_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native permission failure is unknown, never denial', () async {
    const channel = MethodChannel('push-permission-review');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final provider = JPushProvider(
      config: const PushRuntimeConfig(appKey: 'test-key-123'),
      permissions: const MethodChannelPlatformPermissionsPort(channel: channel),
      jpush: _InitialMessageSdk(),
    );
    addTearDown(provider.dispose);
    await expectLater(
      provider.isNotificationEnabled(),
      throwsA(isA<PushProviderFailure>()),
    );
    await expectLater(
      provider.requestPermission(),
      throwsA(isA<PushProviderFailure>()),
    );
  });

  test(
    'initial native read retries errors and shares the pending result',
    () async {
      final sdk = _InitialMessageSdk();
      final provider = JPushProvider(
        config: const PushRuntimeConfig(appKey: 'test-key-123'),
        permissions: const MethodChannelPlatformPermissionsPort(),
        jpush: sdk,
      );
      addTearDown(provider.dispose);
      await expectLater(
        provider.getInitialMessage(),
        throwsA(isA<PushProviderFailure>()),
      );
      sdk.fail = false;
      final pending = provider.getInitialMessage();
      await expectLater(
        pending.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      final retry = provider.getInitialMessage();
      expect(identical(pending, retry), isTrue);
      sdk.gate.complete(<dynamic, dynamic>{});
      expect(await retry, isNull);
      expect(await provider.getInitialMessage(), isNull);
      expect(sdk.calls, 2);
    },
  );

  test('runtime consumes cold entry only after a successful read', () async {
    final fixture = _runtimeFixture();
    addTearDown(fixture.dispose);
    fixture.provider.initialReadFails = true;
    fixture.session.restoreFromUserStatus(
      status: localNumericAuthUserStatus(),
      restoredAt: DateTime.utc(2026, 9, 5),
    );
    await fixture.runtime.start();
    expect(fixture.navigation.pendingCommand, isNull);
    fixture.provider.initialReadFails = false;
    fixture.provider.initialMessage = _validMessage(PushReceiveType.coldStart);
    await fixture.runtime.start();
    expect(fixture.navigation.pendingCommand, isNotNull);
    await fixture.runtime.start();
    expect(fixture.provider.initialReadCalls, 2);
  });

  test(
    'cold-start navigation remains available when registration has no token',
    () async {
      final fixture = _runtimeFixture();
      addTearDown(fixture.dispose);
      fixture.provider.registrationId = null;
      fixture.provider.initialMessage = _validMessage(
        PushReceiveType.coldStart,
      );
      fixture.session.restoreFromUserStatus(
        status: localNumericAuthUserStatus(),
        restoredAt: DateTime.utc(2026, 9, 5),
      );
      await fixture.runtime.start();
      expect(fixture.registration.state.status, PushRegistrationStatus.failed);
      expect(fixture.navigation.pendingCommand, isNotNull);
      fixture.provider.emitForeground(
        _validMessage(PushReceiveType.foreground),
      );
      await _flush();
      expect(fixture.runtime.state.foregroundMessage, isNotNull);
      fixture.session.restoreExpired(
        errorCode: 'AUTH_ACCESS_TOKEN_EXPIRED',
        restoredAt: DateTime.utc(2026, 9, 5),
      );
      expect(fixture.runtime.state.foregroundMessage, isNull);
      expect(fixture.navigation.pendingCommand, isNull);
    },
  );

  test(
    'anonymous and expired sessions cannot consume push callbacks',
    () async {
      final fixture = _runtimeFixture();
      addTearDown(fixture.dispose);

      await fixture.runtime.start();
      expect(fixture.provider.initializeCalls, 0);

      fixture.session.restoreFromUserStatus(
        status: localNumericAuthUserStatus(),
        restoredAt: DateTime.utc(2026, 8, 2),
      );
      await fixture.runtime.start();
      expect(fixture.provider.initializeCalls, 1);

      fixture.provider.emitForeground(
        _validMessage(PushReceiveType.foreground),
      );
      await _flush();
      expect(fixture.runtime.state.foregroundMessage, isNotNull);
      expect(fixture.notificationsApi.listCalls, 1);

      fixture.session.restoreExpired(
        errorCode: 'AUTH_ACCESS_TOKEN_EXPIRED',
        restoredAt: DateTime.utc(2026, 8, 2, 1),
      );
      fixture.registration.handleSessionEnded();
      fixture.runtime.clearForLogout();
      fixture.provider.emitForeground(
        _validMessage(PushReceiveType.foreground),
      );
      fixture.provider.emitOpened(_validMessage(PushReceiveType.opened));
      await _flush();

      expect(fixture.runtime.state.foregroundMessage, isNull);
      expect(fixture.navigation.pendingCommand, isNull);
      expect(fixture.notificationsApi.listCalls, 1);
    },
  );

  test('opened inbox push forces a remote notification refresh', () async {
    final fixture = _runtimeFixture();
    addTearDown(fixture.dispose);
    fixture.session.restoreFromUserStatus(
      status: localNumericAuthUserStatus(),
      restoredAt: DateTime.utc(2026, 9, 2),
    );
    await fixture.runtime.start();

    fixture.provider.emitOpened(
      const InboxPushMessage(
        notificationId: 'notice-inbox-opened-1',
        eventType: 'hotspot_suggestion',
        receiveType: PushReceiveType.opened,
      ),
    );
    await _flush();

    expect(fixture.notificationsApi.listCalls, 1);
    expect(fixture.navigation.pendingCommand?.location, '/v3/notifications');
    expect(
      fixture.navigation.pendingCommand?.notificationId,
      'notice-inbox-opened-1',
    );
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

ValidPushMessage _validMessage(PushReceiveType type) => ValidPushMessage(
  PushMessage(
    notificationId: 'notice-1',
    eventType: 'recording.completed',
    scene: 'recording',
    targetType: 'recording',
    targetId: 'recording-1',
    title: '转写完成',
    body: '录音已完成转写',
    receiveType: type,
  ),
);

_RuntimeFixture _runtimeFixture() {
  final session = SessionStore(
    secureTokenStore: const SecureTokenStore(driver: _TokenDriver()),
  );
  final provider = _RuntimePushProvider();
  final pushApi = _RuntimePushDeviceApi();
  final registration = PushRegistrationController(
    provider: provider,
    api: pushApi,
    sessionStore: session,
    deviceId: 'device-1',
    platform: 'ios',
    appVersion: () async => '1.0.0',
  );
  final notificationsApi = _RuntimeNotificationApi();
  final notifications = NotificationController(api: notificationsApi);
  final navigation = PushNavigationController();
  final runtime = PushRuntimeController(
    provider: provider,
    notifications: notifications,
    navigation: navigation,
    registration: registration,
    sessionStore: session,
  );
  return _RuntimeFixture(
    session: session,
    provider: provider,
    registration: registration,
    notifications: notifications,
    notificationsApi: notificationsApi,
    navigation: navigation,
    runtime: runtime,
  );
}

final class _RuntimeFixture {
  const _RuntimeFixture({
    required this.session,
    required this.provider,
    required this.registration,
    required this.notifications,
    required this.notificationsApi,
    required this.navigation,
    required this.runtime,
  });

  final SessionStore session;
  final _RuntimePushProvider provider;
  final PushRegistrationController registration;
  final NotificationController notifications;
  final _RuntimeNotificationApi notificationsApi;
  final PushNavigationController navigation;
  final PushRuntimeController runtime;

  void dispose() {
    runtime.dispose();
    registration.dispose();
    notifications.dispose();
    navigation.dispose();
    session.dispose();
    provider.dispose();
  }
}

final class _RuntimePushProvider implements PushProvider {
  final _foreground = StreamController<PushParseResult>.broadcast();
  final _opened = StreamController<PushParseResult>.broadcast();
  final _connections = StreamController<void>.broadcast();
  int initializeCalls = 0;
  bool _initialized = false;
  String? registrationId = 'registration-token-123';
  PushParseResult? initialMessage;
  bool initialReadFails = false;
  int initialReadCalls = 0;

  @override
  bool get isConfigured => true;

  @override
  Stream<void> get connections => _connections.stream;

  @override
  Stream<PushParseResult> get foregroundMessages => _foreground.stream;

  @override
  Stream<PushParseResult> get openedMessages => _opened.stream;

  void emitForeground(PushParseResult message) => _foreground.add(message);
  void emitOpened(PushParseResult message) => _opened.add(message);

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    initializeCalls += 1;
  }

  @override
  Future<bool> isNotificationEnabled() async => true;

  @override
  Future<String?> getRegistrationId() async => registrationId;

  @override
  Future<PushParseResult?> getInitialMessage() async {
    initialReadCalls += 1;
    if (initialReadFails) {
      throw const PushProviderFailure('PUSH_INITIAL_MESSAGE_UNAVAILABLE');
    }
    return initialMessage;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> dispose() async {
    await _foreground.close();
    await _opened.close();
    await _connections.close();
  }
}

final class _RuntimePushDeviceApi implements PushDeviceApiPort {
  @override
  Future<ApiResult<PushDeviceMutationReceipt>> registerDevice({
    required PushDeviceRegistration registration,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<PushDeviceMutationReceipt>.success(
    data: PushDeviceMutationReceipt(
      deviceId: registration.deviceId,
      status: 'active',
      updatedAt: '2026-08-07T10:00:00Z',
    ),
    status: 200,
    idempotencyStore: idempotencyStore,
  );

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<PushDeviceMutationReceipt>.success(
    data: PushDeviceMutationReceipt(
      deviceId: deviceId,
      status: 'revoked',
      updatedAt: '2026-08-07T10:00:00Z',
    ),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _RuntimeNotificationApi implements NotificationApiPort {
  int listCalls = 0;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
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
  }) => throw UnimplementedError();
}

final class _TokenDriver implements SecureTokenDriver {
  const _TokenDriver();

  @override
  FutureOr<bool> clear({required String service}) => true;

  @override
  FutureOr<SecureTokenCredential?> read({required String service}) => null;

  @override
  FutureOr<bool> write({
    required String service,
    required String username,
    required String password,
  }) => true;
}

final class _InitialMessageSdk implements JPushFlutterInterface {
  bool fail = true;
  int calls = 0;
  final gate = Completer<Map<dynamic, dynamic>>();

  @override
  Future<Map<dynamic, dynamic>> getLaunchAppNotification() async {
    calls += 1;
    if (fail) throw PlatformException(code: 'not_ready');
    return gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
