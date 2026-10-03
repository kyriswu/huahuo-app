import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/features/ingestion/data/material_ingestion_store.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ingestion-store-test');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'restores nonterminal drafts in update order across database restart',
    () {
      final file = File('${temporary.path}/metadata.json');
      final firstDatabase = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: file),
      );
      final firstStore = MaterialIngestionStore(database: firstDatabase);
      final later = _draft(
        id: 'link-2',
        updatedAt: DateTime.utc(2026, 7, 14, 2),
      );
      final earlier = _draft(
        id: 'link-1',
        updatedAt: DateTime.utc(2026, 7, 14, 1),
      );
      final completed = _draft(
        id: 'link-3',
        updatedAt: DateTime.utc(2026, 7, 14, 3),
        status: MaterialIngestionStatus.completed,
        checkpoint: MaterialIngestionCheckpoint.noteDeposited,
        linkOutlineOwner: MaterialLinkOutlineOwner.backendMedia,
      );
      expect(firstStore.save(later), isNull);
      expect(firstStore.save(earlier), isNull);
      expect(firstStore.save(completed), isNull);

      final restored = MaterialIngestionStore(
        database: AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: file),
        ),
      );

      expect(restored.listRecoverable().map((draft) => draft.id), <String>[
        'link-1',
        'link-2',
      ]);
      expect(restored.get('link-2')?.normalizedUrl, 'https://example.com/a');
      expect(
        restored.get('link-3')?.linkOutlineOwner,
        MaterialLinkOutlineOwner.backendMedia,
      );
    },
  );

  test('ignores malformed sibling record without deleting valid draft', () {
    final database = AppDatabase();
    final store = MaterialIngestionStore(database: database);
    expect(store.save(_draft(id: 'valid')), isNull);
    database.upsertRecord(
      LocalTableName.materialIngestionDrafts,
      'malformed',
      <String, Object?>{
        'draft_id': 'malformed',
        'source': 'unknown',
        'status': 'queued',
      },
    );

    expect(store.listRecoverable().map((draft) => draft.id), <String>['valid']);
    expect(store.get('valid'), isNotNull);
  });

  test('owner scopes cannot read or resume each other drafts', () {
    final database = AppDatabase();
    final first = MaterialIngestionStore(
      database: database,
      ownerScope: 'user-a',
    );
    final second = MaterialIngestionStore(
      database: database,
      ownerScope: 'user-b',
    );
    expect(first.save(_draft(id: 'first')), isNull);
    expect(second.save(_draft(id: 'second')), isNull);

    expect(first.get('first'), isNotNull);
    expect(first.get('second'), isNull);
    expect(second.get('first'), isNull);
    expect(second.listRecoverable().map((draft) => draft.id), ['second']);
  });

  test('same account workspaces and legacy scope stay isolated', () {
    final database = AppDatabase();
    final workspaceA = MaterialIngestionStore(
      database: database,
      ownerScope: 'user-a\u0000workspace-a',
    );
    final workspaceB = MaterialIngestionStore(
      database: database,
      ownerScope: 'user-a\u0000workspace-b',
    );
    final legacyAccount = MaterialIngestionStore(
      database: database,
      ownerScope: 'user-a',
    );
    expect(workspaceA.save(_draft(id: 'workspace-a')), isNull);
    expect(workspaceB.save(_draft(id: 'workspace-b')), isNull);
    expect(legacyAccount.save(_draft(id: 'legacy-account')), isNull);

    expect(workspaceA.listRecoverable().map((draft) => draft.id), [
      'workspace-a',
    ]);
    expect(workspaceB.listRecoverable().map((draft) => draft.id), [
      'workspace-b',
    ]);
    expect(workspaceA.get('legacy-account'), isNull);
    expect(workspaceB.get('legacy-account'), isNull);
  });
}

MaterialIngestionDraft _draft({
  required String id,
  DateTime? updatedAt,
  MaterialIngestionStatus status = MaterialIngestionStatus.queued,
  MaterialIngestionCheckpoint checkpoint =
      MaterialIngestionCheckpoint.taskSubmitted,
  MaterialLinkOutlineOwner? linkOutlineOwner,
}) {
  final time = updatedAt ?? DateTime.utc(2026, 7, 14);
  return MaterialIngestionDraft(
    id: id,
    source: MaterialIngestionSource.link,
    status: status,
    checkpoint: checkpoint,
    title: 'Example',
    normalizedUrl: 'https://example.com/a',
    createdAt: DateTime.utc(2026, 7, 13),
    updatedAt: time,
    submitKey: 'submit-$id',
    remoteTaskId: status == MaterialIngestionStatus.completed
        ? 'task-$id'
        : null,
    noteId: status == MaterialIngestionStatus.completed ? 'note-$id' : null,
    linkOutlineOwner: linkOutlineOwner,
  );
}
