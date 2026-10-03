import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/auth/secure_token_store.dart';
import '../domain/recording_card_account_binding.dart';

final class SecureRecordingCardSnAuthorizationCache
    implements RecordingCardSnAuthorizationCachePort {
  SecureRecordingCardSnAuthorizationCache({
    required SecureTokenDriver driver,
    required String accountScope,
  }) : _driver = driver,
       _service = _serviceFor(accountScope) {
    if (accountScope.trim().isEmpty) {
      throw ArgumentError.value(
        accountScope,
        'accountScope',
        'must not be empty',
      );
    }
  }

  static const _username = 'recording-card-sn-authorization-v1';
  static const _invalidatedUsername =
      'recording-card-sn-authorization-invalidated-v1';
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

  final SecureTokenDriver _driver;
  final String _service;
  bool _invalidated = false;

  @override
  Future<bool> matches(String serialNumber) async {
    if (_invalidated) return false;
    final normalized = normalizeRecordingCardSerialNumberForOwnership(
      serialNumber,
    );
    if (normalized == null) return false;
    try {
      final credential = await _driver.read(service: _service);
      final storedDigest = credential?.password;
      if (credential?.username != _username ||
          storedDigest == null ||
          !_digestPattern.hasMatch(storedDigest)) {
        return false;
      }
      return _constantTimeEquals(storedDigest, _digest(normalized));
    } on Object {
      return false;
    }
  }

  @override
  Future<void> remember(String serialNumber) async {
    final normalized = normalizeRecordingCardSerialNumberForOwnership(
      serialNumber,
    );
    if (normalized == null) return;
    try {
      final stored = await _driver.write(
        service: _service,
        username: _username,
        password: _digest(normalized),
      );
      _invalidated = !stored;
    } on Object {
      _invalidated = true;
      // A cache-write failure only causes the next connection to revalidate.
    }
  }

  @override
  Future<void> clear() async {
    _invalidated = true;
    try {
      final cleared = await _driver.clear(service: _service);
      if (cleared) return;
      await _driver.write(
        service: _service,
        username: _invalidatedUsername,
        password: _digest('invalidated'),
      );
    } on Object {
      // Cloud ownership remains authoritative when local cleanup is unavailable.
    }
  }

  static String _digest(String serialNumber) =>
      sha256.convert(utf8.encode(serialNumber)).toString();

  static String _serviceFor(String accountScope) {
    final scopeHash = sha256
        .convert(utf8.encode(accountScope.trim()))
        .toString()
        .substring(0, 24);
    return 'huahuo.ai.recording-card.sn.$scopeHash';
  }

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }
}

final class UnavailableRecordingCardCloudBindingRepository
    implements RecordingCardCloudBindingPort {
  const UnavailableRecordingCardCloudBindingRepository({
    this.code = 'RECORDING_CARD_CLOUD_BINDING_UNAVAILABLE',
  });

  final String code;

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding?>>
  currentBinding() async => RecordingCardBindingResult.failure(code);

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  }) async => RecordingCardBindingResult.failure(code);

  @override
  Future<RecordingCardBindingResult<bool>> unbind({
    required RecordingCardCloudBinding binding,
    required String idempotencyKey,
  }) async => RecordingCardBindingResult.failure(code);
}

final class RemoteRecordingCardCloudBindingRepository
    implements RecordingCardCloudBindingPort {
  RemoteRecordingCardCloudBindingRepository(ApiClient apiClient)
    : _client = RecordingCardBindingClient(apiClient);

  final RecordingCardBindingClient _client;

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding?>>
  currentBinding() async {
    try {
      final result = await _client.currentBinding();
      final data = result.data;
      if (!result.ok || data == null) {
        return RecordingCardBindingResult.failure(
          result.error?.code ?? 'RECORDING_CARD_CLOUD_BINDING_LOAD_FAILED',
        );
      }
      return RecordingCardBindingResult.success(
        data.binding == null ? null : _binding(data.binding!),
      );
    } on FormatException {
      return RecordingCardBindingResult.failure(
        'RECORDING_CARD_CLOUD_BINDING_RESPONSE_INVALID',
      );
    } on Object {
      return RecordingCardBindingResult.failure(
        'RECORDING_CARD_CLOUD_BINDING_LOAD_FAILED',
      );
    }
  }

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  }) async {
    try {
      final result = await _client.bind(
        serialNumber: serialNumber,
        idempotencyKey: idempotencyKey,
        displayName: displayName,
      );
      final data = result.data;
      if (!result.ok || data == null) {
        return RecordingCardBindingResult.failure(
          result.error?.code ?? 'RECORDING_CARD_BIND_FAILED',
        );
      }
      return RecordingCardBindingResult.success(_binding(data.binding));
    } on FormatException {
      return RecordingCardBindingResult.failure('RECORDING_CARD_BIND_INVALID');
    } on Object {
      return RecordingCardBindingResult.failure('RECORDING_CARD_BIND_FAILED');
    }
  }

  @override
  Future<RecordingCardBindingResult<bool>> unbind({
    required RecordingCardCloudBinding binding,
    required String idempotencyKey,
  }) async {
    try {
      final result = await _client.unbind(
        deviceId: binding.deviceId,
        bindingId: binding.bindingId,
        idempotencyKey: idempotencyKey,
      );
      final data = result.data;
      if (!result.ok || data == null) {
        return RecordingCardBindingResult.failure(
          result.error?.code ?? 'RECORDING_CARD_UNBIND_FAILED',
        );
      }
      if (data.status != 'revoked' || data.resetRequired) {
        return RecordingCardBindingResult.failure(
          data.resetRequired
              ? 'RECORDING_CARD_RESET_REQUIRED'
              : 'RECORDING_CARD_UNBIND_RESPONSE_INVALID',
        );
      }
      return RecordingCardBindingResult.success(true);
    } on FormatException {
      return RecordingCardBindingResult.failure(
        'RECORDING_CARD_UNBIND_RESPONSE_INVALID',
      );
    } on Object {
      return RecordingCardBindingResult.failure('RECORDING_CARD_UNBIND_FAILED');
    }
  }
}

RecordingCardCloudBinding _binding(SharedRecordingCardDeviceBinding binding) =>
    RecordingCardCloudBinding(
      bindingId: binding.bindingId,
      deviceId: binding.deviceId,
      serialNumberMasked: binding.serialNumberMasked,
      displayName: binding.displayName,
      modelCode: binding.modelCode,
      firmwareVersion: binding.firmwareVersion,
      status: binding.status,
      bindingGeneration: binding.bindingGeneration,
      boundAt: binding.boundAt,
    );
