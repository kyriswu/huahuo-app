import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/native/recording_card_native_port.dart';
import '../domain/recording_card_account_binding.dart';
import 'recording_card_controller.dart';

enum RecordingCardCloudBindingStatus {
  idle,
  loading,
  binding,
  bound,
  unbinding,
  unbound,
  unavailable,
  failure,
}

enum RecordingCardUnbindPhase {
  idle,
  disconnectingDevice,
  unbindingCloud,
  completed,
  failed,
}

final class RecordingCardCloudBindingState {
  const RecordingCardCloudBindingState({
    required this.status,
    this.binding,
    this.errorCode,
    this.unbindPhase = RecordingCardUnbindPhase.idle,
  });

  const RecordingCardCloudBindingState.initial()
    : status = RecordingCardCloudBindingStatus.idle,
      binding = null,
      errorCode = null,
      unbindPhase = RecordingCardUnbindPhase.idle;

  final RecordingCardCloudBindingStatus status;
  final RecordingCardCloudBinding? binding;
  final String? errorCode;
  final RecordingCardUnbindPhase unbindPhase;

  bool get isLoading =>
      status == RecordingCardCloudBindingStatus.loading ||
      status == RecordingCardCloudBindingStatus.binding ||
      status == RecordingCardCloudBindingStatus.unbinding;
  bool get isBound =>
      status == RecordingCardCloudBindingStatus.bound && binding != null;
}

final class RecordingCardBindingHardwareSnapshot {
  const RecordingCardBindingHardwareSnapshot({
    required this.connected,
    required this.recordingIdle,
    required this.transferActive,
    required this.commandBusy,
  });

  final bool connected;
  final bool recordingIdle;
  final bool transferActive;
  final bool commandBusy;

  bool get ready =>
      connected && recordingIdle && !transferActive && !commandBusy;
}

abstract interface class RecordingCardCloudBindingHardwarePort {
  RecordingCardBindingHardwareSnapshot get bindingSnapshot;

  Future<RecordingCardResult<RecordingCardOwnershipIdentity>> readIdentity();
}

final class RecordingCardControllerCloudBindingHardware
    implements RecordingCardCloudBindingHardwarePort {
  const RecordingCardControllerCloudBindingHardware(
    this._controller,
    this._ownership,
  );

  final RecordingCardController _controller;
  final RecordingCardOwnershipProofPort _ownership;

  @override
  RecordingCardBindingHardwareSnapshot get bindingSnapshot {
    final state = _controller.state;
    return RecordingCardBindingHardwareSnapshot(
      connected: state.snapshot.deviceState.isOperationallyConnected,
      recordingIdle:
          state.snapshot.recordingInfo.state ==
          RecordingCardRecordingState.idle,
      transferActive: state.hasActiveTransfer,
      commandBusy:
          state.status != RecordingCardControllerStatus.idle &&
          state.status != RecordingCardControllerStatus.error,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>> readIdentity() =>
      _ownership.readAccountBindingIdentity();
}

final class RecordingCardCloudConnectionAuthorization
    implements
        RecordingCardConnectionAuthorizationPort,
        RecordingCardDiscoveryAuthorizationPort {
  RecordingCardCloudConnectionAuthorization({
    required RecordingCardCloudBindingPort port,
    required RecordingCardOwnershipProofPort ownership,
    required bool authenticated,
    RecordingCardSnAuthorizationCachePort authorizationCache =
        const UnavailableRecordingCardSnAuthorizationCache(),
    DateTime Function()? clock,
    Random? random,
  }) : _port = port,
       _ownership = ownership,
       _authenticated = authenticated,
       _authorizationCache = authorizationCache,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final RecordingCardCloudBindingPort _port;
  final RecordingCardOwnershipProofPort _ownership;
  final bool _authenticated;
  final RecordingCardSnAuthorizationCachePort _authorizationCache;
  final DateTime Function() _clock;
  final Random _random;

  @override
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  ) async {
    if (!_authenticated) {
      return _failure('RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED');
    }
    final identityResult = await _ownership.readAccountBindingIdentity();
    final serialNumber = normalizeRecordingCardSerialNumberForOwnership(
      identityResult.value?.serialNumber ?? '',
    );
    if (!identityResult.ok || serialNumber == null) {
      return _failure(
        identityResult.error?.code ?? 'RECORDING_CARD_IDENTITY_READ_FAILED',
      );
    }

    return _authorizeSerial(serialNumber, displayName: device.displayName);
  }

  @override
  Future<RecordingCardResult<bool>> matchesCachedSerial(
    String serialNumber,
  ) async {
    if (!_authenticated) return RecordingCardResult<bool>.success(false);
    final normalized = normalizeRecordingCardSerialNumberForOwnership(
      serialNumber,
    );
    if (normalized == null) return RecordingCardResult<bool>.success(false);
    try {
      return RecordingCardResult<bool>.success(
        await _authorizationCache.matches(normalized),
      );
    } on Object {
      return RecordingCardResult<bool>.success(false);
    }
  }

  @override
  Future<RecordingCardResult<bool>> authorizeDiscoveredDevice({
    required String serialNumber,
    required String displayName,
  }) async {
    if (!_authenticated) {
      return _failure('RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED');
    }
    final normalized = normalizeRecordingCardSerialNumberForOwnership(
      serialNumber,
    );
    if (normalized == null) {
      return _failure('RECORDING_CARD_ADVERTISEMENT_SN_INVALID');
    }
    return _authorizeSerial(normalized, displayName: displayName);
  }

  Future<RecordingCardResult<bool>> _authorizeSerial(
    String serialNumber, {
    String? displayName,
  }) async {
    try {
      if (await _authorizationCache.matches(serialNumber)) {
        return RecordingCardResult<bool>.success(true);
      }
    } on Object {
      // A cache read failure is a miss and must fall back to the Backend.
    }

    RecordingCardBindingResult<RecordingCardCloudBinding> bindResult;
    try {
      bindResult = await _port.bind(
        serialNumber: serialNumber,
        idempotencyKey: _idempotencyKey(),
        displayName: displayName,
      );
    } on Object catch (error) {
      return _failure(
        'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED',
        cause: error,
      );
    }
    if (!bindResult.ok || bindResult.value == null) {
      return _failure(bindResult.errorCode ?? 'RECORDING_CARD_BIND_FAILED');
    }
    await _rememberAuthorization(serialNumber);
    return RecordingCardResult<bool>.success(true);
  }

  Future<void> _rememberAuthorization(String serialNumber) async {
    try {
      await _authorizationCache.remember(serialNumber);
    } on Object {
      // Cloud success authorizes this connection even if caching is unavailable.
    }
  }

  RecordingCardResult<bool> _failure(String code, {Object? cause}) {
    return RecordingCardResult<bool>.failure(
      recordingCardFailure(
        code,
        'Recording-card cloud connection authorization failed',
        cause: cause,
        isRetryable:
            code == 'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED' ||
            code == 'RECORDING_CARD_BIND_FAILED',
      ),
    );
  }

  String _idempotencyKey() {
    final nonce = List<int>.generate(
      12,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'recording-card-connect-${_clock().toUtc().microsecondsSinceEpoch}-$nonce';
  }
}

final class RecordingCardCloudBindingController extends ChangeNotifier {
  RecordingCardCloudBindingController({
    required RecordingCardCloudBindingPort port,
    required RecordingCardCloudBindingHardwarePort hardware,
    required bool authenticated,
    RecordingCardSnAuthorizationCachePort authorizationCache =
        const UnavailableRecordingCardSnAuthorizationCache(),
    Future<void> Function()? onUnbound,
    DateTime Function()? clock,
    Random? random,
  }) : _port = port,
       _hardware = hardware,
       _authenticated = authenticated,
       _authorizationCache = authorizationCache,
       _onUnbound = onUnbound,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final RecordingCardCloudBindingPort _port;
  final RecordingCardCloudBindingHardwarePort _hardware;
  final bool _authenticated;
  final RecordingCardSnAuthorizationCachePort _authorizationCache;
  final Future<void> Function()? _onUnbound;
  final DateTime Function() _clock;
  final Random _random;
  RecordingCardCloudBindingState _state =
      const RecordingCardCloudBindingState.initial();

  RecordingCardCloudBindingState get state => _state;

  Future<void> load() async {
    if (!_authenticated) {
      _setState(
        const RecordingCardCloudBindingState(
          status: RecordingCardCloudBindingStatus.unavailable,
          errorCode: 'RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED',
        ),
      );
      return;
    }
    if (_state.isLoading) return;
    _setState(
      RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.loading,
        binding: _state.binding,
      ),
    );
    final result = await _guard(_port.currentBinding);
    if (!result.ok) {
      _fail(result.errorCode ?? 'RECORDING_CARD_CLOUD_BINDING_LOAD_FAILED');
      return;
    }
    final binding = result.value;
    if (binding == null) await _clearAuthorizationCache();
    _setState(
      RecordingCardCloudBindingState(
        status: binding == null
            ? RecordingCardCloudBindingStatus.unbound
            : RecordingCardCloudBindingStatus.bound,
        binding: binding,
      ),
    );
  }

  Future<bool> bindConnectedCard({String? displayName}) async {
    if (!_authenticated) {
      _fail('RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED');
      return false;
    }
    if (_state.isLoading) return false;
    if (_state.binding != null) {
      _fail('RECORDING_CARD_ACCOUNT_LIMIT_REACHED');
      return false;
    }
    final availabilityError = _bindingAvailabilityError();
    if (availabilityError != null) {
      _fail(availabilityError);
      return false;
    }
    _setState(
      const RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.binding,
      ),
    );

    final identityResult = await _hardware.readIdentity();
    final serialNumber = normalizeRecordingCardSerialNumberForOwnership(
      identityResult.value?.serialNumber ?? '',
    );
    if (!identityResult.ok || serialNumber == null) {
      _fail(
        identityResult.error?.code ?? 'RECORDING_CARD_IDENTITY_READ_FAILED',
      );
      return false;
    }

    final bindResult = await _guard(
      () => _port.bind(
        serialNumber: serialNumber,
        idempotencyKey: _idempotencyKey('bind'),
        displayName: displayName,
      ),
    );
    final binding = bindResult.value;
    if (!bindResult.ok || binding == null) {
      _fail(bindResult.errorCode ?? 'RECORDING_CARD_BIND_FAILED');
      return false;
    }
    await _rememberAuthorization(serialNumber);
    _setState(
      RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.bound,
        binding: binding,
      ),
    );
    return true;
  }

  Future<bool> unbindCurrentCard({
    Future<String?> Function()? beforeCloudUnbind,
  }) async {
    if (!_authenticated) {
      _fail('RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED');
      return false;
    }
    if (_state.isLoading) return false;
    final binding = _state.binding;
    if (binding == null) {
      _fail('RECORDING_CARD_BINDING_NOT_FOUND');
      return false;
    }
    _setState(
      RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.unbinding,
        binding: binding,
        unbindPhase: beforeCloudUnbind == null
            ? RecordingCardUnbindPhase.unbindingCloud
            : RecordingCardUnbindPhase.disconnectingDevice,
      ),
    );
    if (beforeCloudUnbind != null) {
      String? deviceErrorCode;
      try {
        deviceErrorCode = await beforeCloudUnbind();
      } on Object {
        deviceErrorCode = 'RECORDING_CARD_DEVICE_DISCONNECT_FAILED';
      }
      if (deviceErrorCode != null) {
        _fail(
          deviceErrorCode,
          binding: binding,
          unbindPhase: RecordingCardUnbindPhase.failed,
        );
        return false;
      }
    }
    _setState(
      RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.unbinding,
        binding: binding,
        unbindPhase: RecordingCardUnbindPhase.unbindingCloud,
      ),
    );
    final result = await _guard(
      () => _port.unbind(
        binding: binding,
        idempotencyKey: _idempotencyKey('unbind'),
      ),
    );
    if (!result.ok || result.value != true) {
      _fail(
        result.errorCode ?? 'RECORDING_CARD_UNBIND_FAILED',
        binding: binding,
        unbindPhase: RecordingCardUnbindPhase.failed,
      );
      return false;
    }
    _setState(
      const RecordingCardCloudBindingState(
        status: RecordingCardCloudBindingStatus.unbound,
        unbindPhase: RecordingCardUnbindPhase.completed,
      ),
    );
    await _clearAuthorizationCache();
    try {
      await _onUnbound?.call();
    } on Object {
      // Cloud ownership is already released; local disconnect is best-effort.
    }
    return true;
  }

  Future<void> _rememberAuthorization(String serialNumber) async {
    try {
      await _authorizationCache.remember(serialNumber);
    } on Object {
      // The successful cloud mutation remains authoritative for this session.
    }
  }

  Future<void> _clearAuthorizationCache() async {
    try {
      await _authorizationCache.clear();
    } on Object {
      // Cache cleanup must not replace an authoritative cloud result.
    }
  }

  String? _bindingAvailabilityError() {
    final hardware = _hardware.bindingSnapshot;
    if (!hardware.connected) return 'RECORDING_CARD_ACCOUNT_BIND_NOT_CONNECTED';
    if (!hardware.recordingIdle) {
      return 'RECORDING_CARD_ACCOUNT_BIND_RECORDING_ACTIVE';
    }
    if (hardware.transferActive) {
      return 'RECORDING_CARD_ACCOUNT_BIND_TRANSFER_ACTIVE';
    }
    if (hardware.commandBusy) return 'RECORDING_CARD_ACCOUNT_BIND_BUSY';
    return null;
  }

  Future<RecordingCardBindingResult<T>> _guard<T>(
    Future<RecordingCardBindingResult<T>> Function() action,
  ) async {
    try {
      return await action();
    } on Object {
      return RecordingCardBindingResult.failure(
        'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED',
      );
    }
  }

  String _idempotencyKey(String action) {
    final nonce = List<int>.generate(
      12,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'recording-card-$action-${_clock().toUtc().microsecondsSinceEpoch}-$nonce';
  }

  void _fail(
    String code, {
    RecordingCardCloudBinding? binding,
    RecordingCardUnbindPhase unbindPhase = RecordingCardUnbindPhase.idle,
  }) {
    _setState(
      RecordingCardCloudBindingState(
        status: _isUnavailable(code)
            ? RecordingCardCloudBindingStatus.unavailable
            : RecordingCardCloudBindingStatus.failure,
        binding: binding,
        errorCode: code,
        unbindPhase: unbindPhase,
      ),
    );
  }

  bool _isUnavailable(String code) =>
      code == 'API_BASE_URL_UNCONFIGURED' ||
      code.endsWith('_UNAVAILABLE') ||
      code.endsWith('_AUTH_REQUIRED');

  void _setState(RecordingCardCloudBindingState value) {
    _state = value;
    notifyListeners();
  }
}
