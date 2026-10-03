import 'package:flutter/foundation.dart';

import 'feed_item_models.dart';
import 'v3_deposit_models.dart';

@immutable
final class KnowledgeTrashBacklink {
  const KnowledgeTrashBacklink({
    required this.ownerNoteId,
    required this.material,
    required this.index,
  });

  final String ownerNoteId;
  final V3LinkedMaterialRef material;
  final int index;
}

@immutable
final class KnowledgeTrashEntry {
  const KnowledgeTrashEntry({
    required this.note,
    required this.deletedAt,
    this.memberships = const <V3LibraryMembership>[],
    this.depositRecord,
    this.backlinks = const <KnowledgeTrashBacklink>[],
  });

  final V3FeedItem note;
  final DateTime deletedAt;
  final List<V3LibraryMembership> memberships;
  final V3DepositRecord? depositRecord;
  final List<KnowledgeTrashBacklink> backlinks;

  String get id => note.id;

  bool isExpiredAt(DateTime now) =>
      !now.isBefore(deletedAt.add(const Duration(days: 30)));
}
