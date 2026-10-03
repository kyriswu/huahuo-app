import '../../../core/api/api_envelope.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/native/recording_card_native_port.dart';

final class RecordingCardPermissionCoordinator {
  const RecordingCardPermissionCoordinator({
    required this.platformPermissionsPort,
    required this.requiresBluetoothPermissionRequest,
    required this.requiresLocalNetworkPermissionRequest,
  });

  final PlatformPermissionsPort platformPermissionsPort;
  final bool Function() requiresBluetoothPermissionRequest;
  final bool Function() requiresLocalNetworkPermissionRequest;

  Future<AppFailure?> requestBluetoothAccess() {
    return _request(
      requiredByPlatform: requiresBluetoothPermissionRequest,
      kind: PlatformPermissionKind.bluetooth,
      deniedFailure: const AppFailure(
        code: 'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED',
        category: AppFailureCategory.permission,
        message: 'Bluetooth permission is required to connect a recording card',
        userMessageKey:
            'recordingCard.error.RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED',
        isRetryable: true,
        recoveryActions: <String>['retry', 'open_settings'],
      ),
    );
  }

  Future<AppFailure?> requestLocalNetworkAccess() {
    return _request(
      requiredByPlatform: requiresLocalNetworkPermissionRequest,
      kind: PlatformPermissionKind.localNetwork,
      deniedFailure: const AppFailure(
        code: 'RECORDING_CARD_WIFI_PERMISSION_REQUIRED',
        category: AppFailureCategory.permission,
        message:
            'Nearby Wi-Fi permission is required for recording-card transfer',
        userMessageKey:
            'recordingCard.error.RECORDING_CARD_WIFI_PERMISSION_REQUIRED',
        isRetryable: true,
        recoveryActions: <String>['retry', 'open_settings'],
      ),
    );
  }

  Future<AppFailure?> _request({
    required bool Function() requiredByPlatform,
    required PlatformPermissionKind kind,
    required AppFailure deniedFailure,
  }) async {
    if (!requiredByPlatform()) return null;
    final result = await platformPermissionsPort.requestPermissions(
      <PlatformPermissionKind>{kind},
    );
    if (!result.ok || result.value == null) {
      return result.error ??
          recordingCardFailure(
            'PLATFORM_PERMISSION_REQUEST_FAILED',
            'Recording-card controller operation failed',
          );
    }
    final granted = result.value!.any(
      (summary) =>
          summary.kind == kind &&
          summary.status == PlatformPermissionStatus.granted,
    );
    return granted ? null : deniedFailure;
  }
}
