import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/creation_canvas_history_dao.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_history.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test(
    'database history updates one row and isolates account scopes',
    () async {
      final database = AppDatabase();
      final port = DatabaseCreationCanvasHistoryPort(
        CreationCanvasHistoryDao(database),
      );
      final createdAt = DateTime.utc(2026, 7, 20, 8);
      final first = CreationCanvasHistoryEntry(
        id: 'history-1',
        noteId: 'note-1',
        title: '第一篇创作',
        markdown: '正文',
        documentJson: '{"ops":[{"insert":"正文\\n"}]}',
        documentFormatVersion: 1,
        revision: 1,
        linkedMaterials: const [
          V3LinkedMaterialRef(
            id: 'asset-1',
            source: V3MaterialSource.note,
            title: '素材一',
          ),
        ],
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await port.upsert('user:a', first);

      expect(port.list('user:a').single.linkedMaterials.single.id, 'asset-1');
      expect(port.list('user:b'), isEmpty);

      final updated = CreationCanvasHistoryEntry(
        id: first.id,
        noteId: first.noteId,
        title: '第一篇创作（更新）',
        markdown: '更新正文',
        documentJson: '{"ops":[{"insert":"更新正文\\n"}]}',
        documentFormatVersion: 1,
        revision: 2,
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(hours: 1)),
      );
      await port.upsert('user:a', updated);

      expect(port.list('user:a'), hasLength(1));
      expect(port.find('user:a', first.id)?.revision, 2);
      expect(port.find('user:a', first.id)?.title, updated.title);
    },
  );

  test('database history skips malformed rows', () {
    final database = AppDatabase();
    database.upsertRecord(
      LocalTableName.creationCanvasHistory,
      'malformed',
      <String, Object?>{
        'user_scope': 'user:a',
        'history_id': 'broken',
        'note_id': 'note-broken',
        'document_json': '{}',
        'document_format_version': 1,
        'revision': 0,
        'created_at': DateTime.utc(2026).toIso8601String(),
        'updated_at': DateTime.utc(2026).toIso8601String(),
      },
    );
    final port = DatabaseCreationCanvasHistoryPort(
      CreationCanvasHistoryDao(database),
    );

    expect(port.list('user:a'), isEmpty);
  });

  test('database history upsert surfaces worker persistence failure', () async {
    final worker = _FailingHistoryWriteWorker();
    final queue = DatabaseWriteQueue();
    addTearDown(queue.dispose);
    final port = DatabaseCreationCanvasHistoryPort(
      CreationCanvasHistoryDao(
        AppDatabase(writeWorker: worker, writeQueue: queue),
      ),
    );

    await expectLater(
      port.upsert(
        'user:a',
        CreationCanvasHistoryEntry(
          id: 'history-worker-failure',
          noteId: 'note-worker-failure',
          title: '等待真实落盘',
          markdown: '正文',
          documentJson: '[{"insert":"正文\\n"}]',
          documentFormatVersion: 1,
          revision: 1,
          createdAt: DateTime.utc(2026, 9, 4),
          updatedAt: DateTime.utc(2026, 9, 4),
        ),
      ),
      throwsStateError,
    );
    expect(worker.attempts, 1);
  });
}

final class _FailingHistoryWriteWorker implements LocalDatabaseWriteWorkerPort {
  int attempts = 0;

  @override
  bool get isDisposed => false;

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) async {
    attempts += 1;
    throw StateError('history write failed');
  }

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) async {
    throw StateError('unexpected projection write');
  }
}
