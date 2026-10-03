import '../../../core/database/v3_deposit_dao.dart';
import '../domain/v3_deposit_models.dart';

/// Persistence boundary for V6 deposit metadata. It never stores note bodies.
abstract interface class SubscriptionLibraryPort {
  List<V3LibraryMembership> loadMemberships();

  void saveMembership(V3LibraryMembership membership);

  void deleteMembership({
    required String contentId,
    required V3LibraryCollection collection,
  });
}

final class V3DepositRepository implements SubscriptionLibraryPort {
  V3DepositRepository({
    required V3DepositDao dao,
    String userScope = defaultUserScope,
  }) : _dao = dao,
       _userScope = _normalizeScope(userScope);

  static const defaultUserScope = 'ui-v3-local-user';

  final V3DepositDao _dao;
  final String _userScope;

  String get userScope => _userScope;

  @override
  List<V3LibraryMembership> loadMemberships() {
    final memberships = <V3LibraryMembership>[
      for (final record in _dao.listMemberships(_userScope))
        if (_membershipFromRecord(record) case final membership?) membership,
    ];
    memberships.sort((left, right) {
      final byContent = left.contentId.compareTo(right.contentId);
      return byContent != 0
          ? byContent
          : left.collection.index.compareTo(right.collection.index);
    });
    return List<V3LibraryMembership>.unmodifiable(memberships);
  }

  List<V3DepositRecord> loadDepositRecords() {
    final records = <V3DepositRecord>[
      for (final record in _dao.listDepositRecords(_userScope))
        if (_depositRecordFromRecord(record) case final deposit?) deposit,
    ]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<V3DepositRecord>.unmodifiable(records);
  }

  List<V3DepositFolder> loadFolders() {
    final folders =
        <V3DepositFolder>[
          for (final record in _dao.listDepositFolders(_userScope))
            if (_folderFromRecord(record) case final folder?) folder,
        ]..sort((left, right) {
          final byName = left.name.compareTo(right.name);
          return byName != 0 ? byName : left.id.compareTo(right.id);
        });
    return List<V3DepositFolder>.unmodifiable(folders);
  }

  List<GrowthLedgerEntry> loadGrowthLedger() {
    final entries =
        <GrowthLedgerEntry>[
          for (final record in _dao.listGrowthLedger(_userScope))
            if (_growthEntryFromRecord(record) case final entry?) entry,
        ]..sort(
          (left, right) =>
              right.firstDepositedAt.compareTo(left.firstDepositedAt),
        );
    return List<GrowthLedgerEntry>.unmodifiable(entries);
  }

  void saveDeposit({
    required V3LibraryMembership membership,
    required V3DepositRecord record,
  }) {
    if (membership.collection != V3LibraryCollection.deposits ||
        membership.contentId != record.contentId) {
      throw ArgumentError(
        'Deposit membership and record must describe one item.',
      );
    }
    _dao.upsertDeposit(
      userScope: _userScope,
      contentId: record.contentId,
      folderId: record.folderId,
      createdAt: membership.createdAt.toUtc().toIso8601String(),
      depositedAt: record.depositedAt.toUtc().toIso8601String(),
      updatedAt: record.updatedAt.toUtc().toIso8601String(),
    );
  }

  @override
  void saveMembership(V3LibraryMembership membership) {
    _dao.upsertMembership(
      userScope: _userScope,
      contentId: membership.contentId,
      collection: membership.collection.name,
      createdAt: membership.createdAt.toUtc().toIso8601String(),
    );
  }

  @override
  void deleteMembership({
    required String contentId,
    required V3LibraryCollection collection,
  }) {
    _dao.deleteMembership(
      userScope: _userScope,
      contentId: contentId,
      collection: collection.name,
    );
  }

  void saveDepositRecord(V3DepositRecord deposit) {
    _dao.upsertDepositRecord(
      userScope: _userScope,
      contentId: deposit.contentId,
      folderId: deposit.folderId,
      depositedAt: deposit.depositedAt.toUtc().toIso8601String(),
      updatedAt: deposit.updatedAt.toUtc().toIso8601String(),
    );
  }

  void deleteDepositRecord(String contentId) {
    _dao.deleteDepositRecord(userScope: _userScope, contentId: contentId);
  }

  void deleteDeposit(String contentId) {
    _dao.deleteDeposit(userScope: _userScope, contentId: contentId);
  }

  void saveFolder(V3DepositFolder folder) {
    _dao.upsertDepositFolder(
      userScope: _userScope,
      folderId: folder.id,
      name: folder.name,
      parentFolderId: folder.parentFolderId,
      createdAt: folder.createdAt.toUtc().toIso8601String(),
      updatedAt: folder.updatedAt.toUtc().toIso8601String(),
    );
  }

  void deleteFolder(String folderId, {required DateTime updatedAt}) {
    _dao.deleteDepositFolder(
      userScope: _userScope,
      folderId: folderId,
      updatedAt: updatedAt.toUtc().toIso8601String(),
    );
  }

  void deleteContent(String contentId) {
    _dao.deleteContent(userScope: _userScope, contentId: contentId);
  }
}

V3LibraryMembership? _membershipFromRecord(Map<String, Object?> record) {
  final contentId = _nonEmpty(record['content_id']);
  final collection = _collectionFor(record['collection']);
  final createdAt = _date(record['created_at']);
  if (contentId == null || collection == null || createdAt == null) return null;
  return V3LibraryMembership(
    contentId: contentId,
    collection: collection,
    createdAt: createdAt,
  );
}

V3DepositRecord? _depositRecordFromRecord(Map<String, Object?> record) {
  final contentId = _nonEmpty(record['content_id']);
  final depositedAt = _date(record['deposited_at']);
  final updatedAt = _date(record['updated_at']);
  if (contentId == null || depositedAt == null || updatedAt == null) {
    return null;
  }
  return V3DepositRecord(
    contentId: contentId,
    folderId: _nonEmpty(record['folder_id']),
    depositedAt: depositedAt,
    updatedAt: updatedAt,
  );
}

V3DepositFolder? _folderFromRecord(Map<String, Object?> record) {
  final id = _nonEmpty(record['folder_id']);
  final name = _nonEmpty(record['name']);
  final createdAt = _date(record['created_at']);
  final updatedAt = _date(record['updated_at']);
  if (id == null || name == null || createdAt == null || updatedAt == null) {
    return null;
  }
  final parentFolderId = _nonEmpty(record['parent_folder_id']);
  return V3DepositFolder(
    id: id,
    name: name,
    parentFolderId: parentFolderId == id ? null : parentFolderId,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

GrowthLedgerEntry? _growthEntryFromRecord(Map<String, Object?> record) {
  final contentId = _nonEmpty(record['content_id']);
  final firstDepositedAt = _date(record['first_deposited_at']);
  if (contentId == null || firstDepositedAt == null) return null;
  return GrowthLedgerEntry(
    contentId: contentId,
    firstDepositedAt: firstDepositedAt,
  );
}

V3LibraryCollection? _collectionFor(Object? raw) {
  for (final collection in V3LibraryCollection.values) {
    if (collection.name == raw) return collection;
  }
  return null;
}

DateTime? _date(Object? raw) => DateTime.tryParse('${raw ?? ''}');

String? _nonEmpty(Object? raw) {
  final value = '${raw ?? ''}'.trim();
  return value.isEmpty ? null : value;
}

String _normalizeScope(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'userScope', 'must not be empty');
  }
  return normalized;
}
