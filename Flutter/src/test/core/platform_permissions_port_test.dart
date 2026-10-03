import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformPermissionsPort contract', () {
    test('requests Bluetooth and parses the post-request status map', () async {
      const channel = MethodChannel('huahuoai/platform_permissions_contract');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestPermissions');
        expect(call.arguments, <String, Object?>{
          'kinds': <String>['bluetooth'],
        });
        return _statusMap(bluetooth: 'granted');
      });
      const port = MethodChannelPlatformPermissionsPort(channel: channel);

      final result = await port.requestPermissions(
        const <PlatformPermissionKind>{PlatformPermissionKind.bluetooth},
      );

      expect(result.ok, isTrue);
      final bluetooth = result.value!.singleWhere(
        (row) => row.kind == PlatformPermissionKind.bluetooth,
      );
      expect(bluetooth.status, PlatformPermissionStatus.granted);
    });

    test(
      'fails closed when the request result omits the requested kind',
      () async {
        const channel = MethodChannel(
          'huahuoai/platform_permissions_contract_malformed',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          return const <String, Object?>{'microphone': 'granted'};
        });
        const port = MethodChannelPlatformPermissionsPort(channel: channel);

        final result = await port.requestPermissions(
          const <PlatformPermissionKind>{PlatformPermissionKind.bluetooth},
        );

        expect(result.ok, isFalse);
        expect(
          result.error?.code,
          'PLATFORM_PERMISSION_REQUEST_MALFORMED_PAYLOAD',
        );
      },
    );

    test('requests only local-network permission for Wi-Fi handoff', () async {
      const channel = MethodChannel(
        'huahuoai/platform_permissions_local_network_contract',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestPermissions');
        expect(call.arguments, <String, Object?>{
          'kinds': <String>['local_network'],
        });
        return _statusMap(bluetooth: 'granted', localNetwork: 'granted');
      });
      const port = MethodChannelPlatformPermissionsPort(channel: channel);

      final result = await port.requestPermissions(
        const <PlatformPermissionKind>{PlatformPermissionKind.localNetwork},
      );

      expect(result.ok, isTrue);
      expect(
        result.value!
            .singleWhere(
              (row) => row.kind == PlatformPermissionKind.localNetwork,
            )
            .status,
        PlatformPermissionStatus.granted,
      );
    });

    test(
      'requests Android Bluetooth activation and maps cancellation',
      () async {
        const channel = MethodChannel(
          'huahuoai/platform_permissions_bluetooth_activation_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestBluetoothActivation');
          return 'cancelled';
        });
        const port = MethodChannelPlatformPermissionsPort(
          channel: channel,
          isAndroid: true,
        );

        final result = await port.requestBluetoothActivation();

        expect(result.ok, isTrue);
        expect(result.value, BluetoothActivationResult.cancelled);
      },
    );

    test(
      'opens Android legacy location settings through typed target',
      () async {
        const channel = MethodChannel(
          'huahuoai/platform_permissions_bluetooth_settings_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openBluetoothSettings');
          expect(call.arguments, <String, Object?>{
            'target': 'location_services',
          });
          return true;
        });
        const port = MethodChannelPlatformPermissionsPort(
          channel: channel,
          isAndroid: true,
        );

        final result = await port.openBluetoothSettings(
          BluetoothSettingsTarget.locationServices,
        );

        expect(result.ok, isTrue);
        expect(result.value?.opened, isTrue);
        expect(result.value?.target, BluetoothSettingsTarget.locationServices);
      },
    );

    test('maps native permission states to truthful recovery actions', () {
      final rows = buildPermissionSummaryRows(
        const <PlatformPermissionKind, PlatformPermissionStatus>{
          PlatformPermissionKind.microphone:
              PlatformPermissionStatus.notDetermined,
          PlatformPermissionKind.bluetooth:
              PlatformPermissionStatus.notDetermined,
          PlatformPermissionKind.nearbyDevices:
              PlatformPermissionStatus.notDetermined,
          PlatformPermissionKind.notification:
              PlatformPermissionStatus.notDetermined,
          PlatformPermissionKind.camera: PlatformPermissionStatus.denied,
          PlatformPermissionKind.localNetwork:
              PlatformPermissionStatus.systemManaged,
          PlatformPermissionKind.mediaLibrary: PlatformPermissionStatus.blocked,
        },
      );

      expect(
        rows
            .singleWhere((row) => row.kind == PlatformPermissionKind.microphone)
            .recoveryAction,
        PermissionRecoveryAction.request,
      );
      expect(
        rows
            .singleWhere((row) => row.kind == PlatformPermissionKind.bluetooth)
            .recoveryAction,
        PermissionRecoveryAction.request,
      );
      expect(
        rows
            .singleWhere(
              (row) => row.kind == PlatformPermissionKind.nearbyDevices,
            )
            .recoveryAction,
        PermissionRecoveryAction.request,
      );
      expect(
        rows
            .singleWhere(
              (row) => row.kind == PlatformPermissionKind.notification,
            )
            .recoveryAction,
        PermissionRecoveryAction.request,
      );
      expect(
        rows
            .singleWhere((row) => row.kind == PlatformPermissionKind.camera)
            .recoveryAction,
        PermissionRecoveryAction.request,
      );
      expect(
        rows
            .singleWhere(
              (row) => row.kind == PlatformPermissionKind.localNetwork,
            )
            .recoveryAction,
        PermissionRecoveryAction.openSettings,
      );
      expect(
        rows
            .singleWhere(
              (row) => row.kind == PlatformPermissionKind.mediaLibrary,
            )
            .recoveryAction,
        PermissionRecoveryAction.openSettings,
      );
    });
  });
}

Map<String, Object?> _statusMap({
  required String bluetooth,
  String localNetwork = 'unavailable',
}) {
  return <String, Object?>{
    'bluetooth': bluetooth,
    'nearby_devices': bluetooth,
    'microphone': 'denied',
    'camera': 'denied',
    'media_library': 'denied',
    'notification': 'denied',
    'local_network': localNetwork,
  };
}
