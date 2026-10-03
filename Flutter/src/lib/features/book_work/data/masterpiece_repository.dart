import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../domain/masterpiece_state.dart';

final class RemoteMasterpieceRepository implements MasterpieceRemote {
  RemoteMasterpieceRepository(ApiClient client, this.workspaceId)
    : _client = BookWorkClient(client);

  final BookWorkClient _client;
  final String workspaceId;
  final _chapterParts =
      <
        ({String sectionKey, String part, String revisionId}),
        SharedManagedPartRevision
      >{};
  final _chapterReads =
      <
        ({String sectionKey, String part, String revisionId}),
        Future<SharedManagedPartRevision>
      >{};
  Set<({String sectionKey, String part, String revisionId})> _selectedParts =
      {};

  @override
  Future<MasterpieceSnapshot> read() async {
    final book = _data(await _client.bookDetail(workspaceId));
    _selectedParts = {
      for (final section in book.sections)
        for (final entry in section.currentPartRevisionIds.entries)
          (
            sectionKey: section.sectionKey,
            part: entry.key,
            revisionId: entry.value,
          ),
    };
    _chapterParts.removeWhere((key, _) => !_selectedParts.contains(key));
    final chapters = <MasterpieceChapter>[];
    for (var offset = 0; offset < book.sections.length; offset += 4) {
      chapters.addAll(
        await Future.wait(book.sections.skip(offset).take(4).map(_readChapter)),
      );
    }
    return MasterpieceSnapshot(book: book, chapters: chapters);
  }

  Future<MasterpieceChapter> _readChapter(SharedBookSection section) async {
    MasterpieceChapter? first;
    for (final part in const ['raw', 'outline', 'germination']) {
      final revisionId = section.currentPartRevisionIds[part];
      if (revisionId != null) {
        final chapter = MasterpieceChapter(
          section: section,
          revision: await _readChapterRevision(
            section.sectionKey,
            part,
            revisionId,
          ),
        );
        first ??= chapter;
        if (chapter.revision!.contentMarkdown.trim().isNotEmpty) {
          return chapter;
        }
      }
    }
    return first ?? MasterpieceChapter(section: section);
  }

  Future<SharedManagedPartRevision> _readChapterRevision(
    String sectionKey,
    String part,
    String revisionId,
  ) async {
    final key = (sectionKey: sectionKey, part: part, revisionId: revisionId);
    final cached = _chapterParts[key];
    if (cached != null) return cached;
    final active = _chapterReads[key];
    if (active != null) return active;
    final request = readRevision(sectionKey, part, revisionId).then((value) {
      if (_selectedParts.contains(key)) _chapterParts[key] = value;
      return value;
    });
    _chapterReads[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterReads[key], request)) _chapterReads.remove(key);
    }
  }

  @override
  Future<SharedManagedPartRevision> readRevision(
    String sectionKey,
    String part,
    String revisionId,
  ) async => _data(
    await _client.bookSectionPart(
      workspaceId,
      sectionKey,
      part,
      partRevisionId: revisionId,
    ),
  );

  @override
  Future<SharedWorkspaceContentEvent> write(MasterpieceDraft intent) async {
    if (intent.isNew) {
      return _data(
        await _client.createBookSection(
          workspaceId,
          request: SharedCreateBookSectionRequest(
            sectionKey: intent.sectionKey,
            title: intent.title,
            group: 'chapters',
            parts: {intent.part: intent.markdown},
            sourceRefs: [
              ...intent.managedSourceRefs,
              for (final reference in intent.sourceRefs)
                SharedManagedNotePartLineageRef(
                  noteId: reference.noteId,
                  part: reference.part,
                  partRevisionId: reference.partRevisionId,
                ),
            ],
            resourceRefs: intent.resourceRefs,
          ),
          idempotencyKey: intent.idempotencyKey!,
        ),
        mutation: true,
      );
    }
    if (intent.managedSourceRefs.isNotEmpty) {
      throw const MasterpieceRemoteException(
        'MASTERPIECE_MANAGED_LINEAGE_REQUIRES_COPY',
      );
    }
    return _data(
      await _client.putBookSectionPart(
        workspaceId,
        intent.sectionKey,
        intent.part,
        request: SharedUpdateManagedPartRequest(
          contentMarkdown: intent.markdown,
          basePartRevisionId: intent.baseRevisionId!,
          sourceRefs: intent.sourceRefs,
          resourceRefs: intent.resourceRefs,
        ),
        etag: intent.etag!,
        idempotencyKey: intent.idempotencyKey!,
      ),
      mutation: true,
    );
  }

  T _data<T>(ApiResult<T> result, {bool mutation = false}) {
    final value = result.data;
    if (result.ok && value != null) return value;
    final status = result.status;
    throw MasterpieceRemoteException(
      result.error?.code ?? 'MASTERPIECE_RESPONSE_INVALID',
      status: status,
      ambiguous:
          mutation &&
          (status == null ||
              status >= 500 ||
              status == 408 ||
              (status >= 200 && status < 300)),
    );
  }
}

final class PersistentMasterpieceDraftStore implements MasterpieceDraftStore {
  PersistentMasterpieceDraftStore(this._dao, String identity)
    : _key = 'masterpiece:${sha256.convert(utf8.encode(identity))}';

  final AppPreferencesDao _dao;
  final String _key;

  @override
  MasterpieceDraft? read() {
    final value = _dao.readValue(_key);
    if (value == null) return null;
    return MasterpieceDraft.fromJson(
      Map<String, Object?>.from(jsonDecode(value) as Map),
    );
  }

  @override
  Future<void> write(MasterpieceDraft draft) => _dao.upsertValueDeferred(
    preferenceKey: _key,
    value: jsonEncode(draft.toJson()),
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );

  @override
  Future<void> clear() async {
    await _dao.deleteValueDeferred(_key);
  }
}
