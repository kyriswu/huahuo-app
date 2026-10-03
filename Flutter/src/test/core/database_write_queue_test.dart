import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/performance/database_metrics.dart';

void main() {
  group('DatabaseWriteQueue', () {
    test('latest pending write wins and completes every waiter', () async {
      final queue = DatabaseWriteQueue();
      final executed = <String>[];

      final first = queue.enqueue(
        key: 'canvas-draft',
        replacePending: true,
        operation: () => executed.add('old'),
      );
      final second = queue.enqueue(
        key: 'canvas-draft',
        replacePending: true,
        operation: () => executed.add('latest'),
      );

      await Future.wait(<Future<void>>[first, second]);
      expect(executed, <String>['latest']);
      expect(queue.queueDepth, 0);
    });

    test(
      'append writes sharing a stable key execute as one ordered batch',
      () async {
        final queue = DatabaseWriteQueue();
        final batches = <List<int>>[];

        Future<void> append(int value) => queue.enqueueAppend<int>(
          key: 'diagnostic-events',
          value: value,
          operation: (values) => batches.add(values),
        );

        await Future.wait(<Future<void>>[append(1), append(2), append(3)]);
        expect(batches, <List<int>>[
          <int>[1, 2, 3],
        ]);
      },
    );

    test('serializes writes and continues after one operation fails', () async {
      final queue = DatabaseWriteQueue();
      final executed = <String>[];
      final failed = queue.enqueue(
        key: 'first',
        operation: () {
          executed.add('first');
          throw StateError('failed write');
        },
      );
      final failureExpectation = expectLater(failed, throwsStateError);
      final succeeded = queue.enqueue(
        key: 'second',
        operation: () => executed.add('second'),
      );

      await failureExpectation;
      await succeeded;
      await expectLater(queue.flush(), throwsStateError);
      expect(executed, <String>['first', 'second']);
    });

    test('records fake-clock queue wait, execution time, and depth', () async {
      var now = DateTime.utc(2026, 8, 31, 8);
      final metrics = DatabaseMetrics();
      final queue = DatabaseWriteQueue(metrics: metrics, now: () => now);

      final completed = queue.enqueue(
        key: 'measured-write',
        operationLabel: 'upsert',
        table: 'diagnostic_logs',
        reason: 'batch_flush',
        callerFeature: 'diagnostics',
        rows: 4,
        bytes: 32,
        operation: () {
          now = now.add(const Duration(milliseconds: 7));
        },
      );
      now = now.add(const Duration(milliseconds: 5));
      await completed;

      final snapshot = metrics.snapshot();
      expect(snapshot.operations, 1);
      expect(snapshot.queueWait.p50Ms, 5);
      expect(snapshot.execute.p50Ms, 7);
      expect(snapshot.peakQueueDepth, 1);
      expect(snapshot.queueDepth, 0);
      expect(snapshot.rows, 4);
      expect(snapshot.bytes, 32);
      expect(snapshot.byOperation, <String, int>{'upsert': 1});
    });

    test('dispose drains accepted work and rejects later writes', () async {
      final queue = DatabaseWriteQueue();
      final executed = <String>[];
      final accepted = queue.enqueue(
        key: 'accepted',
        operation: () => executed.add('accepted'),
      );

      await queue.dispose();
      await accepted;
      await expectLater(
        queue.enqueue(key: 'late', operation: () {}),
        throwsStateError,
      );
      expect(queue.isDisposed, isTrue);
      expect(executed, <String>['accepted']);
    });
  });

  group('AppDatabase metrics', () {
    test(
      'records safe load, incremental mutation, and transaction labels',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'db-metrics-sqlite-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final metrics = DatabaseMetrics();
        final database = AppDatabase(
          metrics: metrics,
          snapshotStore: LocalDatabaseSnapshotStore(
            file: File('${root.path}/local.db'),
            backend: LocalDatabaseSnapshotBackend.sqlite,
          ),
        );

        database.upsertRecord(
          LocalTableName.appPreferences,
          'private-record-key',
          const <String, Object?>{
            'preference_key': 'theme_mode',
            'value': 'light',
          },
        );
        database.deleteRecord(
          LocalTableName.appPreferences,
          'private-record-key',
        );
        final result = database.withTransaction<void>((db) {
          db.upsertRecord(
            LocalTableName.appPreferences,
            'another-private-key',
            const <String, Object?>{
              'preference_key': 'locale',
              'value': 'zh_CN',
            },
          );
        });

        expect(result.ok, isTrue);
        final snapshot = metrics.snapshot();
        expect(snapshot.byOperation['load'], 1);
        expect(snapshot.byOperation['upsert'], 1);
        expect(snapshot.byOperation['delete'], 1);
        expect(snapshot.byOperation['transaction'], 1);
        expect(snapshot.byTable['app_preferences'], 3);
        expect(
          jsonEncode(snapshot.toJson()),
          isNot(contains('private-record-key')),
        );
      },
    );

    test('records JSON fallback full snapshots without payload text', () async {
      final root = await Directory.systemTemp.createTemp('db-metrics-json-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final metrics = DatabaseMetrics();
      final database = AppDatabase(
        metrics: metrics,
        snapshotStore: LocalDatabaseSnapshotStore(
          file: File('${root.path}/local.json'),
        ),
      );

      database.upsertRecord(
        LocalTableName.appPreferences,
        'payload-key',
        const <String, Object?>{
          'preference_key': 'visual_quality',
          'value': 'balanced',
        },
      );

      final snapshot = metrics.snapshot();
      expect(snapshot.byOperation['load'], 1);
      expect(snapshot.byOperation['full_snapshot'], 1);
      expect(snapshot.byOperation['upsert'], 1);
      final encoded = jsonEncode(snapshot.toJson());
      expect(encoded, isNot(contains('payload-key')));
      expect(encoded, isNot(contains('balanced')));
    });
  });
}
