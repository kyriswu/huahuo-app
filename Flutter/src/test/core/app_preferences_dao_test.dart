import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';

void main() {
  group('AppPreferencesDao', () {
    test('persists device metadata across database instances', () async {
      final root = await Directory.systemTemp.createTemp('app-preferences-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshot = File('${root.path}/local-db.json');
      final first = AppPreferencesDao(
        AppDatabase(snapshotStore: LocalDatabaseSnapshotStore(file: snapshot)),
      );

      first.upsertValue(
        preferenceKey: 'appearance.preset',
        value: 'mist-blue',
        updatedAt: '2026-07-24T01:02:03.000Z',
      );

      final recoveredDatabase = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshot),
      );
      final recovered = AppPreferencesDao(recoveredDatabase);
      expect(recovered.readValue(' appearance.preset '), 'mist-blue');
      expect(recovered.listPreferences().single, <String, Object?>{
        'preference_key': 'appearance.preset',
        'value': 'mist-blue',
        'updated_at': '2026-07-24T01:02:03.000Z',
      });
      expect(snapshot.readAsStringSync(), isNot(contains('user_scope')));

      recoveredDatabase.clearUserScopedLocalData('account-a');
      expect(recovered.readValue('appearance.preset'), 'mist-blue');

      expect(recovered.deleteValue('appearance.preset'), isTrue);
      expect(recovered.readValue('appearance.preset'), isNull);
      expect(recovered.deleteValue('appearance.preset'), isFalse);
    });

    test('rejects blank keys and values', () {
      final dao = AppPreferencesDao(AppDatabase());

      expect(() => dao.readValue('   '), throwsArgumentError);
      expect(
        () => dao.upsertValue(
          preferenceKey: 'appearance.preset',
          value: '   ',
          updatedAt: '2026-07-24T01:02:03.000Z',
        ),
        throwsArgumentError,
      );
    });

    test(
      'deferred values are immediate and pending writes are latest-wins',
      () async {
        final gate = Completer<void>();
        final worker = _RecordWorker(gate: gate);
        final queue = DatabaseWriteQueue();
        final dao = AppPreferencesDao(
          AppDatabase(),
          worker: worker,
          writeQueue: queue,
        );
        addTearDown(queue.dispose);

        final first = dao.upsertValueDeferred(
          preferenceKey: 'read-cache.test',
          value: 'one',
          updatedAt: '2026-08-31T09:00:00Z',
        );
        await Future<void>.delayed(Duration.zero);
        final second = dao.upsertValueDeferred(
          preferenceKey: 'read-cache.test',
          value: 'two',
          updatedAt: '2026-08-31T09:00:01Z',
        );
        final third = dao.upsertValueDeferred(
          preferenceKey: 'read-cache.test',
          value: 'three',
          updatedAt: '2026-08-31T09:00:02Z',
        );

        expect(dao.readValue('read-cache.test'), 'three');
        gate.complete();
        await Future.wait(<Future<void>>[first, second, third]);

        expect(worker.values, <String>['one', 'three']);
      },
    );

    test(
      'worker failure stays observable without synchronous fallback',
      () async {
        final database = AppDatabase();
        final worker = _RecordWorker(failWrites: true);
        final queue = DatabaseWriteQueue();
        final dao = AppPreferencesDao(
          database,
          worker: worker,
          writeQueue: queue,
        );
        addTearDown(queue.dispose);

        await expectLater(
          dao.upsertValueDeferred(
            preferenceKey: 'read-cache.failure',
            value: 'retry-me',
            updatedAt: '2026-08-31T09:00:00Z',
          ),
          throwsStateError,
        );

        expect(worker.writeAttempts, 1);
        expect(dao.readValue('read-cache.failure'), 'retry-me');
        expect(
          AppPreferencesDao(database).readValue('read-cache.failure'),
          isNull,
        );
        await expectLater(queue.flush(), throwsStateError);
      },
    );
  });
}

final class _RecordWorker implements DatabaseRecordWorkerPort {
  _RecordWorker({this.gate, this.failWrites = false});

  final Completer<void>? gate;
  final bool failWrites;
  final List<String> values = <String>[];
  var writeAttempts = 0;

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async {
    writeAttempts += 1;
    if (writeAttempts == 1 && gate != null) await gate!.future;
    if (failWrites) throw StateError('injected worker failure');
    values.add('${record['value']}');
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    for (final entry in records.entries) {
      await upsertRecord(table: table, key: entry.key, record: entry.value);
    }
  }

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => true;

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}
