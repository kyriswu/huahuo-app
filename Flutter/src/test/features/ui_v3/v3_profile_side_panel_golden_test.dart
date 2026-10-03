import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_metrics_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/user_profile_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_metrics_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_profile_side_panel.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M11 profile drawer covers all curated recording states', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = _sessionStore();
    final profile = UserProfileController(
      port: const UnavailableUserProfilePort(),
      initialSession: session.state,
    );
    final events = StreamController<Object?>(sync: true);
    final nativePort = MethodChannelRecordingCardPort(
      methodChannel: const MethodChannel('huahuoai/profile_drawer_golden'),
      nativeEvents: events.stream,
      clock: () => DateTime(2026, 8, 22, 9),
    );
    final recordingCard = RecordingCardController(
      port: nativePort,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
      requiresBluetoothPermissionRequest: () => false,
      clock: () => DateTime(2026, 8, 22, 9),
    );
    final positioning = DeepPositioningController(
      PersistentDeepPositioningMockRepository(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'm11-profile-drawer-golden',
        seedResult: DeepPositioningResult(
          markdown: '## 当前定位报告',
          savedAt: DateTime.utc(2026, 8, 22, 9),
          initialCompletedAt: DateTime.utc(2026, 8, 1, 9),
        ),
      ),
    );
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => showV3ProfileSidePanel(context),
              child: const Text('open-profile'),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/:rest',
          builder: (context, state) => const Scaffold(body: Text('目标页')),
        ),
        GoRoute(
          path: '/v3/profile/:section',
          builder: (context, state) => const Scaffold(body: Text('目标页')),
        ),
        GoRoute(
          path: '/v3/workbench/:section',
          builder: (context, state) => const Scaffold(body: Text('目标页')),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await nativePort.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => session),
          userProfileControllerProvider.overrideWith((ref) => profile),
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(includeDemoFixtures: false),
          ),
          noteMetricsRepositoryProvider.overrideWithValue(
            const _GoldenMetricsRepository(),
          ),
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
          recordingCardControllerProvider.overrideWith((ref) => recordingCard),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 54, bottom: 24),
              viewPadding: const EdgeInsets.only(top: 54, bottom: 24),
            ),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();

    expect(find.text('002测试'), findsOneWidget);
    expect(find.text('188****0002'), findsOneWidget);
    expect(find.text('会员与额度'), findsNothing);
    expect(find.text('帮助与反馈'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('资产新增'), findsOneWidget);
    expect(find.text('本周新增 18 条'), findsOneWidget);
    expect(find.textContaining('本月新增'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-asset-growth-line')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-asset-period-week')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-asset-period-month')),
      findsOneWidget,
    );
    await _golden(tester, 'profile_drawer_week_disconnected.png');

    await tester.tap(find.byKey(const ValueKey('profile-asset-period-month')));
    await tester.pumpAndSettle();
    expect(find.text('本月新增 30 条'), findsOneWidget);
    await _golden(tester, 'profile_drawer_month_disconnected.png');

    await tester.tap(find.byKey(const ValueKey('profile-asset-period-week')));
    await tester.pumpAndSettle();
    expect(find.text('本周新增 18 条'), findsOneWidget);
    events.add(_connectionEvent('connecting'));
    await tester.pump();
    expect(find.text('连接中'), findsOneWidget);
    await _golden(tester, 'profile_drawer_connecting.png');

    events.add(_connectionEvent('ble_ready', stage: 'connected'));
    await tester.pump();
    expect(find.text('已连接'), findsOneWidget);
    await _golden(tester, 'profile_drawer_connected.png');

    events.add(_recordingEvent('recording', revision: 1));
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    await _golden(tester, 'profile_drawer_recording.png');

    events.add(_recordingEvent('paused', revision: 2));
    await tester.pump();
    expect(find.text('继续'), findsOneWidget);
    await _golden(tester, 'profile_drawer_paused.png');
  });
}

Future<void> _golden(WidgetTester tester, String fileName) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('goldens/$fileName'),
);

Map<String, Object?> _connectionEvent(String state, {String? stage}) =>
    <String, Object?>{
      'type': 'connection_state',
      'connectionState': state,
      'connectionStage': stage ?? state,
      'displayName': '无限花火录音卡',
      'safeDeviceFingerprint': 'profile-drawer-golden-card',
    };

Map<String, Object?> _recordingEvent(String state, {required int revision}) =>
    <String, Object?>{
      'type': 'recording_state',
      'state': state,
      'durationSeconds': 0,
      'revision': revision,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
    };

SessionStore _sessionStore() {
  final store = SessionStore(
    secureTokenStore: SecureTokenStore(
      driver: _TokenDriver(
        const SecureTokenCredential(
          username: 'access-token',
          password: 'refresh-token', // secret-scan: allow
        ),
      ),
    ),
  );
  store.refreshUserStatus(
    status: const SessionUserStatus(
      user: SessionUser(
        userId: 'm11-profile-user',
        maskedPhoneNumber: '188****0002',
        displayName: '002测试',
      ),
      workspace: SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'm11-profile-workspace',
      ),
    ),
    updatedAt: DateTime.utc(2026, 8, 22, 9),
  );
  return store;
}

final class _TokenDriver implements SecureTokenDriver {
  _TokenDriver(this.credential);

  SecureTokenCredential? credential;

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    credential = SecureTokenCredential(username: username, password: password);
    return true;
  }

  @override
  bool clear({required String service}) {
    credential = null;
    return true;
  }
}

final class _GoldenMetricsRepository implements NoteMetricsRepository {
  const _GoldenMetricsRepository();

  @override
  Future<WorkspaceNoteMetricsPage> load({
    required int limit,
    String? cursor,
  }) async {
    const recentCounts = <int>[0, 1, 5, 0, 4, 8, 10];
    return WorkspaceNoteMetricsPage(
      schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
      metricId: 'new_note_count',
      timezone: 'Asia/Shanghai',
      asOf: DateTime.utc(2026, 8, 22, 4),
      coverage: WorkspaceNoteMetricsCoverage(
        startAt: DateTime.utc(2026, 7, 23),
        startDate: '2026-07-23',
        completeFromDate: '2026-07-23',
        currentDate: '2026-08-22',
        historyComplete: true,
      ),
      days: List<WorkspaceNoteMetricDay>.generate(31, (offset) {
        final date = DateTime.utc(2026, 8, 22).subtract(Duration(days: offset));
        return WorkspaceNoteMetricDay(
          date:
              '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
          count: offset < recentCounts.length
              ? recentCounts[offset]
              : offset == 7
              ? 2
              : 0,
          complete: true,
        );
      }),
      hasMore: false,
      nextCursor: '',
    );
  }
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
  loadPermissionSummary() async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async => PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
    PermissionSettingsOpenReceipt(
      kind: kind,
      opened: impactAcknowledged,
      impactText: buildPermissionImpactText(kind),
    ),
  );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );
}
