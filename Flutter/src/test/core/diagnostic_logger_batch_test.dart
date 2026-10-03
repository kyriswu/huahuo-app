import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/performance/database_metrics.dart';

void main() {
  testWidgets('background diagnostics bypass the foreground batch delay', (
    tester,
  ) async {
    var foreground = true;
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      flushInterval: const Duration(seconds: 1),
      canDeferFlush: () => foreground,
    );
    addTearDown(logger.dispose);
    logger.log(_input(summary: 'foreground batch'));
    expect(dao.stagedCount, 1);
    foreground = false;
    logger.log(_input(summary: 'background event'));
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(2));
    foreground = true;
    logger.log(_input(summary: 'resumed event'));
    expect(dao.stagedCount, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(dao.stagedCount, 0);
  });

  testWidgets('timed batching spans events without sliding its deadline', (
    tester,
  ) async {
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      flushInterval: const Duration(seconds: 1),
    );
    addTearDown(logger.dispose);
    logger.log(_input(summary: 'first event'));
    await tester.pump(const Duration(milliseconds: 600));
    logger.log(_input(summary: 'second event'));
    expect(dao.query(), hasLength(2));
    expect(dao.stagedCount, 2);
    await tester.pump(const Duration(milliseconds: 399));
    expect(logger.pendingEventCount, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(logger.pendingEventCount, 0);
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(2));
  });

  testWidgets('explicit flush and dispose cancel delayed diagnostics work', (
    tester,
  ) async {
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      flushInterval: const Duration(seconds: 1),
    );
    logger.log(_input(summary: 'foreground event'));
    logger.flush();
    expect(dao.stagedCount, 0);
    logger.log(_input(summary: 'dispose event'));
    logger.dispose();
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(2));
    await tester.pump(const Duration(seconds: 2));
    expect(dao.query(), hasLength(2));
  });

  test('rejects a negative diagnostic flush interval', () {
    expect(
      () => DiagnosticLogger(
        dao: DiagnosticLogDao(AppDatabase()),
        flushInterval: const Duration(milliseconds: -1),
      ),
      throwsArgumentError,
    );
  });

  test('aggregates the same safe event for one minute with a fake clock', () {
    var now = DateTime.utc(2026, 8, 31, 9);
    final scheduled = <void Function()>[];
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      now: () => now,
      scheduleIdle: scheduled.add,
    );

    final firstId = logger.log(_input(summary: 'retryable upload'));
    now = now.add(const Duration(seconds: 45));
    final repeatedId = logger.log(_input(summary: 'retryable upload'));

    expect(repeatedId, firstId);
    expect(logger.pendingEventCount, 1);
    expect(dao.stagedCount, 1);
    expect(dao.query(), hasLength(1));
    expect(dao.query().single.redactedMetadata['aggregate_count'], 2);

    logger.flush();
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(1));

    now = now.add(const Duration(seconds: 61));
    final nextWindowId = logger.log(_input(summary: 'retryable upload'));
    expect(nextWindowId, isNot(firstId));
    logger.flush();
    expect(dao.query(), hasLength(2));
  });

  test('flushes twenty unique events in one database transaction', () async {
    final root = await Directory.systemTemp.createTemp(
      'diagnostic-batch-metrics-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final metrics = DatabaseMetrics();
    final dao = DiagnosticLogDao(
      AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(
          file: File('${root.path}/metadata.sqlite'),
          backend: LocalDatabaseSnapshotBackend.sqlite,
        ),
        metrics: metrics,
      ),
    );
    final logger = DiagnosticLogger(
      dao: dao,
      now: () => DateTime.utc(2026, 8, 31, 10),
      scheduleIdle: (_) {},
    );

    for (var index = 0; index < 20; index += 1) {
      logger.log(_input(summary: 'event-$index'));
    }

    expect(logger.pendingEventCount, 0);
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(20));
    expect(metrics.snapshot().byOperation['transaction'], 1);
  });

  test('short idle callback flushes a staged batch', () {
    final scheduled = <void Function()>[];
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(dao: dao, scheduleIdle: scheduled.add);

    logger.log(_input(summary: 'idle event'));
    expect(scheduled, hasLength(1));
    expect(dao.stagedCount, 1);

    scheduled.single();

    expect(logger.pendingEventCount, 0);
    expect(dao.stagedCount, 0);
    expect(dao.query().single.safeSummary, 'idle event');
  });

  test('flushes before memory pressure and keeps every accepted event', () {
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      batchSize: 20,
      memoryCapacity: 2,
      scheduleIdle: (_) {},
    );

    logger.log(_input(summary: 'one'));
    logger.log(_input(summary: 'two'));
    logger.log(_input(summary: 'three'));

    expect(logger.pendingEventCount, 1);
    expect(dao.stagedCount, 1);
    expect(dao.query(), hasLength(3));
    logger.flush();
    expect(dao.query(), hasLength(3));
  });

  test('automatically prunes persisted events to the configured cap', () {
    var now = DateTime.utc(2026, 8, 31, 11);
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(
      dao: dao,
      now: () => now,
      scheduleIdle: (_) {},
      pruneInterval: Duration.zero,
      maxPersistedEvents: 2,
    );

    for (var index = 0; index < 3; index += 1) {
      logger.log(_input(summary: 'bounded-$index', flushImmediately: true));
      now = now.add(const Duration(seconds: 1));
    }

    final records = dao.query();
    expect(records, hasLength(2));
    expect(records.map((record) => record.safeSummary), <String>[
      'bounded-2',
      'bounded-1',
    ]);
  });

  test(
    'clear removes staged events and a later flush does not revive them',
    () {
      final dao = DiagnosticLogDao(AppDatabase());
      final logger = DiagnosticLogger(dao: dao, scheduleIdle: (_) {});

      logger.log(_input(summary: 'clear me'));
      expect(dao.clear(), 1);

      logger.flush();

      expect(logger.pendingEventCount, 0);
      expect(dao.query(), isEmpty);
    },
  );

  test('failed batch persistence keeps the staged event for retry', () {
    final store = _FailOnceSnapshotStore();
    final dao = DiagnosticLogDao(AppDatabase(snapshotStore: store));
    final logger = DiagnosticLogger(dao: dao, scheduleIdle: (_) {});
    logger.log(_input(summary: 'retry after storage failure'));

    expect(logger.flush, throwsStateError);
    expect(logger.pendingEventCount, 1);
    expect(dao.stagedCount, 1);
    expect(dao.query(), hasLength(1));

    logger.flush();
    expect(logger.pendingEventCount, 0);
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(1));
    expect(store.saveCalls, 3);
  });

  test('explicit error flush and dispose persist all accepted events', () {
    final dao = DiagnosticLogDao(AppDatabase());
    final logger = DiagnosticLogger(dao: dao, scheduleIdle: (_) {});

    logger.log(
      const DiagnosticLogInput(
        category: DiagnosticCategory.api,
        severity: DiagnosticSeverity.error,
        safeSummary: 'terminal request failure',
        flushImmediately: true,
      ),
    );
    expect(dao.stagedCount, 0);

    logger.log(_input(summary: 'pending before dispose'));
    logger.dispose();

    expect(logger.isDisposed, isTrue);
    expect(logger.pendingEventCount, 0);
    expect(dao.stagedCount, 0);
    expect(dao.query(), hasLength(2));
    expect(() => logger.log(_input(summary: 'too late')), throwsStateError);
  });

  test('deferred worker failure remains staged and observable', () async {
    final database = AppDatabase();
    final queue = DatabaseWriteQueue();
    final dao = DiagnosticLogDao(
      database,
      worker: const _FailingDiagnosticWorker(),
      writeQueue: queue,
    );
    final scheduled = <void Function()>[];
    final logger = DiagnosticLogger(dao: dao, scheduleIdle: scheduled.add);
    addTearDown(() async {
      logger.dispose();
      await queue.dispose();
    });

    logger.log(_input(summary: 'worker fallback event'));
    expect(dao.stagedCount, 1);
    scheduled.single();
    await expectLater(queue.flush(), throwsStateError);
    await Future<void>.delayed(Duration.zero);

    expect(logger.lastFlushError, isA<StateError>());
    expect(scheduled, hasLength(1));
    expect(logger.pendingEventCount, 1);
    expect(dao.stagedCount, 1);
    expect(dao.query().single.safeSummary, 'worker fallback event');
    expect(DiagnosticLogDao(database).query(), isEmpty);
  });
}

final class _FailingDiagnosticWorker implements DatabaseRecordWorkerPort {
  const _FailingDiagnosticWorker();

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async => throw StateError('injected worker failure');

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async => throw StateError('injected worker failure');

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => throw StateError('injected worker failure');

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}

final class _FailOnceSnapshotStore extends LocalDatabaseSnapshotStore {
  _FailOnceSnapshotStore() : super(file: File('unused-diagnostic-test.json'));

  var saveCalls = 0;

  @override
  LocalDatabaseSnapshot? load() => null;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    saveCalls += 1;
    if (saveCalls == 1) throw StateError('simulated storage failure');
  }
}

DiagnosticLogInput _input({
  required String summary,
  bool flushImmediately = false,
}) {
  return DiagnosticLogInput(
    category: DiagnosticCategory.app,
    severity: DiagnosticSeverity.info,
    safeSummary: summary,
    metadata: const <String, Object?>{'stage': 'test'},
    flushImmediately: flushImmediately,
  );
}
