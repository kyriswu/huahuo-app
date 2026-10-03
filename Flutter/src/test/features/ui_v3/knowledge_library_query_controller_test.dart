import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_query_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_deposit_models.dart';

void main() {
  test('owns normalized query state and memoized immutable results', () {
    final now = DateTime(2026, 8, 31, 12);
    var notes = <V3FeedItem>[
      _note('beta', 'Beta', now.subtract(const Duration(hours: 1))),
      _note('alpha', 'Alpha', now),
    ];
    final controller = KnowledgeLibraryQueryController(
      notes: () => notes,
      hasMembership: (_, _) => false,
      isDeposited: (_) => true,
      folderNameFor: (_) => null,
      folderIdFor: (_) => null,
      folderExists: (_) => false,
      folderNames: () => const <String>[],
      effectiveTags: (note) => note.topics,
      now: () => now,
    );
    addTearDown(controller.dispose);

    final first = controller.filteredNotesFor(V3KnowledgeLibraryTab.mine);
    expect(first.map((note) => note.id), <String>['alpha', 'beta']);
    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.mine),
      same(first),
    );
    expect(() => first.add(_note('x', 'X', now)), throwsUnsupportedError);

    var notifications = 0;
    controller.addListener(() => notifications += 1);
    controller.setQuery('  beta  ');
    controller.setQuery('beta');
    expect(notifications, 1);
    expect(controller.query, 'beta');
    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.mine).single.id,
      'beta',
    );

    notes = <V3FeedItem>[...notes, _note('beta-2', 'Beta 2', now)];
    controller.invalidate();
    expect(
      controller
          .filteredNotesFor(V3KnowledgeLibraryTab.mine)
          .map((note) => note.id),
      <String>['beta-2', 'beta'],
    );
  });

  test('projects membership, date, and deposit-folder filters', () {
    final now = DateTime(2026, 8, 31, 12);
    final notes = <V3FeedItem>[
      _note('mine-today', 'Mine today', now),
      _note(
        'subscribed-old',
        'Subscribed old',
        now.subtract(const Duration(days: 20)),
        ownership: V3NoteOwnership.subscribed,
      ),
      _note('foldered', 'Foldered', now.subtract(const Duration(days: 2))),
    ];
    final memberships = <(String, V3LibraryCollection)>{
      ('subscribed-old', V3LibraryCollection.subscribed),
    };
    final folderIds = <String, String>{'foldered': 'folder-1'};
    final controller = KnowledgeLibraryQueryController(
      notes: () => notes,
      hasMembership: (id, collection) => memberships.contains((id, collection)),
      isDeposited: (_) => true,
      folderNameFor: (id) => folderIds[id] == null ? null : 'Projects',
      folderIdFor: (id) => folderIds[id],
      folderExists: (id) => id == 'folder-1',
      folderNames: () => const <String>['Projects'],
      effectiveTags: (_) => const <String>[],
      now: () => now,
    );
    addTearDown(controller.dispose);

    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.subscribed).single.id,
      'subscribed-old',
    );

    controller.setTimeFilter(KnowledgeTimeFilter.last7Days);
    expect(
      controller
          .filteredNotesFor(V3KnowledgeLibraryTab.mine)
          .map((note) => note.id),
      <String>['mine-today', 'foldered'],
    );

    controller.setDepositFolderFilter('folder-1');
    expect(controller.filteredDepositNotes.single.id, 'foldered');
    expect(controller.groupedDepositNotes.keys, <String>['我的内容']);

    controller.setDepositGrouping(V3KnowledgeGrouping.folder);
    expect(controller.groupedDepositNotes.keys, <String>['Projects']);
  });
}

V3FeedItem _note(
  String id,
  String title,
  DateTime updatedAt, {
  V3NoteOwnership ownership = V3NoteOwnership.mine,
}) => V3FeedItem(
  id: id,
  title: title,
  source: V3MaterialSource.note,
  createdAt: updatedAt,
  updatedAt: updatedAt,
  rawBody: title,
  ownership: ownership,
);
