import 'package:flutter_test/flutter_test.dart';

import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';

void main() {
  test(
    'isolates ETag projections by account and Workspace and clears a scope',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final first = ScopedReadCache(
        dao: dao,
        userScope: 'user_1',
        workspaceScope: 'workspace_1',
        now: () => DateTime.utc(2026, 8, 16),
      );
      first.write(
        'workspacePositioningProgress',
        'workspace_1',
        etag: '"progress-v1"',
        payload: <String, Object?>{'schemaVersion': 'v1'},
      );

      expect(
        first.read('workspacePositioningProgress', 'workspace_1')?.etag,
        '"progress-v1"',
      );
      expect(
        ScopedReadCache(
          dao: dao,
          userScope: 'user_2',
          workspaceScope: 'workspace_1',
        ).read('workspacePositioningProgress', 'workspace_1'),
        isNull,
      );
      expect(
        ScopedReadCache(
          dao: dao,
          userScope: 'user_1',
          workspaceScope: 'workspace_2',
        ).read('workspacePositioningProgress', 'workspace_1'),
        isNull,
      );

      first.clearScope();
      expect(first.read('workspacePositioningProgress', 'workspace_1'), isNull);
    },
  );

  test(
    'deferred cache writes remain staged and expose worker failure',
    () async {
      final database = AppDatabase();
      final queue = DatabaseWriteQueue();
      final dao = AppPreferencesDao(
        database,
        worker: const _FailingRecordWorker(),
        writeQueue: queue,
      );
      addTearDown(queue.dispose);
      final cache = ScopedReadCache(
        dao: dao,
        userScope: 'worker-cache-user',
        workspaceScope: 'worker-cache-workspace',
        now: () => DateTime.utc(2026, 8, 31),
      );

      cache.write(
        'workspacePositioningProgress',
        'workspace_1',
        etag: '"worker-v1"',
        payload: <String, Object?>{'schemaVersion': 'v1'},
      );
      expect(
        cache.read('workspacePositioningProgress', 'workspace_1')?.etag,
        '"worker-v1"',
      );
      await expectLater(queue.flush(), throwsStateError);

      expect(
        cache.read('workspacePositioningProgress', 'workspace_1')?.etag,
        '"worker-v1"',
      );

      final recovered = ScopedReadCache(
        dao: AppPreferencesDao(database),
        userScope: 'worker-cache-user',
        workspaceScope: 'worker-cache-workspace',
      );
      expect(
        recovered.read('workspacePositioningProgress', 'workspace_1'),
        isNull,
      );
    },
  );
}

final class _FailingRecordWorker implements DatabaseRecordWorkerPort {
  const _FailingRecordWorker();

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
