import 'dart:io';

import 'package:flutter/services.dart';

import '../api/api_envelope.dart';

enum PlatformPermissionKind {
  bluetooth('bluetooth', '蓝牙'),
  nearbyDevices('nearby_devices', '附近设备'),
  microphone('microphone', '麦克风'),
  camera('camera', '相机'),
  mediaLibrary('media_library', '媒体库'),
  notification('notification', '通知'),
  localNetwork('local_network', '本地网络');

  const PlatformPermissionKind(this.wireName, this.label);

  final String wireName;
  final String label;
}

enum PlatformPermissionStatus {
  granted('granted'),
  denied('denied'),
  notDetermined('not_determined'),
  blocked('blocked'),
  systemManaged('system_managed'),
  unavailable('unavailable');

  const PlatformPermissionStatus(this.wireName);

  final String wireName;
}

enum PermissionRecoveryAction { request, openSettings, none }

enum BluetoothActivationResult { enabled, cancelled, unavailable }

enum BluetoothSettingsTarget {
  locationServices('location_services');

  const BluetoothSettingsTarget(this.wireName);

  final String wireName;
}

final class PlatformPermissionSummary {
  const PlatformPermissionSummary({
    required this.kind,
    required this.status,
    required this.impactText,
    required this.recoveryAction,
  });

  final PlatformPermissionKind kind;
  final PlatformPermissionStatus status;
  final String impactText;
  final PermissionRecoveryAction recoveryAction;
}

final class PermissionSettingsOpenReceipt {
  const PermissionSettingsOpenReceipt({
    required this.kind,
    required this.opened,
    required this.impactText,
  });

  final PlatformPermissionKind kind;
  final bool opened;
  final String impactText;
}

final class BluetoothSettingsOpenReceipt {
  const BluetoothSettingsOpenReceipt({
    required this.target,
    required this.opened,
  });

  final BluetoothSettingsTarget target;
  final bool opened;
}

final class PlatformPermissionResult<T> {
  const PlatformPermissionResult._({required this.ok, this.value, this.error});

  factory PlatformPermissionResult.success(T value) {
    return PlatformPermissionResult<T>._(ok: true, value: value);
  }

  factory PlatformPermissionResult.failure(AppFailure error) {
    return PlatformPermissionResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

abstract interface class PlatformPermissionsPort {
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary();

  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds);

  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  });

  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation();
}

abstract interface class BluetoothSettingsRecoveryPort {
  Future<PlatformPermissionResult<BluetoothSettingsOpenReceipt>>
  openBluetoothSettings(BluetoothSettingsTarget target);
}

final class MethodChannelPlatformPermissionsPort
    implements PlatformPermissionsPort, BluetoothSettingsRecoveryPort {
  const MethodChannelPlatformPermissionsPort({
    this._channel = const MethodChannel('huahuoai/platform_permissions'),
    bool? isAndroid,
  }) : _isAndroidOverride = isAndroid;

  final MethodChannel _channel;
  final bool? _isAndroidOverride;

  @override
  Future<PlatformPermissionResult<BluetoothSettingsOpenReceipt>>
  openBluetoothSettings(BluetoothSettingsTarget target) async {
    if (!(_isAndroidOverride ?? Platform.isAndroid)) {
      return PlatformPermissionResult<BluetoothSettingsOpenReceipt>.failure(
        _permissionFailure(
          code: 'PLATFORM_BLUETOOTH_SETTINGS_UNAVAILABLE',
          message: 'Bluetooth system settings are unavailable',
          retryable: false,
          metadata: <String, Object?>{'target': target.wireName},
        ),
      );
    }
    try {
      final opened =
          await _channel.invokeMethod<bool>(
            'openBluetoothSettings',
            <String, Object?>{'target': target.wireName},
          ) ??
          false;
      if (!opened) {
        return PlatformPermissionResult<BluetoothSettingsOpenReceipt>.failure(
          _permissionFailure(
            code: 'PLATFORM_BLUETOOTH_SETTINGS_NOT_OPENED',
            message: 'Bluetooth system settings were not opened',
            retryable: true,
            metadata: <String, Object?>{'target': target.wireName},
          ),
        );
      }
      return PlatformPermissionResult<BluetoothSettingsOpenReceipt>.success(
        BluetoothSettingsOpenReceipt(target: target, opened: true),
      );
    } on MissingPluginException catch (error) {
      return PlatformPermissionResult<BluetoothSettingsOpenReceipt>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_DRIVER_UNAVAILABLE',
          message: 'Platform permission driver is unavailable',
          retryable: false,
          metadata: <String, Object?>{'target': target.wireName},
          cause: error,
        ),
      );
    } on PlatformException catch (error) {
      return PlatformPermissionResult<BluetoothSettingsOpenReceipt>.failure(
        _permissionFailure(
          code:
              _safePermissionFailureCode(error.code) ??
              'PLATFORM_BLUETOOTH_SETTINGS_FAILED',
          message: 'Opening Bluetooth system settings failed',
          retryable: true,
          metadata: <String, Object?>{'target': target.wireName},
          cause: error,
        ),
      );
    }
  }

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async {
    if (!(_isAndroidOverride ?? Platform.isAndroid)) {
      return PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );
    }
    try {
      final raw = await _channel.invokeMethod<String>(
        'requestBluetoothActivation',
      );
      final value = switch (raw) {
        'enabled' => BluetoothActivationResult.enabled,
        'cancelled' => BluetoothActivationResult.cancelled,
        _ => BluetoothActivationResult.unavailable,
      };
      return PlatformPermissionResult<BluetoothActivationResult>.success(value);
    } on MissingPluginException catch (error) {
      return PlatformPermissionResult<BluetoothActivationResult>.failure(
        _permissionFailure(
          code: 'PLATFORM_BLUETOOTH_ACTIVATION_UNAVAILABLE',
          message: 'Bluetooth activation is unavailable',
          retryable: false,
          cause: error,
        ),
      );
    } on PlatformException catch (error) {
      return PlatformPermissionResult<BluetoothActivationResult>.failure(
        _permissionFailure(
          code:
              _safePermissionFailureCode(error.code) ??
              'PLATFORM_BLUETOOTH_ACTIVATION_FAILED',
          message: 'Bluetooth activation failed',
          retryable: true,
          cause: error,
        ),
      );
    }
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getPermissionStatuses',
      );
      return _summaryResultFromRaw(
        raw,
        unavailableCode: 'PLATFORM_PERMISSION_STATUS_UNAVAILABLE',
        unavailableMessage: 'Platform permission statuses are unavailable',
      );
    } on MissingPluginException catch (error) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_DRIVER_UNAVAILABLE',
          message: 'Platform permission driver is unavailable',
          retryable: false,
          cause: error,
        ),
      );
    } catch (error) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_STATUS_FAILED',
          message: 'Platform permission status query failed',
          retryable: true,
          cause: error,
        ),
      );
    }
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    if (kinds.isEmpty) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_REQUEST_INVALID',
          message: 'At least one platform permission must be requested',
          retryable: false,
        ),
      );
    }

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'requestPermissions',
        <String, Object?>{
          'kinds': kinds.map((kind) => kind.wireName).toList(growable: false),
        },
      );
      return _summaryResultFromRaw(
        raw,
        unavailableCode: 'PLATFORM_PERMISSION_REQUEST_UNAVAILABLE',
        unavailableMessage: 'Platform permission request result is unavailable',
        requiredKinds: kinds,
      );
    } on MissingPluginException catch (error) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_DRIVER_UNAVAILABLE',
          message: 'Platform permission driver is unavailable',
          retryable: false,
          cause: error,
        ),
      );
    } on PlatformException catch (error) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code:
              _safePermissionFailureCode(error.code) ??
              'PLATFORM_PERMISSION_REQUEST_FAILED',
          message: 'Platform permission request failed',
          retryable: true,
          cause: error,
        ),
      );
    } catch (error) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_REQUEST_FAILED',
          message: 'Platform permission request failed',
          retryable: true,
          cause: error,
        ),
      );
    }
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    final impactText = buildPermissionImpactText(kind);
    if (!impactAcknowledged) {
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
        _permissionFailure(
          code: 'PERMISSION_IMPACT_ACK_REQUIRED',
          message: 'Permission impact acknowledgement is required',
          retryable: false,
          metadata: <String, Object?>{'kind': kind.wireName},
        ),
      );
    }

    try {
      final opened =
          await _channel.invokeMethod<bool>(
            'openAppSettings',
            <String, Object?>{'kind': kind.wireName},
          ) ??
          false;
      if (!opened) {
        return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
          _permissionFailure(
            code: 'PLATFORM_PERMISSION_SETTINGS_NOT_OPENED',
            message: 'Platform settings were not opened',
            retryable: true,
            metadata: <String, Object?>{'kind': kind.wireName},
          ),
        );
      }
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
        PermissionSettingsOpenReceipt(
          kind: kind,
          opened: true,
          impactText: impactText,
        ),
      );
    } on MissingPluginException catch (error) {
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_DRIVER_UNAVAILABLE',
          message: 'Platform permission driver is unavailable',
          retryable: false,
          metadata: <String, Object?>{'kind': kind.wireName},
          cause: error,
        ),
      );
    } catch (error) {
      return PlatformPermissionResult<PermissionSettingsOpenReceipt>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_SETTINGS_FAILED',
          message: 'Opening platform settings failed',
          retryable: true,
          metadata: <String, Object?>{'kind': kind.wireName},
          cause: error,
        ),
      );
    }
  }

  PlatformPermissionResult<List<PlatformPermissionSummary>>
  _summaryResultFromRaw(
    Map<String, Object?>? raw, {
    required String unavailableCode,
    required String unavailableMessage,
    Set<PlatformPermissionKind> requiredKinds =
        const <PlatformPermissionKind>{},
  }) {
    if (raw == null) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: unavailableCode,
          message: unavailableMessage,
          retryable: true,
        ),
      );
    }
    if (requiredKinds.any((kind) => !raw.containsKey(kind.wireName))) {
      return PlatformPermissionResult<List<PlatformPermissionSummary>>.failure(
        _permissionFailure(
          code: 'PLATFORM_PERMISSION_REQUEST_MALFORMED_PAYLOAD',
          message: 'Platform permission request result is malformed',
          retryable: true,
        ),
      );
    }
    final statuses = <PlatformPermissionKind, PlatformPermissionStatus>{};
    for (final kind in PlatformPermissionKind.values) {
      statuses[kind] = _parseStatus(raw[kind.wireName]);
    }
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      buildPermissionSummaryRows(statuses),
    );
  }
}

List<PlatformPermissionSummary> buildPermissionSummaryRows(
  Map<PlatformPermissionKind, PlatformPermissionStatus> statuses, {
  PlatformPermissionStatus fallbackStatus =
      PlatformPermissionStatus.notDetermined,
}) {
  return List<PlatformPermissionSummary>.unmodifiable(
    PlatformPermissionKind.values.map((kind) {
      final status = statuses[kind] ?? fallbackStatus;
      return PlatformPermissionSummary(
        kind: kind,
        status: status,
        impactText: buildPermissionImpactText(kind),
        recoveryAction: _recoveryActionFor(status),
      );
    }),
  );
}

String buildPermissionImpactText(PlatformPermissionKind kind) {
  return switch (kind) {
    PlatformPermissionKind.bluetooth ||
    PlatformPermissionKind.nearbyDevices => '影响连接录音卡和同步设备录音。',
    PlatformPermissionKind.microphone => '影响工作 AI 和喂养 AI 的聊天语音输入，不会替代录音卡设备录音。',
    PlatformPermissionKind.camera => '影响拍摄图片和视频并导入记忆库。',
    PlatformPermissionKind.mediaLibrary => '影响导入本地录音，以及将图片保存到系统媒体库。',
    PlatformPermissionKind.notification => '影响系统推送提醒，不影响消息中心和红点。',
    PlatformPermissionKind.localNetwork => '影响录音卡 Wi-Fi 快传。',
  };
}

PlatformPermissionStatus _parseStatus(Object? value) {
  final text = value?.toString();
  for (final status in PlatformPermissionStatus.values) {
    if (status.wireName == text) return status;
  }
  return PlatformPermissionStatus.unavailable;
}

String? _safePermissionFailureCode(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(text)
      ? text
      : null;
}

PermissionRecoveryAction _recoveryActionFor(PlatformPermissionStatus status) {
  return switch (status) {
    PlatformPermissionStatus.notDetermined ||
    PlatformPermissionStatus.denied => PermissionRecoveryAction.request,
    PlatformPermissionStatus.blocked ||
    PlatformPermissionStatus.systemManaged =>
      PermissionRecoveryAction.openSettings,
    PlatformPermissionStatus.granted ||
    PlatformPermissionStatus.unavailable => PermissionRecoveryAction.none,
  };
}

AppFailure _permissionFailure({
  required String code,
  required String message,
  required bool retryable,
  Map<String, Object?> metadata = const <String, Object?>{},
  Object? cause,
}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.permission,
    message: message,
    userMessageKey: 'settings.permissions.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
    metadata: metadata,
    cause: cause,
  );
}
