import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test(
    'long-running generation survives navigation without duplicate dispatch',
    () async {
      final note = _note('normal-1', '材料');
      final repository = _PendingGenerationRepository();
      final library = KnowledgeLibraryController(initialNotes: [note]);
      final controller =
          WorkbenchGenerationController(
              library: library,
              repository: repository,
            )
            ..startSelection(WorkbenchPurpose.persona)
            ..toggleNote(note.id);
      addTearDown(controller.dispose);
      addTearDown(library.dispose);
      final result = controller.generate();
      final generationId = controller.generationId;
      expect(controller.status, WorkbenchGenerationStatus.generating);
      controller.startSelection(WorkbenchPurpose.lead);
      controller.clearForWorkbench();
      expect(controller.toggleNote(note.id), isFalse);
      controller.replaceSelection([]);
      controller.consumeSelection();
      expect(controller.selectedNoteIds, {note.id});
      expect(await controller.generate(), isFalse);
      expect(controller.purpose, WorkbenchPurpose.persona);
      expect(controller.generationId, generationId);
      expect(repository.calls, 1);
      repository.completion.complete(
        WorkbenchGenerationResult(
          markdown: '真实结果',
          generatedAt: DateTime.utc(2026, 9, 1),
        ),
      );
      expect(await result, isTrue);
      expect(controller.resultMarkdown, '真实结果');
      expect(controller.generationId, generationId);
      controller.startSelection(WorkbenchPurpose.lead);
      controller.clearForWorkbench();
      expect(controller.taskForId(generationId)!.result!.markdown, '真实结果');
      expect(controller.tasks, hasLength(1));
    },
  );

  for (final terminal in [false, true]) {
    test(
      'recovery freezes sources and ${terminal ? 'restarts a terminal run' : 'reuses an uncertain run'}',
      () async {
        final original = _note('original', '原始材料');
        final replacement = _note('replacement', '另一份材料');
        final library = KnowledgeLibraryController(
          initialNotes: [original, replacement],
        );
        final repository = _RecoverableGenerationRepository(terminal: terminal);
        final controller =
            WorkbenchGenerationController(
                library: library,
                repository: repository,
              )
              ..startSelection(WorkbenchPurpose.persona)
              ..toggleNote(original.id);
        addTearDown(controller.dispose);
        addTearDown(library.dispose);
        expect(await controller.generate(), isFalse);
        final originalId = controller.generationId!;
        final startedAt = controller.generationStartedAt;
        expect(
          controller.taskForId(originalId)!.status,
          terminal
              ? WorkbenchGenerationTaskStatus.failed
              : WorkbenchGenerationTaskStatus.awaitingResult,
        );
        controller.startSelection(WorkbenchPurpose.lead);
        controller.toggleNote(replacement.id);
        expect(await controller.retry(originalId), isTrue);
        expect(repository.sources.last.single.id, original.id);
        expect(repository.purposes.last, WorkbenchPurpose.persona);
        expect(repository.ids.last == originalId, !terminal);
        if (!terminal) expect(controller.generationStartedAt, startedAt);
        expect(controller.tasks, hasLength(terminal ? 2 : 1));
      },
    );
  }

  test('selection is required, unique, and survives query/filter changes', () {
    final note = _note('normal-1', '客户案例');
    final controller = WorkbenchGenerationController(
      library: KnowledgeLibraryController(initialNotes: [note]),
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    )..startSelection(WorkbenchPurpose.persona);

    expect(controller.canGenerate, isFalse);
    controller.toggleNote(note.id);
    controller.toggleNote(note.id);
    expect(controller.selectedCount, 0);
    controller.toggleNote(note.id);
    controller.setQuery('不存在的关键词');
    controller.setFilter(WorkbenchNoteFilter.mine);

    expect(controller.selectedNoteIds, contains(note.id));
    expect(controller.canGenerate, isTrue);
  });

  test('selection accepts at most two notes and is consumed after handoff', () {
    final notes = <V3FeedItem>[
      _note('normal-1', '客户案例一'),
      _note('normal-2', '客户案例二'),
      _note('normal-3', '客户案例三'),
    ];
    final controller = WorkbenchGenerationController(
      library: KnowledgeLibraryController(initialNotes: notes),
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    )..startSelection(WorkbenchPurpose.persona);

    expect(controller.toggleNote(notes[0].id), isTrue);
    expect(controller.toggleNote(notes[1].id), isTrue);
    expect(controller.toggleNote(notes[2].id), isFalse);
    expect(controller.selectedNoteIds, <String>{notes[0].id, notes[1].id});

    controller.replaceSelection(<String>[
      notes[2].id,
      notes[1].id,
      notes[0].id,
    ]);
    expect(controller.selectedNoteIds, <String>{notes[2].id, notes[1].id});

    controller.consumeSelection();
    expect(controller.selectedNoteIds, isEmpty);
    expect(controller.canGenerate, isFalse);
  });

  test('persona and lead mocks cite selected notes', () async {
    final note = _note('normal-1', '真实客户问题');
    final controller =
        WorkbenchGenerationController(
            library: KnowledgeLibraryController(initialNotes: [note]),
            repository: const WorkbenchGenerationMockRepository(
              delay: Duration.zero,
            ),
          )
          ..startSelection(WorkbenchPurpose.persona)
          ..toggleNote(note.id);

    expect(await controller.generate(), isTrue);
    expect(controller.resultMarkdown, contains('用真实经历建立可信人设'));
    expect(controller.resultMarkdown, contains(note.title));

    controller.startSelection(WorkbenchPurpose.lead);
    controller.toggleNote(note.id);
    expect(await controller.generate(), isTrue);
    expect(controller.resultMarkdown, contains('用客户问题激发咨询意愿'));
    expect(controller.resultMarkdown, contains(note.title));
  });
}

final class _PendingGenerationRepository
    implements WorkbenchGenerationRepository {
  final completion = Completer<WorkbenchGenerationResult>();
  int calls = 0;

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) {
    calls += 1;
    return completion.future;
  }
}

final class _RecoverableGenerationRepository
    implements WorkbenchGenerationRepository {
  _RecoverableGenerationRepository({required this.terminal});
  final bool terminal;
  final List<String> ids = [];
  final List<List<V3FeedItem>> sources = [];
  final List<WorkbenchPurpose> purposes = [];

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) async {
    ids.add(operationId);
    sources.add(notes);
    purposes.add(purpose);
    if (ids.length == 1) {
      throw WorkbenchGenerationException(
        'TEST_FAILURE',
        resultPending: !terminal,
        terminalFailure: terminal,
      );
    }
    return WorkbenchGenerationResult(
      markdown: '原任务结果',
      generatedAt: DateTime.now(),
    );
  }
}

V3FeedItem _note(String id, String title) => V3FeedItem(
  id: id,
  title: title,
  source: V3MaterialSource.note,
  createdAt: DateTime(2026, 7, 13),
  rawBody: '真实经历与客户问题',
  summaryBody: '一段可以用于生成的纲要',
);
