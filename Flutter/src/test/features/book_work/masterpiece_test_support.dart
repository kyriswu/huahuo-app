import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/domain/masterpiece_state.dart';

final class TestMasterpieceStore implements MasterpieceDraftStore {
  MasterpieceDraft? value;
  bool failWrites = false;
  Completer<void>? writeGate;
  Completer<void>? clearGate;
  final saved = <MasterpieceDraft?>[];

  @override
  MasterpieceDraft? read() => value;
  @override
  Future<void> write(MasterpieceDraft draft) async {
    await writeGate?.future;
    if (failWrites) throw StateError('disk full');
    value = MasterpieceDraft.fromJson(draft.toJson());
    saved.add(value);
  }

  @override
  Future<void> clear() async {
    await clearGate?.future;
    value = null;
    saved.add(null);
  }
}

final class TestMasterpieceRemote implements MasterpieceRemote {
  TestMasterpieceRemote({MasterpieceSnapshot? snapshot})
    : snapshot = snapshot ?? masterpieceSnapshot();

  MasterpieceSnapshot snapshot;
  MasterpieceSnapshot? staleRead;
  Object? readFailure;
  Object? writeFailure;
  bool failReadAfterWrite = false;
  Completer<MasterpieceSnapshot>? readGate;
  Completer<void>? writeGate;
  int reads = 0;
  final writes = <MasterpieceDraft>[];

  @override
  Future<MasterpieceSnapshot> read() async {
    reads += 1;
    if (readGate != null) return readGate!.future;
    if (readFailure != null) throw readFailure!;
    return staleRead ?? snapshot;
  }

  @override
  Future<SharedManagedPartRevision> readRevision(
    String sectionKey,
    String part,
    String revisionId,
  ) async {
    final revision = snapshot.chapter(sectionKey)!.revision!;
    if (revision.partRevisionId != revisionId) {
      throw StateError('revision missing');
    }
    return revision;
  }

  @override
  Future<SharedWorkspaceContentEvent> write(MasterpieceDraft intent) async {
    writes.add(intent);
    await writeGate?.future;
    if (writeFailure != null) throw writeFailure!;
    snapshot = masterpieceSnapshot(
      key: intent.sectionKey,
      markdown: intent.markdown,
      revision: 2,
      part: intent.part,
      managedSourceRefs: intent.managedSourceRefs,
    );
    if (failReadAfterWrite) readFailure = StateError('read unavailable');
    return SharedWorkspaceContentEvent(
      eventId: 'event-1',
      workspaceId: 'workspace-1',
      cursor: '2',
      operationId: 'operation-1',
      occurredAt: DateTime.utc(2026, 9, 5),
      objectKind: 'book_section',
      objectId: 'opaque-section-id',
      changeType: intent.isNew ? 'created' : 'revision_created',
      version: intent.isNew ? 1 : null,
      revisionId: intent.isNew ? null : 'revision-2',
      tombstone: false,
      resourcePinDelta: const SharedWorkspaceResourcePinDelta(
        added: [],
        released: [],
      ),
    );
  }
}

MasterpieceSnapshot masterpieceSnapshot({
  String key = 'chapter-1',
  String markdown = '云端正文',
  int revision = 1,
  bool empty = false,
  String part = 'raw',
  Map<String, String> additionalHeads = const {},
  List<SharedManagedLineageRef> managedSourceRefs = const [],
}) {
  final section = SharedBookSection(
    sectionKey: key,
    title: '第一章',
    group: 'chapters',
    ordinal: 0,
    metadataVersion: 1,
    currentPartRevisionIds: {part: 'revision-$revision', ...additionalHeads},
    parts: [
      SharedManagedPartHead(
        part: part,
        status: 'current',
        currentRevisionId: 'revision-$revision',
        revision: revision,
      ),
    ],
    sourceRefs: managedSourceRefs,
    resourceRefs: [
      SharedManagedResourceRef(resourceId: 'resource-1', role: 'illustration'),
    ],
    etag: '"metadata-etag"',
  );
  final book = SharedBook(
    bookId: 'book-1',
    currentBookRevisionId: 'book-revision-$revision',
    current: SharedBookRevision(
      bookRevisionId: 'book-revision-$revision',
      revision: revision,
      title: '我的云端代表作',
      language: 'zh-CN',
      status: 'active',
      sectionOrderVersion: revision,
      sections: empty
          ? []
          : [
              SharedBookSectionSnapshot(
                sectionKey: key,
                title: section.title,
                group: section.group,
                ordinal: 0,
                metadataVersion: 1,
                currentPartRevisionIds: section.currentPartRevisionIds,
              ),
            ],
      createdAt: DateTime.utc(2026, 9, 5),
    ),
    sections: empty ? [] : [section],
    etag: '"book-etag-$revision"',
  );
  return MasterpieceSnapshot(
    book: book,
    chapters: empty
        ? []
        : [
            MasterpieceChapter(
              section: section,
              revision: SharedManagedPartRevision(
                part: part,
                partRevisionId: 'revision-$revision',
                revision: revision,
                contentMarkdown: markdown,
                contentHash: 'content-hash',
                sizeBytes: markdown.length,
                sourceRefs: [
                  SharedNotePartSourceRef(
                    noteId: 'note-1',
                    part: 'raw',
                    partRevisionId: 'note-revision-1',
                  ),
                ],
                managedSourceRefs: managedSourceRefs,
                createdAt: DateTime.utc(2026, 9, 5),
                etag: '"part-etag-$revision"',
              ),
            ),
          ],
  );
}
