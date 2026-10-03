import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/idempotency.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../data/push_device_api.dart';
import '../domain/push_registration.dart';
import '../infrastructure/push_provider.dart';

enum PushRegistrationStatus {
  idle,
  unconfigured,
  initializing,
  permissionRequired,
  registering,
  registered,
  denied,
  failed,
}

final class PushRegistrationState {
  const PushRegistrationState({
    required this.status,
    this.lastErrorCode,
    this.needsReconcile = false,
  });

  const PushRegistrationState.idle()
    : status = PushRegistrationStatus.idle,
      lastErrorCode = null,
      needsReconcile = false;

  final PushRegistrationStatus status;
  final String? lastErrorCode;
  final bool needsReconcile;
}

final class PushRegistrationController extends ChangeNotifier {
  PushRegistrationController({
    required PushProvider provider,
    required PushDeviceApiPort api,
    required SessionStore sessionStore,
    required String deviceId,
    required String platform,
    required Future<String> Function() appVersion,
    AppPreferencesDao? preferences,
    Duration unregisterTimeout = const Duration(seconds: 3),
    Duration operationTimeout = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _provider = provider,
       _api = api,
       _sessionStore = sessionStore,
       _deviceId = deviceId,
       _platform = platform,
       _appVersion = appVersion,
       _preferences = preferences,
       _unregisterTimeout = unregisterTimeout,
       _operationTimeout = operationTimeout,
       _now = now ?? DateTime.now,
       _state = PushRegistrationState(
         status: provider.isConfigured
             ? PushRegistrationStatus.idle
             : PushRegistrationStatus.unconfigured,
         needsReconcile:
             preferences?.readValue(_reconcilePreferenceKey) == 'true',
       ) {
    _sessionUserId = _currentUserId;
    _sessionStore.addListener(_handleSessionChanged);
    _registeredDigest = preferences?.readValue(_registeredDigestPreferenceKey);
    _registeredAccountDigest = preferences?.readValue(
      _registeredAccountPreferenceKey,
    );
    _restoreReconciliation();
    _state = PushRegistrationState(
      status: _state.status,
      needsReconcile: _hasPendingReconciliation,
    );
  }

  static const _registrationOwnerPreferenceKey =
      'push-device-unconfirmed-registration-owner-v2';
  static const _unscopedReconcilePreferenceKey =
      'push-device-unscoped-reconcile-v2';
  static const _pendingRevocationsPreferenceKey =
      'push-device-pending-revocations-v2';
  static const _reconcilePreferenceKey = 'push-device-needs-reconcile';
  static const _registeredDigestPreferenceKey =
      'push-device-registration-digest';
  static const _registeredAccountPreferenceKey =
      'push-device-registration-account';

  final PushProvider _provider;
  final PushDeviceApiPort _api;
  final SessionStore _sessionStore;
  final String _deviceId;
  final String _platform;
  final Future<String> Function() _appVersion;
  final AppPreferencesDao? _preferences;
  final Duration _unregisterTimeout;
  final Duration _operationTimeout;
  final DateTime Function() _now;
  PushRegistrationState _state;
  String? _registeredDigest;
  String? _registeredAccountDigest;
  String? _permissionRevocationAttemptedFor;
  bool _sessionEndAlreadyRevoked = false;
  Future<void>? _syncFuture;
  Future<bool>? _permissionFuture;
  Future<bool>? _logoutFuture;
  String? _sessionUserId;
  String? _registrationIntent;
  String? _registrationKey;
  final Map<String, String> _pendingRevocations = <String, String>{};
  Future<void>? _mutationSettlement;
  String? _logoutAccountDigest;
  bool _unscopedReconcile = false;
  var _generation = 0;
  bool _syncRequested = false;
  bool _endingSession = false;
  bool _bindingVerified = false;
  bool _disposed = false;

  PushRegistrationState get state => _state;

  Future<void> synchronize() {
    if (_disposed || _endingSession || _sessionEndAlreadyRevoked) {
      return Future<void>.value();
    }
    final userId = _currentUserId;
    if (userId != null && _logoutAccountDigest == _accountDigest(userId)) {
      return unregisterBeforeLogout().then((_) {});
    }
    final permission = _permissionFuture;
    if (permission != null) return permission.then((_) {});
    return _enqueueSynchronization();
  }

  Future<void> _enqueueSynchronization() {
    _syncRequested = true;
    final active = _syncFuture;
    if (active != null) return active;
    final completer = Completer<void>();
    _syncFuture = completer.future;
    unawaited(_drainSynchronization(completer));
    return completer.future;
  }

  Future<void> _drainSynchronization(Completer<void> completer) async {
    try {
      while (_syncRequested && !_disposed && !_endingSession) {
        _syncRequested = false;
        await _synchronizeOnce();
      }
    } finally {
      _syncFuture = null;
      completer.complete();
    }
  }

  Future<void> _synchronizeOnce() async {
    if (!_provider.isConfigured) {
      _set(
        PushRegistrationState(
          status: PushRegistrationStatus.unconfigured,
          needsReconcile: _state.needsReconcile,
        ),
      );
      return;
    }
    final userId = _currentUserId;
    if (userId == null) {
      _set(
        PushRegistrationState(
          status: PushRegistrationStatus.idle,
          needsReconcile: _state.needsReconcile,
        ),
      );
      return;
    }
    final generation = _generation;
    final accountDigest = _accountDigest(userId);
    _set(
      PushRegistrationState(
        status: PushRegistrationStatus.initializing,
        needsReconcile: _state.needsReconcile,
      ),
    );
    try {
      await _mutationSettlement?.timeout(_operationTimeout);
      if (!_isCurrent(generation, userId)) return;
      if (_hasPendingReconciliation && !_persistReconciliation()) {
        _fail('PUSH_RECONCILE_SAVE_FAILED');
        return;
      }
      if (_pendingRevocations.containsKey(accountDigest)) {
        if (!await _revokeCurrentDevice(
          generation: generation,
          userId: userId,
        )) {
          if (_isCurrent(generation, userId)) {
            _fail('PUSH_DEVICE_RECONCILE_FAILED');
          }
          return;
        }
        if (!_isCurrent(generation, userId)) return;
        _permissionRevocationAttemptedFor = accountDigest;
      }
      final enabled = await _provider.isNotificationEnabled().timeout(
        _operationTimeout,
      );
      if (!_isCurrent(generation, userId)) return;
      if (!enabled) {
        if (!_provider.isConfigured) {
          _set(
            PushRegistrationState(
              status: PushRegistrationStatus.unconfigured,
              needsReconcile: _state.needsReconcile,
            ),
          );
          return;
        }
        if (_permissionRevocationAttemptedFor != accountDigest ||
            _pendingRevocations.containsKey(accountDigest)) {
          final revoked = await _revokeCurrentDevice(
            generation: generation,
            userId: userId,
          );
          if (!_isCurrent(generation, userId)) return;
          if (revoked) _permissionRevocationAttemptedFor = accountDigest;
        }
        _set(
          PushRegistrationState(
            status: PushRegistrationStatus.permissionRequired,
            needsReconcile: _state.needsReconcile,
          ),
        );
        return;
      }
      _permissionRevocationAttemptedFor = null;
      await _provider.initialize().timeout(_operationTimeout);
      if (!_isCurrent(generation, userId)) return;
      if (!_provider.isConfigured) {
        _set(
          PushRegistrationState(
            status: PushRegistrationStatus.unconfigured,
            needsReconcile: _state.needsReconcile,
          ),
        );
        return;
      }
      final registrationId = await _provider.getRegistrationId().timeout(
        _operationTimeout,
      );
      if (!_isCurrent(generation, userId)) return;
      if (registrationId == null) {
        _fail('PUSH_REGISTRATION_ID_UNAVAILABLE');
        return;
      }
      final version = await _appVersion().timeout(_operationTimeout);
      if (!_isCurrent(generation, userId)) return;
      final digest = sha256
          .convert(
            utf8.encode(jsonEncode([registrationId, _platform, version])),
          )
          .toString();
      if (_bindingVerified &&
          _registeredDigest == digest &&
          _registeredAccountDigest == accountDigest &&
          !_pendingRevocations.containsKey(accountDigest)) {
        _set(
          const PushRegistrationState(
            status: PushRegistrationStatus.registered,
          ),
        );
        return;
      }
      final intent = '$accountDigest:$digest:$version';
      if (_registrationIntent != intent || _registrationKey == null) {
        _registrationIntent = intent;
        _registrationKey = _newIntentKey('register', accountDigest);
      }
      _set(
        PushRegistrationState(
          status: PushRegistrationStatus.registering,
          needsReconcile: _state.needsReconcile,
        ),
      );
      if (!_isCurrent(generation, userId)) return;
      _preferences?.upsertValue(
        preferenceKey: _registrationOwnerPreferenceKey,
        value: accountDigest,
        updatedAt: _now().toUtc().toIso8601String(),
      );
      final write = _api.registerDevice(
        registration: PushDeviceRegistration(
          deviceId: _deviceId,
          platform: _platform,
          pushProvider: 'jpush',
          pushToken: registrationId,
          notificationPermission: 'authorized',
          appVersion: version,
        ),
        idempotency: IdempotencyRequestContext(explicitKey: _registrationKey),
      );
      final result = await _trackMutation(write).timeout(_operationTimeout);
      if (!_isCurrent(generation, userId)) return;
      if (!result.ok || result.data == null) {
        _fail(result.error?.code ?? 'PUSH_DEVICE_REGISTER_FAILED');
        return;
      }
      _bindingVerified = true;
      _registeredDigest = digest;
      _registeredAccountDigest = accountDigest;
      _registrationKey = null;
      _sessionEndAlreadyRevoked = false;
      _persistBinding();
      _set(
        const PushRegistrationState(status: PushRegistrationStatus.registered),
      );
    } catch (error) {
      if (_isCurrent(generation, userId)) {
        _fail(
          error is PushProviderFailure
              ? error.code
              : 'PUSH_REGISTRATION_FAILED',
        );
      }
    }
  }

  Future<bool> requestPermission() {
    if (_disposed || _endingSession || _logoutAccountDigest != null) {
      return Future<bool>.value(false);
    }
    final active = _permissionFuture;
    if (active != null) return active;
    final completer = Completer<bool>();
    _permissionFuture = completer.future;
    unawaited(() async {
      final granted = await _requestPermissionOnce();
      _permissionFuture = null;
      completer.complete(granted);
    }());
    return completer.future;
  }

  Future<bool> _requestPermissionOnce() async {
    final generation = _generation;
    final userId = _currentUserId;
    if (!_provider.isConfigured) {
      _set(
        PushRegistrationState(
          status: PushRegistrationStatus.unconfigured,
          needsReconcile: _state.needsReconcile,
        ),
      );
      return false;
    }
    try {
      await _syncFuture;
      if (!_isCurrent(generation, userId)) return false;
      final granted = await _provider.requestPermission();
      if (!_isCurrent(generation, userId)) return false;
      if (!_provider.isConfigured) {
        _set(
          PushRegistrationState(
            status: PushRegistrationStatus.unconfigured,
            needsReconcile: _state.needsReconcile,
          ),
        );
        return false;
      }
      if (!granted) {
        if (userId != null) {
          final revoked = await _revokeCurrentDevice(
            generation: generation,
            userId: userId,
          );
          if (!_isCurrent(generation, userId)) return false;
          if (revoked) {
            _permissionRevocationAttemptedFor = _accountDigest(userId);
          }
        }
        _set(
          PushRegistrationState(
            status: PushRegistrationStatus.denied,
            needsReconcile: _state.needsReconcile,
          ),
        );
        return false;
      }
      await _enqueueSynchronization();
      return _isCurrent(generation, userId);
    } catch (_) {
      if (_isCurrent(generation, userId)) {
        _fail('PUSH_PERMISSION_REQUEST_FAILED');
      }
      return false;
    }
  }

  Future<bool> unregisterBeforeLogout() {
    if (_disposed) return Future<bool>.value(false);
    final active = _logoutFuture;
    if (active != null) return active;
    _endingSession = true;
    _syncRequested = false;
    _generation += 1;
    final completer = Completer<bool>();
    _logoutFuture = completer.future;
    unawaited(() async {
      final revoked = await _unregisterBeforeLogoutOnce();
      _logoutFuture = null;
      _endingSession = false;
      completer.complete(revoked);
    }());
    return completer.future;
  }

  Future<bool> _unregisterBeforeLogoutOnce() async {
    final generation = _generation;
    final userId = _currentUserId;
    if (userId == null) {
      _clearBinding();
      return true;
    }
    final accountDigest = _accountDigest(userId);
    if (!_provider.isConfigured &&
        !_pendingRevocations.containsKey(accountDigest) &&
        _registeredAccountDigest != accountDigest &&
        _mutationSettlement == null) {
      return true;
    }
    _logoutAccountDigest = accountDigest;
    if (!_markReconcile(accountDigest: accountDigest)) {
      _fail('PUSH_RECONCILE_SAVE_FAILED');
      return false;
    }
    try {
      await _syncFuture?.timeout(_unregisterTimeout);
      await _mutationSettlement?.timeout(_unregisterTimeout);
    } catch (_) {
      if (_isCurrent(generation, userId)) {
        _fail('PUSH_LOGOUT_WAITING_FOR_REGISTRATION');
      }
      return false;
    }
    if (!_isCurrent(generation, userId)) return false;
    final revoked = await _revokeCurrentDevice(
      generation: generation,
      userId: userId,
    );
    if (_isCurrent(generation, userId)) {
      _sessionEndAlreadyRevoked = revoked;
      _set(
        PushRegistrationState(
          status: PushRegistrationStatus.idle,
          needsReconcile: _state.needsReconcile,
        ),
      );
    }
    return revoked;
  }

  String? get _currentUserId =>
      _sessionStore.state.authState == SessionAuthState.authenticated
      ? _sessionStore.state.user?.userId
      : null;

  bool _isCurrent(int generation, String? userId) =>
      !_disposed && generation == _generation && userId == _currentUserId;

  void _handleSessionChanged() {
    final next = _currentUserId;
    if (_sessionUserId == next) return;
    if (_sessionUserId != null) handleSessionEnded();
    _sessionUserId = next;
    _endingSession = false;
    _logoutAccountDigest = null;
    if (_syncFuture != null && next != null) _syncRequested = true;
  }

  void handleSessionEnded() {
    _generation += 1;
    _syncRequested = false;
    _permissionRevocationAttemptedFor = null;
    _registrationIntent = null;
    _registrationKey = null;
    final wasRevoked = _sessionEndAlreadyRevoked;
    _sessionEndAlreadyRevoked = false;
    final endedUserId = _sessionUserId;
    if (!wasRevoked &&
        endedUserId != null &&
        (_provider.isConfigured ||
            _registeredAccountDigest != null ||
            _mutationSettlement != null)) {
      _markReconcile(accountDigest: _accountDigest(endedUserId));
    }
    _logoutAccountDigest = null;
    _clearBinding();
    _set(
      PushRegistrationState(
        status: PushRegistrationStatus.idle,
        needsReconcile: _state.needsReconcile,
      ),
    );
  }

  Future<bool> _revokeCurrentDevice({
    required int generation,
    required String userId,
  }) async {
    if (!_isCurrent(generation, userId)) return false;
    final accountDigest = _accountDigest(userId);
    if (!_markReconcile(accountDigest: accountDigest)) return false;
    _registrationIntent = null;
    _registrationKey = null;
    try {
      await _mutationSettlement?.timeout(_unregisterTimeout);
      if (!_isCurrent(generation, userId)) return false;
      final write = _api.unregisterDevice(
        deviceId: _deviceId,
        idempotency: IdempotencyRequestContext(
          explicitKey: _pendingRevocations[accountDigest],
        ),
      );
      final result = await _trackMutation(write).timeout(_unregisterTimeout);
      if (!_isCurrent(generation, userId)) return false;
      if ((result.ok && result.data != null) ||
          result.error?.code == 'NOT_FOUND') {
        _preferences?.deleteValue(_registrationOwnerPreferenceKey);
        _clearBinding();
        return _clearReconcile(accountDigest);
      }
    } catch (_) {}
    return false;
  }

  Future<T> _trackMutation<T>(Future<T> write) {
    final settlement = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _mutationSettlement = settlement;
    unawaited(
      settlement.then((_) {
        if (identical(_mutationSettlement, settlement)) {
          _mutationSettlement = null;
        }
      }),
    );
    return write;
  }

  String _accountDigest(String userId) =>
      sha256.convert(utf8.encode(userId)).toString();

  String _newIntentKey(String operation, String accountDigest) {
    final random = Random.secure();
    final nonce = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'idem-push-$operation-${accountDigest.substring(0, 12)}-$nonce';
  }

  void _persistBinding() {
    final digest = _registeredDigest;
    final account = _registeredAccountDigest;
    if (digest == null || account == null) return;
    final updatedAt = _now().toUtc().toIso8601String();
    try {
      _preferences?.upsertValue(
        preferenceKey: _registeredDigestPreferenceKey,
        value: digest,
        updatedAt: updatedAt,
      );
      _preferences?.upsertValue(
        preferenceKey: _registeredAccountPreferenceKey,
        value: account,
        updatedAt: updatedAt,
      );
      _preferences?.deleteValue(_registrationOwnerPreferenceKey);
    } catch (_) {}
  }

  void _clearBinding() {
    _bindingVerified = false;
    _registeredDigest = null;
    _registeredAccountDigest = null;
    try {
      _preferences?.deleteValue(_registeredDigestPreferenceKey);
      _preferences?.deleteValue(_registeredAccountPreferenceKey);
    } catch (_) {}
  }

  bool get _hasPendingReconciliation =>
      _unscopedReconcile || _pendingRevocations.isNotEmpty;

  void _restoreReconciliation() {
    _unscopedReconcile =
        _preferences?.readValue(_unscopedReconcilePreferenceKey) == 'true';
    final raw = _preferences?.readValue(_pendingRevocationsPreferenceKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) &&
              entry.value is String &&
              RegExp(
                r'^idem-push-unregister-[a-f0-9]{12}-[a-f0-9]{32}$',
              ).hasMatch(entry.value as String)) {
            _pendingRevocations[entry.key] = entry.value as String;
          } else {
            _unscopedReconcile = true;
          }
        }
      } catch (_) {
        _unscopedReconcile = true;
      }
    }
    final unconfirmedAccount = _preferences?.readValue(
      _registrationOwnerPreferenceKey,
    );
    final registeredAccount = _registeredAccountDigest;
    final current = _currentUserId;
    for (final account in <String?>[
      unconfirmedAccount,
      if (current == null || registeredAccount != _accountDigest(current))
        registeredAccount,
    ]) {
      if (account == null) continue;
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(account)) {
        _pendingRevocations.putIfAbsent(
          account,
          () => _newIntentKey('unregister', account),
        );
      } else {
        _unscopedReconcile = true;
      }
    }
    if (_state.needsReconcile && _pendingRevocations.isEmpty) {
      final account = _registeredAccountDigest;
      if (account != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(account)) {
        _pendingRevocations[account] = _newIntentKey('unregister', account);
        _persistReconciliation();
      } else {
        _unscopedReconcile = true;
      }
    }
  }

  bool _markReconcile({required String accountDigest}) {
    _pendingRevocations.putIfAbsent(
      accountDigest,
      () => _newIntentKey('unregister', accountDigest),
    );
    final saved = _persistReconciliation();
    _set(_state);
    return saved;
  }

  bool _clearReconcile(String accountDigest) {
    final key = _pendingRevocations.remove(accountDigest);
    if (_persistReconciliation()) return true;
    if (key != null) _pendingRevocations[accountDigest] = key;
    return false;
  }

  bool _persistReconciliation() {
    try {
      if (_unscopedReconcile) {
        _preferences?.upsertValue(
          preferenceKey: _unscopedReconcilePreferenceKey,
          value: 'true',
          updatedAt: _now().toUtc().toIso8601String(),
        );
      }
      _preferences?.upsertValue(
        preferenceKey: _pendingRevocationsPreferenceKey,
        value: jsonEncode(_pendingRevocations),
        updatedAt: _now().toUtc().toIso8601String(),
      );
      if (_hasPendingReconciliation) {
        _preferences?.upsertValue(
          preferenceKey: _reconcilePreferenceKey,
          value: 'true',
          updatedAt: _now().toUtc().toIso8601String(),
        );
      } else {
        _preferences?.deleteValue(_reconcilePreferenceKey);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _fail(String code) {
    _set(
      PushRegistrationState(
        status: PushRegistrationStatus.failed,
        lastErrorCode: RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(code)
            ? code
            : 'PUSH_REGISTRATION_FAILED',
        needsReconcile: _state.needsReconcile,
      ),
    );
  }

  void _set(PushRegistrationState state) {
    if (_disposed) return;
    _state = PushRegistrationState(
      status: state.status,
      lastErrorCode: state.lastErrorCode,
      needsReconcile: _hasPendingReconciliation,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionStore.removeListener(_handleSessionChanged);
    super.dispose();
  }
}
