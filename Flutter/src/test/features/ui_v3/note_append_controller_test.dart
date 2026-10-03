import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_append_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  V3FeedItem note({
    required String id,
    V3NoteOwnership ownership = V3NoteOwnership.mine,
  }) {
    return V3FeedItem(
      id: id,
      title: '笔记 $id',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 15, 9),
      rawBody: '原始正文',
      ownership: ownership,
    );
  }

  test(
    'session demo append is isolated by target and never mutates library',
    () async {
      final targetA = note(id: 'note-a');
      final targetB = note(id: 'note-b');
      final library = KnowledgeLibraryController(
        initialNotes: [targetA, targetB],
      );
      final port = _RecordingAppendPort();
      final controller = NoteAppendController(
        knowledgeLibrary: library,
        port: port,
        now: () => DateTime(2026, 7, 15, 10),
      );

      final appended = await controller.submit(
        targetNoteId: targetA.id,
        source: NoteAppendSource.link,
        title: 'example.com',
        referenceId: 'https://example.com/article',
      );

      expect(appended?.status, NoteAppendStatus.completed);
      expect(appended?.isDemo, isTrue);
      expect(controller.itemsFor(targetA.id), hasLength(1));
      expect(controller.itemsFor(targetB.id), isEmpty);
      expect(port.requests.single.targetNoteId, targetA.id);
      expect(port.requests.single.idempotencyKey, startsWith('${targetA.id}:'));
      expect(library.noteForId(targetA.id)?.rawBody, targetA.rawBody);
      expect(library.noteForId(targetA.id)?.linkedMaterials, isEmpty);
      expect(library.notes, hasLength(2));

      controller.clearSession();
      expect(controller.itemsFor(targetA.id), isEmpty);
      expect(library.notes, hasLength(2));
    },
  );

  test('missing and read-only targets reject before the append port', () async {
    final readOnly = note(
      id: 'read-only',
      ownership: V3NoteOwnership.subscribed,
    );
    final port = _RecordingAppendPort();
    final controller = NoteAppendController(
      knowledgeLibrary: KnowledgeLibraryController(initialNotes: [readOnly]),
      port: port,
    );

    expect(
      await controller.submit(
        targetNoteId: readOnly.id,
        source: NoteAppendSource.monologue,
        title: '一段录音',
      ),
      isNull,
    );
    expect(
      await controller.submit(
        targetNoteId: 'missing',
        source: NoteAppendSource.document,
        title: '资料.pdf',
      ),
      isNull,
    );
    expect(port.requests, isEmpty);
  });

  test(
    'failed demo task stays retryable with the same target request',
    () async {
      final target = note(id: 'target');
      final port = _RecordingAppendPort(failFirst: true);
      final controller = NoteAppendController(
        knowledgeLibrary: KnowledgeLibraryController(initialNotes: [target]),
        port: port,
      );

      final failed = await controller.submit(
        targetNoteId: target.id,
        source: NoteAppendSource.document,
        title: '产品资料.pdf',
        referenceId: 'picked-document://1',
      );
      expect(failed?.status, NoteAppendStatus.failed);

      final retried = await controller.retry(failed!.id);
      expect(retried?.status, NoteAppendStatus.completed);
      expect(port.requests, hasLength(2));
      expect(port.requests[1].targetNoteId, target.id);
      expect(port.requests[1].idempotencyKey, port.requests[0].idempotencyKey);
    },
  );

  test(
    'production success requires and merges the complete matching parent',
    () async {
      final target = note(id: 'parent');
      final updated = target.copyWith(
        rawBody: '服务端返回的完整父笔记',
        remoteRevision: 8,
        syncState: NoteSyncState.synced,
      );
      final library = KnowledgeLibraryController(initialNotes: [target]);
      final controller = NoteAppendController(
        knowledgeLibrary: library,
        port: _ProductionAppendPort(updatedParent: updated),
      );

      final completed = await controller.submit(
        targetNoteId: target.id,
        source: NoteAppendSource.relatedNote,
        title: '关联资料',
        referenceId: 'related-1',
      );

      expect(completed?.status, NoteAppendStatus.completed);
      expect(completed?.isDemo, isFalse);
      expect(library.noteForId(target.id)?.rawBody, '服务端返回的完整父笔记');

      final missingController = NoteAppendController(
        knowledgeLibrary: library,
        port: _ProductionAppendPort(),
      );
      final failed = await missingController.submit(
        targetNoteId: target.id,
        source: NoteAppendSource.link,
        title: '正式追加',
        referenceId: 'https://example.com',
      );
      expect(failed?.status, NoteAppendStatus.failed);
      expect(failed?.errorCode, 'NOTE_APPEND_UPDATED_PARENT_MISSING');
    },
  );

  test(
    'late async completion cannot repopulate a cleared or disposed session',
    () async {
      final target = note(id: 'target');
      final port = _DelayedAppendPort();
      final controller = NoteAppendController(
        knowledgeLibrary: KnowledgeLibraryController(initialNotes: [target]),
        port: port,
      );

      final pending = controller.submit(
        targetNoteId: target.id,
        source: NoteAppendSource.link,
        title: '延迟链接',
        referenceId: 'https://example.com/delayed',
      );
      controller.clearSession();
      port.complete();

      expect(await pending, isNull);
      expect(controller.itemsFor(target.id), isEmpty);
      controller.dispose();
    },
  );
}

final class _RecordingAppendPort implements NoteAppendPort {
  _RecordingAppendPort({this.failFirst = false});

  final bool failFirst;
  final List<NoteAppendRequest> requests = <NoteAppendRequest>[];

  @override
  bool get isDemo => true;

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    requests.add(request);
    onProgress(NoteAppendStatus.analyzing);
    if (failFirst && requests.length == 1) {
      return const NoteAppendPortResult(
        ok: false,
        isDemo: true,
        errorCode: 'DEMO_ANALYSIS_FAILED',
      );
    }
    return const NoteAppendPortResult(ok: true, isDemo: true, summary: '演示摘要');
  }
}

final class _ProductionAppendPort implements NoteAppendPort {
  _ProductionAppendPort({this.updatedParent});

  final V3FeedItem? updatedParent;

  @override
  bool get isDemo => false;

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    onProgress(NoteAppendStatus.analyzing);
    return NoteAppendPortResult(ok: true, updatedParentNote: updatedParent);
  }
}

final class _DelayedAppendPort implements NoteAppendPort {
  final Completer<void> _gate = Completer<void>();

  @override
  bool get isDemo => true;

  void complete() => _gate.complete();

  @override
  Future<NoteAppendPortResult> submit(
    NoteAppendRequest request, {
    required NoteAppendProgress onProgress,
  }) async {
    await _gate.future;
    onProgress(NoteAppendStatus.analyzing);
    return const NoteAppendPortResult(ok: true, isDemo: true);
  }
}
