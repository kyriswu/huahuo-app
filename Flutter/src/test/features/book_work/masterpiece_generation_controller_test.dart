import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_controller.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_generation_controller.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_providers.dart';
import 'package:huahuoai_app/features/book_work/widgets/masterpiece_generation_panel.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';

import 'masterpiece_test_support.dart';

void main() {
  testWidgets('cached note count is not presented as verified lock progress', (
    tester,
  ) async {
    final controller = _controller(
      _Remote(),
      _Store()
        ..value = const MasterpieceGenerationRecord(
          unlocked: true,
          noteCount: 100,
        ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MasterpieceGenerationPanel(
            controller: controller,
            onRefresh: () async {},
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('masterpiece-locked-book')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('masterpiece-unlock-progress')),
      findsNothing,
    );
    expect(find.text('100 / 100 篇'), findsNothing);
    expect(find.textContaining('尚未完成云端笔记核验'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final count in [99, 100]) {
    testWidgets(
      'Book failure still verifies $count notes and cold start shows a lock',
      (tester) async {
        final remote = _Remote()..count = count;
        final generation = _controller(remote, _Store());
        final document = MasterpieceController(
          remote: TestMasterpieceRemote()
            ..readFailure = const MasterpieceRemoteException('BOOK_NOT_FOUND'),
          store: TestMasterpieceStore(),
          generation: generation,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              masterpieceControllerProvider.overrideWith((ref) => document),
            ],
            child: const MaterialApp(
              home: Scaffold(body: V3MasterpiecePage(active: false)),
            ),
          ),
        );
        expect(find.byType(MasterpieceGenerationPanel), findsOneWidget);
        expect(find.byKey(const ValueKey('masterpiece-new')), findsNothing);
        await tester.runAsync(document.refresh);
        await tester.pumpAndSettle();
        expect(generation.record.noteCount, count);
        expect(generation.unlocked, count >= 100);
        expect(remote.eligibilityReads, 1);
        expect(remote.creates, isEmpty);
        expect(document.snapshot, isNull);
        expect(document.errorCode, 'BOOK_NOT_FOUND');
        expect(document.canStartAction, isFalse);
        if (count < 100) {
          expect(find.text('$count / 100 篇'), findsOneWidget);
          expect(find.byType(MasterpieceGenerationPanel), findsOneWidget);
        } else {
          expect(find.text('代表作 · 待解锁'), findsNothing);
          expect(find.textContaining('尚未初始化代表作'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test(
    'Book refresh invalidates prior access and relocks after note deletion',
    () async {
      final remote = _Remote()..cloud = masterpieceSnapshot();
      final book = TestMasterpieceRemote(snapshot: remote.cloud);
      final generation = _controller(remote, _Store());
      final document = MasterpieceController(
        remote: book,
        store: TestMasterpieceStore(),
        generation: generation,
      );
      addTearDown(document.dispose);
      await document.refresh();
      expect(generation.unlocked, isTrue);
      final savedBook = document.snapshot;
      remote.count = 99;
      final readGate = Completer<MasterpieceSnapshot>();
      book.readGate = readGate;
      final refresh = document.refresh();
      expect(generation.unlocked, isFalse);
      readGate.completeError(const MasterpieceRemoteException('SERVICE_BUSY'));
      await refresh;
      expect(generation.unlocked, isFalse);
      expect(generation.record.noteCount, 99);
      expect(remote.eligibilityReads, 2);
      expect(document.snapshot, same(savedBook));
      expect(document.canStartAction, isFalse);
      expect(remote.creates, isEmpty);
    },
  );

  test(
    'failed eligibility bypasses the Book freshness cache on retry',
    () async {
      final remote = _Remote()
        ..cloud = masterpieceSnapshot()
        ..eligibilityError = const MasterpieceRemoteException('SERVICE_BUSY');
      final generation = _controller(remote, _Store());
      final document = MasterpieceController(
        remote: TestMasterpieceRemote(snapshot: remote.cloud),
        store: TestMasterpieceStore(),
        generation: generation,
        now: () => DateTime.utc(2026, 9, 1),
      );
      addTearDown(document.dispose);
      await document.refresh();
      expect(generation.unlocked, isFalse);
      remote.eligibilityError = null;
      await document.refresh(force: false);
      expect(remote.eligibilityReads, 2);
      expect(generation.unlocked, isTrue);
      expect(document.canStartAction, isTrue);
      expect(remote.creates, isEmpty);
    },
  );

  testWidgets(
    'unlock progress, refresh and cancellation dialog are interactive',
    (tester) async {
      final remote = _Remote()..count = 99;
      final controller = _controller(remote, _Store());
      await tester.runAsync(() => _refresh(controller, remote));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => MasterpieceGenerationPanel(
                controller: controller,
                onRefresh: () => _refresh(controller, remote),
              ),
            ),
          ),
        ),
      );
      expect(find.text('99 / 100 篇'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('masterpiece-locked-book')),
        findsOneWidget,
      );
      expect(find.text('还需沉淀 1 篇笔记'), findsOneWidget);
      remote.count = 100;
      await tester.tap(find.text('重新核对云端笔记'));
      await tester.pumpAndSettle();
      expect(find.text('代表作已解锁'), findsOneWidget);
      expect(remote.creates, hasLength(1));
      await tester.tap(find.text('取消本次生成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.intent!.cancelRequested, isFalse);
      remote.status = 'cancelled';
      await tester.tap(find.text('取消本次生成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(controller.intent!.stage, MasterpieceGenerationStage.cancelled);
      expect(remote.publications, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  test(
    '99 stays locked; 100 submits once and a later count drop preserves its run',
    () async {
      final remote = _Remote()..count = 99;
      final store = _Store();
      final controller = _controller(remote, store);
      await _refresh(controller, remote);
      expect(controller.unlocked, isFalse);
      expect(controller.record.noteCount, 99);
      expect(remote.creates, isEmpty);
      remote.count = 100;
      await _refresh(controller, remote);
      expect(controller.unlocked, isTrue);
      expect(remote.creates.single.sources.length, 100);
      expect(controller.allowsEditing, isFalse);
      await _refresh(controller, remote);
      expect(remote.creates, hasLength(1));
      controller.dispose();
      remote.count = 2;
      final restored = _controller(remote, store);
      expect(restored.unlocked, isFalse);
      await _refresh(restored, remote);
      expect(restored.unlocked, isFalse);
      expect(restored.record.noteCount, 2);
      expect(restored.allowsEditing, isFalse);
      expect(remote.creates, hasLength(1));
      expect(restored.intent!.runId, 'run-1');
      restored.dispose();
    },
  );

  test(
    '100 notes unlock existing cloud chapters without a model call',
    () async {
      final remote = _Remote()..cloud = masterpieceSnapshot();
      final controller = _controller(remote, _Store());
      await _refresh(controller, remote);
      expect(controller.allowsEditing, isTrue);
      expect(remote.creates, isEmpty);
      expect(remote.eligibilityReads, 1);
      controller.dispose();
    },
  );

  for (final count in [0, 99]) {
    test(
      'existing chapters and cached unlock stay locked at $count notes',
      () async {
        final remote = _Remote()
          ..count = count
          ..cloud = masterpieceSnapshot();
        final store = _Store()
          ..value = const MasterpieceGenerationRecord(
            unlocked: true,
            noteCount: 100,
            automaticAttempted: true,
            settled: true,
          );
        final controller = _controller(remote, store);
        expect(controller.unlocked, isFalse);
        await _refresh(controller, remote);
        expect(controller.unlocked, isFalse);
        expect(controller.allowsEditing, isFalse);
        expect(controller.canRestart, isFalse);
        expect(controller.record.noteCount, count);
        await controller.requestGeneration();
        expect(remote.creates, isEmpty);
        expect(remote.cloud.chapters, hasLength(1));
        remote.count = 100;
        await _refresh(controller, remote);
        expect(controller.allowsEditing, isTrue);
        expect(remote.creates, isEmpty);
        controller.dispose();
      },
    );
  }

  test(
    'new generation rechecks the threshold before allocating an attempt',
    () async {
      final remote = _Remote()..cloud = masterpieceSnapshot();
      final controller = _controller(remote, _Store());
      await _refresh(controller, remote);
      expect(controller.canRestart, isTrue);
      remote.count = 99;
      await controller.requestGeneration();
      expect(controller.unlocked, isFalse);
      expect(controller.record.attempt, 0);
      expect(controller.record.settled, isTrue);
      expect(controller.intent, isNull);
      expect(remote.creates, isEmpty);
      expect(remote.publications, isEmpty);
      controller.dispose();
    },
  );

  test(
    'failed eligibility keeps access locked and preserves uncertain admission',
    () async {
      final remote = _Remote()
        ..createError = const MasterpieceRemoteException(
          'NETWORK',
          ambiguous: true,
        );
      final store = _Store();
      final controller = _controller(remote, store);
      await _refresh(controller, remote);
      final frozen = controller.intent!.toJson();
      controller.dispose();
      remote.eligibilityError = const MasterpieceRemoteException(
        'AUTH_REQUIRED',
        status: 401,
      );
      final restored = _controller(remote, store);
      await _refresh(restored, remote);
      expect(restored.unlocked, isFalse);
      expect(restored.errorCode, 'AUTH_REQUIRED');
      expect(restored.intent!.toJson(), frozen);
      expect(remote.creates, hasLength(1));
      restored.dispose();
    },
  );

  testWidgets('open information sheet follows the current note eligibility', (
    tester,
  ) async {
    final remote = _Remote()
      ..count = 99
      ..cloud = masterpieceSnapshot();
    final generation = _controller(remote, _Store());
    final document = MasterpieceController(
      remote: TestMasterpieceRemote(snapshot: remote.cloud),
      store: TestMasterpieceStore(),
      generation: generation,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          masterpieceControllerProvider.overrideWith((ref) => document),
        ],
        child: const MaterialApp(
          home: Scaffold(body: V3MasterpiecePage(active: false)),
        ),
      ),
    );
    await tester.runAsync(document.refresh);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('masterpiece-more')));
    await tester.pumpAndSettle();
    final generate = find.byKey(
      const ValueKey('masterpiece-information-generate'),
    );
    expect(tester.widget<OutlinedButton>(generate).onPressed, isNull);
    expect(find.textContaining('还需 1 篇'), findsOneWidget);
    remote.count = 100;
    await tester.runAsync(document.refresh);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(generate).onPressed, isNotNull);
    expect(find.textContaining('已沉淀 100 篇'), findsOneWidget);
    remote.count = 99;
    await tester.runAsync(document.refresh);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(generate).onPressed, isNull);
    expect(remote.creates, isEmpty);
    expect(remote.publications, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'locked page preserves a restored draft without exposing its editor',
    (tester) async {
      final remote = _Remote()
        ..count = 99
        ..cloud = masterpieceSnapshot();
      final generation = _controller(remote, _Store());
      final document = MasterpieceController(
        remote: TestMasterpieceRemote(snapshot: remote.cloud),
        store: TestMasterpieceStore()
          ..value = const MasterpieceDraft(
            bookId: 'book-1',
            sectionKey: 'chapter-draft',
            title: '保留草稿',
            markdown: '不足 100 篇也不能丢失的正文',
          ),
        generation: generation,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            masterpieceControllerProvider.overrideWith((ref) => document),
          ],
          child: const MaterialApp(
            home: Scaffold(body: V3MasterpiecePage(active: false)),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('masterpiece-generation-panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('masterpiece-editor')), findsNothing);
      await tester.runAsync(document.refresh);
      await tester.pumpAndSettle();
      expect(find.text('代表作 · 待解锁'), findsOneWidget);
      expect(find.text('99 / 100 篇'), findsOneWidget);
      expect(find.byKey(const ValueKey('masterpiece-new')), findsNothing);
      expect(find.byKey(const ValueKey('masterpiece-editor')), findsNothing);
      expect(document.canSave, isFalse);
      expect(document.draft!.markdown, '不足 100 篇也不能丢失的正文');
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'unknown admission freezes sources and key across restart and auth failure',
    () async {
      final remote = _Remote()
        ..createError = const MasterpieceRemoteException(
          'NETWORK',
          ambiguous: true,
        );
      final store = _Store();
      final controller = _controller(remote, store);
      await _refresh(controller, remote);
      final frozen = controller.intent!.toJson();
      expect(controller.intent!.stage, MasterpieceGenerationStage.uncertain);
      controller.dispose();
      remote.count = 120;
      remote.createError = const MasterpieceRemoteException(
        'AUTH_REQUIRED',
        status: 401,
      );
      final restored = _controller(remote, store);
      await _refresh(restored, remote);
      expect(restored.intent!.stage, MasterpieceGenerationStage.uncertain);
      expect(restored.intent!.requestKey, frozen['requestKey']);
      expect(
        remote.creates.last.sources.map((source) => source.toJson()).toList(),
        frozen['sources'],
      );
      expect(restored.canDismiss, isFalse);
      expect(restored.canRestart, isFalse);
      restored.dispose();
    },
  );

  test(
    'accepted publication only rereads and opens editor after visibility',
    () async {
      final remote = _Remote()..readbackVisible = false;
      final generation = _controller(remote, _Store());
      final document = MasterpieceController(
        remote: TestMasterpieceRemote(snapshot: remote.cloud),
        store: TestMasterpieceStore(),
        generation: generation,
      );
      await document.refresh();
      expect(document.canStartAction, isFalse);
      remote.status = 'succeeded';
      await generation.retry();
      expect(generation.intent!.stage, MasterpieceGenerationStage.accepted);
      expect(remote.publications, hasLength(1));
      await generation.retry();
      expect(remote.publications, hasLength(1));
      remote.readbackVisible = true;
      await generation.retry();
      expect(generation.intent, isNull);
      expect(
        document.snapshot!.chapters.single.revision!.contentMarkdown,
        '生成正文',
      );
      expect(document.canStartAction, isTrue);
      expect(document.beginNew(title: '我的章节', markdown: '草稿'), isTrue);
      await generation.requestGeneration();
      expect(remote.creates, hasLength(1));
      document.dispose();
    },
  );

  test(
    'storage failure stops admission and resumes the persisted exact intent',
    () async {
      final remote = _Remote();
      final store = _Store()
        ..rejectStage = MasterpieceGenerationStage.submitting;
      final controller = _controller(remote, store);
      await _refresh(controller, remote);
      expect(remote.creates, isEmpty);
      expect(controller.errorCode, 'MASTERPIECE_GENERATION_STORAGE_FAILED');
      expect(controller.allowsEditing, isFalse);
      store.rejectStage = null;
      await controller.retry();
      expect(remote.creates, hasLength(1));
      controller.dispose();
    },
  );

  test(
    'terminal failure never auto-reruns; explicit retry creates a new key',
    () async {
      final remote = _Remote()..status = 'failed';
      final controller = _controller(remote, _Store());
      await _refresh(controller, remote);
      final originalKey = controller.intent!.requestKey;
      await _refresh(controller, remote);
      expect(remote.creates, hasLength(1));
      remote.status = 'running';
      await controller.requestGeneration();
      expect(remote.creates, hasLength(2));
      expect(controller.intent!.requestKey, isNot(originalKey));
      controller.dispose();
    },
  );

  test(
    'background and disposed owners never advance a late accepted run',
    () async {
      final remote = _Remote()..createGate = Completer<AgentRunSnapshot>();
      final store = _Store();
      final controller = _controller(remote, store);
      final operation = _refresh(controller, remote);
      while (remote.creates.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.dispose();
      remote.createGate!.complete(_run('succeeded'));
      await operation;
      expect(store.value!.intent!.stage, MasterpieceGenerationStage.submitting);
      expect(remote.publications, isEmpty);
      remote.createGate = null;
      final restored = _controller(remote, store)..setForeground(false);
      await _refresh(restored, remote);
      expect(remote.creates, hasLength(1));
      restored.setForeground(true);
      await _refresh(restored, remote);
      expect(remote.creates, hasLength(2));
      expect(remote.creates.first.requestKey, remote.creates.last.requestKey);
      restored.dispose();
    },
  );

  test(
    'cancellation race keeps successful output unsubmitted on later refresh',
    () async {
      final remote = _Remote();
      final controller = _controller(remote, _Store());
      await _refresh(controller, remote);
      remote.status = 'succeeded';
      await controller.cancel();
      expect(controller.intent!.stage, MasterpieceGenerationStage.generated);
      await _refresh(controller, remote);
      expect(remote.publications, isEmpty);
      await controller.dismiss();
      expect(controller.allowsEditing, isTrue);
      controller.dispose();
    },
  );

  test(
    'readback rejection cannot release an uncertain publication latch',
    () async {
      final remote = _Remote()
        ..publishError = const MasterpieceRemoteException(
          'NETWORK',
          ambiguous: true,
        );
      final controller = _controller(remote, _Store());
      await _refresh(controller, remote);
      remote.status = 'succeeded';
      await controller.retry();
      expect(controller.intent!.stage, MasterpieceGenerationStage.publishing);
      remote.readbackError = const MasterpieceRemoteException(
        'AUTH_REQUIRED',
        status: 401,
      );
      await controller.retry();
      expect(controller.intent!.stage, MasterpieceGenerationStage.publishing);
      expect(controller.canDismiss, isFalse);
      controller.dispose();
    },
  );
}

MasterpieceGenerationController _controller(_Remote remote, _Store store) =>
    MasterpieceGenerationController(
      remote: remote,
      store: store,
      identity: 'user-1\u0000workspace-1',
    );

Future<void> _refresh(
  MasterpieceGenerationController controller,
  _Remote remote,
) => controller.reconcile(snapshot: remote.cloud, documentIdle: true);

final class _Store implements MasterpieceGenerationStore {
  MasterpieceGenerationRecord? value;
  MasterpieceGenerationStage? rejectStage;
  @override
  MasterpieceGenerationRecord? read() => value;
  @override
  Future<void> write(MasterpieceGenerationRecord record) async {
    if (rejectStage != null && record.intent?.stage == rejectStage) {
      throw StateError('disk full');
    }
    value = MasterpieceGenerationRecord.fromJson(record.toJson());
  }
}

final class _Remote implements MasterpieceGenerationRemote {
  var count = 100;
  var eligibilityReads = 0;
  var status = 'running';
  var readbackVisible = true;
  MasterpieceSnapshot cloud = masterpieceSnapshot(empty: true);
  Object? createError;
  Object? eligibilityError;
  Object? publishError;
  Object? readbackError;
  Completer<AgentRunSnapshot>? createGate;
  final creates = <MasterpieceGenerationIntent>[];
  final publications = <MasterpieceGenerationIntent>[];
  @override
  Future<MasterpieceEligibility> eligibility() async {
    eligibilityReads += 1;
    if (eligibilityError != null) throw eligibilityError!;
    return MasterpieceEligibility(
      List.generate(
        count,
        (index) => MasterpieceSourceHead('note-$index', 'note-revision-$index'),
      ),
    );
  }

  @override
  Future<MasterpieceGenerationPreparation> prepare(
    MasterpieceEligibility eligibility,
  ) async => MasterpieceGenerationPreparation('book_writing', [
    for (final head in eligibility.notes.take(masterpieceUnlockCount))
      SharedNotePartSourceRef(
        noteId: head.noteId,
        part: 'raw',
        partRevisionId: '${head.revisionId}-raw',
      ),
  ]);
  @override
  Future<AgentRunSnapshot> create(MasterpieceGenerationIntent intent) async {
    creates.add(intent);
    if (createError != null) throw createError!;
    return createGate?.future ?? _run(status);
  }

  @override
  Future<AgentRunSnapshot> run(String runId) async => _run(status);
  @override
  Future<AgentRunSnapshot> cancel(MasterpieceGenerationIntent intent) async =>
      _run(status);
  @override
  Future<MasterpieceSnapshot> book() async => cloud;
  @override
  Future<void> publish(MasterpieceGenerationIntent intent) async {
    publications.add(intent);
    if (publishError != null) throw publishError!;
    cloud = masterpieceSnapshot(
      key: intent.sectionKey,
      markdown: intent.markdown!,
      revision: 2,
    );
  }

  @override
  Future<MasterpieceSnapshot?> readback(
    MasterpieceGenerationIntent intent,
  ) async {
    if (readbackError != null) throw readbackError!;
    return readbackVisible && cloud.chapter(intent.sectionKey) != null
        ? cloud
        : null;
  }
}

AgentRunSnapshot _run(String status) => AgentRunSnapshot(
  agentRunId: 'run-1',
  workspaceId: 'workspace-1',
  status: status,
  workspaceVersion: 1,
  workspaceBindingVersion: 1,
  contextGeneration: 1,
  usage: const AgentRunUsage(
    measurementStatus: 'pending',
    inputTokens: null,
    outputTokens: null,
    imageCount: null,
    videoSeconds: null,
    accountedCredits: null,
    policyVersion: null,
  ),
  toolTrace: const [],
  createdAt: DateTime.utc(2026, 9, 5),
  updatedAt: DateTime.utc(2026, 9, 5),
  result: status == 'succeeded'
      ? const AgentRunResult(
          finalAnswer: '生成正文',
          assistantMessageId: 'message-1',
          completionMode: 'normal',
        )
      : null,
);
