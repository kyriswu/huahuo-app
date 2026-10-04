import 'dart:async';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/notifications/application/push_registration_controller.dart';
import 'package:huahuoai_app/features/notifications/data/push_device_api.dart';
import 'package:huahuoai_app/features/notifications/domain/push_message.dart';
import 'package:huahuoai_app/features/notifications/domain/push_registration.dart';
import 'package:huahuoai_app/features/notifications/infrastructure/push_provider.dart';

void main() {
  test('timed out registration cannot overtake logout revocation', () async {
    final api = _FakePushDeviceApi()..registrationGate = Completer<void>();
    final fixture = _fixture(
      api: api,
      unregisterTimeout: const Duration(milliseconds: 5),
      operationTimeout: const Duration(milliseconds: 5),
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
    );
    addTearDown(fixture.dispose);
    await fixture.controller.synchronize();
    expect(await fixture.controller.unregisterBeforeLogout(), isFalse);
    expect(api.unregisterCalls, 0);
    expect(fixture.session.state.authState, SessionAuthState.authenticated);
    expect(fixture.controller.state.needsReconcile, isTrue);
    api.registrationGate!.complete();
    await fixture.controller.synchronize();
    expect(api.unregisterCalls, 1);
    expect(api.registrations, hasLength(1));
    expect(fixture.controller.state.needsReconcile, isFalse);
  });

  test('unconfirmed registration survives process restart', () async {
    final preferences = AppPreferencesDao(AppDatabase());
    final api = _FakePushDeviceApi()..registrationGate = Completer<void>();
    final first = _fixture(
      api: api,
      preferences: preferences,
      operationTimeout: const Duration(milliseconds: 5),
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
    );
    await first.controller.synchronize();
    first.dispose();
    api.registrationGate!.complete();
    final second = _fixture(
      preferences: preferences,
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
    );
    addTearDown(second.dispose);
    expect(second.controller.state.needsReconcile, isTrue);
    await second.controller.synchronize();
    expect(second.api.unregisterCalls, 1);
    expect(second.api.registrations, hasLength(1));
    expect(second.controller.state.needsReconcile, isFalse);
  });

  test('coalesces synchronization and registers the latest token', () async {
    final provider = _FakePushProvider(
      configured: true,
      permissionEnabled: true,
      registrationId: 'registration-token-first',
    );
    final api = _FakePushDeviceApi()..registrationGate = Completer<void>();
    final fixture = _fixture(provider: provider, api: api);
    addTearDown(fixture.dispose);
    final first = fixture.controller.synchronize();
    await Future<void>.delayed(Duration.zero);
    expect(api.registrations, hasLength(1));
    provider.registrationId = 'registration-token-second';
    final second = fixture.controller.synchronize();
    expect(identical(first, second), isTrue);
    api.registrationGate!.complete();
    await second;
    expect(api.registrations.map((item) => item.pushToken), <String>[
      'registration-token-first',
      'registration-token-second',
    ]);
    expect(fixture.controller.state.status, PushRegistrationStatus.registered);
  });

  test(
    'account changes invalidate late registration and drain the new account',
    () async {
      final api = _FakePushDeviceApi()..registrationGate = Completer<void>();
      final fixture = _fixture(
        api: api,
        provider: _FakePushProvider(
          configured: true,
          permissionEnabled: true,
          registrationId: 'registration-token-123',
        ),
      );
      addTearDown(fixture.dispose);
      final pending = fixture.controller.synchronize();
      await Future<void>.delayed(Duration.zero);
      fixture.session.restoreFromUserStatus(
        status: _userStatus('user-next'),
        restoredAt: DateTime.utc(2026, 9, 5),
      );
      expect(fixture.controller.state.status, PushRegistrationStatus.idle);
      api.registrationGate!.complete();
      await pending;
      expect(api.registrationKeys.toSet(), hasLength(2));
      expect(
        fixture.controller.state.status,
        PushRegistrationStatus.registered,
      );
    },
  );

  test('logout waits for the in-flight register before revocation', () async {
    final api = _FakePushDeviceApi()..registrationGate = Completer<void>();
    final fixture = _fixture(
      api: api,
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
    );
    addTearDown(fixture.dispose);
    final pending = fixture.controller.synchronize();
    await Future<void>.delayed(Duration.zero);
    final logout = fixture.controller.unregisterBeforeLogout();
    expect(api.unregisterCalls, 0);
    api.registrationGate!.complete();
    await pending;
    expect(await logout, isTrue);
    expect(api.unregisterCalls, 1);
    await fixture.controller.synchronize();
    expect(api.registrations, hasLength(1));
  });

  test(
    'permission revoke and restore rotate successful mutation keys',
    () async {
      final provider = _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      );
      final fixture = _fixture(provider: provider);
      addTearDown(fixture.dispose);
      await fixture.controller.synchronize();
      provider.permissionEnabled = false;
      fixture.api.blockUnregister = true;
      final failed = fixture.controller.synchronize();
      await failed;
      expect(fixture.controller.state.needsReconcile, isTrue);
      fixture.api.unregistrationGate!.complete();
      fixture.api.blockUnregister = false;
      await fixture.controller.synchronize();
      expect(fixture.api.unregisterCalls, 2);
      expect(fixture.api.unregisterKeys.toSet(), hasLength(1));
      expect(fixture.controller.state.needsReconcile, isFalse);
      provider.permissionEnabled = true;
      await fixture.controller.synchronize();
      provider.permissionEnabled = false;
      await fixture.controller.synchronize();
      expect(fixture.api.registrationKeys.toSet(), hasLength(2));
      expect(fixture.api.unregisterKeys.toSet(), hasLength(2));
    },
  );

  test('stays fail-closed when JPush is unconfigured', () async {
    final fixture = _fixture(provider: _FakePushProvider(configured: false));
    addTearDown(fixture.dispose);

    await fixture.controller.synchronize();
    expect(
      fixture.controller.state.status,
      PushRegistrationStatus.unconfigured,
    );
    expect(await fixture.controller.requestPermission(), isFalse);
    expect(fixture.provider.initializeCalls, 0);
    expect(fixture.api.registrations, isEmpty);
  });

  test('stops when native initialization finds a missing AppKey', () async {
    final fixture = _fixture(
      provider: _FakePushProvider(
        configured: true,
        configuredAfterInitialize: false,
        permissionEnabled: true,
      ),
    );
    addTearDown(fixture.dispose);

    await fixture.controller.synchronize();

    expect(
      fixture.controller.state.status,
      PushRegistrationStatus.unconfigured,
    );
    expect(fixture.provider.permissionRequests, 0);
    expect(fixture.api.registrations, isEmpty);
  });

  test('requires an explicit grant before registration', () async {
    final provider = _FakePushProvider(
      configured: true,
      permissionEnabled: false,
      permissionGrant: true,
      registrationId: 'registration-token-123',
    );
    final fixture = _fixture(provider: provider);
    addTearDown(fixture.dispose);

    await fixture.controller.synchronize();
    expect(
      fixture.controller.state.status,
      PushRegistrationStatus.permissionRequired,
    );
    expect(provider.permissionRequests, 0);

    expect(await fixture.controller.requestPermission(), isTrue);
    expect(provider.permissionRequests, 1);
    expect(fixture.controller.state.status, PushRegistrationStatus.registered);
    expect(
      fixture.api.registrations.single.pushToken,
      'registration-token-123',
    );
    expect(fixture.api.registrations.single.pushProvider, 'jpush');
    expect(
      fixture.api.registrations.single.notificationPermission,
      'authorized',
    );
  });

  test(
    'reports denial and re-registers when registration id changes',
    () async {
      final provider = _FakePushProvider(
        configured: true,
        permissionEnabled: false,
        permissionGrant: false,
        registrationId: 'registration-token-123',
      );
      final fixture = _fixture(provider: provider);
      addTearDown(fixture.dispose);

      expect(await fixture.controller.requestPermission(), isFalse);
      expect(fixture.controller.state.status, PushRegistrationStatus.denied);
      expect(fixture.api.registrations, isEmpty);

      provider.permissionEnabled = true;
      await fixture.controller.synchronize();
      expect(fixture.api.registrations, hasLength(1));
      await fixture.controller.synchronize();
      expect(fixture.api.registrations, hasLength(1));

      provider.registrationId = 'registration-token-456';
      await fixture.controller.synchronize();
      expect(fixture.api.registrations, hasLength(2));
      expect(fixture.api.registrationKeys.toSet(), hasLength(2));
      expect(
        fixture.api.registrations.last.pushToken,
        'registration-token-456',
      );
      expect(
        fixture.api.registrationKeys.first,
        isNot(fixture.api.registrationKeys.last),
      );
    },
  );

  test(
    'logout timeout records only a non-sensitive reconcile marker',
    () async {
      final root = await Directory.systemTemp.createTemp('push-reconcile-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshot = File('${root.path}/local-db.json');
      final preferences = AppPreferencesDao(
        AppDatabase(snapshotStore: LocalDatabaseSnapshotStore(file: snapshot)),
      );
      final provider = _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-sensitive-123',
      );
      final api = _FakePushDeviceApi()..blockUnregister = true;
      final fixture = _fixture(
        provider: provider,
        api: api,
        preferences: preferences,
        unregisterTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(fixture.dispose);
      await fixture.controller.synchronize();

      expect(await fixture.controller.unregisterBeforeLogout(), isFalse);
      expect(fixture.controller.state.needsReconcile, isTrue);
      final contents = snapshot.readAsStringSync();
      expect(contents, contains('push-device-needs-reconcile'));
      expect(contents, isNot(contains('registration-token-sensitive-123')));
    },
  );

  test('permission revocation unregisters the server device', () async {
    final provider = _FakePushProvider(
      configured: true,
      permissionEnabled: true,
      registrationId: 'registration-token-123',
    );
    final fixture = _fixture(provider: provider);
    addTearDown(fixture.dispose);
    await fixture.controller.synchronize();

    provider.permissionEnabled = false;
    await fixture.controller.synchronize();

    expect(fixture.api.unregisterCalls, 1);
    expect(
      fixture.controller.state.status,
      PushRegistrationStatus.permissionRequired,
    );
  });

  test(
    'same token registers again when the authenticated account changes',
    () async {
      final provider = _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      );
      final fixture = _fixture(provider: provider);
      addTearDown(fixture.dispose);
      await fixture.controller.synchronize();

      final originalUserId = fixture.session.state.user!.userId;
      fixture.session.restoreFromUserStatus(
        status: _userStatus('user-2'),
        restoredAt: DateTime.utc(2026, 8, 2),
      );
      await fixture.controller.synchronize();

      expect(fixture.api.registrations, hasLength(2));
      expect(fixture.controller.state.needsReconcile, isTrue);
      expect(fixture.api.unregisterCalls, 0);
      expect(await fixture.controller.unregisterBeforeLogout(), isTrue);
      expect(fixture.controller.state.needsReconcile, isTrue);
      fixture.session.restoreFromUserStatus(
        status: _userStatus(originalUserId),
        restoredAt: DateTime.utc(2026, 9, 5),
      );
      await fixture.controller.synchronize();
      expect(fixture.api.unregisterCalls, 2);
      expect(fixture.controller.state.needsReconcile, isFalse);
    },
  );

  test('logout attempts revoke after process restart', () async {
    final database = AppDatabase();
    final preferences = AppPreferencesDao(database);
    final first = _fixture(
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
      preferences: preferences,
    );
    await first.controller.synchronize();
    first.dispose();

    final api = _FakePushDeviceApi();
    final second = _fixture(
      provider: _FakePushProvider(
        configured: true,
        permissionEnabled: true,
        registrationId: 'registration-token-123',
      ),
      api: api,
      preferences: preferences,
    );
    addTearDown(second.dispose);

    expect(await second.controller.unregisterBeforeLogout(), isTrue);
    expect(api.unregisterCalls, 1);
  });
}

SessionUserStatus _userStatus(String userId) => SessionUserStatus(
  user: SessionUser(userId: userId, maskedPhoneNumber: '***'),
  workspace: const SessionWorkspace(
    status: SessionWorkspaceStatus.ready,
    workspaceId: 'workspace-1',
  ),
  onboardingRequired: false,
);

_Fixture _fixture({
  required _FakePushProvider provider,
  _FakePushDeviceApi? api,
  AppPreferencesDao? preferences,
  Duration unregisterTimeout = const Duration(seconds: 1),
  Duration operationTimeout = const Duration(seconds: 15),
}) {
  final session = SessionStore(
    secureTokenStore: const SecureTokenStore(driver: _TokenDriver()),
  );
  session.restoreFromUserStatus(
    status: localNumericAuthUserStatus(),
    restoredAt: DateTime.utc(2026, 7, 31),
  );
  final deviceApi = api ?? _FakePushDeviceApi();
  return _Fixture(
    provider: provider,
    api: deviceApi,
    session: session,
    controller: PushRegistrationController(
      provider: provider,
      api: deviceApi,
      sessionStore: session,
      deviceId: 'device-1',
      platform: 'android',
      appVersion: () async => '1.2.3',
      preferences: preferences,
      unregisterTimeout: unregisterTimeout,
      operationTimeout: operationTimeout,
    ),
  );
}

final class _Fixture {
  const _Fixture({
    required this.provider,
    required this.api,
    required this.session,
    required this.controller,
  });

  final _FakePushProvider provider;
  final _FakePushDeviceApi api;
  final SessionStore session;
  final PushRegistrationController controller;

  void dispose() {
    controller.dispose();
    session.dispose();
    provider.dispose();
  }
}

final class _FakePushProvider implements PushProvider {
  _FakePushProvider({
    required this.configured,
    this.configuredAfterInitialize,
    this.permissionEnabled = false,
    this.permissionGrant = false,
    this.registrationId,
  });

  bool configured;
  final bool? configuredAfterInitialize;
  bool permissionEnabled;
  bool permissionGrant;
  String? registrationId;
  int initializeCalls = 0;
  int permissionRequests = 0;

  @override
  bool get isConfigured => configured;

  @override
  Stream<void> get connections => const Stream<void>.empty();

  @override
  Stream<PushParseResult> get foregroundMessages =>
      const Stream<PushParseResult>.empty();

  @override
  Stream<PushParseResult> get openedMessages =>
      const Stream<PushParseResult>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<String?> getRegistrationId() async => registrationId;

  @override
  Future<PushParseResult?> getInitialMessage() async => null;

  @override
  Future<void> initialize() async {
    initializeCalls += 1;
    configured = configuredAfterInitialize ?? configured;
  }

  @override
  Future<bool> isNotificationEnabled() async => permissionEnabled;

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    if (permissionGrant) permissionEnabled = true;
    return permissionGrant;
  }
}

final class _FakePushDeviceApi implements PushDeviceApiPort {
  final registrations = <PushDeviceRegistration>[];
  final registrationKeys = <String>[];
  final unregisterKeys = <String>[];
  Completer<void>? registrationGate;
  bool blockUnregister = false;
  Completer<void>? unregistrationGate;
  int unregisterCalls = 0;

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> registerDevice({
    required PushDeviceRegistration registration,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    registrations.add(registration);
    registrationKeys.add(idempotency.explicitKey!);
    await registrationGate?.future;
    return ApiResult<PushDeviceMutationReceipt>.success(
      data: PushDeviceMutationReceipt(
        deviceId: registration.deviceId,
        status: 'active',
        updatedAt: '2026-08-07T10:00:00Z',
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    unregisterCalls += 1;
    unregisterKeys.add(idempotency.explicitKey!);
    if (blockUnregister) {
      await (unregistrationGate ??= Completer<void>()).future;
    }
    return ApiResult<PushDeviceMutationReceipt>.success(
      data: PushDeviceMutationReceipt(
        deviceId: deviceId,
        status: 'revoked',
        updatedAt: '2026-08-07T10:00:00Z',
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
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
