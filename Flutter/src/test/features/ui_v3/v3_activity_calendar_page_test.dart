import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/activity_calendar_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_metrics_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_metrics_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_activity_calendar_page.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M11 calendar current day uses real metric summary', (
    tester,
  ) async {
    await _pumpCalendarGolden(tester);

    final summary = find.byKey(const ValueKey('calendar-summary-strip'));
    for (final value in const ['3', '4', '2']) {
      expect(
        find.descendant(of: summary, matching: find.text(value)),
        findsOneWidget,
      );
    }
    expect(find.text('今日新增仍在统计中'), findsOneWidget);
    _expectLegacyFiltersAbsent();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/activity_calendar_default.png'),
    );
  });

  testWidgets('M11 selected day renders real owned HNotes and sources', (
    tester,
  ) async {
    await _pumpCalendarGolden(tester, selectedDay: DateTime(2026, 8, 12));

    expect(find.text('8月12日 · 周三'), findsOneWidget);
    expect(find.text('新增 2 条'), findsOneWidget);
    expect(find.text('行业资料链接'), findsOneWidget);
    expect(find.text('自由创作草稿'), findsOneWidget);
    expect(find.textContaining('· 链接'), findsOneWidget);
    expect(find.textContaining('· 自由创作'), findsOneWidget);
    expect(find.text('订阅内容不属于我的资产'), findsNothing);
    _expectLegacyFiltersAbsent();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/activity_calendar_selected.png'),
    );
  });

  testWidgets('calendar opens a real note and explains unavailable remainder', (
    tester,
  ) async {
    await _pumpCalendar(
      tester,
      metrics: _readyMetrics(_augustMetrics()),
      notes: _calendarNotes(),
      selectedDay: DateTime(2026, 8, 19),
    );

    expect(find.text('会议纪要'), findsOneWidget);
    expect(find.text('另有 1 条资产已删除或暂不可查看'), findsOneWidget);
    await tester.tap(find.text('会议纪要'));
    await tester.pumpAndSettle();
    expect(find.text('opened:meeting-note'), findsOneWidget);
  });

  testWidgets(
    'known zero, loading, failure and incomplete history stay distinct',
    (tester) async {
      final deferred = _DeferredNoteMetricsRepository();
      final loadingMetrics = NoteMetricsController(repository: deferred);
      final loading = loadingMetrics.load();
      await _pumpCalendar(
        tester,
        metrics: loadingMetrics,
        notes: const <V3FeedItem>[],
        selectedDay: DateTime(2026, 8, 11),
        settle: false,
      );
      expect(find.text('正在加载新增统计'), findsOneWidget);

      deferred.pending.single.complete(_augustMetrics());
      await loading;
      await tester.pumpAndSettle();
      expect(find.text('8月11日暂无新增资产'), findsOneWidget);

      final failed = NoteMetricsController(
        repository: _QueueNoteMetricsRepository(<Object>[
          const NoteMetricsException('NOTE_METRICS_LOAD_FAILED'),
        ]),
      );
      await failed.load();
      await _pumpCalendar(
        tester,
        metrics: failed,
        notes: const <V3FeedItem>[],
        selectedDay: DateTime(2026, 8, 11),
      );
      expect(find.text('新增统计加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await _pumpCalendar(
        tester,
        metrics: _readyMetrics(
          _augustMetrics(historyComplete: false, completeFromDay: 10),
        ),
        notes: const <V3FeedItem>[],
        selectedDay: DateTime(2026, 8, 5),
      );
      expect(find.text('该日期统计暂不可用'), findsOneWidget);
      expect(find.text('8月5日暂无新增资产'), findsNothing);
    },
  );

  testWidgets('calendar blocks future dates and future months', (tester) async {
    final calendar = ActivityCalendarController(now: DateTime(2026, 8, 22));
    await _pumpCalendar(
      tester,
      metrics: _readyMetrics(_augustMetrics()),
      notes: _calendarNotes(),
      calendar: calendar,
    );

    final next = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip('下个月'),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(next.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('calendar-day-2026-8-23')));
    await tester.pump();
    expect(calendar.selectedDay, DateTime(2026, 8, 22));

    calendar.selectDay(DateTime(2027, 1, 1));
    expect(calendar.selectedDay, DateTime(2026, 8, 22));
    expect(calendar.month, DateTime(2026, 8));
  });

  testWidgets('opening an older month loads metrics cursor pages once', (
    tester,
  ) async {
    final pages = _paginatedMetrics();
    final repository = _QueueNoteMetricsRepository(<Object>[...pages]);
    final metrics = NoteMetricsController(repository: repository);
    await metrics.load();
    await _pumpCalendar(tester, metrics: metrics, notes: const <V3FeedItem>[]);

    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();

    expect(find.text('2026年7月'), findsOneWidget);
    expect(repository.cursors, <String?>[null, 'older-1']);
  });
}

void _expectLegacyFiltersAbsent() {
  for (final label in const <String>[
    '全部',
    '原始材料',
    '纲要',
    '深度洞察',
    '对话创作',
    '上传',
  ]) {
    expect(find.text(label), findsNothing);
  }
}

Future<void> _pumpCalendarGolden(
  WidgetTester tester, {
  DateTime? selectedDay,
}) async {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _pumpCalendar(
    tester,
    metrics: _readyMetrics(_augustMetrics()),
    notes: _calendarNotes(),
    selectedDay: selectedDay,
    theme: figmaGoldenTheme(),
    mediaPadding: const EdgeInsets.only(top: 54, bottom: 24),
  );
}

Future<void> _pumpCalendar(
  WidgetTester tester, {
  required NoteMetricsController metrics,
  required List<V3FeedItem> notes,
  DateTime? selectedDay,
  ActivityCalendarController? calendar,
  ThemeData? theme,
  EdgeInsets mediaPadding = EdgeInsets.zero,
  bool settle = true,
}) async {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final library = KnowledgeLibraryController(
    initialNotes: notes,
    includeDemoFixtures: false,
  );
  final router = GoRouter(
    initialLocation: '/calendar',
    routes: [
      GoRoute(
        path: '/calendar',
        builder: (context, state) =>
            V3ActivityCalendarPage(initialSelectedDay: selectedDay),
      ),
      GoRoute(
        path: '/v3/feed/items/:itemId',
        builder: (context, state) =>
            Scaffold(body: Text('opened:${state.pathParameters['itemId']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        noteMetricsControllerProvider.overrideWith((ref) => metrics),
        activityCalendarControllerProvider.overrideWith(
          (ref) =>
              calendar ??
              ActivityCalendarController(now: DateTime(2026, 8, 22)),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: mediaPadding, viewPadding: mediaPadding),
          child: child!,
        ),
        routerConfig: router,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

NoteMetricsController _readyMetrics(WorkspaceNoteMetricsPage page) =>
    NoteMetricsController(
      repository: _QueueNoteMetricsRepository(<Object>[page]),
    )..load();

WorkspaceNoteMetricsPage _augustMetrics({
  bool historyComplete = true,
  int completeFromDay = 1,
}) {
  final current = DateTime.utc(2026, 8, 22);
  final completeFrom = DateTime.utc(2026, 8, completeFromDay);
  const counts = <String, int>{'2026-08-12': 2, '2026-08-19': 2};
  return WorkspaceNoteMetricsPage(
    schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
    metricId: 'new_note_count',
    timezone: 'Asia/Shanghai',
    asOf: DateTime.utc(2026, 8, 22, 4),
    coverage: WorkspaceNoteMetricsCoverage(
      startAt: DateTime.utc(2026, 7, 31, 16),
      startDate: '2026-08-01',
      completeFromDate: _dateText(completeFrom),
      currentDate: '2026-08-22',
      historyComplete: historyComplete,
    ),
    days: List<WorkspaceNoteMetricDay>.generate(22, (offset) {
      final day = current.subtract(Duration(days: offset));
      return WorkspaceNoteMetricDay(
        date: _dateText(day),
        count: counts[_dateText(day)] ?? 0,
        complete:
            day != current && (historyComplete || !day.isBefore(completeFrom)),
      );
    }),
    hasMore: false,
    nextCursor: '',
  );
}

List<WorkspaceNoteMetricsPage> _paginatedMetrics() {
  final coverage = WorkspaceNoteMetricsCoverage(
    startAt: DateTime.utc(2026, 5, 31, 16),
    startDate: '2026-06-01',
    completeFromDate: '2026-06-01',
    currentDate: '2026-08-22',
    historyComplete: true,
  );
  WorkspaceNoteMetricsPage page({
    required DateTime newest,
    required String nextCursor,
  }) => WorkspaceNoteMetricsPage(
    schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
    metricId: 'new_note_count',
    timezone: 'Asia/Shanghai',
    asOf: DateTime.utc(2026, 8, 22, 4),
    coverage: coverage,
    days: List<WorkspaceNoteMetricDay>.generate(31, (offset) {
      final day = newest.subtract(Duration(days: offset));
      return WorkspaceNoteMetricDay(
        date: _dateText(day),
        count: 0,
        complete: day != DateTime.utc(2026, 8, 22),
      );
    }),
    hasMore: true,
    nextCursor: nextCursor,
  );
  return <WorkspaceNoteMetricsPage>[
    page(newest: DateTime.utc(2026, 8, 22), nextCursor: 'older-1'),
    page(newest: DateTime.utc(2026, 7, 22), nextCursor: 'older-2'),
  ];
}

List<V3FeedItem> _calendarNotes() => <V3FeedItem>[
  _ownedNote(
    id: 'link-note',
    title: '行业资料链接',
    source: V3MaterialSource.link,
    createdAt: DateTime(2026, 8, 12, 9, 20),
  ),
  _ownedNote(
    id: 'creation-note',
    title: '自由创作草稿',
    source: V3MaterialSource.note,
    contentOrigin: V3ContentOrigin.freeCreation,
    createdAt: DateTime(2026, 8, 12, 8, 10),
  ),
  _ownedNote(
    id: 'meeting-note',
    title: '会议纪要',
    source: V3MaterialSource.meeting,
    createdAt: DateTime(2026, 8, 19, 14, 30),
  ),
  V3FeedItem(
    id: 'subscription-note',
    title: '订阅内容不属于我的资产',
    source: V3MaterialSource.subscription,
    ownership: V3NoteOwnership.subscribed,
    createdAt: DateTime(2026, 8, 12, 7),
    rawBody: '只用于证明日历仅展示本人资产。',
  ),
];

V3FeedItem _ownedNote({
  required String id,
  required String title,
  required V3MaterialSource source,
  required DateTime createdAt,
  V3ContentOrigin contentOrigin = V3ContentOrigin.standard,
}) => V3FeedItem(
  id: id,
  title: title,
  source: source,
  createdAt: createdAt,
  rawBody: '真实 Workspace HNote 内容',
  ownership: V3NoteOwnership.mine,
  syncState: NoteSyncState.synced,
  contentOrigin: contentOrigin,
  remoteNoteId: 'remote-$id',
);

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

final class _QueueNoteMetricsRepository implements NoteMetricsRepository {
  _QueueNoteMetricsRepository(this.responses);

  final List<Object> responses;
  final List<String?> cursors = <String?>[];

  @override
  Future<WorkspaceNoteMetricsPage> load({
    required int limit,
    String? cursor,
  }) async {
    cursors.add(cursor);
    final response = responses.removeAt(0);
    if (response is NoteMetricsException) throw response;
    return response as WorkspaceNoteMetricsPage;
  }
}

final class _DeferredNoteMetricsRepository implements NoteMetricsRepository {
  final pending = <Completer<WorkspaceNoteMetricsPage>>[];

  @override
  Future<WorkspaceNoteMetricsPage> load({required int limit, String? cursor}) {
    final completer = Completer<WorkspaceNoteMetricsPage>();
    pending.add(completer);
    return completer.future;
  }
}
