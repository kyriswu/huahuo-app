import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_quick_wifi_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_connection_history.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_ui_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_control_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_live_page.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('management hero opens details from non-command surfaces only', (
    tester,
  ) async {
    final controller = RecordingCardController(
      port: const UnavailableRecordingCardPort(),
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    final router = GoRouter(
      initialLocation: '/recording-card',
      routes: [
        GoRoute(
          path: '/recording-card',
          builder: (context, state) => const V3RecordingCardLivePage(),
        ),
        GoRoute(
          path: '/v3/recording-card/details',
          builder: (context, state) => const Scaffold(body: Text('录音卡设备详情页')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      tester.getSize(
        find.byKey(const ValueKey('recording-card-connection-target')),
      ),
      const Size(62, 48),
    );

    await tester.tap(find.byKey(const ValueKey('recording-card-device-icon')));
    await tester.pumpAndSettle();
    expect(find.text('录音卡设备详情页'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump();
    expect(find.text('录音卡设备详情页'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('V3 recording-card page exposes native driver failures', (
    tester,
  ) async {
    const permissionsChannel = MethodChannel('huahuoai/platform_permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(permissionsChannel, null),
    );
    messenger.setMockMethodCallHandler(permissionsChannel, (call) async {
      if (call.method == 'getPermissionStatuses' ||
          call.method == 'requestPermissions') {
        return const <String, Object?>{
          'bluetooth': 'granted',
          'nearby_devices': 'granted',
          'microphone': 'denied',
          'media_library': 'denied',
          'notification': 'denied',
          'local_network': 'unavailable',
        };
      }
      return null;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardPortProvider.overrideWithValue(
            const UnavailableRecordingCardPort(),
          ),
        ],
        child: const MaterialApp(home: V3RecordingCardLivePage()),
      ),
    );

    final deviceImage = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('recording-card-device-icon')),
        matching: find.byType(Image),
      ),
    );
    expect(
      (deviceImage.image as AssetImage).assetName,
      'assets/images/recording_card_device.png',
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('当前设备暂不支持录音卡连接。'), findsWidgets);
    expect(find.text('已连接'), findsNothing);
    expect(find.text('连接录音卡'), findsNothing);
    expect(find.text('已用存储'), findsNothing);
    expect(find.text('固件版本'), findsNothing);
  });

  testWidgets(
    'paused Wi-Fi recovery keeps BLE connect enabled and only real connect spins',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_paused_reconnect');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final connectResult = Completer<Object?>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'scanDevices' => <String, Object?>{
            'devices': <Object?>[
              <String, Object?>{
                'displayName': 'Huahuo FW920',
                'safeDeviceFingerprint': 'card-fingerprint-paused',
                'isConnectable': true,
              },
            ],
          },
          'connect' => connectResult.future,
          'readRecordingState' => <String, Object?>{'state': 'idle'},
          'scanFiles' => <String, Object?>{'files': <Object?>[]},
          _ => null,
        };
      });
      final database = AppDatabase();
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      );
      final recordedAt = DateTime.utc(2026, 7, 16, 9);
      repository.upsertRecordingCardWifiBatchItem(
        transferId: 'wifi-paused-reconnect-0',
        batchId: 'wifi-paused-reconnect',
        deviceFingerprint: 'card-fingerprint-paused',
        deviceIdentity: 'card-fingerprint-paused',
        deviceFileId: 'card-file-paused',
        deviceFilename: '20260716090000.m4a',
        localFileKey: 'card-paused',
        itemOrder: 0,
        expectedSizeBytes: 4096,
        attemptCount: 1,
        batchStage: RecordingCardWifiBatchState.transferring.name,
        stage: RecordingCardWifiBatchItemState.queued.name,
        idempotencyKey:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        createdAt: recordedAt,
        updatedAt: recordedAt,
        fileFormat: RecordingCardFileFormat.m4a.name,
      );
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: repository,
        platformPermissionsPort: const _GrantedPermissionsPort(),
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(() async {
        if (!connectResult.isCompleted) {
          connectResult.completeError(StateError('test disposed'));
        }
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _autoSyncOverride(),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3RecordingCardLivePage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.paused,
      );
      final connectButton = find.byKey(
        const ValueKey('recording-card-connect'),
      );
      expect(tester.widget<FilledButton>(connectButton).onPressed, isNotNull);
      expect(
        find.descendant(
          of: connectButton,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: connectButton, matching: find.text('连接')),
        findsOneWidget,
      );

      await tester.tap(connectButton);
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey(
            'recording-card-nearby-device-card-fingerprint-paused',
          ),
        ),
      );
      await tester.pump();

      expect(calls, contains('connect'));
      expect(tester.widget<FilledButton>(connectButton).onPressed, isNull);
      expect(
        find.descendant(
          of: connectButton,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      connectResult.complete(<String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'safeDeviceFingerprint': 'card-fingerprint-paused',
        'displayName': 'Huahuo FW920',
      });
      await tester.pump(const Duration(milliseconds: 560));

      expect(
        find.byKey(const ValueKey('recording-card-disconnect')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'quick Wi-Fi transfer queues every verified unsynchronized card file',
    (tester) async {
      final events = StreamController<Object?>(sync: true);
      const channel = MethodChannel('recording_card_quick_wifi_transfer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final wifiPreparation = Completer<Object?>();
      var prepareCalls = 0;
      final nativeCalls = <String>[];
      final scannedFiles = <Object?>[
        _managementFile(
          id: 'quick-newer',
          name: '20260903090000.m4a',
          recordedAt: '2026-09-03T09:00:00Z',
          durationSeconds: 61,
          synced: false,
        ),
        _managementFile(
          id: 'quick-older',
          name: '20260902080000.m4a',
          recordedAt: '2026-09-02T08:00:00Z',
          durationSeconds: 32,
          synced: false,
        ),
      ];
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        return switch (call.method) {
          'scanFiles' => <String, Object?>{'files': scannedFiles},
          'connect' => <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'card-quick-transfer',
            'serialNumber': 'SP63A03003',
            'displayName': 'Huahuo FW920',
            'wifiSupported': true,
          },
          'beginWifiAttempt' => true,
          'prepareWifiSession' => () {
            prepareCalls += 1;
            return wifiPreparation.future;
          }(),
          _ => null,
        };
      });
      final database = AppDatabase();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: LocalRecordingRepository(
          database: database,
          fileStorage: const UnavailableFileStoragePort(),
          accountScope: 'quick-card-account',
          requireAuthenticatedAccount: true,
        ),
        platformPermissionsPort: const _GrantedPermissionsPort(),
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (!wifiPreparation.isCompleted) {
          wifiPreparation.completeError(StateError('test disposed'));
        }
        await port.dispose();
        await events.close();
      });
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'card-quick-transfer',
            'serialNumber': 'SP63A03003',
            'displayName': 'Huahuo FW920',
            'wifiSupported': true,
          },
          'recordingInfo': <String, Object?>{'state': 'idle'},
          'files': const <Object?>[],
        },
      });

      final syncStore = RecordingCardAutoSyncStore(
        database: database,
        accountScope: 'quick-card-account',
      );
      syncStore.savePreferences(
        const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
      );
      final autoSync = RecordingCardAutoSyncCoordinator(
        persistence: syncStore,
        actions: ControllerRecordingCardAutoSyncActions(controller),
      );
      final quickWifi = RecordingCardQuickWifiCoordinator(
        runtime: ControllerRecordingCardQuickWifiRuntime(
          controller: controller,
          automaticSync: autoSync,
          candidateResolver: (directory, _) => directory,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authenticatedRecordingUserScopeProvider.overrideWith(
              (ref) => 'quick-card-account',
            ),
            recordingCardAutoSyncStoreProvider.overrideWithValue(syncStore),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => autoSync,
            ),
            recordingCardQuickWifiCoordinatorProvider.overrideWith(
              (ref) => quickWifi,
            ),
            appDatabaseProvider.overrideWith((ref) => database),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3RecordingCardLivePage()),
        ),
      );
      await tester.pump();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      final quickTransfer = find.byKey(
        const ValueKey('recording-card-quick-wifi-transfer'),
      );
      final syncPanel = find.byKey(
        const ValueKey('recording-card-auto-sync-progress'),
      );
      expect(controller.state.fileCatalog.isReady, isTrue);
      expect(syncPanel, findsOneWidget);
      expect(
        find.descendant(of: syncPanel, matching: quickTransfer),
        findsOneWidget,
      );
      expect(find.text('快速传输'), findsOneWidget);
      expect(tester.widget<TextButton>(quickTransfer).onPressed, isNotNull);

      await tester.tap(quickTransfer);
      await tester.pump();

      expect(
        find.byKey(const ValueKey('recording-card-wifi-flow-sheet')),
        findsOneWidget,
      );
      expect(wifiPreparation.isCompleted, isFalse);

      for (var frame = 0; frame < 20 && prepareCalls == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        prepareCalls,
        1,
        reason:
            'phase=${quickWifi.state.phase.name} '
            'failure=${quickWifi.state.failureCode} '
            'targets=${quickWifi.state.targetFileKeys} calls=$nativeCalls',
      );
      expect(
        controller.state.wifiBatch!.items
            .map((item) => item.file.localFileKey)
            .toSet(),
        <String>{'local-quick-newer', 'local-quick-older'},
      );
      wifiPreparation.completeError(
        PlatformException(code: 'TEST_WIFI_PREPARATION_STOPPED'),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('management hero guides a powered-off phone Bluetooth state', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    const channel = MethodChannel('recording_card_management_bluetooth_off');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'scanDevices' => throw PlatformException(
          code: 'RECORDING_CARD_BLUETOOTH_POWERED_OFF',
        ),
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardPortProvider.overrideWithValue(port),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: const V3RecordingCardLivePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.byKey(
        const ValueKey('recording-card-management-bluetooth-off-guidance'),
      ),
      findsOneWidget,
    );
    expect(find.text('蓝牙已关闭'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('请先在控制中心或系统设置中打开手机蓝牙'), findsWidgets);
    expect(find.text('连接异常'), findsNothing);
    expect(find.text('RECORDING_CARD_BLUETOOTH_POWERED_OFF'), findsNothing);
    expect(find.text('设备连接失败，请重新连接'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_dialog_bluetooth_off.png'),
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-cancel')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_bluetooth_off.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Mobile V5 discovery states use the production dialog', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    const channel = MethodChannel('recording_card_management_golden_states');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final scan = Completer<Object?>();
    final connect = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'readRecordingState' => <String, Object?>{'state': 'idle'},
        'scanDevices' => scan.future,
        'connect' => connect.future,
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      connectionHistory: InMemoryRecordingCardConnectionHistory(
        initialEntries: <RecordingCardConnectionHistoryEntry>[
          RecordingCardConnectionHistoryEntry(
            displayName: '无限花火录音卡',
            safeDeviceFingerprint: 'remembered-golden-card',
            lastConnectedAt: DateTime.utc(2026, 8, 22, 9),
          ),
        ],
      ),
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      if (!scan.isCompleted) {
        scan.complete(<String, Object?>{'devices': <Object?>[]});
      }
      if (!connect.isCompleted) {
        connect.completeError(StateError('golden fixture disposed'));
      }
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardPortProvider.overrideWithValue(port),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: const V3RecordingCardLivePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在搜索录音卡'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_searching.png'),
    );

    scan.complete(<String, Object?>{
      'devices': <Object?>[
        <String, Object?>{
          'displayName': '无限花火录音卡',
          'safeDeviceFingerprint': 'remembered-golden-card',
          'serialNumber': 'SP63A03003',
          'rssi': -47,
          'isConnectable': true,
        },
        <String, Object?>{
          'displayName': '附近录音卡',
          'safeDeviceFingerprint': 'nearby-golden-card',
          'serialNumber': 'SP63A03004',
          'rssi': -61,
          'isConnectable': true,
        },
      ],
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('请选择要连接的录音卡'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_device_list.png'),
    );

    await tester.tap(
      find.byKey(
        const ValueKey('recording-card-nearby-device-nearby-golden-card'),
      ),
    );
    await tester.pump();
    expect(find.text('正在连接录音卡'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_device_connecting.png'),
    );

    connect.complete(<String, Object?>{
      'connectionState': 'ble_ready',
      'connectionStage': 'connected',
      'displayName': '附近录音卡',
      'safeDeviceFingerprint': 'nearby-golden-card',
      'serialNumber': 'SP63A03004',
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('录音卡已连接'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_device_connected.png'),
    );
    await tester.pump(const Duration(milliseconds: 520));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Mobile V5 empty discovery keeps retry and cancel active', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    const channel = MethodChannel('recording_card_management_empty_golden');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'readRecordingState' => <String, Object?>{'state': 'idle'},
        'scanDevices' => <String, Object?>{'devices': <Object?>[]},
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardPortProvider.overrideWithValue(port),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: const V3RecordingCardLivePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('未发现附近的录音卡'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('recording-card-connection-rescan')),
          )
          .onPressed,
      isNotNull,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_search_empty.png'),
    );
  });

  testWidgets(
    'management page excludes card inventory and prioritizes device activity',
    (tester) async {
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(nativeEvents: events.stream);
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const UnavailableFileStoragePort(),
        ),
        platformPermissionsPort: const _GrantedPermissionsPort(),
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(() async {
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardPortProvider.overrideWithValue(port),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: V3RecordingCardLivePage(
              initialTab: V3RecordingLibraryTab.device,
              focusLibrary: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'card-fingerprint-1',
            'displayName': 'Huahuo FW920',
          },
          'recordingInfo': <String, Object?>{
            'state': 'paused',
            'durationSeconds': 90,
          },
          'files': <Object?>[
            <String, Object?>{
              'deviceFileId': 'card-file-live',
              'localFileKey': 'card-live',
              'deviceFilename': '20260712090000',
              'sizeBytes': 4096,
              'sizeConfidence': 'suspect',
              'durationSeconds': 321,
              'syncState': 'deviceOnly',
            },
          ],
        },
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('00:01:30'), findsNothing);
      expect(find.text('已暂停'), findsNothing);
      expect(find.text('录音已暂停'), findsOneWidget);
      expect(find.text('卡内文件 1 条'), findsNothing);
      expect(find.text('已同步 0 条'), findsNothing);
      expect(
        find.byKey(const ValueKey('recording-card-import-local')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-card-live-status')),
        findsNothing,
      );
      expect(find.text('20260712090000'), findsNothing);
      expect(find.textContaining('07-12 09:00'), findsNothing);
      expect(find.text('未同步'), findsNothing);
      expect(find.textContaining('录音卡 ·'), findsNothing);
      expect(find.text('05:21'), findsNothing);
      expect(
        find.byKey(const ValueKey('recording-library-search')),
        findsNothing,
      );
      expect(find.text('导入本地文件'), findsNothing);
      expect(find.text('筛选'), findsNothing);
      expect(find.text('全部时间'), findsNothing);
      expect(find.text('可播放'), findsNothing);

      events.add(<String, Object?>{
        'type': 'transfer_progress',
        'progress': <String, Object?>{
          'localFileKey': 'card-live',
          'receivedBytes': 1024,
          'totalBytes': 4096,
          'correlationId': 'transfer-widget-test',
        },
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('已接收 1.0 KB / 4.0 KB'), findsNothing);
      expect(
        find.byKey(const ValueKey('recording-card-cancel-transfer-card-live')),
        findsNothing,
      );

      events.add(<String, Object?>{
        'type': 'recording_state',
        'recordingInfo': <String, Object?>{'state': 'recording'},
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('录音中'), findsOneWidget);
      expect(find.text('文件传输中'), findsNothing);
    },
  );

  testWidgets('Mobile V5 connected inventory states use one page owner', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    final events = StreamController<Object?>(sync: true);
    const channel = MethodChannel('recording_card_management_inventory_golden');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late final MethodChannelRecordingCardPort port;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        return <String, Object?>{
          'files': port.runtimeSnapshot.files
              .map((file) => file.toChannelMap())
              .toList(growable: false),
        };
      }
      return null;
    });
    port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardPortProvider.overrideWithValue(port),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: const V3RecordingCardLivePage(
            initialTab: V3RecordingLibraryTab.device,
          ),
        ),
      ),
    );
    await tester.pump();
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'card-management-golden',
          'displayName': '无限花火录音卡',
          'batteryPercent': 78,
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': _managementFiles(),
      },
    });
    await tester.pump();
    await precacheFigmaFixtureImages(tester);
    expect(find.text('客户访谈 2026-08-20'), findsOneWidget);
    expect(find.text('临时记录 08-14'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_management_connected.png'),
    );

    await tester.tap(find.byTooltip('同步设置'));
    await tester.pumpAndSettle();
    expect(find.text('同步设置'), findsWidgets);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_device_operations.png'),
    );
    Navigator.of(tester.element(find.text('同步设置').last)).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pumpAndSettle();
    expect(find.text('断开录音卡连接？'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_disconnect_confirm.png'),
    );
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'card-management-golden',
          'displayName': '无限花火录音卡',
          'batteryPercent': 78,
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    expect(find.textContaining('还没有录音文件'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_management_empty.png'),
    );

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'card-management-golden',
          'displayName': '无限花火录音卡',
          'batteryPercent': 78,
          'wifiSupported': true,
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': _managementFiles().take(7).toList(growable: false),
      },
    });
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recording-card-toggle-batch')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('选择录音'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_batch_unselected.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-card-device-row-local-interview')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_batch_selected.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-card-device-batch-delete')),
    );
    await tester.pumpAndSettle();
    expect(find.text('永久删除录音卡文件？'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_batch_delete_confirm.png'),
    );
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('recording-card-device-select-all')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 7 项'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_batch_select_all.png'),
    );
  });

  testWidgets(
    'management settings retain auto sync controls without file commands',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [_autoSyncOverride()],
          child: const MaterialApp(home: V3RecordingCardLivePage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('recording-library-search')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-library-inline-import')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-card-import-local')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
        findsOneWidget,
      );
      expect(find.text('批量管理'), findsOneWidget);
      final settings = find.byKey(
        const ValueKey<String>('recording-card-management-sync-settings'),
      );
      expect(settings, findsOneWidget);

      await tester.tap(settings);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(
          const ValueKey<String>('recording-card-sync-settings-sheet'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-card-import-local')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
        findsOneWidget,
      );
      final autoSync = find.byKey(
        const ValueKey('recording-card-auto-sync-switch'),
      );
      final autoTranscription = find.byKey(
        const ValueKey('recording-card-auto-transcription-switch'),
      );
      expect(autoSync, findsOneWidget);
      expect(autoTranscription, findsOneWidget);
      expect(tester.widget<SwitchListTile>(autoSync).value, isTrue);
      expect(tester.widget<SwitchListTile>(autoTranscription).value, isFalse);
      await tester.tap(autoTranscription);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(autoTranscription).value, isTrue);
      await tester.tap(autoSync);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(autoSync).value, isFalse);
      expect(
        tester.widget<SwitchListTile>(autoTranscription).onChanged,
        isNull,
      );
      expect(find.text('自动同步已关闭'), findsOneWidget);
      expect(find.text('读取设备文件'), findsNothing);
      expect(find.text('刷新设备状态'), findsNothing);
      expect(find.text('搜索附近设备'), findsNothing);
      expect(find.text('扫描附近设备'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('recording-card-management-menu-wifi-transfer'),
        ),
        findsNothing,
      );
      expect(find.text('云端账号绑定'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('recording-card-management-menu-account-binding'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem),
          matching: find.text('批量管理'),
        ),
        findsNothing,
      );
      Navigator.of(tester.element(autoSync)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
      );
      await tester.pump();
      expect(settings, findsNothing);
      expect(
        find.byKey(const ValueKey('recording-card-device-wifi-batch-download')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-card-device-batch-delete')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('recording-card-device-batch-delete')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'dedicated control page owns state timer commands and status-only resume',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_control_page');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = StreamController<Object?>(sync: true);
      var scanCalls = 0;
      var readCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'scanFiles':
            scanCalls += 1;
            return <String, Object?>{'files': const <Object?>[]};
          case 'readRecordingState':
            readCalls += 1;
            return <String, Object?>{'state': 'paused', 'durationSeconds': 90};
          case 'resumeRecording':
            return <String, Object?>{
              'state': 'recording',
              'durationSeconds': 90,
            };
          case 'stopRecording':
            return <String, Object?>{'state': 'idle', 'durationSeconds': 0};
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await events.close();
      });
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      addTearDown(port.dispose);
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const UnavailableFileStoragePort(),
        ),
        platformPermissionsPort: const _GrantedPermissionsPort(),
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => false,
      );
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'card-control-fingerprint',
            'displayName': 'Huahuo FW920',
          },
          'recordingInfo': <String, Object?>{
            'state': 'paused',
            'durationSeconds': 90,
          },
          'files': const <Object?>[],
        },
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _autoSyncOverride(),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3RecordingCardControlPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('00:01:30'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('结束'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('recording-card-control-disconnect')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-card-open-management')),
        findsOneWidget,
      );
      expect(find.textContaining('卡内文件'), findsNothing);
      expect(find.textContaining('已同步'), findsNothing);
      expect(scanCalls, 0);

      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-pause-resume')),
      );
      await tester.pump();
      expect(find.text('录音中'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      final elapsedFinder = find.byKey(
        const ValueKey('recording-card-control-elapsed'),
      );
      final beforeTick = tester.widget<Text>(elapsedFinder).data!;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        _clockSeconds(tester.widget<Text>(elapsedFinder).data!),
        greaterThan(_clockSeconds(beforeTick)),
      );

      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-stop')),
      );
      await tester.pumpAndSettle();
      expect(find.text('待机'), findsOneWidget);
      expect(find.text('00:00:00'), findsOneWidget);

      final readsBeforeResume = readCalls;
      final scansBeforeResume = scanCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(readCalls, readsBeforeResume);
      expect(scanCalls, scansBeforeResume);
    },
  );

  testWidgets('connection scans once while visibility events and menu do not', (
    tester,
  ) async {
    const channel = MethodChannel('huahuoai/recording_card_lifecycle_refresh');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'readRecordingState' => <String, Object?>{'state': 'idle'},
        'scanFiles' => <String, Object?>{'files': <Object?>[]},
        'prepareWifiSession' => <String, Object?>{
          'ssid': 'FW920_TEST',
          'password': 'test-pass',
        },
        'cancelWifiSession' => true,
        _ => null,
      };
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3RecordingCardLivePage(),
        ),
      ),
    );
    await tester.pump();
    events.add(<String, Object?>{
      'type': 'connection_state',
      'deviceState': <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'safeDeviceFingerprint': 'card-fingerprint-lifecycle',
        'displayName': 'Huahuo FW920',
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(calls.where((call) => call == 'scanFiles'), hasLength(1));

    calls.clear();
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('刷新设备状态'), findsNothing);
    expect(find.text('搜索附近设备'), findsNothing);
    expect(find.text('读取设备文件'), findsNothing);
    Navigator.of(
      tester.element(
        find.byKey(const ValueKey('recording-card-auto-sync-switch')),
      ),
    ).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-target')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(calls.where((call) => call == 'scanFiles'), isEmpty);

    calls.clear();
    final pageContext = tester.element(find.byType(V3RecordingCardLivePage));
    unawaited(
      Navigator.of(pageContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('设备详情')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    Navigator.of(tester.element(find.text('设备详情'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 20));
    expect(calls.where((call) => call == 'scanFiles'), isEmpty);

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('读取设备文件'), findsNothing);
    expect(find.text('刷新设备状态'), findsNothing);
    expect(find.text('搜索附近设备'), findsNothing);
    expect(calls, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Map<String, Object?> _managementFile({
  required String id,
  required String name,
  required String recordedAt,
  required int durationSeconds,
  int sizeBytes = 4096,
  bool synced = true,
}) {
  return <String, Object?>{
    'deviceFileId': 'device-$id',
    'localFileKey': 'local-$id',
    'deviceFilename': name,
    'sizeBytes': sizeBytes,
    'sizeConfidence': 'verified',
    'durationSeconds': durationSeconds,
    'recordedAt': recordedAt,
    'syncState': synced ? 'synced' : 'deviceOnly',
    if (synced) 'localFileId': 'verified-$id',
    if (synced) 'appPrivateUri': 'app-private://recording-card/$id',
  };
}

List<Object?> _managementFiles() {
  const mib = 1024 * 1024;
  return <Object?>[
    _managementFile(
      id: 'interview',
      name: '客户访谈 2026-08-20.wav',
      recordedAt: '2026-08-20T09:32:00Z',
      durationSeconds: 38,
      sizeBytes: 32 * mib + 512 * 1024,
      synced: false,
    ),
    _managementFile(
      id: 'summary',
      name: '访谈纪要.m4a',
      recordedAt: '2026-08-19T18:20:00Z',
      durationSeconds: 766,
      sizeBytes: 26 * mib,
    ),
    _managementFile(
      id: 'review-0819',
      name: '产品复盘 08-19.wav',
      recordedAt: '2026-08-19T14:09:00Z',
      durationSeconds: 291,
      sizeBytes: 29 * mib + 410 * 1024,
    ),
    _managementFile(
      id: 'idea-0818',
      name: '灵感随记 08-18.m4a',
      recordedAt: '2026-08-18T21:06:00Z',
      durationSeconds: 82,
      sizeBytes: 22 * mib + 819 * 1024,
    ),
    _managementFile(
      id: 'requirements',
      name: '客户需求讨论.wav',
      recordedAt: '2026-08-17T16:40:00Z',
      durationSeconds: 1575,
      sizeBytes: 33 * mib,
    ),
    _managementFile(
      id: 'standup-0816',
      name: '团队周会 08-16.m4a',
      recordedAt: '2026-08-16T10:00:00Z',
      durationSeconds: 2883,
      sizeBytes: 25 * mib + 205 * 1024,
    ),
    _managementFile(
      id: 'project-0815',
      name: '项目复盘 08-15.wav',
      recordedAt: '2026-08-15T19:26:00Z',
      durationSeconds: 1110,
      sizeBytes: 19 * mib + 512 * 1024,
    ),
    _managementFile(
      id: 'temporary-0814',
      name: '临时记录 08-14.m4a',
      recordedAt: '2026-08-14T08:12:00Z',
      durationSeconds: 42,
      sizeBytes: 8 * mib,
    ),
  ];
}

void _installGoldenViewport(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _goldenMediaQuery(BuildContext context, Widget? child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      padding: const EdgeInsets.only(top: 54, bottom: 24),
      viewPadding: const EdgeInsets.only(top: 54, bottom: 24),
    ),
    child: child!,
  );
}

Future<String> _bindingToken() async => '0123456789abcdef0123456789abcdef';

Override _autoSyncOverride() {
  return recordingCardAutoSyncCoordinatorProvider.overrideWith((ref) {
    return RecordingCardAutoSyncCoordinator(
      persistence: _LivePageAutoSyncPersistence(),
      actions: _LivePageAutoSyncActions(),
    );
  });
}

final class _LivePageAutoSyncPersistence
    implements RecordingCardAutoSyncPersistencePort {
  RecordingCardAutoSyncPreferences _preferences =
      const RecordingCardAutoSyncPreferences();

  @override
  RecordingCardAutoSyncPreferences loadPreferences() => _preferences;

  @override
  List<RecordingCardAutoSyncTask> loadTasks() =>
      const <RecordingCardAutoSyncTask>[];

  @override
  void savePreferences(RecordingCardAutoSyncPreferences preferences) {
    _preferences = preferences;
  }

  @override
  void saveTask(RecordingCardAutoSyncTask task) {}
}

final class _LivePageAutoSyncActions extends ChangeNotifier
    implements RecordingCardAutoSyncActions {
  @override
  bool get hasActiveTransfer => false;

  @override
  RecordingCardRuntimeSnapshot get snapshot =>
      RecordingCardRuntimeSnapshot.initial();

  @override
  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  ) => throw UnsupportedError('No download in management menu tests');

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false}) =>
      throw UnsupportedError('No scan in management menu tests');
}

int _clockSeconds(String value) {
  final parts = value.split(':').map(int.parse).toList(growable: false);
  return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

final class _GrantedPermissionsPort implements PlatformPermissionsPort {
  const _GrantedPermissionsPort();

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      const <PlatformPermissionSummary>[],
    );
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
      PermissionSettingsOpenReceipt(
        kind: kind,
        opened: impactAcknowledged,
        impactText: buildPermissionImpactText(kind),
      ),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      const <PlatformPermissionSummary>[
        PlatformPermissionSummary(
          kind: PlatformPermissionKind.bluetooth,
          status: PlatformPermissionStatus.granted,
          impactText: '',
          recoveryAction: PermissionRecoveryAction.none,
        ),
      ],
    );
  }
}
