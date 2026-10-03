import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/settings/domain/app_appearance_preset.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_history.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_history_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_detail_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures profile account and settings voiceprint entry points', (
    tester,
  ) async {
    await _launchFeed(tester);
    expect(find.bySemanticsLabel('开始聚合').hitTestable(), findsOneWidget);
    await _capture(binding, 'v8_feed_labelled_aggregation');
    final feedContext = tester.element(
      find.bySemanticsLabel('开始聚合').hitTestable(),
    );
    ProviderScope.containerOf(feedContext)
        .read(appAppearanceControllerProvider)
        .selectPreset(AppAppearancePreset.dark);
    await _settle(tester);
    await _capture(binding, 'v21_feed_ai_mark_dark');
    ProviderScope.containerOf(feedContext)
        .read(appAppearanceControllerProvider)
        .selectPreset(AppAppearancePreset.light);
    await _settle(tester);
    await _openProfile(tester);
    await _capture(binding, 'v7_profile_panel');
    expect(find.text('会员与额度'), findsNothing);
    expect(find.text('帮助与反馈'), findsNothing);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('profile-header-account-entry')),
    );
    await _settle(tester);
    expect(find.text('个人资料'), findsOneWidget);
    await _capture(binding, 'v7_account_profile');

    await _backToProfile(tester);
    await _tapProfileEntry(tester, '设置');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-preset-light')));
    await _settle(tester);
    await _capture(binding, 'v7_settings_light');
    await tester.tap(find.byKey(const ValueKey('appearance-preset-dark')));
    await _settle(tester);
    await _capture(binding, 'v7_settings_dark');
    await tester.tap(find.byKey(const ValueKey('appearance-preset-light')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('settings-text-size-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-glass-opacity-slider')),
      findsOneWidget,
    );
    expect(find.text('50%'), findsWidgets);
    for (final label in const ['80%', '90%', '100%', '110%', '120%', '130%']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-glass-opacity-slider')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await _capture(binding, 'v19_settings_glass_opacity');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-trash')),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-trash')), findsOneWidget);
    await _capture(binding, 'v7_settings_voiceprint_entry');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-version-introduction')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('settings-version-introduction')).hitTestable(),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('settings-version-release-title')),
      findsOneWidget,
    );
    await _capture(binding, 'v8_settings_version_introduction');
    await tester.tap(find.text('知道了').hitTestable());
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-voiceprint-management')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('settings-voiceprint-management')),
    );
    await _settle(tester);
    expect(find.text('声纹管理'), findsOneWidget);
    await _capture(binding, 'v7_voiceprint_management');
  });

  testWidgets('captures current knowledge and my assets roots', (tester) async {
    await _launchFeed(tester);
    await _openProfile(tester);
    await _tapProfileEntry(tester, '外部世界');
    await _settle(tester);
    expect(find.byKey(const ValueKey('knowledge-page-view')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('knowledge-tab-subscribed')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('knowledge-tab-square')), findsOneWidget);
    await _capture(binding, 'v7_knowledge_library');

    await _backToProfile(tester);
    await _tapProfileEntry(tester, '我的资产');
    await _settle(tester);
    expect(find.text('我的资产'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-assets-page-view')), findsOneWidget);
    await _capture(binding, 'v7_my_assets');
  });

  testWidgets('captures compact calendar and the two-command chat context', (
    tester,
  ) async {
    await _launchFeed(tester);
    await _openProfile(tester);
    await tester.tap(
      find.byKey(const ValueKey('profile-asset-growth-card')).hitTestable(),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('calendar-month-grid')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calendar-summary-strip')),
      findsOneWidget,
    );
    await _capture(binding, 'v20_profile_asset_calendar');
    final calendarContext = tester.element(
      find.byKey(const ValueKey('calendar-month-grid')),
    );
    ProviderScope.containerOf(calendarContext)
        .read(appAppearanceControllerProvider)
        .selectPreset(AppAppearancePreset.dark);
    await _settle(tester);
    await _capture(binding, 'v20_profile_asset_calendar_dark');
    ProviderScope.containerOf(calendarContext)
        .read(appAppearanceControllerProvider)
        .selectPreset(AppAppearancePreset.light);
    await _settle(tester);

    await tester.tap(find.byTooltip('返回').last);
    await _settle(tester);
    final panel = find.byKey(const ValueKey<String>('v3-profile-side-panel'));
    expect(panel, findsOneWidget);
    Navigator.of(tester.element(panel), rootNavigator: true).pop();
    await _settle(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('home-chat-feed')).hitTestable(),
    );
    await _settle(tester);
    expect(find.text('聊一聊'), findsOneWidget);
    await _capture(binding, 'v20_chat_glass_triad_mark');
    await tester.tap(find.byIcon(Icons.add).hitTestable());
    await _settle(tester);
    for (final label in const ['引用笔记', '拍照', '图片', '本地文件']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('引用观点'), findsNothing);
    expect(find.text('引用录音'), findsNothing);
    expect(tester.takeException(), isNull);
    await _capture(binding, 'v20_chat_mobile_v5_attachment_actions');
  });

  testWidgets('captures right add menu and unified recording card', (
    tester,
  ) async {
    const recordingCardChannel = MethodChannel('huahuoai/recording_card');
    const permissionsChannel = MethodChannel('huahuoai/platform_permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final wifiJoinRelease = Completer<void>();
    var wifiJoinRequested = false;
    messenger.setMockMethodCallHandler(recordingCardChannel, (call) async {
      switch (call.method) {
        case 'connect':
        case 'getConnectionState':
          return const <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'displayName': 'Huahuo FW920',
            'safeDeviceFingerprint': 'v7-screenshot-card',
            'batteryPercent': 82,
            'wifiSupported': true,
            'wifiFirmwareVersion': '1.0.2',
          };
        case 'refreshDeviceInfo':
          return const <String, Object?>{
            'deviceState': <String, Object?>{
              'connectionState': 'ble_ready',
              'connectionStage': 'connected',
              'displayName': 'Huahuo FW920',
              'safeDeviceFingerprint': 'v7-screenshot-card',
              'batteryPercent': 82,
              'storageTotalBytes': 8589934592,
              'storageFreeBytes': 4294967296,
              'storageUsedBytes': 4294967296,
              'firmwareVersion': '1.0.2',
              'deviceModel': 'FW920',
              'wifiSupported': true,
              'wifiFirmwareVersion': '1.0.2',
              'recordingFormat': 'm4a',
            },
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[],
            'discoveredDevices': <Object?>[],
          };
        case 'readRecordingState':
          return const <String, Object?>{'state': 'idle'};
        case 'scanFiles':
          return const <String, Object?>{
            'files': <Object?>[
              <String, Object?>{
                'deviceFileId': 'v7-wifi-file',
                'localFileKey': 'v7-wifi-file',
                'deviceFilename': '20260724103000.m4a',
                'sizeBytes': 4194304,
                'sizeConfidence': 'trusted',
                'format': 'm4a',
                'syncState': 'deviceOnly',
              },
            ],
          };
        case 'prepareWifiSession':
          return const <String, Object?>{
            'ssid': 'FW920_SCREENSHOT_FIXTURE',
            'password': 'fixture-only-password',
          };
        case 'joinWifiNetwork':
          wifiJoinRequested = true;
          await wifiJoinRelease.future;
          throw PlatformException(code: 'SCREENSHOT_WIFI_JOIN_STOP');
        case 'cancelWifiSession':
        case 'closeWifiSession':
          return const <String, Object?>{'cancelled': true};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(permissionsChannel, (call) async {
      if (call.method == 'getPermissionStatuses' ||
          call.method == 'requestPermissions') {
        return const <String, Object?>{
          'bluetooth': 'granted',
          'nearby_devices': 'granted',
          'microphone': 'granted',
          'media_library': 'granted',
          'notification': 'granted',
          'local_network': 'granted',
        };
      }
      return null;
    });
    addTearDown(() {
      if (!wifiJoinRelease.isCompleted) wifiJoinRelease.complete();
      messenger.setMockMethodCallHandler(recordingCardChannel, null);
      messenger.setMockMethodCallHandler(permissionsChannel, null);
    });

    await _launchFeed(tester);
    await tester.tap(find.bySemanticsLabel('新建').hitTestable());
    await _settle(tester);
    expect(find.text('独白'), findsOneWidget);
    expect(find.text('文字'), findsOneWidget);
    await _capture(binding, 'v7_feed_create_sheet');

    await tester.tapAt(const Offset(4, 4));
    await _settle(tester);
    await _openProfile(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile-recording-card-control-card')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.byKey(const ValueKey('profile-recording-card-connect')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-recording-card-start')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-recording-card-pause-resume')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-recording-card-stop')),
      findsOneWidget,
    );
    await _capture(binding, 'v10_profile_recording_card_control');

    await tester.tap(
      find.byKey(const ValueKey('profile-recording-card-open-management')),
    );
    await _settle(tester);
    expect(find.text('录音卡设备管理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-import-local')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-toggle-batch')),
      findsOneWidget,
    );
    final pageContext = tester.element(find.text('录音卡设备管理').first);
    final container = ProviderScope.containerOf(pageContext);
    final recordingCardPort = container.read(recordingCardPortProvider);
    final connected = await recordingCardPort.connect(
      request: const RecordingCardConnectRequest(
        displayName: 'Huahuo FW920',
        safeDeviceFingerprint: 'v7-screenshot-card',
      ),
    );
    expect(connected.ok, isTrue);
    final scanned = await recordingCardPort.scanFiles();
    expect(scanned.ok, isTrue);
    expect(scanned.value, hasLength(1));
    await _settle(tester);
    await _capture(binding, 'v7_recording_card_management');

    await tester.tap(find.byKey(const ValueKey('recording-card-toggle-batch')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('recording-card-device-selection-count')),
      findsOneWidget,
    );
    await _dismissCurrentSnack(tester);
    await _capture(binding, 'v8_recording_card_local_batch');
    await tester.tap(find.byKey(const ValueKey('recording-card-toggle-batch')));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey('recording-card-import-local')),
      findsOneWidget,
    );
    await _capture(binding, 'v7_recording_card_device_tab');

    await tester.tap(find.byKey(const ValueKey('recording-card-toggle-batch')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('recording-card-device-wifi-batch-download')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-device-batch-delete')),
      findsOneWidget,
    );
    final wifiFile = find.byKey(
      const ValueKey('recording-card-device-row-v7-wifi-file'),
    );
    await tester.ensureVisible(wifiFile);
    await tester.tap(wifiFile);
    await _settle(tester);
    expect(find.text('已选 1 条 · 4.0 MB'), findsOneWidget);
    final wifiDownload = find.byKey(
      const ValueKey('recording-card-device-wifi-batch-download'),
    );
    expect(tester.widget<FilledButton>(wifiDownload).onPressed, isNotNull);
    await _dismissCurrentSnack(tester);
    await _capture(binding, 'v8_recording_card_device_batch');

    await tester.tap(wifiDownload);
    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('recording-card-wifi-flow-sheet')),
    );
    await _waitForFinder(tester, find.textContaining('系统可能询问本地网络访问'));
    expect(wifiJoinRequested, isTrue);
    final lastWifiStep = find.byKey(
      const ValueKey('recording-card-wifi-step-finished'),
    );
    await tester.ensureVisible(lastWifiStep);
    await _settle(tester);
    for (final key in const <String>[
      'recording-card-wifi-step-open-hotspot',
      'recording-card-wifi-step-connect-hotspot',
      'recording-card-wifi-step-transfer',
      'recording-card-wifi-step-finished',
    ]) {
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
    }
    expect(find.text('FW920_SCREENSHOT_FIXTURE'), findsNothing);
    expect(find.text('fixture-only-password'), findsNothing);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-flow-error')),
      findsNothing,
    );
    await _settle(tester);
    await _capture(binding, 'v7_recording_card_wifi_transfer_steps');
    wifiJoinRelease.complete();
    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('recording-card-wifi-flow-close')),
    );
    final wifiFlowClose = find.byKey(
      const ValueKey('recording-card-wifi-flow-close'),
    );
    await tester.ensureVisible(wifiFlowClose);
    await _settle(tester);
    await tester.tap(wifiFlowClose.hitTestable());
    await _settle(tester);
    final recordingCardController = container.read(
      recordingCardControllerProvider,
    );
    await recordingCardController.cancelWifiBatch();
    recordingCardController.dismissWifiBatch();
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('recording-card-details')));
    await _settle(tester);
    expect(find.text('录音卡设备详情'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('recording-card-unbind')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await _capture(binding, 'v7_recording_card_unbind_detail');

    final unbind = find.byKey(const ValueKey('recording-card-unbind'));
    await tester.tap(unbind.hitTestable());
    await _waitForFinder(
      tester,
      find.byKey(const ValueKey('recording-card-unbind-clear-device-files')),
    );
    final cleanupOption = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('recording-card-unbind-clear-device-files')),
    );
    expect(cleanupOption.value, isFalse);
    expect(find.text('同时清空录音卡内录音文件'), findsOneWidget);
    await _capture(binding, 'v9_recording_card_unbind_dialog');
    await tester.tap(find.text('返回'));
    await _settle(tester);
  });

  testWidgets('captures recording-card detail dark-palette contrast', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardPortProvider.overrideWithValue(
            const UnavailableRecordingCardPort(),
          ),
          resolvedDeviceIdProvider.overrideWithValue('screenshot-device'),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.dark(),
          home: const V3RecordingCardDetailPage(),
        ),
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('recording-card-auto-sync-switch')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('recording-card-detail-more')),
      findsNothing,
    );
    expect(find.text('设备名称'), findsOneWidget);
    await _capture(binding, 'v18_recording_card_detail_dark_contrast');
  });

  testWidgets('captures dark creation history contrast', (tester) async {
    final history = InMemoryCreationCanvasHistoryPort();
    for (var index = 0; index < 2; index++) {
      history.upsert(
        'screenshot-user',
        CreationCanvasHistoryEntry(
          id: 'dark-history-$index',
          noteId: 'dark-history-note-$index',
          title: index == 0 ? '把复杂经验整理成方法' : '一次客户访谈复盘',
          markdown: '正文',
          documentJson: '[{"insert":"正文\\n"}]',
          documentFormatVersion:
              CreationCanvasDraft.currentDocumentFormatVersion,
          revision: index + 1,
          createdAt: DateTime.utc(2026, 7, 28, 10 + index),
          updatedAt: DateTime.utc(2026, 7, 29, 16 + index, 37),
        ),
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authenticatedUserDataScopeProvider.overrideWithValue(
            'screenshot-user',
          ),
          creationCanvasHistoryPortProvider.overrideWithValue(history),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.dark(),
          home: const V3CreationHistoryPage(),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('创作历史'), findsOneWidget);
    expect(find.text('自由创作'), findsNWidgets(2));
    await _capture(binding, 'v19_creation_history_dark');
  });

  testWidgets('captures fixed masterpiece actions and unlocked chat entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) =>
                KnowledgeLibraryController(initialNotes: _masterpieceNotes(12)),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: V3MasterpiecePage(accessMode: V3MasterpieceAccessMode.locked),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('masterpiece-more')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('masterpiece-chat-entry')),
      findsNothing,
    );
    await _capture(binding, 'v18_masterpiece_locked_fixed_action');
    await tester.tap(find.byKey(const ValueKey<String>('masterpiece-more')));
    await _settle(tester);
    expect(find.text('尚未解锁'), findsOneWidget);
    expect(find.text('等待解锁'), findsOneWidget);
    await _capture(binding, 'v18_masterpiece_locked_information');

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(
              initialNotes: _masterpieceNotes(100),
            ),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: V3MasterpiecePage(
              accessMode: V3MasterpieceAccessMode.preview,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('masterpiece-reader')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('masterpiece-chat-entry')),
      findsOneWidget,
    );
    await _capture(binding, 'v18_masterpiece_preview_chat_entry');
    await tester.tap(
      find.byKey(const ValueKey<String>('masterpiece-directory-handle')),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('masterpiece-directory')),
      findsOneWidget,
    );
    await _capture(binding, 'v25_masterpiece_directory_overlay');

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(
              initialNotes: _masterpieceNotes(100),
            ),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: V3MasterpiecePage()),
        ),
      ),
    );
    await _settle(tester);
    final moreAction = find.byKey(const ValueKey<String>('masterpiece-more'));
    expect(moreAction, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('masterpiece-chat-entry')),
      findsOneWidget,
    );
    final initialMorePosition = tester.getTopLeft(moreAction);
    await tester.drag(
      find.byKey(const ValueKey<String>('masterpiece-reader')),
      const Offset(0, -420),
    );
    await _settle(tester);
    expect(tester.getTopLeft(moreAction), initialMorePosition);
    await _capture(binding, 'v18_masterpiece_unlocked_fixed_actions');
  });
}

List<V3FeedItem> _masterpieceNotes(int count) => List<V3FeedItem>.generate(
  count,
  (index) => V3FeedItem(
    id: 'screenshot-masterpiece-note-$index',
    title: '沉淀笔记 ${index + 1}',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 1, 1).add(Duration(days: index)),
    rawBody: '第 ${index + 1} 篇完整正文，用于形成代表作。',
    summaryBody: '第 ${index + 1} 篇摘要。',
    topics: const <String>['知识与方法'],
  ),
);

Future<void> _launchFeed(WidgetTester tester) async {
  await app.main();
  await tester.pump();
  if (find.text('创作空间').hitTestable().evaluate().isNotEmpty) {
    await tester.drag(find.byType(PageView), const Offset(-360, 0));
    await tester.pump(const Duration(milliseconds: 450));
  }
  await _waitForFinder(tester, find.text('思想图谱').hitTestable());
  expect(find.text('思想图谱').hitTestable(), findsOneWidget);
  final feedContext = tester.element(find.text('思想图谱').hitTestable());
  ProviderScope.containerOf(feedContext)
      .read(appAppearanceControllerProvider)
      .selectPreset(AppAppearancePreset.light);
  await _settle(tester);
}

Future<void> _openProfile(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
  );
  await _settle(tester);
  expect(
    find.byKey(const ValueKey<String>('v3-profile-side-panel')),
    findsOneWidget,
  );
}

Future<void> _backToProfile(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回').last);
  await _settle(tester);
  final panel = find.byKey(const ValueKey<String>('v3-profile-side-panel'));
  if (panel.evaluate().isEmpty) await _openProfile(tester);
  expect(panel, findsOneWidget);
}

Future<void> _tapProfileEntry(WidgetTester tester, String label) async {
  final panel = find.byKey(const ValueKey<String>('v3-profile-side-panel'));
  final entry = find.descendant(of: panel, matching: find.text(label));
  if (entry.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      entry,
      120,
      scrollable: find
          .descendant(of: panel, matching: find.byType(Scrollable))
          .first,
    );
    await _settle(tester);
  }
  await tester.tap(entry.hitTestable());
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<void> _dismissCurrentSnack(WidgetTester tester) async {
  final pageContext = tester.element(find.text('录音卡设备管理').first);
  ScaffoldMessenger.of(pageContext).hideCurrentSnackBar();
  await _settle(tester);
}

Future<void> _waitForFinder(WidgetTester tester, Finder finder) async {
  const interval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 40; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(interval);
    await tester.pump();
  }
  expect(finder, findsWidgets);
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty);
}
