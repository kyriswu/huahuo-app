import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_metrics_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_metrics_repository.dart';

void main() {
  group('AssetGrowthPeriodController', () {
    test('defaults to week and restores the last selection per account', () {
      final dao = AppPreferencesDao(AppDatabase());
      final firstAccount = AssetGrowthPeriodRepository(
        dao: dao,
        userScope: 'account-a',
      );
      final secondAccount = AssetGrowthPeriodRepository(
        dao: dao,
        userScope: 'account-b',
      );

      final first = AssetGrowthPeriodController(repository: firstAccount)
        ..restore();
      addTearDown(first.dispose);
      expect(first.period, AssetGrowthPeriod.week);
      expect(first.selectPeriod(AssetGrowthPeriod.month), isTrue);

      final restored = AssetGrowthPeriodController(repository: firstAccount)
        ..restore();
      addTearDown(restored.dispose);
      final isolated = AssetGrowthPeriodController(repository: secondAccount)
        ..restore();
      addTearDown(isolated.dispose);

      expect(restored.period, AssetGrowthPeriod.month);
      expect(isolated.period, AssetGrowthPeriod.week);
      expect(firstAccount.preferenceKey, isNot(secondAccount.preferenceKey));
    });

    test('repairs an invalid persisted period to week', () {
      final dao = AppPreferencesDao(AppDatabase());
      final repository = AssetGrowthPeriodRepository(
        dao: dao,
        userScope: 'invalid-period-account',
      );
      dao.upsertValue(
        preferenceKey: repository.preferenceKey,
        value: 'quarter',
        updatedAt: '2026-08-26T00:00:00.000Z',
      );

      final controller = AssetGrowthPeriodController(repository: repository)
        ..restore();
      addTearDown(controller.dispose);

      expect(controller.period, AssetGrowthPeriod.week);
      expect(
        dao.readValue(repository.preferenceKey),
        AssetGrowthPeriod.week.wireName,
      );
      expect(controller.errorCode, isNull);
    });

    test('keeps the visible period when persistence fails', () async {
      final root = await Directory.systemTemp.createTemp(
        'asset-period-failure-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = AppDatabase(
        snapshotStore: _ThrowingSnapshotStore(
          file: File('${root.path}/local-db.json'),
        ),
      );
      final controller = AssetGrowthPeriodController(
        repository: AssetGrowthPeriodRepository(
          dao: AppPreferencesDao(database),
          userScope: 'failing-account',
        ),
      )..restore();
      addTearDown(controller.dispose);

      expect(controller.period, AssetGrowthPeriod.week);
      expect(controller.selectPeriod(AssetGrowthPeriod.month), isFalse);
      expect(controller.period, AssetGrowthPeriod.week);
      expect(controller.errorCode, 'ASSET_GROWTH_PERIOD_SAVE_FAILED');
    });
  });

  test('loads server daily counts without replacing zero days', () async {
    final repository = _QueueNoteMetricsRepository(<Object?>[_newestPage()]);
    final controller = NoteMetricsController(
      repository: repository,
      pageSize: 2,
    );

    await controller.load();

    expect(controller.state.status, NoteMetricsStatus.ready);
    expect(controller.state.days.map((day) => day.date), <String>[
      '2026-08-19',
      '2026-08-18',
    ]);
    expect(controller.state.days.map((day) => day.count), <int>[2, 0]);
    expect(controller.state.currentDay?.complete, isFalse);
    expect(controller.state.coverage?.historyComplete, isFalse);
    expect(repository.cursors, <String?>[null]);
  });

  test(
    'appends only an older cursor page and retains coverage facts',
    () async {
      final repository = _QueueNoteMetricsRepository(<Object?>[
        _newestPage(),
        _olderPage(),
      ]);
      final controller = NoteMetricsController(
        repository: repository,
        pageSize: 2,
      );

      await controller.load();
      await controller.loadMore();

      expect(controller.state.status, NoteMetricsStatus.ready);
      expect(controller.state.days.map((day) => day.date), <String>[
        '2026-08-19',
        '2026-08-18',
        '2026-08-17',
      ]);
      expect(controller.state.hasMore, isFalse);
      expect(repository.cursors, <String?>[null, 'opaque-next']);
    },
  );

  test(
    'does not substitute a local weekly or monthly count after failure',
    () async {
      final controller = NoteMetricsController(
        repository: _QueueNoteMetricsRepository(<Object?>[
          const NoteMetricsException('WORKSPACE_METRICS_UNAVAILABLE'),
        ]),
      );

      await controller.load();

      expect(controller.state.status, NoteMetricsStatus.failed);
      expect(controller.state.days, isEmpty);
      expect(controller.state.coverage, isNull);
      expect(controller.state.errorCode, 'WORKSPACE_METRICS_UNAVAILABLE');
    },
  );

  test(
    'rejects a skipped day and a terminal page short of coverage start',
    () async {
      final skipped = NoteMetricsController(
        repository: _QueueNoteMetricsRepository(<Object?>[
          _newestSingleDayPage(),
          _olderPage(),
        ]),
      );
      await skipped.load();
      await skipped.loadMore();

      expect(skipped.state.days, hasLength(1));
      expect(skipped.state.errorCode, 'NOTE_METRICS_PAGE_INVALID');

      final shortTerminal = NoteMetricsController(
        repository: _QueueNoteMetricsRepository(<Object?>[
          _shortTerminalPage(),
        ]),
      );
      await shortTerminal.load();

      expect(shortTerminal.state.status, NoteMetricsStatus.failed);
      expect(shortTerminal.state.errorCode, 'NOTE_METRICS_PAGE_INVALID');
    },
  );

  test(
    'restores a fresh scoped metrics snapshot and revalidates stale data',
    () async {
      var now = DateTime.utc(2026, 8, 19, 8);
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'metrics-cache-user',
        workspaceScope: 'metrics-cache-workspace',
        now: () => now,
      );
      final firstRepository = _QueueNoteMetricsRepository(<Object?>[
        _newestPage(),
      ]);
      final first = NoteMetricsController(
        repository: firstRepository,
        cache: cache,
        pageSize: 2,
      );
      await first.load();

      final freshRepository = _QueueNoteMetricsRepository(<Object?>[]);
      final fresh = NoteMetricsController(
        repository: freshRepository,
        cache: cache,
        pageSize: 2,
      );
      await fresh.load();
      expect(fresh.state.currentDay?.count, 2);
      expect(freshRepository.cursors, isEmpty);

      now = now.add(const Duration(minutes: 6));
      final staleRepository = _QueueNoteMetricsRepository(<Object?>[
        const NoteMetricsException('METRICS_REVALIDATE_FAILED'),
      ]);
      final stale = NoteMetricsController(
        repository: staleRepository,
        cache: cache,
        pageSize: 2,
      );
      await stale.load();

      expect(stale.state.status, NoteMetricsStatus.ready);
      expect(stale.state.currentDay?.count, 2);
      expect(stale.state.errorCode, 'METRICS_REVALIDATE_FAILED');
      expect(staleRepository.cursors, <String?>[null]);
    },
  );

  test('live asset work bypasses a fresh scoped metrics snapshot', () async {
    final cache = ScopedReadCache(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'metrics-live-cache-user',
      workspaceScope: 'metrics-live-cache-workspace',
      now: () => DateTime.utc(2026, 8, 19, 8),
    );
    final firstRepository = _QueueNoteMetricsRepository(<Object?>[
      _newestPage(),
    ]);
    final first = NoteMetricsController(
      repository: firstRepository,
      cache: cache,
      pageSize: 2,
    );
    await first.load();

    final liveRepository = _QueueNoteMetricsRepository(<Object?>[
      _newestPage(),
    ]);
    final live = NoteMetricsController(
      repository: liveRepository,
      cache: cache,
      cacheBypass: () => true,
      pageSize: 2,
    );
    await live.load();

    expect(liveRepository.cursors, <String?>[null]);
    expect(live.state.currentDay?.count, 2);
  });

  test(
    'an explicit metrics refresh failure invalidates the scoped snapshot',
    () async {
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'metrics-refresh-cache-user',
        workspaceScope: 'metrics-refresh-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      final firstRepository = _QueueNoteMetricsRepository(<Object?>[
        _newestPage(),
        const NoteMetricsException('METRICS_REFRESH_FAILED'),
      ]);
      final first = NoteMetricsController(
        repository: firstRepository,
        cache: cache,
        pageSize: 2,
      );
      await first.load();
      await first.load(force: true, invalidateCache: true);

      final restoredRepository = _QueueNoteMetricsRepository(<Object?>[
        const NoteMetricsException('METRICS_RESTORED_LOAD_FAILED'),
      ]);
      final restored = NoteMetricsController(
        repository: restoredRepository,
        cache: cache,
        pageSize: 2,
      );
      await restored.load();

      expect(restoredRepository.cursors, <String?>[null]);
      expect(restored.state.status, NoteMetricsStatus.failed);
      expect(restored.state.days, isEmpty);
    },
  );

  test(
    'a newer invalidating metrics refresh drops an older response and cache write',
    () async {
      final repository = _DeferredNoteMetricsRepository();
      final cache = ScopedReadCache(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'metrics-race-cache-user',
        workspaceScope: 'metrics-race-cache-workspace',
        now: () => DateTime.utc(2026, 8, 19, 8),
      );
      var revision = 'recording:processing';
      final controller = NoteMetricsController(
        repository: repository,
        cache: cache,
        cacheRevision: () => revision,
        pageSize: 2,
      );

      final older = controller.load();
      expect(repository.pending, hasLength(1));

      revision = 'recording:completed';
      final newest = controller.load(force: true, invalidateCache: true);
      expect(repository.pending, hasLength(2));

      repository.pending[0].complete(_newestPage(currentCount: 1));
      await older;

      expect(controller.state.days, isEmpty);
      expect(cache.read('workspaceNoteMetrics', 'initial-2'), isNull);

      repository.pending[1].complete(_newestPage(currentCount: 9));
      await newest;

      expect(controller.state.currentDay?.count, 9);
      final restoredRepository = _QueueNoteMetricsRepository(<Object?>[]);
      final restored = NoteMetricsController(
        repository: restoredRepository,
        cache: cache,
        pageSize: 2,
      );
      await restored.load();
      expect(restored.state.currentDay?.count, 9);
      expect(restoredRepository.cursors, isEmpty);
    },
  );

  test('projects fixed seven-day and thirty-day growth series', () {
    final current = DateTime.utc(2026, 8, 19);
    final state = NoteMetricsState(
      status: NoteMetricsStatus.ready,
      coverage: WorkspaceNoteMetricsCoverage(
        startAt: DateTime.utc(2026, 7, 21),
        startDate: '2026-07-21',
        completeFromDate: '2026-07-21',
        currentDate: '2026-08-19',
        historyComplete: true,
      ),
      days: List<WorkspaceNoteMetricDay>.generate(30, (offset) {
        final date = current.subtract(Duration(days: offset));
        return WorkspaceNoteMetricDay(
          date: _testDateText(date),
          count: offset,
          complete: offset != 0,
        );
      }),
    );

    final week = state.growthSeriesFor(AssetGrowthPeriod.week);
    final month = state.growthSeriesFor(AssetGrowthPeriod.month);

    expect(week?.days, hasLength(7));
    expect(week?.days.map((day) => day.count), <int>[6, 5, 4, 3, 2, 1, 0]);
    expect(month?.days, hasLength(30));
    expect(month?.days.first.date, '2026-07-21');
    expect(month?.days.last.date, '2026-08-19');
  });

  test('zero-fills only dates covered by complete Workspace history', () {
    const days = <WorkspaceNoteMetricDay>[
      WorkspaceNoteMetricDay(date: '2026-08-19', count: 2, complete: false),
      WorkspaceNoteMetricDay(date: '2026-08-18', count: 0, complete: true),
      WorkspaceNoteMetricDay(date: '2026-08-17', count: 1, complete: true),
    ];
    NoteMetricsState state(bool historyComplete) => NoteMetricsState(
      status: NoteMetricsStatus.ready,
      coverage: WorkspaceNoteMetricsCoverage(
        startAt: DateTime.utc(2026, 8, 17),
        startDate: '2026-08-17',
        completeFromDate: '2026-08-17',
        currentDate: '2026-08-19',
        historyComplete: historyComplete,
      ),
      days: days,
    );

    final complete = state(true).growthSeriesFor(AssetGrowthPeriod.week);
    expect(complete?.days, hasLength(7));
    expect(complete?.days.map((day) => day.count), <int>[0, 0, 0, 0, 1, 0, 2]);
    expect(state(false).growthSeriesFor(AssetGrowthPeriod.week), isNull);
  });
}

String _testDateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

final class _ThrowingSnapshotStore extends LocalDatabaseSnapshotStore {
  const _ThrowingSnapshotStore({required super.file});

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    throw FileSystemException('test persistence failure', file.path);
  }
}

final class _QueueNoteMetricsRepository implements NoteMetricsRepository {
  _QueueNoteMetricsRepository(this.responses);

  final List<Object?> responses;
  final List<String?> cursors = <String?>[];

  @override
  Future<WorkspaceNoteMetricsPage> load({
    required int limit,
    String? cursor,
  }) async {
    cursors.add(cursor);
    final response = responses.removeAt(0);
    if (response is NoteMetricsException) throw response;
    return response! as WorkspaceNoteMetricsPage;
  }
}

final class _DeferredNoteMetricsRepository implements NoteMetricsRepository {
  final pending = <Completer<WorkspaceNoteMetricsPage>>[];
  final cursors = <String?>[];

  @override
  Future<WorkspaceNoteMetricsPage> load({required int limit, String? cursor}) {
    cursors.add(cursor);
    final completion = Completer<WorkspaceNoteMetricsPage>();
    pending.add(completion);
    return completion.future;
  }
}

WorkspaceNoteMetricsCoverage _coverage() => WorkspaceNoteMetricsCoverage(
  startAt: DateTime.utc(2026, 8, 16, 16),
  startDate: '2026-08-17',
  completeFromDate: '2026-08-18',
  currentDate: '2026-08-19',
  historyComplete: false,
);

WorkspaceNoteMetricsPage _newestPage({int currentCount = 2}) =>
    WorkspaceNoteMetricsPage(
      schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
      metricId: 'new_note_count',
      timezone: 'Asia/Shanghai',
      asOf: DateTime.utc(2026, 8, 19, 4),
      coverage: _coverage(),
      days: <WorkspaceNoteMetricDay>[
        WorkspaceNoteMetricDay(
          date: '2026-08-19',
          count: currentCount,
          complete: false,
        ),
        const WorkspaceNoteMetricDay(
          date: '2026-08-18',
          count: 0,
          complete: true,
        ),
      ],
      hasMore: true,
      nextCursor: 'opaque-next',
    );

WorkspaceNoteMetricsPage _olderPage() => WorkspaceNoteMetricsPage(
  schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
  metricId: 'new_note_count',
  timezone: 'Asia/Shanghai',
  asOf: DateTime.utc(2026, 8, 19, 4),
  coverage: _coverage(),
  days: const <WorkspaceNoteMetricDay>[
    WorkspaceNoteMetricDay(date: '2026-08-17', count: 1, complete: false),
  ],
  hasMore: false,
  nextCursor: '',
);

WorkspaceNoteMetricsPage _newestSingleDayPage() => WorkspaceNoteMetricsPage(
  schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
  metricId: 'new_note_count',
  timezone: 'Asia/Shanghai',
  asOf: DateTime.utc(2026, 8, 19, 4),
  coverage: _coverage(),
  days: const <WorkspaceNoteMetricDay>[
    WorkspaceNoteMetricDay(date: '2026-08-19', count: 2, complete: false),
  ],
  hasMore: true,
  nextCursor: 'opaque-next',
);

WorkspaceNoteMetricsPage _shortTerminalPage() => WorkspaceNoteMetricsPage(
  schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
  metricId: 'new_note_count',
  timezone: 'Asia/Shanghai',
  asOf: DateTime.utc(2026, 8, 19, 4),
  coverage: _coverage(),
  days: const <WorkspaceNoteMetricDay>[
    WorkspaceNoteMetricDay(date: '2026-08-19', count: 2, complete: false),
    WorkspaceNoteMetricDay(date: '2026-08-18', count: 0, complete: true),
  ],
  hasMore: false,
  nextCursor: '',
);
