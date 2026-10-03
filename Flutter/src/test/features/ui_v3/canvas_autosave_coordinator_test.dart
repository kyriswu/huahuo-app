import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_autosave_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test(
    'draft writes and cleanup share one FIFO across page lifetimes',
    () async {
      final store = _QueuedDraftStore()..gate = Completer<void>();
      final firstPage = CanvasDraftPersistenceCoordinator(store);
      final nextPage = CanvasDraftPersistenceCoordinator(store);
      expect(identical(firstPage, nextPage), isTrue);
      final first = firstPage.persist(_queuedDraft(1));
      final receipt = firstPage.persist(_queuedDraft(2));
      final clear = nextPage.persist(null);
      final fresh = nextPage.persist(_queuedDraft(3));
      await Future<void>.delayed(Duration.zero);
      expect(store.operations, ['write:1']);
      store.gate!.complete();
      await Future.wait([first, receipt, clear, fresh]);
      await nextPage.drain();
      expect(store.operations, ['write:1', 'write:2', 'clear', 'write:3']);
      expect(store.load()?.revision, 3);
    },
  );

  test('failed draft writes do not poison cleanup or retry', () async {
    final store = _QueuedDraftStore()..failNext = true;
    final coordinator = CanvasDraftPersistenceCoordinator(store);
    await expectLater(coordinator.persist(_queuedDraft(1)), throwsStateError);
    await coordinator.persist(_queuedDraft(2));
    expect(store.load()?.revision, 2);
    await coordinator.persist(null);
    expect(store.load(), isNull);
  });

  test('draft snapshot elides empty content', () {
    final at = DateTime.utc(2026, 8, 31);
    expect(
      buildCanvasAutosaveDraft(
        title: ' ',
        markdown: '\n',
        documentJson: '{}',
        documentFormatVersion: 1,
        linkedMaterials: const <V3LinkedMaterialRef>[],
        sourceTopicId: null,
        sourceTitle: null,
        synchronizedNoteId: null,
        revision: 3,
        createdAt: at,
        now: at,
      ),
      isNull,
    );
  });

  test('draft snapshot preserves payload and monotonic timestamp', () {
    final createdAt = DateTime.utc(2026, 8, 31, 10);
    const material = V3LinkedMaterialRef(
      id: 'note-1',
      source: V3MaterialSource.note,
      title: 'Source',
    );
    final draft = buildCanvasAutosaveDraft(
      title: 'Title',
      markdown: 'Body',
      documentJson: '{"ops":[]}',
      documentFormatVersion: 1,
      linkedMaterials: const <V3LinkedMaterialRef>[material],
      sourceTopicId: 'topic-1',
      sourceTitle: 'Topic',
      synchronizedNoteId: 'remote-1',
      revision: 7,
      createdAt: createdAt,
      now: createdAt.subtract(const Duration(seconds: 1)),
    );

    expect(draft, isNotNull);
    expect(draft!.title, 'Title');
    expect(draft.markdown, 'Body');
    expect(draft.documentJson, '{"ops":[]}');
    expect(draft.linkedMaterials, const <V3LinkedMaterialRef>[material]);
    expect(draft.sourceTopicId, 'topic-1');
    expect(draft.synchronizedNoteId, 'remote-1');
    expect(draft.revision, 7);
    expect(draft.updatedAt, createdAt);
  });

  testWidgets('local persist and cloud sync are independently debounced', (
    tester,
  ) async {
    var persists = 0;
    var synchronizations = 0;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => true,
      canScheduleCloudSync: () => true,
      canRunCloudSync: () => true,
      persist: () {
        persists += 1;
        return true;
      },
      synchronize: () async {
        synchronizations += 1;
      },
      cloudSyncDelay: const Duration(seconds: 2),
    );
    addTearDown(coordinator.dispose);

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 400));
    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 799));
    expect(persists, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(persists, 1);
    expect(synchronizations, 0);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(synchronizations, 1);
  });

  testWidgets('gates, cancellation and dispose suppress delayed work', (
    tester,
  ) async {
    var allowPersist = false;
    var allowSync = true;
    var persists = 0;
    var synchronizations = 0;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => allowPersist,
      canScheduleCloudSync: () => true,
      canRunCloudSync: () => allowSync,
      persist: () {
        persists += 1;
        return true;
      },
      synchronize: () async {
        synchronizations += 1;
      },
      persistDelay: const Duration(milliseconds: 10),
      cloudSyncDelay: const Duration(milliseconds: 20),
    );

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 30));
    expect(persists, 0);

    allowPersist = true;
    coordinator.schedule();
    coordinator.cancelPersist();
    allowSync = false;
    await tester.pump(const Duration(milliseconds: 20));
    expect(persists, 0);
    expect(synchronizations, 0);

    allowSync = true;
    coordinator.schedule();
    coordinator.dispose();
    await tester.pump(const Duration(milliseconds: 30));
    expect(persists, 0);
    expect(synchronizations, 0);
  });

  testWidgets('accepts an asynchronous worker persist callback', (
    tester,
  ) async {
    var persisted = false;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => true,
      canScheduleCloudSync: () => false,
      canRunCloudSync: () => false,
      persist: () async {
        await Future<void>.delayed(Duration.zero);
        persisted = true;
        return true;
      },
      synchronize: () async {},
      persistDelay: const Duration(milliseconds: 10),
      cloudSyncDelay: const Duration(seconds: 1),
    );
    addTearDown(coordinator.dispose);

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(persisted, isTrue);
  });

  testWidgets('drain waits for persist after its timer has fired', (
    tester,
  ) async {
    final persistCompletion = Completer<bool>();
    var persistStarted = false;
    var drainCompleted = false;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => true,
      canScheduleCloudSync: () => false,
      canRunCloudSync: () => false,
      persist: () {
        persistStarted = true;
        return persistCompletion.future;
      },
      synchronize: () async {},
      persistDelay: const Duration(milliseconds: 10),
      cloudSyncDelay: const Duration(seconds: 1),
    );
    addTearDown(coordinator.dispose);

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 10));
    expect(persistStarted, isTrue);

    final draining = coordinator.drainPersist().then((_) {
      drainCompleted = true;
    });
    await tester.pump();
    expect(drainCompleted, isFalse);

    persistCompletion.complete(true);
    await draining;
    expect(drainCompleted, isTrue);
  });

  testWidgets('persist launches stay serial and errors do not poison queue', (
    tester,
  ) async {
    final firstCompletion = Completer<bool>();
    var calls = 0;
    var active = 0;
    var maximumActive = 0;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => true,
      canScheduleCloudSync: () => false,
      canRunCloudSync: () => false,
      persist: () async {
        calls += 1;
        active += 1;
        maximumActive = active > maximumActive ? active : maximumActive;
        try {
          if (calls == 1) return await firstCompletion.future;
          throw StateError('worker persist failed');
        } finally {
          active -= 1;
        }
      },
      synchronize: () async {},
      persistDelay: const Duration(milliseconds: 10),
      cloudSyncDelay: const Duration(seconds: 1),
    );
    addTearDown(coordinator.dispose);

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 10));
    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 10));
    expect(calls, 1);

    firstCompletion.complete(true);
    await coordinator.drainPersist();

    expect(calls, 2);
    expect(maximumActive, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel-and-drain cancels timer and waits for active persist', (
    tester,
  ) async {
    final firstCompletion = Completer<bool>();
    var calls = 0;
    var drainCompleted = false;
    final coordinator = CanvasAutosaveCoordinator(
      canSchedulePersist: () => true,
      canScheduleCloudSync: () => false,
      canRunCloudSync: () => false,
      persist: () {
        calls += 1;
        return firstCompletion.future;
      },
      synchronize: () async {},
      persistDelay: const Duration(milliseconds: 10),
      cloudSyncDelay: const Duration(seconds: 1),
    );
    addTearDown(coordinator.dispose);

    coordinator.schedule();
    await tester.pump(const Duration(milliseconds: 10));
    expect(calls, 1);

    coordinator.schedule();
    final draining = coordinator.cancelPersistAndDrain().then((_) {
      drainCompleted = true;
    });
    await tester.pump();
    expect(drainCompleted, isFalse);

    firstCompletion.complete(true);
    await draining;
    await tester.pump(const Duration(milliseconds: 10));
    expect(drainCompleted, isTrue);
    expect(calls, 1);
  });
}

CreationCanvasDraft _queuedDraft(int revision) => CreationCanvasDraft(
  title: '顺序草稿',
  markdown: '版本 $revision',
  revision: revision,
  createdAt: DateTime.utc(2026, 9, 16),
  updatedAt: DateTime.utc(2026, 9, 16),
);

final class _QueuedDraftStore implements CreationCanvasDraftStore {
  final operations = <String>[];
  Completer<void>? gate;
  bool failNext = false;
  CreationCanvasDraft? snapshot;

  @override
  String get userScope => 'queued-draft-user';

  @override
  CreationCanvasDraft? load() => snapshot;

  @override
  void upsert(CreationCanvasDraft draft) => snapshot = draft;

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    operations.add('write:${draft.revision}');
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('injected draft failure');
    }
    upsert(draft);
  }

  @override
  bool clear() {
    final existed = snapshot != null;
    snapshot = null;
    return existed;
  }

  @override
  Future<bool> clearDeferred() async {
    operations.add('clear');
    return clear();
  }
}
