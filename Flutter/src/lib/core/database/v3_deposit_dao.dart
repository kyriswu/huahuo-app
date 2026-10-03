import 'dart:convert';

import 'app_database.dart';

/// Low-level, metadata-only storage for the V6 personal-asset hierarchy.
final class V3DepositDao {
  V3DepositDao(this._database);

  final AppDatabase _database;

  List<LocalDatabaseRecord> listMemberships(String userScope) {
    return _listScoped(LocalTableName.knowledgeLibraryMemberships, userScope);
  }

  List<LocalDatabaseRecord> listDepositRecords(String userScope) {
    return _listScoped(LocalTableName.depositRecords, userScope);
  }

  List<LocalDatabaseRecord> listDepositFolders(String userScope) {
    return _listScoped(LocalTableName.depositFolders, userScope);
  }

  List<LocalDatabaseRecord> listGrowthLedger(String userScope) {
    return _listScoped(LocalTableName.growthLedger, userScope);
  }

  void upsertDeposit({
    required String userScope,
    required String contentId,
    required String createdAt,
    required String depositedAt,
    required String updatedAt,
    String? folderId,
  }) {
    final scope = _normalizedScope(userScope);
    _runTransaction((database) {
      _upsertWithLegacyCleanup(
        database,
        table: LocalTableName.knowledgeLibraryMemberships,
        key: _membershipKey(scope, contentId, 'deposits'),
        legacyKey: _legacyMembershipKey(scope, contentId, 'deposits'),
        value: <String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'collection': 'deposits',
          'created_at': createdAt,
        },
        ownsLegacy: (record) =>
            record['user_scope'] == scope &&
            record['content_id'] == contentId &&
            record['collection'] == 'deposits',
      );
      _upsertDepositRecord(
        database,
        userScope: scope,
        contentId: contentId,
        folderId: folderId,
        depositedAt: depositedAt,
        updatedAt: updatedAt,
      );
      _ensureGrowthLedgerEntry(
        database,
        userScope: scope,
        contentId: contentId,
        firstDepositedAt: depositedAt,
      );
    });
  }

  void upsertMembership({
    required String userScope,
    required String contentId,
    required String collection,
    required String createdAt,
  }) {
    final scope = _normalizedScope(userScope);
    _upsertRecord(
      table: LocalTableName.knowledgeLibraryMemberships,
      key: _membershipKey(scope, contentId, collection),
      legacyKey: _legacyMembershipKey(scope, contentId, collection),
      value: <String, Object?>{
        'user_scope': scope,
        'content_id': contentId,
        'collection': collection,
        'created_at': createdAt,
      },
      ownsLegacy: (record) =>
          record['user_scope'] == scope &&
          record['content_id'] == contentId &&
          record['collection'] == collection,
    );
  }

  void deleteMembership({
    required String userScope,
    required String contentId,
    required String collection,
  }) {
    final scope = _normalizedScope(userScope);
    _deleteRecord(
      table: LocalTableName.knowledgeLibraryMemberships,
      key: _membershipKey(scope, contentId, collection),
      legacyKey: _legacyMembershipKey(scope, contentId, collection),
      ownsLegacy: (record) =>
          record['user_scope'] == scope &&
          record['content_id'] == contentId &&
          record['collection'] == collection,
    );
  }

  void upsertDepositRecord({
    required String userScope,
    required String contentId,
    required String depositedAt,
    required String updatedAt,
    String? folderId,
  }) {
    final scope = _normalizedScope(userScope);
    _upsertRecord(
      table: LocalTableName.depositRecords,
      key: _depositKey(scope, contentId),
      legacyKey: _legacyDepositKey(scope, contentId),
      value: <String, Object?>{
        'user_scope': scope,
        'content_id': contentId,
        'folder_id': folderId,
        'deposited_at': depositedAt,
        'updated_at': updatedAt,
      },
      ownsLegacy: (record) =>
          record['user_scope'] == scope && record['content_id'] == contentId,
    );
  }

  void deleteDepositRecord({
    required String userScope,
    required String contentId,
  }) {
    final scope = _normalizedScope(userScope);
    _deleteRecord(
      table: LocalTableName.depositRecords,
      key: _depositKey(scope, contentId),
      legacyKey: _legacyDepositKey(scope, contentId),
      ownsLegacy: (record) =>
          record['user_scope'] == scope && record['content_id'] == contentId,
    );
  }

  void deleteDeposit({required String userScope, required String contentId}) {
    final scope = _normalizedScope(userScope);
    _runTransaction((database) {
      _deleteDepositRecord(database, userScope: scope, contentId: contentId);
      _deleteMembership(
        database,
        userScope: scope,
        contentId: contentId,
        collection: 'deposits',
      );
      _deleteAllAssetClassifications(
        database,
        userScope: scope,
        contentId: contentId,
      );
    });
  }

  void upsertDepositFolder({
    required String userScope,
    required String folderId,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? parentFolderId,
  }) {
    final scope = _normalizedScope(userScope);
    _upsertRecord(
      table: LocalTableName.depositFolders,
      key: _folderKey(scope, folderId),
      legacyKey: _legacyFolderKey(scope, folderId),
      value: <String, Object?>{
        'user_scope': scope,
        'folder_id': folderId,
        'parent_folder_id': _normalizedOptionalFolderId(parentFolderId),
        'name': name,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
      ownsLegacy: (record) =>
          record['user_scope'] == scope && record['folder_id'] == folderId,
    );
  }

  void deleteDepositFolder({
    required String userScope,
    required String folderId,
    required String updatedAt,
  }) {
    final scope = _normalizedScope(userScope);
    _runTransaction((database) {
      final folderRecords = _listScoped(
        LocalTableName.depositFolders,
        scope,
        database: database,
      );
      String? parentFolderId;
      for (final record in folderRecords) {
        if (record['folder_id'] != folderId) continue;
        final rawParentId = record['parent_folder_id'];
        parentFolderId = rawParentId is String
            ? _normalizedOptionalFolderId(rawParentId)
            : null;
        break;
      }
      for (final record in folderRecords) {
        final rawParentId = record['parent_folder_id'];
        if (rawParentId is! String || rawParentId.trim() != folderId) {
          continue;
        }
        final childFolderId = record['folder_id'] as String?;
        final name = record['name'] as String?;
        final createdAt = record['created_at'] as String?;
        if (childFolderId == null || name == null || createdAt == null) {
          continue;
        }
        _upsertDepositFolder(
          database,
          userScope: scope,
          folderId: childFolderId,
          parentFolderId: parentFolderId,
          name: name,
          createdAt: createdAt,
          updatedAt: updatedAt,
        );
      }
      for (final record in _listScoped(
        LocalTableName.depositRecords,
        scope,
        database: database,
      )) {
        if (record['folder_id'] != folderId) continue;
        final contentId = record['content_id'] as String?;
        final depositedAt = record['deposited_at'] as String?;
        if (contentId == null || depositedAt == null) continue;
        _upsertDepositRecord(
          database,
          userScope: scope,
          contentId: contentId,
          folderId: parentFolderId,
          depositedAt: depositedAt,
          updatedAt: updatedAt,
        );
      }
      _deleteCurrentAndOwnedLegacy(
        database,
        table: LocalTableName.depositFolders,
        key: _folderKey(scope, folderId),
        legacyKey: _legacyFolderKey(scope, folderId),
        ownsLegacy: (record) =>
            record['user_scope'] == scope && record['folder_id'] == folderId,
      );
    });
  }

  void _upsertDepositFolder(
    AppDatabase database, {
    required String userScope,
    required String folderId,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? parentFolderId,
  }) {
    _upsertWithLegacyCleanup(
      database,
      table: LocalTableName.depositFolders,
      key: _folderKey(userScope, folderId),
      legacyKey: _legacyFolderKey(userScope, folderId),
      value: <String, Object?>{
        'user_scope': userScope,
        'folder_id': folderId,
        'parent_folder_id': _normalizedOptionalFolderId(parentFolderId),
        'name': name,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
      ownsLegacy: (record) =>
          record['user_scope'] == userScope && record['folder_id'] == folderId,
    );
  }

  void _upsertDepositRecord(
    AppDatabase database, {
    required String userScope,
    required String contentId,
    required String depositedAt,
    required String updatedAt,
    String? folderId,
  }) {
    _upsertWithLegacyCleanup(
      database,
      table: LocalTableName.depositRecords,
      key: _depositKey(userScope, contentId),
      legacyKey: _legacyDepositKey(userScope, contentId),
      value: <String, Object?>{
        'user_scope': userScope,
        'content_id': contentId,
        'folder_id': folderId,
        'deposited_at': depositedAt,
        'updated_at': updatedAt,
      },
      ownsLegacy: (record) =>
          record['user_scope'] == userScope &&
          record['content_id'] == contentId,
    );
  }

  void _deleteDepositRecord(
    AppDatabase database, {
    required String userScope,
    required String contentId,
  }) {
    _deleteCurrentAndOwnedLegacy(
      database,
      table: LocalTableName.depositRecords,
      key: _depositKey(userScope, contentId),
      legacyKey: _legacyDepositKey(userScope, contentId),
      ownsLegacy: (record) =>
          record['user_scope'] == userScope &&
          record['content_id'] == contentId,
    );
  }

  void _deleteMembership(
    AppDatabase database, {
    required String userScope,
    required String contentId,
    required String collection,
  }) {
    _deleteCurrentAndOwnedLegacy(
      database,
      table: LocalTableName.knowledgeLibraryMemberships,
      key: _membershipKey(userScope, contentId, collection),
      legacyKey: _legacyMembershipKey(userScope, contentId, collection),
      ownsLegacy: (record) =>
          record['user_scope'] == userScope &&
          record['content_id'] == contentId &&
          record['collection'] == collection,
    );
  }

  void _deleteAllAssetClassifications(
    AppDatabase database, {
    required String userScope,
    required String contentId,
  }) {
    for (final category in _allAssetCategoryWireValues) {
      database.deleteRecord(
        LocalTableName.assetClassifications,
        _classificationKey(userScope, contentId, category),
      );
    }
    database.deleteRecord(
      LocalTableName.assetClassifications,
      _legacyClassificationKey(userScope, contentId),
    );
  }

  void _ensureGrowthLedgerEntry(
    AppDatabase database, {
    required String userScope,
    required String contentId,
    required String firstDepositedAt,
  }) {
    final key = _growthKey(userScope, contentId);
    if (database.getRecord<LocalDatabaseRecord>(
          LocalTableName.growthLedger,
          key,
        ) !=
        null) {
      return;
    }
    database.upsertRecord(LocalTableName.growthLedger, key, <String, Object?>{
      'user_scope': userScope,
      'content_id': contentId,
      'first_deposited_at': firstDepositedAt,
    });
  }

  void _upsertRecord({
    required LocalTableName table,
    required String key,
    required String legacyKey,
    required LocalDatabaseRecord value,
    required bool Function(LocalDatabaseRecord record) ownsLegacy,
  }) {
    final legacy = _database.getRecord<LocalDatabaseRecord>(table, legacyKey);
    if (legacy != null && ownsLegacy(legacy)) {
      _runTransaction((database) {
        _upsertWithLegacyCleanup(
          database,
          table: table,
          key: key,
          legacyKey: legacyKey,
          value: value,
          ownsLegacy: ownsLegacy,
        );
      });
      return;
    }
    _upsertRecordWithRollback(_database, table, key, value);
  }

  void _deleteRecord({
    required LocalTableName table,
    required String key,
    required String legacyKey,
    required bool Function(LocalDatabaseRecord record) ownsLegacy,
  }) {
    final legacy = _database.getRecord<LocalDatabaseRecord>(table, legacyKey);
    if (legacy != null && ownsLegacy(legacy)) {
      _runTransaction((database) {
        _deleteCurrentAndOwnedLegacy(
          database,
          table: table,
          key: key,
          legacyKey: legacyKey,
          ownsLegacy: ownsLegacy,
        );
      });
      return;
    }
    _deleteRecordWithRollback(_database, table, key);
  }

  void _upsertRecordWithRollback(
    AppDatabase database,
    LocalTableName table,
    String key,
    LocalDatabaseRecord value,
  ) {
    final previous = database.getRecord<LocalDatabaseRecord>(table, key);
    try {
      database.upsertRecord(table, key, value);
    } catch (cause, stackTrace) {
      _restoreRecord(database, table, key, previous);
      Error.throwWithStackTrace(cause, stackTrace);
    }
  }

  void _deleteRecordWithRollback(
    AppDatabase database,
    LocalTableName table,
    String key,
  ) {
    final previous = database.getRecord<LocalDatabaseRecord>(table, key);
    if (previous == null) return;
    try {
      database.deleteRecord(table, key);
    } catch (cause, stackTrace) {
      _restoreRecord(database, table, key, previous);
      Error.throwWithStackTrace(cause, stackTrace);
    }
  }

  void _restoreRecord(
    AppDatabase database,
    LocalTableName table,
    String key,
    LocalDatabaseRecord? previous,
  ) {
    try {
      if (previous == null) {
        database.deleteRecord(table, key);
      } else {
        database.upsertRecord(table, key, previous);
      }
    } catch (_) {
      // AppDatabase updates memory before persistence, so compensation restores
      // the controller-visible row even if the backing store remains offline.
    }
  }

  void _upsertWithLegacyCleanup(
    AppDatabase database, {
    required LocalTableName table,
    required String key,
    required String legacyKey,
    required LocalDatabaseRecord value,
    required bool Function(LocalDatabaseRecord record) ownsLegacy,
  }) {
    database.upsertRecord(table, key, value);
    _deleteOwnedLegacy(
      database,
      table: table,
      legacyKey: legacyKey,
      ownsLegacy: ownsLegacy,
    );
  }

  void _deleteCurrentAndOwnedLegacy(
    AppDatabase database, {
    required LocalTableName table,
    required String key,
    required String legacyKey,
    required bool Function(LocalDatabaseRecord record) ownsLegacy,
  }) {
    database.deleteRecord(table, key);
    _deleteOwnedLegacy(
      database,
      table: table,
      legacyKey: legacyKey,
      ownsLegacy: ownsLegacy,
    );
  }

  void _deleteOwnedLegacy(
    AppDatabase database, {
    required LocalTableName table,
    required String legacyKey,
    required bool Function(LocalDatabaseRecord record) ownsLegacy,
  }) {
    final legacy = database.getRecord<LocalDatabaseRecord>(table, legacyKey);
    if (legacy != null && ownsLegacy(legacy)) {
      database.deleteRecord(table, legacyKey);
    }
  }

  void _runTransaction(void Function(AppDatabase database) action) {
    final result = _database.withTransaction<void>(action);
    if (result.ok) return;
    throw StateError(
      result.error?.code ?? 'DEPOSIT_METADATA_TRANSACTION_FAILED',
    );
  }

  void deleteContent({required String userScope, required String contentId}) {
    final scope = _normalizedScope(userScope);
    _runTransaction((database) {
      _deleteDepositRecord(database, userScope: scope, contentId: contentId);
      _deleteAllAssetClassifications(
        database,
        userScope: scope,
        contentId: contentId,
      );
      for (final membership in _listScoped(
        LocalTableName.knowledgeLibraryMemberships,
        scope,
        database: database,
      )) {
        if (membership['content_id'] != contentId) continue;
        final collection = membership['collection'] as String?;
        if (collection == null) continue;
        _deleteMembership(
          database,
          userScope: scope,
          contentId: contentId,
          collection: collection,
        );
      }
    });
  }

  List<LocalDatabaseRecord> _listScoped(
    LocalTableName table,
    String userScope, {
    AppDatabase? database,
  }) {
    final normalizedScope = _normalizedScope(userScope);
    return (database ?? _database)
        .listRecords<LocalDatabaseRecord>(table)
        .where((record) => record['user_scope'] == normalizedScope)
        .toList(growable: false);
  }

  String _membershipKey(String userScope, String contentId, String collection) {
    return '${_scopeKey(userScope)}:membership:${_encodedKey(contentId)}:${_encodedKey(collection)}';
  }

  String _depositKey(String userScope, String contentId) {
    return '${_scopeKey(userScope)}:deposit:${_encodedKey(contentId)}';
  }

  String _folderKey(String userScope, String folderId) {
    return '${_scopeKey(userScope)}:folder:${_encodedKey(folderId)}';
  }

  String _classificationKey(
    String userScope,
    String contentId,
    String category,
  ) {
    return 'v3:scope:${_encodedKey(_normalizedScope(userScope))}:asset:'
        '${_encodedKey(contentId)}:${_encodedKey(category)}';
  }

  String _legacyClassificationKey(String userScope, String contentId) =>
      '${_scopeKey(userScope)}:asset:${_encodedKey(contentId)}';

  String _growthKey(String userScope, String contentId) =>
      'v3:scope:${_encodedKey(_normalizedScope(userScope))}:growth:'
      '${_encodedKey(contentId)}';

  String _scopeKey(String userScope) =>
      'v2:scope:${_encodedKey(_normalizedScope(userScope))}';

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
      'scope-${_legacyStableKey(_normalizedScope(userScope))}';

  String _normalizedScope(String userScope) {
    final normalized = userScope.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(userScope, 'userScope', 'must not be empty');
    }
    return normalized;
  }

  String? _normalizedOptionalFolderId(String? folderId) {
    final normalized = folderId?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  String _encodedKey(String value) {
    return base64Url.encode(utf8.encode(value)).replaceAll('=', '');
  }

  String _legacyStableKey(String value) {
    var hash = 0;
    for (final unit in value.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}

const _allAssetCategoryWireValues = <String>[
  'experience',
  'knowledge',
  'insight',
  'expression',
  'creation',
  'information',
  'mediaResources',
  'expressionTendency',
  'creationOutcome',
];
