import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../domain/masterpiece_generation.dart';
import '../domain/masterpiece_state.dart';
import 'masterpiece_repository.dart';

final class RemoteMasterpieceGenerationRepository
    implements MasterpieceGenerationRemote {
  RemoteMasterpieceGenerationRepository(ApiClient api, this.workspaceId)
    : _content = WorkspaceContentClient(api),
      _catalog = AgentCatalogClient(api),
      _runs = AgentRunClient(api),
      _books = BookWorkClient(api),
      _documents = RemoteMasterpieceRepository(api, workspaceId);

  final String workspaceId;
  final WorkspaceContentClient _content;
  final AgentCatalogClient _catalog;
  final AgentRunClient _runs;
  final BookWorkClient _books;
  final RemoteMasterpieceRepository _documents;

  @override
  Future<MasterpieceEligibility> eligibility() async {
    String? pageToken;
    String? snapshotId;
    String? cursor;
    final tokens = <String>{};
    final objects = <String, SharedWorkspaceSnapshotObject>{};
    do {
      final page = _data(
        await _content.contentSnapshot(workspaceId, pageToken: pageToken),
      );
      snapshotId ??= page.snapshotId;
      cursor ??= page.atCursor;
      if (snapshotId != page.snapshotId || cursor != page.atCursor) {
        throw const MasterpieceRemoteException('MASTERPIECE_SNAPSHOT_CHANGED');
      }
      for (final object in page.objects) {
        if (object.ownerRef.workspaceId != workspaceId) {
          throw const MasterpieceRemoteException(
            'MASTERPIECE_WORKSPACE_MISMATCH',
          );
        }
        if (object.ownerRef.kind != 'hnote') continue;
        final previous = objects[object.ownerRef.id];
        if (object.revisionId?.isNotEmpty != true ||
            (previous != null &&
                (previous.revisionId != object.revisionId ||
                    previous.tombstone != object.tombstone))) {
          throw const MasterpieceRemoteException(
            'MASTERPIECE_SNAPSHOT_INVALID',
          );
        }
        objects[object.ownerRef.id] = object;
      }
      if (!page.hasMore) break;
      pageToken = page.nextPageToken;
      if (pageToken == null ||
          pageToken.isEmpty ||
          !tokens.add(pageToken) ||
          tokens.length > 1000) {
        throw const MasterpieceRemoteException(
          'MASTERPIECE_PAGINATION_INVALID',
        );
      }
    } while (true);
    final heads =
        objects.values
            .where((object) => !object.tombstone)
            .map(
              (object) =>
                  MasterpieceSourceHead(object.ownerRef.id, object.revisionId!),
            )
            .toList()
          ..sort((first, second) => first.noteId.compareTo(second.noteId));
    return MasterpieceEligibility(heads);
  }

  @override
  Future<MasterpieceGenerationPreparation> prepare(
    MasterpieceEligibility eligibility,
  ) async {
    final profiles = _data(await _catalog.profiles());
    final route = AgentFeatureRoutes.forFeature('book.writing')!;
    if (!profiles.items.any(
      (profile) => profile.agentProfileId == route.agentProfileId,
    )) {
      throw const MasterpieceRemoteException('MASTERPIECE_AGENT_UNAVAILABLE');
    }
    final selected = eligibility.notes.take(masterpieceUnlockCount).toList();
    if (selected.isEmpty) {
      throw const MasterpieceRemoteException('MASTERPIECE_SOURCES_UNAVAILABLE');
    }
    final sources = <SharedNotePartSourceRef>[];
    for (var offset = 0; offset < selected.length; offset += 4) {
      sources.addAll(
        await Future.wait(
          selected.skip(offset).take(4).map((head) async {
            final note = _data(
              await _content.note(
                workspaceId,
                head.noteId,
                revisionId: head.revisionId,
              ),
            );
            if (note.noteId != head.noteId ||
                note.noteRevisionId != head.revisionId ||
                (note.workspaceId != null && note.workspaceId != workspaceId) ||
                note.state != 'active') {
              throw const MasterpieceRemoteException(
                'MASTERPIECE_SOURCE_CHANGED',
              );
            }
            return SharedNotePartSourceRef(
              noteId: note.noteId,
              part: 'raw',
              partRevisionId: note.raw.partRevisionId,
            );
          }),
        ),
      );
    }
    return MasterpieceGenerationPreparation(
      route.agentProfileId,
      List.unmodifiable(sources),
    );
  }

  @override
  Future<AgentRunSnapshot> create(MasterpieceGenerationIntent intent) async =>
      _validatedRun(
        _data(
          await _runs.create(
            AgentRunRequest(
              workspaceId: workspaceId,
              agentProfileId: intent.profileId,
              input: SharedAgentInput(
                content: [
                  SharedAgentTextContent(text: intent.instruction),
                  for (final source in intent.sources)
                    SharedAgentWorkspaceDocumentContent(
                      ownerKind: 'hnote',
                      ownerId: source.noteId,
                      part: source.part,
                      partRevisionId: source.partRevisionId,
                    ),
                ],
              ),
            ),
            idempotencyKey: intent.requestKey,
          ),
          mutation: true,
        ),
      );

  @override
  Future<AgentRunSnapshot> run(String runId) async =>
      _validatedRun(_data(await _runs.get(runId)), runId);

  @override
  Future<AgentRunSnapshot> cancel(MasterpieceGenerationIntent intent) async =>
      _validatedRun(
        _data(
          await _runs.cancel(
            intent.runId!,
            idempotencyKey: intent.cancellationKey,
          ),
          mutation: true,
        ),
        intent.runId,
      );

  AgentRunSnapshot _validatedRun(AgentRunSnapshot run, [String? expectedId]) {
    if (run.workspaceId != workspaceId ||
        (expectedId != null && run.agentRunId != expectedId)) {
      throw const MasterpieceRemoteException(
        'MASTERPIECE_RUN_IDENTITY_INVALID',
        ambiguous: true,
      );
    }
    return run;
  }

  @override
  Future<MasterpieceSnapshot> book() => _documents.read();

  @override
  Future<void> publish(MasterpieceGenerationIntent intent) async {
    _data(
      await _books.createBookSection(
        workspaceId,
        request: SharedCreateBookSectionRequest(
          sectionKey: intent.sectionKey,
          title: intent.title,
          group: 'chapters',
          parts: {'raw': intent.markdown!},
          sourceRefs: [
            for (final source in intent.sources)
              SharedManagedNotePartLineageRef(
                noteId: source.noteId,
                part: source.part,
                partRevisionId: source.partRevisionId,
              ),
          ],
        ),
        idempotencyKey: intent.publicationKey,
      ),
      mutation: true,
    );
  }

  @override
  Future<MasterpieceSnapshot?> readback(
    MasterpieceGenerationIntent intent,
  ) async {
    final snapshot = await book();
    if (snapshot.book.bookId != intent.bookId) return null;
    final chapter = snapshot.chapter(intent.sectionKey);
    if (chapter == null) return null;
    if (chapter.revision?.part == 'raw' &&
        chapter.revision?.contentMarkdown == intent.markdown) {
      return snapshot;
    }
    final history = _data(
      await _books.bookSectionPartRevisions(
        workspaceId,
        intent.sectionKey,
        'raw',
      ),
    );
    final currentId = chapter.section.currentPartRevisionIds['raw'];
    final visible = history.items
        .where((revision) => revision.partRevisionId == currentId)
        .firstOrNull;
    return visible != null &&
            history.items.any(
              (revision) =>
                  revision.contentMarkdown == intent.markdown &&
                  visible.revision >= revision.revision,
            )
        ? snapshot
        : null;
  }

  T _data<T>(ApiResult<T> result, {bool mutation = false}) {
    if (result.ok && result.data != null) return result.data as T;
    final status = result.status;
    throw MasterpieceRemoteException(
      result.error?.code ?? 'MASTERPIECE_GENERATION_RESPONSE_INVALID',
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

final class PersistentMasterpieceGenerationStore extends ChangeNotifier
    implements MasterpieceGenerationStore {
  PersistentMasterpieceGenerationStore(this._dao, String identity)
    : _key = 'masterpiece-gen:${sha256.convert(utf8.encode(identity))}';
  final AppPreferencesDao _dao;
  final String _key;
  MasterpieceGenerationRecord? _committedRecord;
  bool _loaded = false;
  bool _disposed = false;

  @override
  MasterpieceGenerationRecord? read() {
    if (_loaded) return _committedRecord;
    final value = _dao.readValue(_key);
    _committedRecord = value == null
        ? null
        : MasterpieceGenerationRecord.fromJson(
            Map<String, Object?>.from(jsonDecode(value) as Map),
          );
    _loaded = true;
    return _committedRecord;
  }

  @override
  Future<void> write(MasterpieceGenerationRecord record) async {
    read();
    await _dao.upsertValueDeferred(
      preferenceKey: _key,
      value: jsonEncode(record.toJson()),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _committedRecord = record;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
