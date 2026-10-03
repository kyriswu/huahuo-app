import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_account_binding_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_account_binding.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_detail_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('Mobile V5 device detail reuses one connected state owner', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    const channel = MethodChannel('recording_card_detail_golden');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final operationLog = <String>[];
    var refreshDeviceInfoCalls = 0;
    var failRefresh = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        operationLog.add('scanFiles');
        if (failRefresh) throw PlatformException(code: 'TEST_SCAN_FAILED');
        return <String, Object?>{'files': const <Object?>[]};
      }
      if (call.method == 'refreshDeviceInfo') {
        refreshDeviceInfoCalls += 1;
        operationLog.add('refreshDeviceInfo');
        if (failRefresh) throw PlatformException(code: 'TEST_REFRESH_FAILED');
        return <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'displayName': '无限花火录音卡',
            'safeDeviceFingerprint': 'detail-golden-card',
            'batteryPercent': 78,
            'deviceModel': 'HH-REC-01',
            'firmwareVersion': '1.0.8',
            'recordingFormat': 'm4a',
          },
          'recordingInfo': <String, Object?>{'state': 'idle'},
          'files': const <Object?>[],
        };
      }
      return null;
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final database = AppDatabase();
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const UnavailableFileStoragePort(),
    );
    final libraryController = RecordingLibraryController(
      repository: repository,
      nativeFilePort: const UnavailableNativeFilePort(),
    );
    final cardController = RecordingCardController(
      port: port,
      localRecordingRepository: repository,
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    final cloudController = RecordingCardCloudBindingController(
      port: _DetailCloudBindingPort(),
      hardware: const _DisconnectedCloudBindingHardware(),
      authenticated: true,
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
          recordingCardControllerProvider.overrideWith((ref) => cardController),
          recordingLibraryControllerProvider.overrideWith(
            (ref) => libraryController,
          ),
          recordingCardCloudBindingControllerProvider.overrideWith(
            (ref) => cloudController,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: const V3RecordingCardDetailPage(),
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
          'displayName': '无限花火录音卡',
          'safeDeviceFingerprint': 'detail-golden-card',
          'batteryPercent': 78,
          'storageUsedBytes': 1288490189,
          'storageFreeBytes': 7301444403,
          'storageTotalBytes': 8589934592,
          'deviceModel': 'HH-REC-01',
          'firmwareVersion': '1.0.8',
          'recordingFormat': 'm4a',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await _pumpUntilDetailSettles(
      tester,
      cardController: cardController,
      libraryController: libraryController,
    );
    await precacheFigmaFixtureImages(tester);
    expect(find.text('无限花火录音卡'), findsWidgets);
    expect(refreshDeviceInfoCalls, 0);
    operationLog.clear();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-detail-refresh')),
    );
    await tester.pumpAndSettle();
    expect(operationLog, <String>['refreshDeviceInfo', 'scanFiles']);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_detail_connected.png'),
    );

    failRefresh = true;
    await tester.tap(
      find.byKey(const ValueKey('recording-card-detail-refresh')),
    );
    await tester.pumpAndSettle();
    expect(find.text('设备详情刷新失败，请点击右上角刷新重试。'), findsOneWidget);

    failRefresh = false;
    await cardController.refreshFiles(
      reason: RecordingCardFileRefreshReason.appResumed,
    );
    await tester.pump();
    expect(find.text('设备详情刷新失败，请点击右上角刷新重试。'), findsNothing);

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
          'batteryPercent': 78,
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    expect(find.text('未连接'), findsWidgets);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/recording_card_detail_disconnected.png'),
    );
  });

  testWidgets('device detail projects native snapshot and local storage totals', (
    tester,
  ) async {
    final database = AppDatabase();
    final recordings = <RecordingLibraryItem>[
      _recording(
        displayName: '用户重命名的访谈录音.m4a',
        deviceFilename: '20260601080000',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      _recording(
        recordingId: 'local-detail-duplicate',
        displayName: '重命名副本.m4a',
        deviceFilename: '20260601090000',
        appPrivateUri:
            'app-private://recording-card/local-detail-duplicate.m4a',
        contentHash:
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        durationSeconds: 60,
        sizeBytes: 1024 * 1024,
      ),
      _recording(
        recordingId: 'local-detail-uri-only',
        displayName: '重命名后的临时记录.m4a',
        deviceFilename: '20260601100000',
        appPrivateUri: 'app-private://recording-card/local-detail-uri-only.m4a',
        durationSeconds: 120,
        sizeBytes: 2 * 1024 * 1024,
      ),
      _recording(
        recordingId: 'local-detail-missing',
        displayName: '已丢失的录音卡文件.m4a',
        deviceFilename: '20260601110000',
        appPrivateUri: 'app-private://recording-card/local-detail-missing.m4a',
        contentHash:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        localFileState: RecordingLocalFileState.missing,
        durationSeconds: 0,
        sizeBytes: 0,
      ),
    ];
    final dao = RecordingDao(database);
    for (final recording in recordings) {
      dao.upsertLocalRecording(recording.recordingId, recording.toRecord());
    }
    database.upsertRecord(
      LocalTableName.recordingCardDownloadedManifest,
      'detail-card-file-manifest',
      <String, Object?>{
        'device_file_id': 'card-20260714113000',
        'device_fingerprint': 'serial:SP63A03003',
        'device_filename': '20260714113000',
        'local_file_id': 'local-detail-duplicate',
        'app_private_uri':
            'app-private://recording-card/local-detail-duplicate.m4a',
        'expected_size_bytes': 2 * 1024 * 1024,
        'actual_size_bytes': 1024 * 1024,
        'duration_seconds': 60,
        'content_hash':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'local_state': 'synced',
        'downloaded_at': '2026-07-14T11:31:00Z',
        'updated_at': '2026-07-14T11:31:00Z',
      },
    );
    final libraryController = RecordingLibraryController(
      repository: LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      ),
      nativeFilePort: const UnavailableNativeFilePort(),
    );
    const channel = MethodChannel('huahuoai/recording_card_detail_projection');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var scanFilesCalls = 0;
    final deviceFiles = <Object?>[
      <String, Object?>{
        'deviceFileId': 'card-20260714103000',
        'localFileKey': 'card-20260714103000',
        'deviceFilename': '20260714103000',
        'sizeBytes': 2 * 1024 * 1024,
        'durationSeconds': 120,
        'recordedAt': '2026-07-14T10:30:00',
        'sizeConfidence': 'trusted',
        'syncState': 'deviceOnly',
      },
      <String, Object?>{
        'deviceFileId': 'card-20260714113000',
        'localFileKey': 'card-20260714113000',
        'deviceFilename': '20260714113000',
        'sizeBytes': 2 * 1024 * 1024,
        'recordedAt': '2026-07-14T11:30:00',
        'sizeConfidence': 'suspect',
        'syncState': 'synced',
        'localFileId': 'local-detail-duplicate',
        'appPrivateUri':
            'app-private://recording-card/local-detail-duplicate.m4a',
        'contentHash':
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      },
      <String, Object?>{
        'deviceFileId': 'card-20260714123000',
        'localFileKey': 'card-20260714123000',
        'deviceFilename': '20260714123000',
        'recordedAt': '2026-07-14T12:30:00',
        'syncState': 'deviceOnly',
      },
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        scanFilesCalls += 1;
        return <String, Object?>{'files': deviceFiles};
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final cardController = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: database,
        fileStorage: const _VerifiedDetailFileStorage(),
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
          recordingCardControllerProvider.overrideWith((ref) => cardController),
          recordingLibraryControllerProvider.overrideWith(
            (ref) => libraryController,
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3RecordingCardDetailPage(),
        ),
      ),
    );
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': 'FW920',
          'serialNumber': 'SP63A03003',
          'batteryPercent': 69,
          'storageUsedBytes': 1024 * 1024 * 1024,
          'storageFreeBytes': 3 * 1024 * 1024 * 1024,
          'storageTotalBytes': 4 * 1024 * 1024 * 1024,
          'deviceModel': 'FW920',
          'firmwareVersion': '1.2.3',
          'wifiFirmwareVersion': '1.0.2',
          'recordingFormat': 'm4a',
          'wifiSupported': true,
          'lastInfoRefreshedAt': '2026-07-14T10:20:00',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': deviceFiles,
      },
    });
    await tester.pump();
    await _pumpUntilDetailSettles(
      tester,
      cardController: cardController,
      libraryController: libraryController,
    );
    events.add(<String, Object?>{
      'type': 'recording_state',
      'recordingInfo': <String, Object?>{
        'state': 'paused',
        'currentFileName': '20260714123000',
      },
    });
    await tester.pump();
    expect(scanFilesCalls, 1);
    expect(
      find.byKey(const ValueKey('recording-card-detail-more')),
      findsNothing,
    );
    final deviceNameRow = find.ancestor(
      of: find.text('设备名称'),
      matching: find.byType(Row),
    );
    expect(
      tester.widget<Text>(find.text('设备名称')).style?.color,
      HuahuoV3Theme.darkTokens.muted,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: deviceNameRow, matching: find.text('FW920')),
          )
          .style
          ?.color,
      HuahuoV3Theme.darkTokens.text,
    );

    expect(find.text('69%'), findsOneWidget);
    expect(find.text('已用容量'), findsNothing);
    expect(find.text('可用容量'), findsNothing);
    expect(find.text('总容量'), findsNothing);
    expect(find.text('存储使用率'), findsNothing);
    expect(
      tester.getTopLeft(find.text('蓝牙设置')).dy,
      lessThan(tester.getTopLeft(find.text('设备信息')).dy),
    );
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('Wi-Fi 固件版本'), findsNothing);
    expect(find.text('录音格式'), findsNothing);
    expect(find.text('Wi-Fi 文件传输'), findsNothing);
    expect(find.text('刷新时间'), findsNothing);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('已连接'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('3 条'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('录音卡存储'), findsOneWidget);
    expect(find.text('3 条'), findsOneWidget);
    expect(find.text('4.0 MB（1 条大小未读取，1 条待校验）'), findsOneWidget);
    expect(find.text('3 分钟（1 条未读取）'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('已同步到本地'), matching: find.byType(Row)),
        matching: find.text('1 条'),
      ),
      findsOneWidget,
    );
    expect(find.text('2026-07-14 12:30'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('本地存储'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('本地录音'), matching: find.byType(Row)),
        matching: find.text('4 条'),
      ),
      findsOneWidget,
    );
    expect(find.text('6.0 MB'), findsOneWidget);
    expect(find.text('1 小时 33 分钟'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('绑定录音卡 SN'), findsOneWidget);
    expect(find.text('SP63A03003'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('recording-card-unbind')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('missing native metadata remains explicitly unread', (
    tester,
  ) async {
    final database = AppDatabase();
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(nativeEvents: events.stream);
    final cardController = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: database,
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
          recordingCardControllerProvider.overrideWith((ref) => cardController),
        ],
        child: const MaterialApp(home: V3RecordingCardDetailPage()),
      ),
    );
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
        'lastDeviceUpdatedAt': '2026-07-14T12:34:00',
      },
    });
    await tester.pump();

    expect(find.text('未读取'), findsWidgets);
    expect(find.text('2026-07-14 12:34'), findsNothing);
    expect(find.text('刷新时间'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('0 条'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('0 条'), findsOneWidget);
    final cardRecordingRow = find.ancestor(
      of: find.text('卡内录音'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: cardRecordingRow, matching: find.text('未连接')),
      findsOneWidget,
    );
  });

  testWidgets('detail identity shows the Bluetooth name from each connection', (
    tester,
  ) async {
    final database = AppDatabase();
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(nativeEvents: events.stream);
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const UnavailableFileStoragePort(),
    );
    final libraryController = RecordingLibraryController(
      repository: repository,
      nativeFilePort: const UnavailableNativeFilePort(),
    );
    final cardController = RecordingCardController(
      port: port,
      localRecordingRepository: repository,
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
          recordingCardControllerProvider.overrideWith((ref) => cardController),
          recordingLibraryControllerProvider.overrideWith(
            (ref) => libraryController,
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3RecordingCardDetailPage(),
        ),
      ),
    );
    await _pumpUntilDetailSettles(
      tester,
      cardController: cardController,
      libraryController: libraryController,
    );

    const nameKey = ValueKey('recording-card-detail-identity-bluetooth-name');
    const nameLabelKey = ValueKey(
      'recording-card-detail-identity-bluetooth-name-label',
    );
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '会议室录音卡',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(nameKey)).data, '会议室录音卡');
    expect(tester.widget<Text>(find.byKey(nameLabelKey)).data, '蓝牙名称');

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(nameKey)).data, '录音卡');
    expect(tester.widget<Text>(find.byKey(nameLabelKey)).data, '连接录音卡后显示蓝牙名称');

    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '访谈录音卡',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(nameKey)).data, '访谈录音卡');
    expect(find.text('会议室录音卡'), findsNothing);
  });

  testWidgets('detail page lists nearby cards and connects the selected card', (
    tester,
  ) async {
    const channel = MethodChannel('recording_card_detail_guided_connect');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'displayName': 'Huahuo FW920 A',
              'safeDeviceFingerprint': 'guided-detail-card-a',
              'isConnectable': true,
            },
            <String, Object?>{
              'displayName': 'Huahuo FW920 B',
              'safeDeviceFingerprint': 'guided-detail-card-b',
              'isConnectable': true,
            },
          ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': 'Huahuo FW920 B',
          'safeDeviceFingerprint': 'guided-detail-card-b',
        },
        'scanFiles' => <String, Object?>{'files': <Object?>[]},
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
      messenger.setMockMethodCallHandler(channel, null);
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
          theme: HuahuoV3Theme.dark(),
          home: const V3RecordingCardDetailPage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('从搜索结果中选择'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-detail-connect')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Huahuo FW920 A'), findsOneWidget);
    expect(find.text('Huahuo FW920 B'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey('recording-card-nearby-device-guided-detail-card-b'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 560));

    expect(
      calls.map((call) => call.method),
      containsAll(<String>['scanDevices', 'connect']),
    );
    final connect = calls.firstWhere((call) => call.method == 'connect');
    expect(
      (connect.arguments as Map<Object?, Object?>)['safeDeviceFingerprint'],
      'guided-detail-card-b',
    );
    expect(find.text('录音卡已连接'), findsWidgets);
  });

  testWidgets('guided connection explains when Bluetooth is powered off', (
    tester,
  ) async {
    const channel = MethodChannel('recording_card_detail_bluetooth_off');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var scanCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanDevices') {
        scanCalls += 1;
        throw PlatformException(code: 'RECORDING_CARD_BLUETOOTH_POWERED_OFF');
      }
      return null;
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
      messenger.setMockMethodCallHandler(channel, null);
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
          theme: HuahuoV3Theme.dark(),
          home: const V3RecordingCardDetailPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-detail-connect')),
    );
    await tester.pumpAndSettle();

    expect(scanCalls, 1);
    expect(find.textContaining('请先在系统设置中打开手机蓝牙'), findsWidgets);
    expect(
      find.byKey(const ValueKey('recording-card-connection-rescan')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-card-connection-rescan')),
    );
    await tester.pumpAndSettle();

    expect(scanCalls, 2);
  });

  testWidgets(
    'guided connection opens Bluetooth permission settings when blocked',
    (tester) async {
      _installGoldenViewport(tester);
      final permissions = _BlockedBluetoothPermissionsPort();
      final controller = RecordingCardController(
        port: const UnavailableRecordingCardPort(),
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const UnavailableFileStoragePort(),
        ),
        platformPermissionsPort: permissions,
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _autoSyncOverride(),
            platformPermissionsPortProvider.overrideWithValue(permissions),
            recordingCardPortProvider.overrideWithValue(
              const UnavailableRecordingCardPort(),
            ),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            builder: _goldenMediaQuery,
            home: const V3RecordingCardDetailPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-detail-connect')),
      );
      await tester.pumpAndSettle();

      expect(permissions.requestedKinds, <Set<PlatformPermissionKind>>[
        const <PlatformPermissionKind>{PlatformPermissionKind.bluetooth},
      ]);
      expect(find.textContaining('请允许应用使用蓝牙'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey('recording-card-connection-cancel')),
      );
      await tester.pumpAndSettle();
      final settingsAction = find.byKey(
        const ValueKey('recording-card-detail-open-bluetooth-settings'),
      );
      expect(settingsAction, findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/recording_card_detail_permission.png'),
      );
      await tester.tap(settingsAction);
      await tester.pumpAndSettle();

      expect(permissions.openedSettings, <_OpenedSettingsRequest>[
        const _OpenedSettingsRequest(
          kind: PlatformPermissionKind.bluetooth,
          impactAcknowledged: true,
        ),
      ]);
    },
  );

  testWidgets(
    'detail page edits a valid Bluetooth name and shows device rejection feedback',
    (tester) async {
      _installGoldenViewport(tester);
      addTearDown(tester.view.resetViewInsets);
      var compactEditor = false;
      const channel = MethodChannel('recording_card_detail_bluetooth_name');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final submittedNames = <String>[];
      var currentName = 'FW920';
      var rejectNext = false;
      Map<String, Object?> deviceState() => <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'displayName': currentName,
        'safeDeviceFingerprint': 'detail-name-card',
        'recordingFormat': 'm4a',
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'refreshDeviceInfo':
            return <String, Object?>{
              'deviceState': deviceState(),
              'recordingInfo': <String, Object?>{'state': 'idle'},
              'files': const <Object?>[],
            };
          case 'scanFiles':
            return <String, Object?>{'files': const <Object?>[]};
          case 'setBluetoothName':
            final arguments = call.arguments as Map<Object?, Object?>;
            final bluetoothName = arguments['bluetoothName'] as String;
            submittedNames.add(bluetoothName);
            if (rejectNext) {
              throw PlatformException(
                code: 'RECORDING_CARD_BLUETOOTH_NAME_REJECTED',
              );
            }
            currentName = bluetoothName;
            return deviceState();
        }
        return null;
      });
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final database = AppDatabase();
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      );
      final libraryController = RecordingLibraryController(
        repository: repository,
        nativeFilePort: const UnavailableNativeFilePort(),
      );
      final cardController = RecordingCardController(
        port: port,
        localRecordingRepository: repository,
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
            recordingCardControllerProvider.overrideWith(
              (ref) => cardController,
            ),
            recordingLibraryControllerProvider.overrideWith(
              (ref) => libraryController,
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            builder: (context, child) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  padding: const EdgeInsets.only(top: 54, bottom: 24),
                  viewPadding: const EdgeInsets.only(top: 54, bottom: 24),
                  textScaler: compactEditor
                      ? const TextScaler.linear(1.3)
                      : media.textScaler,
                ),
                child: child!,
              );
            },
            home: const V3RecordingCardDetailPage(),
          ),
        ),
      );
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': deviceState(),
          'recordingInfo': <String, Object?>{'state': 'idle'},
          'files': const <Object?>[],
        },
      });
      await _pumpUntilDetailSettles(
        tester,
        cardController: cardController,
        libraryController: libraryController,
      );

      final editButton = find.byKey(
        const ValueKey('recording-card-bluetooth-name-edit'),
      );
      await tester.scrollUntilVisible(
        editButton,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      expect(find.text('修改蓝牙名称'), findsOneWidget);
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey('recording-card-bluetooth-name-dialog-card'),
              ),
            )
            .height,
        215,
      );
      expect(find.textContaining('/ 32 字节'), findsNothing);
      expect(
        find.byKey(
          const ValueKey('recording-card-bluetooth-name-restart-note'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('recording-card-bluetooth-name-restart-note'),
              ),
            )
            .data,
        '保存后需重新启动，录音卡名称才会有效',
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/recording_card_detail_rename.png'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('recording-card-bluetooth-name-input')),
        '无限花火 A',
      );
      await tester.pump();
      expect(find.textContaining('/ 32 字节'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('recording-card-bluetooth-name-save')),
      );
      await tester.pumpAndSettle();

      expect(submittedNames, <String>['无限花火 A']);
      expect(cardController.state.snapshot.deviceState.displayName, '无限花火 A');
      expect(find.text('蓝牙名称已设置，请重启录音卡后重新连接。'), findsWidgets);

      rejectNext = true;
      await tester.tap(editButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recording-card-bluetooth-name-input')),
        '被拒绝的名称',
      );
      await tester.tap(
        find.byKey(const ValueKey('recording-card-bluetooth-name-save')),
      );
      await tester.pumpAndSettle();

      expect(submittedNames, <String>['无限花火 A', '被拒绝的名称']);
      expect(find.text('设备拒绝修改蓝牙名称，请稍后重试。'), findsOneWidget);
      expect(find.text('修改蓝牙名称'), findsOneWidget);
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey('recording-card-bluetooth-name-dialog-card'),
              ),
            )
            .height,
        236,
      );

      compactEditor = true;
      tester.view
        ..physicalSize = const Size(320, 568)
        ..viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();

      final compactInput = find.byKey(
        const ValueKey('recording-card-bluetooth-name-input'),
      );
      final compactError = find.text('设备拒绝修改蓝牙名称，请稍后重试。');
      final compactCancel = find.byKey(
        const ValueKey('recording-card-bluetooth-name-cancel'),
      );
      final compactSave = find.byKey(
        const ValueKey('recording-card-bluetooth-name-save'),
      );
      final compactActions = find.byKey(
        const ValueKey('recording-card-bluetooth-name-actions'),
      );
      expect(compactInput.hitTestable(), findsOneWidget);
      expect(compactError.hitTestable(), findsOneWidget);
      expect(compactCancel.hitTestable(), findsOneWidget);
      expect(compactSave.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(compactActions).dy, lessThanOrEqualTo(328));

      compactEditor = false;
      tester.view
        ..resetViewInsets()
        ..physicalSize = const Size(402, 874);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('recording-card-bluetooth-name-input')),
        '花' * 11,
      );
      await tester.pump();
      expect(find.textContaining('/ 32 字节'), findsNothing);
      final saveButton = find.descendant(
        of: find.byKey(const ValueKey('recording-card-bluetooth-name-save')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
      expect(submittedNames, <String>['无限花火 A', '被拒绝的名称']);
    },
  );

  testWidgets('connected card unbinds local firmware before cloud account', (
    tester,
  ) async {
    _installGoldenViewport(tester);
    const channel = MethodChannel('recording_card_detail_unbind');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var unbindCalls = 0;
    bool? deleteDeviceFiles;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'unbindDevice') {
        unbindCalls += 1;
        deleteDeviceFiles =
            (call.arguments as Map<Object?, Object?>)['deleteDeviceFiles']
                as bool?;
        return <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        };
      }
      if (call.method == 'refreshDeviceInfo') {
        throw PlatformException(code: 'TEST_REFRESH_FAILED');
      }
      return null;
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final cardController = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    final cloudPort = _DetailCloudBindingPort(
      onUnbind: () => expect(unbindCalls, 1),
    );
    final cloudController = RecordingCardCloudBindingController(
      port: cloudPort,
      hardware: const _DisconnectedCloudBindingHardware(),
      authenticated: true,
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
          recordingCardControllerProvider.overrideWith((ref) => cardController),
          recordingCardCloudBindingControllerProvider.overrideWith(
            (ref) => cloudController,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: _goldenMediaQuery,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const V3RecordingCardDetailPage(),
                  ),
                ),
                child: const Text('打开设备详情'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设备详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': <String, Object?>{
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': 'FW920',
          'safeDeviceFingerprint': 'detail-unbind-connected-card',
        },
        'recordingInfo': <String, Object?>{'state': 'idle'},
        'files': const <Object?>[],
      },
    });
    await tester.pump();
    await cardController.refreshDeviceInfo();
    await tester.pump();
    expect(cardController.state.status, RecordingCardControllerStatus.error);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('recording-card-unbind')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('解除录音卡绑定？'), findsOneWidget);
    expect(find.textContaining('将先断开 FW920 的本机连接'), findsOneWidget);
    expect(find.textContaining('与当前账号的云端绑定'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-unbind-clear-device-files')),
      findsNothing,
    );
    expect(find.textContaining('不会删除录音卡内文件'), findsOneWidget);
    expect(unbindCalls, 0);
    expect(cloudPort.unbindCalls, 0);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-unbind-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(unbindCalls, 1);
    expect(deleteDeviceFiles, isFalse);
    expect(cloudPort.unbindCalls, 1);
    expect(find.text('打开设备详情'), findsOneWidget);
  });

  testWidgets('disconnected detail completes remaining cloud unbind only', (
    tester,
  ) async {
    final cloudPort = _DetailCloudBindingPort();
    final cloudController = RecordingCardCloudBindingController(
      port: cloudPort,
      hardware: const _DisconnectedCloudBindingHardware(),
      authenticated: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _autoSyncOverride(),
          recordingCardCloudBindingControllerProvider.overrideWith(
            (ref) => cloudController,
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const V3RecordingCardDetailPage(),
                  ),
                ),
                child: const Text('打开云端解绑详情'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开云端解绑详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
    );
    await tester.pump();

    expect(find.text('解除录音卡绑定'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('recording-card-unbind')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.textContaining('可通过已绑定 SN 的账号记录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-card-unbind')));
    await tester.pumpAndSettle();
    expect(find.text('解除录音卡绑定？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-unbind-clear-device-files')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-unbind-confirm')),
    );
    await tester.pumpAndSettle();
    expect(cloudPort.unbindCalls, 1);
    expect(find.text('打开云端解绑详情'), findsOneWidget);
  });

  testWidgets('unbind never offers firmware file deletion', (tester) async {
    final scenario = _DetailUnbindScenario();
    await _pumpDetailUnbindScenario(tester, scenario);

    await tester.tap(find.byKey(const ValueKey('recording-card-unbind')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recording-card-unbind-clear-device-files')),
      findsNothing,
    );
    expect(find.textContaining('不会删除录音卡内文件'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-unbind-confirm')),
    );
    await tester.pumpAndSettle();

    expect(scenario.localUnbindCalls, 1);
    expect(scenario.unbindDeleteDeviceFiles, isFalse);
    expect(scenario.cloudPort.unbindCalls, 1);
    expect(scenario.operations, <String>['local-unbind', 'account-unbind']);
  });

  testWidgets(
    'unchecked unbind preserves firmware files without file commands',
    (tester) async {
      final scenario = _DetailUnbindScenario();
      await _pumpDetailUnbindScenario(tester, scenario);

      await _confirmDetailUnbind(tester);

      expect(scenario.unbindDeleteDeviceFiles, isFalse);
      expect(scenario.operations, <String>['local-unbind', 'account-unbind']);
    },
  );

  testWidgets('local firmware unbind failure preserves account binding', (
    tester,
  ) async {
    final scenario = _DetailUnbindScenario(
      localUnbindErrorCode: 'TEST_LOCAL_UNBIND_FAILED',
    );
    await _pumpDetailUnbindScenario(tester, scenario);

    await _confirmDetailUnbind(tester);

    expect(scenario.localUnbindCalls, 1);
    expect(scenario.cloudPort.unbindCalls, 0);
    expect(find.textContaining('账号绑定已保留'), findsOneWidget);
  });

  testWidgets('cloud failure remains retryable after local unbind succeeds', (
    tester,
  ) async {
    final scenario = _DetailUnbindScenario(
      cloudUnbindErrorCode: 'TEST_CLOUD_UNBIND_FAILED',
    );
    await _pumpDetailUnbindScenario(tester, scenario);

    await _confirmDetailUnbind(tester);

    expect(scenario.operations, <String>['local-unbind', 'account-unbind']);
    expect(find.textContaining('设备连接已断开，但账号解绑失败'), findsOneWidget);
    expect(scenario.cloudPort.binding, isNotNull);
  });

  testWidgets('recording activity disables unified unbind', (tester) async {
    final scenario = _DetailUnbindScenario(recordingActive: true);
    await _pumpDetailUnbindScenario(tester, scenario);

    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('recording-card-unbind')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('录音进行中，请结束录音后再解除绑定。'), findsOneWidget);
  });
}

var _detailUnbindScenarioId = 0;

final class _DetailUnbindScenario {
  _DetailUnbindScenario({
    this.localUnbindErrorCode,
    this.cloudUnbindErrorCode,
    this.recordingActive = false,
  }) : cloudPort = _DetailCloudBindingPort(
         unbindErrorCode: cloudUnbindErrorCode,
       ) {
    cloudPort.onOperation = () => operations.add('account-unbind');
  }

  final String? localUnbindErrorCode;
  final String? cloudUnbindErrorCode;
  final bool recordingActive;
  final List<String> operations = <String>[];
  final _DetailCloudBindingPort cloudPort;
  var localUnbindCalls = 0;
  var unbindDeleteDeviceFiles = false;
}

Future<void> _pumpDetailUnbindScenario(
  WidgetTester tester,
  _DetailUnbindScenario scenario,
) async {
  final channel = MethodChannel(
    'recording_card_detail_unbind_scenario_${_detailUnbindScenarioId++}',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'refreshDeviceInfo':
        throw PlatformException(code: 'TEST_REFRESH_UNAVAILABLE');
      case 'unbindDevice':
        scenario.operations.add('local-unbind');
        scenario.localUnbindCalls += 1;
        scenario.unbindDeleteDeviceFiles =
            (call.arguments as Map<Object?, Object?>)['deleteDeviceFiles']
                as bool;
        final errorCode = scenario.localUnbindErrorCode;
        if (errorCode != null) throw PlatformException(code: errorCode);
        return <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        };
    }
    return null;
  });
  final events = StreamController<Object?>(sync: true);
  final port = MethodChannelRecordingCardPort(
    methodChannel: channel,
    nativeEvents: events.stream,
  );
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: const UnavailableFileStoragePort(),
  );
  final cardController = RecordingCardController(
    port: port,
    localRecordingRepository: repository,
    platformPermissionsPort: const _GrantedPermissionsPort(),
    bindingTokenProvider: _bindingToken,
    requiresBluetoothPermissionRequest: () => false,
  );
  final cloudController = RecordingCardCloudBindingController(
    port: scenario.cloudPort,
    hardware: const _DisconnectedCloudBindingHardware(),
    authenticated: true,
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
        recordingCardControllerProvider.overrideWith((ref) => cardController),
        recordingCardCloudBindingControllerProvider.overrideWith(
          (ref) => cloudController,
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const V3RecordingCardDetailPage(),
                ),
              ),
              child: const Text('打开解绑场景'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开解绑场景'));
  await tester.pump();
  events.add(<String, Object?>{
    'type': 'runtime_snapshot',
    'snapshot': <String, Object?>{
      'deviceState': <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'displayName': 'FW920',
        'safeDeviceFingerprint': 'detail-unbind-scenario-card',
      },
      'recordingInfo': <String, Object?>{
        'state': scenario.recordingActive ? 'recording' : 'idle',
      },
      'files': const <Object?>[],
    },
  });
  await tester.pump(const Duration(milliseconds: 300));
  scenario.operations.clear();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('recording-card-unbind')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(
    find.byKey(const ValueKey('recording-card-unbind')),
  );
  await tester.pump();
}

Future<void> _confirmDetailUnbind(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('recording-card-unbind')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('recording-card-unbind-confirm')));
  await tester.pumpAndSettle();
}

final class _DetailCloudBindingPort implements RecordingCardCloudBindingPort {
  _DetailCloudBindingPort({this.onUnbind, this.unbindErrorCode});

  final VoidCallback? onUnbind;
  final String? unbindErrorCode;
  VoidCallback? onOperation;
  RecordingCardCloudBinding? binding = RecordingCardCloudBinding(
    bindingId: 'binding-detail-1',
    deviceId: 'device-detail-1',
    serialNumberMasked: '****3003',
    displayName: 'FW920',
    status: 'active',
    bindingGeneration: 1,
    boundAt: DateTime.utc(2026, 8, 22),
  );
  var unbindCalls = 0;

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  }) async => RecordingCardBindingResult.failure('TEST_BIND_UNAVAILABLE');

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding?>>
  currentBinding() async => RecordingCardBindingResult.success(binding);

  @override
  Future<RecordingCardBindingResult<bool>> unbind({
    required RecordingCardCloudBinding binding,
    required String idempotencyKey,
  }) async {
    onOperation?.call();
    onUnbind?.call();
    unbindCalls += 1;
    final errorCode = unbindErrorCode;
    if (errorCode != null) {
      return RecordingCardBindingResult.failure(errorCode);
    }
    this.binding = null;
    return RecordingCardBindingResult.success(true);
  }
}

final class _DisconnectedCloudBindingHardware
    implements RecordingCardCloudBindingHardwarePort {
  const _DisconnectedCloudBindingHardware();

  @override
  RecordingCardBindingHardwareSnapshot get bindingSnapshot =>
      const RecordingCardBindingHardwareSnapshot(
        connected: false,
        recordingIdle: true,
        transferActive: false,
        commandBusy: false,
      );

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>> readIdentity() {
    return Future<RecordingCardResult<RecordingCardOwnershipIdentity>>.value(
      RecordingCardResult<RecordingCardOwnershipIdentity>.failure(
        recordingCardFailure('TEST_IDENTITY_UNAVAILABLE', 'Unavailable'),
      ),
    );
  }
}

RecordingLibraryItem _recording({
  String recordingId = 'local-detail-1',
  String displayName = '访谈录音.m4a',
  String deviceFilename = '20260714103000',
  String appPrivateUri = 'app-private://recording-card/local-detail-1.m4a',
  String? contentHash,
  RecordingLocalFileState localFileState = RecordingLocalFileState.ready,
  int durationSeconds = 5400,
  int sizeBytes = 3 * 1024 * 1024,
}) {
  return RecordingLibraryItem(
    recordingId: recordingId,
    source: RecordingLibrarySource.device,
    displayName: displayName,
    format: RecordingLibraryFormat.m4a,
    localFileState: localFileState,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: durationSeconds,
    sizeBytes: sizeBytes,
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: DateTime(2026, 7, 14, 9),
    updatedAt: DateTime(2026, 7, 14, 9),
    deviceFilename: deviceFilename,
    appPrivateUri: appPrivateUri,
    contentHash: contentHash,
  );
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
      persistence: _DetailAutoSyncPersistence(),
      actions: _DetailAutoSyncActions(),
    );
  });
}

final class _DetailAutoSyncPersistence
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

final class _DetailAutoSyncActions extends ChangeNotifier
    implements RecordingCardAutoSyncActions {
  @override
  bool get hasActiveTransfer => false;

  @override
  RecordingCardRuntimeSnapshot get snapshot =>
      RecordingCardRuntimeSnapshot.initial();

  @override
  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  ) => throw UnsupportedError('No download in detail projection tests');

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false}) =>
      throw UnsupportedError('No scan in detail projection tests');
}

Future<void> _pumpUntilDetailSettles(
  WidgetTester tester, {
  required RecordingCardController cardController,
  required RecordingLibraryController libraryController,
}) async {
  var settledFrames = 0;
  for (var attempt = 0; attempt < 50; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 20));
    final cardStatus = cardController.state.status;
    final cardBusy =
        cardStatus == RecordingCardControllerStatus.refreshing ||
        cardStatus == RecordingCardControllerStatus.scanning;
    final libraryBusy =
        libraryController.state.status ==
        RecordingLibraryControllerStatus.loading;
    if (!cardBusy && !libraryBusy) {
      settledFrames += 1;
      if (settledFrames >= 2) return;
    } else {
      settledFrames = 0;
    }
  }
  throw TestFailure(
    'Device detail did not settle: card=${cardController.state.status}, '
    'library=${libraryController.state.status}',
  );
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
      const <PlatformPermissionSummary>[],
    );
  }
}

final class _VerifiedDetailFileStorage extends UnavailableFileStoragePort {
  const _VerifiedDetailFileStorage();

  static const _uri = 'app-private://recording-card/local-detail-duplicate.m4a';
  static const _hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) {
    if (appPrivateUri != _uri) return super.statPrivateAudio(appPrivateUri);
    return Future<FileStorageResult<PrivateAudioFileStat>>.value(
      FileStorageResult<PrivateAudioFileStat>.success(
        const PrivateAudioFileStat(
          exists: true,
          sizeBytes: 1024 * 1024,
          durationSeconds: 60,
        ),
      ),
    );
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(String appPrivateUri) {
    if (appPrivateUri != _uri) return super.hashPrivateAudio(appPrivateUri);
    return Future<FileStorageResult<String>>.value(
      FileStorageResult<String>.success(_hash),
    );
  }
}

final class _BlockedBluetoothPermissionsPort
    implements PlatformPermissionsPort {
  final requestedKinds = <Set<PlatformPermissionKind>>[];
  final openedSettings = <_OpenedSettingsRequest>[];

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
      const <PlatformPermissionSummary>[
        PlatformPermissionSummary(
          kind: PlatformPermissionKind.bluetooth,
          status: PlatformPermissionStatus.blocked,
          impactText: '连接录音卡需要蓝牙权限。',
          recoveryAction: PermissionRecoveryAction.openSettings,
        ),
      ],
    );
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    openedSettings.add(
      _OpenedSettingsRequest(
        kind: kind,
        impactAcknowledged: impactAcknowledged,
      ),
    );
    return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
      PermissionSettingsOpenReceipt(
        kind: kind,
        opened: true,
        impactText: buildPermissionImpactText(kind),
      ),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    requestedKinds.add(Set<PlatformPermissionKind>.of(kinds));
    return loadPermissionSummary();
  }
}

final class _OpenedSettingsRequest {
  const _OpenedSettingsRequest({
    required this.kind,
    required this.impactAcknowledged,
  });

  final PlatformPermissionKind kind;
  final bool impactAcknowledged;

  @override
  bool operator ==(Object other) {
    return other is _OpenedSettingsRequest &&
        other.kind == kind &&
        other.impactAcknowledged == impactAcknowledged;
  }

  @override
  int get hashCode => Object.hash(kind, impactAcknowledged);
}
