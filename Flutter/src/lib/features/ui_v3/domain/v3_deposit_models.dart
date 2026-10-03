import 'package:flutter/foundation.dart';

/// A collection relationship is independent from a feed item's material source.
enum V3LibraryCollection { deposits, subscribed, square }

enum V3DepositFilterKind { browse, all, unclassified, folder }

@immutable
final class GrowthLedgerEntry {
  const GrowthLedgerEntry({
    required this.contentId,
    required this.firstDepositedAt,
  }) : assert(contentId != '');

  final String contentId;
  final DateTime firstDepositedAt;
}

enum V3AssetStatisticsPeriod { week, month }

enum V3AssetMediaKind { image, video }

@immutable
final class V3AssetMediaResource {
  const V3AssetMediaResource({
    required this.resourceId,
    required this.contentId,
    required this.displayName,
    required this.kind,
    required this.createdAt,
  });

  /// Opaque app-private reference. It is never a local filesystem path.
  final String resourceId;
  final String contentId;
  final String displayName;
  final V3AssetMediaKind kind;
  final DateTime createdAt;
}

@immutable
final class V3LibraryMembership {
  const V3LibraryMembership({
    required this.contentId,
    required this.collection,
    required this.createdAt,
  });

  final String contentId;
  final V3LibraryCollection collection;
  final DateTime createdAt;
}

@immutable
final class V3DepositRecord {
  const V3DepositRecord({
    required this.contentId,
    required this.depositedAt,
    required this.updatedAt,
    this.folderId,
  });

  final String contentId;
  final String? folderId;
  final DateTime depositedAt;
  final DateTime updatedAt;

  V3DepositRecord copyWith({
    String? folderId,
    DateTime? updatedAt,
    bool clearFolder = false,
  }) {
    return V3DepositRecord(
      contentId: contentId,
      folderId: clearFolder ? null : folderId ?? this.folderId,
      depositedAt: depositedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

@immutable
final class V3DepositFolder {
  const V3DepositFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.parentFolderId,
  }) : assert(id != ''),
       assert(name != ''),
       assert(parentFolderId != id);

  final String id;
  final String name;
  final String? parentFolderId;
  final DateTime createdAt;
  final DateTime updatedAt;

  V3DepositFolder copyWith({
    String? name,
    String? parentFolderId,
    DateTime? updatedAt,
    bool clearParentFolder = false,
  }) {
    return V3DepositFolder(
      id: id,
      name: name ?? this.name,
      parentFolderId: clearParentFolder
          ? null
          : parentFolderId ?? this.parentFolderId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
