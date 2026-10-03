import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart'
    show resolvedDeviceIdProvider;
import 'package:huahuoai_app/app/bootstrap/asset_projection_cache_scope.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_metrics_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_metrics_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_profile_side_panel.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

void main() {
  testWidgets('profile menu uses the remote supported entry set', (
    tester,
  ) async {
    final library = KnowledgeLibraryController(
      now: () => DateTime(2026, 7, 15, 12),
      initialNotes: [
        V3FeedItem(
          id: 'profile-assets-week-a',
          title: '本周资产一',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 13, 9),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'profile-assets-week-b',
          title: '本周资产二',
          source: V3MaterialSource.monologue,
          createdAt: DateTime(2026, 7, 14, 16),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'profile-assets-month-only',
          title: '本月较早资产',
          source: V3MaterialSource.link,
          createdAt: DateTime(2026, 7, 2, 10),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'profile-assets-previous-month',
          title: '上月资产',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 6, 30, 18),
          rawBody: '正文',
        ),
      ],
    );
    final positioning = DeepPositioningController(
      const _SeedPositioningRepository(),
    );
    final noteMetrics = _NoteMetricsRepository(<WorkspaceNoteMetricsPage>[
      _newestMetricsPage(),
      _newestMetricsPage(),
    ]);
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
          path: '/v3/recording-card',
          builder: (context, state) => const Scaffold(body: Text('录音卡设备管理页')),
        ),
        GoRoute(
          path: '/v3/profile/digital-twin',
          builder: (context, state) => const Scaffold(
            key: ValueKey('digital-twin-route'),
            body: Text('数字孪生详情'),
          ),
        ),
        GoRoute(
          path: '/v3/profile/voiceprint',
          builder: (context, state) =>
              const Scaffold(body: Text('voiceprint-route')),
        ),
        GoRoute(
          path: '/v3/profile/recordings',
          builder: (context, state) =>
              const Scaffold(body: Text('recordings-route')),
        ),
        GoRoute(
          path: '/v3/profile/:section',
          builder: (context, state) => Scaffold(
            body: Text('profile-route-${state.pathParameters['section']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue(
            'profile-navigation-device',
          ),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
          noteMetricsRepositoryProvider.overrideWithValue(noteMetrics),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(find.text('日历'), findsNothing);
    expect(find.text('活跃热力图'), findsNothing);
    expect(find.textContaining('近 10 周'), findsNothing);
    expect(find.text('时间（周）'), findsNothing);
    expect(find.byKey(const ValueKey('profile-usage-line')), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-asset-growth-card')),
      findsOneWidget,
    );
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
    expect(find.textContaining('总库'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-note-metrics-period-selector')),
      findsNothing,
    );
    expect(find.text('资产新增'), findsOneWidget);
    expect(find.text('近 7 天新增 7 条'), findsOneWidget);
    expect(find.textContaining('近 30 天新增'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-asset-current-summary')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('profile-asset-period-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('逐日新增'), findsNothing);
    expect(
      tester
          .widget<V3AssetGrowthSparkline>(
            find.byKey(const ValueKey('profile-asset-growth-line')),
          )
          .values,
      <int>[1, 1, 1, 1, 1, 0, 2],
    );
    await tester.tap(find.byKey(const ValueKey('profile-asset-period-month')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<V3AssetGrowthSparkline>(
            find.byKey(const ValueKey('profile-asset-growth-line')),
          )
          .values,
      hasLength(30),
    );
    expect(find.text('近 30 天新增 30 条'), findsOneWidget);
    expect(noteMetrics.cursors, <String?>[null]);
    expect(noteMetrics.limits, <int>[30]);
    await tester.tap(find.byKey(const ValueKey('profile-asset-growth-card')));
    await tester.pumpAndSettle();
    expect(find.text('profile-route-calendar'), findsOneWidget);
    router.go('/home');
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();

    expect(find.text('资产新增'), findsOneWidget);
    expect(find.text('近 30 天新增 30 条'), findsOneWidget);
    expect(
      tester
          .widget<V3AssetGrowthSparkline>(
            find.byKey(const ValueKey('profile-asset-growth-line')),
          )
          .values,
      hasLength(30),
    );
    expect(noteMetrics.cursors, <String?>[null, null]);
    expect(noteMetrics.limits, <int>[30, 30]);
    expect(find.text('外部世界'), findsOneWidget);
    expect(find.text('数字孪生'), findsOneWidget);
    expect(find.textContaining('当前等级 Lv.'), findsOneWidget);
    expect(find.text('充值'), findsNothing);
    expect(find.textContaining('/ 100'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );
    expect(find.text('社媒定位'), findsNothing);
    expect(find.text('查看报告'), findsNothing);
    expect(find.text('我的资产'), findsOneWidget);
    expect(find.text('录音文件'), findsNothing);
    expect(find.text('会员与额度'), findsNothing);
    expect(find.text('录音卡'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-recording-card-control-card')),
      findsOneWidget,
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
    expect(
      find.byKey(const ValueKey('profile-recording-card-battery')),
      findsOneWidget,
    );
    expect(find.text('--'), findsOneWidget);
    expect(find.textContaining('电量'), findsNothing);
    expect(find.text('声纹识别'), findsNothing);
    expect(find.text('声纹管理'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-recording-card-voiceprint')),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.text('设置'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('花火 Spark'), findsNothing);
    expect(find.text('花火商学院'), findsOneWidget);
    expect(find.text('账号与安全'), findsNothing);
    expect(find.text('已登录'), findsNothing);
    expect(find.text('未登录'), findsNothing);
    expect(find.text('帮助与反馈'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('自媒体日报'), findsNothing);
    expect(find.text('深度洞察报告'), findsNothing);
    expect(find.text('本地录音库'), findsNothing);
    expect(find.text('本地存储'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('数字孪生'),
      -160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('数字孪生'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('digital-twin-route')), findsOneWidget);
    expect(find.text('数字孪生详情'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile-recording-card-open-management')),
      -160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(
      find.byKey(const ValueKey('profile-recording-card-open-management')),
    );
    await tester.pumpAndSettle();
    expect(find.text('录音卡设备管理页'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );

    expect(find.text('录音文件'), findsNothing);
  });

  testWidgets('live profile metrics require foreground visible panel', (
    tester,
  ) async {
    final activity = AppActivityCoordinator(binding: tester.binding);
    activity.updateLifecycle(AppLifecycleState.resumed);
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    final positioning = DeepPositioningController(
      const _SeedPositioningRepository(),
    );
    final metrics = _NoteMetricsRepository(<WorkspaceNoteMetricsPage>[
      _newestMetricsPage(),
      _newestMetricsPage(),
      _newestMetricsPage(),
    ]);
    final navigatorKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: navigatorKey,
      initialLocation: '/home',
      routes: <RouteBase>[
        GoRoute(
          path: '/home',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => showV3ProfileSidePanel(context),
              child: const Text('open-profile'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
          assetProjectionFreshnessProvider.overrideWithValue(
            const AssetProjectionFreshness(
              hasActiveWork: true,
              revision: 'profile-asset-run:processing',
            ),
          ),
          noteMetricsRepositoryProvider.overrideWithValue(metrics),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(metrics.cursors, hasLength(1));

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(metrics.cursors, hasLength(1));

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(metrics.cursors, hasLength(2));

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 11));
    expect(metrics.cursors, hasLength(2));

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(metrics.cursors, hasLength(3));
  });
}

final class _NoteMetricsRepository implements NoteMetricsRepository {
  _NoteMetricsRepository(this.pages);

  final List<WorkspaceNoteMetricsPage> pages;
  final List<String?> cursors = <String?>[];
  final List<int> limits = <int>[];

  @override
  Future<WorkspaceNoteMetricsPage> load({
    required int limit,
    String? cursor,
  }) async {
    limits.add(limit);
    cursors.add(cursor);
    return pages.removeAt(0);
  }
}

WorkspaceNoteMetricsCoverage _metricsCoverage() => WorkspaceNoteMetricsCoverage(
  startAt: DateTime.utc(2026, 7, 21),
  startDate: '2026-07-21',
  completeFromDate: '2026-07-21',
  currentDate: '2026-08-19',
  historyComplete: true,
);

WorkspaceNoteMetricsPage _newestMetricsPage() => WorkspaceNoteMetricsPage(
  schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
  metricId: 'new_note_count',
  timezone: 'Asia/Shanghai',
  asOf: DateTime.utc(2026, 8, 19, 4),
  coverage: _metricsCoverage(),
  days: List<WorkspaceNoteMetricDay>.generate(30, (offset) {
    final date = DateTime.utc(2026, 8, 19).subtract(Duration(days: offset));
    final count = switch (offset) {
      0 => 2,
      1 => 0,
      _ => 1,
    };
    return WorkspaceNoteMetricDay(
      date:
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      count: count,
      complete: offset != 0,
    );
  }),
  hasMore: false,
  nextCursor: '',
);

final class _SeedPositioningRepository implements DeepPositioningRepository {
  const _SeedPositioningRepository();

  @override
  bool get isDemo => true;

  @override
  DeepPositioningResult? load() => v3DemoPersonPositioningResult;

  @override
  Future<DeepPositioningResult?> refresh() async => load();

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async => v3DemoPersonPositioningResult;

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) async =>
      v3DemoPersonPositioningResult;

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) async => v3DemoPersonPositioningResult;
}
