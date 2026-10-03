import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/v3_deposit_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_deposit_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_deposit_models.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  group('V3DepositRepository', () {
    test(
      'persists a scoped folder and assignment across database reloads',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-deposit-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshot = LocalDatabaseSnapshotStore(
          file: File('${root.path}/knowledge.json'),
        );
        final now = DateTime.utc(2026, 7, 16, 10);
        final firstDatabase = AppDatabase(snapshotStore: snapshot);
        final firstRepository = V3DepositRepository(
          dao: V3DepositDao(firstDatabase),
          userScope: 'user-one',
        );
        final firstLibrary = KnowledgeLibraryController(
          depositRepository: firstRepository,
          now: () => now,
        );
        final note = firstLibrary.mineNotes.first;
        final folder = firstLibrary.createDepositFolder('客户访谈', createdAt: now);

        expect(folder, isNotNull);
        expect(
          firstLibrary.depositContent(note.id, folderId: folder!.id),
          isNotNull,
        );
        expect(
          firstLibrary.assignToDepositFolder(
            contentId: note.id,
            folderId: folder.id,
            updatedAt: now,
          ),
          isTrue,
        );

        final secondDatabase = AppDatabase(snapshotStore: snapshot);
        final secondRepository = V3DepositRepository(
          dao: V3DepositDao(secondDatabase),
          userScope: 'user-one',
        );
        final secondLibrary = KnowledgeLibraryController(
          depositRepository: secondRepository,
          now: () => now,
        );
        final otherScope = V3DepositRepository(
          dao: V3DepositDao(secondDatabase),
          userScope: 'user-two',
        );

        expect(secondLibrary.depositFolderFor(folder.id)?.name, '客户访谈');
        expect(secondLibrary.depositRecordFor(note.id)?.folderId, folder.id);
        expect(otherScope.loadFolders(), isEmpty);
        expect(otherScope.loadDepositRecords(), isEmpty);
      },
    );

    test('keeps subscribed and deposited memberships independent', () {
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'user-one',
      );
      final createdAt = DateTime.utc(2026, 7, 16, 11);

      repository.saveMembership(
        V3LibraryMembership(
          contentId: 'sub-1',
          collection: V3LibraryCollection.subscribed,
          createdAt: createdAt,
        ),
      );
      repository.saveMembership(
        V3LibraryMembership(
          contentId: 'sub-1',
          collection: V3LibraryCollection.deposits,
          createdAt: createdAt,
        ),
      );

      expect(
        repository
            .loadMemberships()
            .where((item) => item.contentId == 'sub-1')
            .map((item) => item.collection),
        containsAll(<V3LibraryCollection>[
          V3LibraryCollection.subscribed,
          V3LibraryCollection.deposits,
        ]),
      );
    });

    test('deleting a personal note clears its persisted metadata', () {
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'user-one',
      );
      final library = KnowledgeLibraryController(
        depositRepository: repository,
        now: () => DateTime.utc(2026, 7, 16, 12),
      );
      final note = library.mineNotes.first;

      expect(library.deleteNote(note.id)?.id, note.id);
      expect(
        repository.loadMemberships().where((item) => item.contentId == note.id),
        isEmpty,
      );
      expect(
        repository.loadDepositRecords().where(
          (item) => item.contentId == note.id,
        ),
        isEmpty,
      );
    });

    test(
      'rename and delete retain deposits while clearing assignments',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-folders-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshot = LocalDatabaseSnapshotStore(
          file: File('${root.path}/knowledge.json'),
        );
        final timestamp = DateTime.utc(2026, 7, 18, 9);
        final database = AppDatabase(snapshotStore: snapshot);
        final repository = V3DepositRepository(
          dao: V3DepositDao(database),
          userScope: 'folder-owner',
        );
        final otherRepository = V3DepositRepository(
          dao: V3DepositDao(database),
          userScope: 'other-owner',
        );
        final library = KnowledgeLibraryController(
          depositRepository: repository,
          now: () => timestamp,
        );
        final note = library.mineNotes.first;
        final folder = library.createDepositFolder('原目录')!;
        expect(library.depositContent(note.id), isNotNull);
        expect(
          library.assignToDepositFolder(
            contentId: note.id,
            folderId: folder.id,
          ),
          isTrue,
        );
        otherRepository.saveFolder(
          V3DepositFolder(
            id: 'other-folder',
            name: '其他用户目录',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );

        expect(
          library.renameDepositFolder(
            folderId: folder.id,
            name: '新目录',
            updatedAt: timestamp.add(const Duration(minutes: 1)),
          ),
          isTrue,
        );
        expect(
          library.deleteDepositFolder(
            folder.id,
            updatedAt: timestamp.add(const Duration(minutes: 2)),
          ),
          isTrue,
        );
        expect(library.noteForId(note.id), isNotNull);
        expect(library.isDeposited(note.id), isTrue);
        expect(library.depositRecordFor(note.id)?.folderId, isNull);

        final reloaded = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: snapshot)),
          userScope: 'folder-owner',
        );
        expect(reloaded.loadFolders(), isEmpty);
        expect(reloaded.loadDepositRecords(), isNotEmpty);
        expect(
          reloaded
              .loadDepositRecords()
              .firstWhere((record) => record.contentId == note.id)
              .folderId,
          isNull,
        );
        expect(
          reloaded.loadMemberships().where(
            (membership) => membership.contentId == note.id,
          ),
          isNotEmpty,
        );
        expect(otherRepository.loadFolders().single.name, '其他用户目录');
      },
    );

    test(
      'persists nested folders and promotes direct children on deletion',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'huahuo-folder-hierarchy-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshot = LocalDatabaseSnapshotStore(
          file: File('${root.path}/knowledge.json'),
        );
        final timestamp = DateTime.utc(2026, 7, 27, 10);
        final repository = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: snapshot)),
          userScope: 'folder-hierarchy-owner',
        );
        final library = KnowledgeLibraryController(
          depositRepository: repository,
          now: () => timestamp,
        );
        final rootFolder = library.createDepositFolder('客户资料')!;
        final childFolder = library.createDepositFolder(
          '会议记录',
          parentFolderId: rootFolder.id,
        )!;
        final grandchild = library.createDepositFolder(
          '访谈',
          parentFolderId: childFolder.id,
        )!;
        expect(
          library.createDepositFolder('会议记录', parentFolderId: rootFolder.id),
          isNull,
        );
        expect(
          library.createDepositFolder('客户资料', parentFolderId: rootFolder.id),
          isNotNull,
        );

        final notes = library.mineNotes.take(2).toList(growable: false);
        expect(
          library.assignToDepositFolder(
            contentId: notes.first.id,
            folderId: rootFolder.id,
          ),
          isTrue,
        );
        expect(
          library.assignToDepositFolder(
            contentId: notes.last.id,
            folderId: childFolder.id,
          ),
          isTrue,
        );
        expect(library.depositFolderPath(grandchild.id), '客户资料 / 会议记录 / 访谈');

        expect(library.deleteDepositFolder(rootFolder.id), isTrue);
        expect(
          library.depositFolderFor(childFolder.id)?.parentFolderId,
          isNull,
        );
        expect(
          library.depositFolderFor(grandchild.id)?.parentFolderId,
          childFolder.id,
        );
        expect(library.depositRecordFor(notes.first.id)?.folderId, isNull);
        expect(
          library.depositRecordFor(notes.last.id)?.folderId,
          childFolder.id,
        );

        final reloaded = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: snapshot)),
          userScope: 'folder-hierarchy-owner',
        );
        final persistedChild = reloaded.loadFolders().singleWhere(
          (folder) => folder.id == childFolder.id,
        );
        expect(persistedChild.parentFolderId, isNull);
        expect(
          reloaded
              .loadFolders()
              .singleWhere((folder) => folder.id == grandchild.id)
              .parentFolderId,
          childFolder.id,
        );
      },
    );

    test(
      'collision-free keys isolate colliding scopes, content, and folders',
      () {
        final database = AppDatabase();
        final scopeAa = V3DepositRepository(
          dao: V3DepositDao(database),
          userScope: 'Aa',
        );
        final scopeBb = V3DepositRepository(
          dao: V3DepositDao(database),
          userScope: 'BB',
        );
        final timestamp = DateTime.utc(2026, 7, 18, 10);

        for (final folder in <V3DepositFolder>[
          V3DepositFolder(
            id: 'Aa',
            name: 'Aa 文件夹',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
          V3DepositFolder(
            id: 'BB',
            name: 'BB 文件夹',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        ]) {
          scopeAa.saveFolder(folder);
        }
        scopeBb.saveFolder(
          V3DepositFolder(
            id: 'Aa',
            name: '另一用户文件夹',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
        for (final contentId in <String>['Aa', 'BB']) {
          scopeAa.saveMembership(
            V3LibraryMembership(
              contentId: contentId,
              collection: V3LibraryCollection.deposits,
              createdAt: timestamp,
            ),
          );
          scopeAa.saveDepositRecord(
            V3DepositRecord(
              contentId: contentId,
              folderId: contentId,
              depositedAt: timestamp,
              updatedAt: timestamp,
            ),
          );
        }

        expect(
          scopeAa.loadFolders().map((folder) => folder.id).toSet(),
          <String>{'Aa', 'BB'},
        );
        expect(scopeBb.loadFolders().single.name, '另一用户文件夹');
        expect(scopeAa.loadMemberships(), hasLength(2));
        expect(scopeAa.loadDepositRecords(), hasLength(2));

        scopeAa.deleteFolder('Aa', updatedAt: timestamp);
        expect(scopeAa.loadFolders().single.id, 'BB');
        expect(scopeBb.loadFolders().single.name, '另一用户文件夹');
        expect(
          scopeAa
              .loadDepositRecords()
              .firstWhere((record) => record.contentId == 'Aa')
              .folderId,
          isNull,
        );
      },
    );

    test('legacy keys migrate lazily without deleting a colliding owner', () {
      final database = AppDatabase();
      final timestamp = DateTime.utc(2026, 7, 18, 11);
      const scope = 'legacy-user';
      const contentId = 'legacy-content';
      const folderId = 'legacy-folder';
      final createdAt = timestamp.toIso8601String();
      database.upsertRecord(
        LocalTableName.knowledgeLibraryMemberships,
        _legacyMembershipKey(scope, contentId, 'deposits'),
        <String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'collection': 'deposits',
          'created_at': createdAt,
        },
      );
      database.upsertRecord(
        LocalTableName.depositRecords,
        _legacyDepositKey(scope, contentId),
        <String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'folder_id': folderId,
          'deposited_at': createdAt,
          'updated_at': createdAt,
        },
      );
      database.upsertRecord(
        LocalTableName.depositFolders,
        _legacyFolderKey(scope, folderId),
        <String, Object?>{
          'user_scope': scope,
          'folder_id': folderId,
          'name': '旧目录',
          'created_at': createdAt,
          'updated_at': createdAt,
        },
      );
      final repository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: scope,
      );

      expect(repository.loadMemberships().single.contentId, contentId);
      expect(repository.loadDepositRecords().single.folderId, folderId);
      expect(repository.loadFolders().single.name, '旧目录');

      repository.saveMembership(
        V3LibraryMembership(
          contentId: contentId,
          collection: V3LibraryCollection.deposits,
          createdAt: timestamp,
        ),
      );
      repository.saveDepositRecord(
        V3DepositRecord(
          contentId: contentId,
          folderId: folderId,
          depositedAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      repository.saveFolder(
        V3DepositFolder(
          id: folderId,
          name: '新目录',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );

      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.knowledgeLibraryMemberships,
          _legacyMembershipKey(scope, contentId, 'deposits'),
        ),
        isNull,
      );
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.depositRecords,
          _legacyDepositKey(scope, contentId),
        ),
        isNull,
      );
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.depositFolders,
          _legacyFolderKey(scope, folderId),
        ),
        isNull,
      );
      expect(repository.loadFolders().single.name, '新目录');

      database.upsertRecord(
        LocalTableName.depositFolders,
        _legacyFolderKey('BB', 'same-folder'),
        <String, Object?>{
          'user_scope': 'BB',
          'folder_id': 'same-folder',
          'name': 'BB legacy',
          'created_at': createdAt,
          'updated_at': createdAt,
        },
      );
      final collidingScope = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'Aa',
      );
      collidingScope.saveFolder(
        V3DepositFolder(
          id: 'same-folder',
          name: 'Aa current',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      expect(collidingScope.loadFolders().single.name, 'Aa current');
      expect(
        V3DepositRepository(
          dao: V3DepositDao(database),
          userScope: 'BB',
        ).loadFolders().single.name,
        'BB legacy',
      );
    });

    test(
      'content delete surfaces transaction failure and restores metadata',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'deposit-delete-fail-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final store = _FailOnceSnapshotStore(
          file: File('${root.path}/metadata.json'),
        );
        final repository = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'delete-user',
        );
        final timestamp = DateTime.utc(2026, 7, 18, 12);
        repository.saveMembership(
          V3LibraryMembership(
            contentId: 'note',
            collection: V3LibraryCollection.deposits,
            createdAt: timestamp,
          ),
        );
        repository.saveDepositRecord(
          V3DepositRecord(
            contentId: 'note',
            depositedAt: timestamp,
            updatedAt: timestamp,
          ),
        );
        store.failNextSave = true;

        expect(
          () => repository.deleteContent('note'),
          throwsA(isA<StateError>()),
        );
        expect(repository.loadMemberships(), hasLength(1));
        expect(repository.loadDepositRecords(), hasLength(1));

        final reloaded = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'delete-user',
        );
        expect(reloaded.loadMemberships(), hasLength(1));
        expect(reloaded.loadDepositRecords(), hasLength(1));
      },
    );

    test(
      'sqlite folder delete preserves externally inserted unrelated rows',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'deposit-sqlite-batch-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final sqliteFile = File('${root.path}/metadata.sqlite');
        final store = LocalDatabaseSnapshotStore(
          file: sqliteFile,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final repository = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'sqlite-user',
        );
        final timestamp = DateTime.utc(2026, 7, 18, 13);
        repository.saveFolder(
          V3DepositFolder(
            id: 'folder',
            name: '待删除',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
        repository.saveMembership(
          V3LibraryMembership(
            contentId: 'note',
            collection: V3LibraryCollection.deposits,
            createdAt: timestamp,
          ),
        );
        repository.saveDepositRecord(
          V3DepositRecord(
            contentId: 'note',
            folderId: 'folder',
            depositedAt: timestamp,
            updatedAt: timestamp,
          ),
        );
        _insertExternalSqliteRecord(
          sqliteFile,
          table: LocalTableName.localTransferRecords,
          key: 'external-transfer',
          value: const <String, Object?>{
            'transfer_id': 'external-transfer',
            'stage': 'external',
          },
        );

        repository.deleteFolder('folder', updatedAt: timestamp);

        final raw = sqlite.sqlite3.open(sqliteFile.path);
        try {
          expect(
            raw.select(
              'SELECT record_key FROM local_records WHERE table_name = ? '
              'AND record_key = ?',
              <Object?>[
                LocalTableName.localTransferRecords.dbName,
                'external-transfer',
              ],
            ),
            hasLength(1),
          );
        } finally {
          raw.close();
        }
        final reloaded = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'sqlite-user',
        );
        expect(reloaded.loadFolders(), isEmpty);
        expect(reloaded.loadDepositRecords().single.folderId, isNull);
      },
    );

    test('ordinary new-key saves stay on incremental row operations', () async {
      final root = await Directory.systemTemp.createTemp(
        'deposit-incremental-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = _CountingSqliteSnapshotStore(
        file: File('${root.path}/metadata.sqlite'),
      );
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase(snapshotStore: store)),
        userScope: 'incremental-user',
      );
      final timestamp = DateTime.utc(2026, 7, 18, 14);
      for (var index = 0; index < 50; index++) {
        final contentId = 'note-$index';
        repository.saveMembership(
          V3LibraryMembership(
            contentId: contentId,
            collection: V3LibraryCollection.deposits,
            createdAt: timestamp,
          ),
        );
        repository.saveDepositRecord(
          V3DepositRecord(
            contentId: contentId,
            depositedAt: timestamp,
            updatedAt: timestamp,
          ),
        );
      }

      expect(store.incrementalUpsertCount, 100);
      expect(store.incrementalDeleteCount, 0);
      expect(store.completeSnapshotCount, 0);
    });

    test(
      'atomic deposit save rolls membership and record back together',
      () async {
        final root = await Directory.systemTemp.createTemp('deposit-atomic-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final store = _FailOnceSnapshotStore(
          file: File('${root.path}/metadata.json'),
        );
        final repository = V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'atomic-user',
        );
        final timestamp = DateTime.utc(2026, 7, 19, 10);
        store.failNextSave = true;

        expect(
          () => repository.saveDeposit(
            membership: V3LibraryMembership(
              contentId: 'note-atomic',
              collection: V3LibraryCollection.deposits,
              createdAt: timestamp,
            ),
            record: V3DepositRecord(
              contentId: 'note-atomic',
              depositedAt: timestamp,
              updatedAt: timestamp,
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(repository.loadMemberships(), isEmpty);
        expect(repository.loadDepositRecords(), isEmpty);
      },
    );

    test('deposit and immutable growth stay user scoped', () {
      final database = AppDatabase();
      final repository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'asset-owner',
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        now: () => DateTime.utc(2026, 7, 20, 10),
      );
      final note = controller.mineNotes.first;

      expect(controller.depositContent(note.id), isNotNull);
      expect(
        repository.loadMemberships().where(
          (membership) =>
              membership.contentId == note.id &&
              membership.collection == V3LibraryCollection.deposits,
        ),
        hasLength(1),
      );
      expect(
        repository.loadDepositRecords().where(
          (record) => record.contentId == note.id,
        ),
        hasLength(1),
      );
      expect(
        repository.loadGrowthLedger().where(
          (entry) => entry.contentId == note.id,
        ),
        hasLength(1),
      );

      final otherRepository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'other-owner',
      );
      expect(otherRepository.loadMemberships(), isEmpty);
      expect(otherRepository.loadDepositRecords(), isEmpty);
      expect(otherRepository.loadGrowthLedger(), isEmpty);

      expect(controller.removeFromDeposits(note.id), isTrue);
      expect(
        repository.loadDepositRecords().where(
          (record) => record.contentId == note.id,
        ),
        isEmpty,
      );
      expect(
        repository.loadGrowthLedger().where(
          (entry) => entry.contentId == note.id,
        ),
        hasLength(1),
      );
    });
  });
}

final class _FailOnceSnapshotStore extends LocalDatabaseSnapshotStore {
  _FailOnceSnapshotStore({required super.file});

  bool failNextSave = false;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('forced transaction failure');
    }
    super.save(schemaVersion: schemaVersion, tables: tables);
  }
}

final class _CountingSqliteSnapshotStore extends LocalDatabaseSnapshotStore {
  _CountingSqliteSnapshotStore({required super.file})
    : super(backend: LocalDatabaseSnapshotBackend.sqlite);

  int incrementalUpsertCount = 0;
  int incrementalDeleteCount = 0;
  int completeSnapshotCount = 0;

  @override
  void upsertRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord value,
  }) {
    incrementalUpsertCount += 1;
    super.upsertRecord(
      schemaVersion: schemaVersion,
      table: table,
      key: key,
      value: value,
    );
  }

  @override
  void deleteRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
  }) {
    incrementalDeleteCount += 1;
    super.deleteRecord(schemaVersion: schemaVersion, table: table, key: key);
  }

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    completeSnapshotCount += 1;
    super.save(schemaVersion: schemaVersion, tables: tables);
  }
}

void _insertExternalSqliteRecord(
  File file, {
  required LocalTableName table,
  required String key,
  required LocalDatabaseRecord value,
}) {
  final database = sqlite.sqlite3.open(file.path);
  try {
    database.execute(
      'INSERT INTO local_records(table_name, record_key, payload_json) '
      'VALUES (?, ?, ?)',
      <Object?>[table.dbName, key, jsonEncode(value)],
    );
  } finally {
    database.close();
  }
}

String _legacyMembershipKey(
  String userScope,
  String contentId,
  String collection,
) {
  return '${_legacyScopeKey(userScope)}:membership:${_legacyStableKey(contentId)}:${_legacyStableKey(collection)}';
}

String _legacyDepositKey(String userScope, String contentId) {
  return '${_legacyScopeKey(userScope)}:deposit:${_legacyStableKey(contentId)}';
}

String _legacyFolderKey(String userScope, String folderId) {
  return '${_legacyScopeKey(userScope)}:folder:${_legacyStableKey(folderId)}';
}

String _legacyScopeKey(String userScope) =>
    'scope-${_legacyStableKey(userScope.trim())}';

String _legacyStableKey(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash.toRadixString(16);
}
