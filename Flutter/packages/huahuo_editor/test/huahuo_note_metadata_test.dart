import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 28, 9);

  HuahuoDocumentSnapshot snapshot({
    String? summaryMarkdown,
    String? sproutMarkdown,
    Iterable<HuahuoAiAnnotation> aiAnnotations = const <HuahuoAiAnnotation>[],
  }) {
    return HuahuoDocumentSnapshot(
      id: 'note-1',
      title: 'Note protocol',
      deltaJson: '[{"insert":"Original draft\\n"}]',
      revision: 7,
      createdAt: createdAt,
      modifiedAt: createdAt.add(const Duration(minutes: 5)),
      summaryMarkdown: summaryMarkdown,
      sproutMarkdown: sproutMarkdown,
      aiAnnotations: aiAnnotations,
    );
  }

  test('migrates a v1 snapshot to a raw-only v2 note without losing Delta', () {
    final legacy = <String, Object?>{
      'formatVersion': 1,
      'id': 'legacy-note',
      'title': 'Legacy note',
      'delta': <Object?>[
        <String, Object?>{'insert': 'Legacy body\n'},
      ],
      'revision': 3,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': createdAt.add(const Duration(minutes: 2)).toIso8601String(),
    };

    final restored = HuahuoDocumentSnapshot.fromJson(legacy);
    final serialized = restored.toJson();

    expect(restored.toDocument().toPlainText(), 'Legacy body\n');
    expect(restored.availableNoteStages, <HuahuoNoteStage>[
      HuahuoNoteStage.raw,
    ]);
    expect(
      restored.stageContent(HuahuoNoteStage.raw)!.format,
      HuahuoNoteStageContentFormat.quillDelta,
    );
    expect(
      restored.stageContent(HuahuoNoteStage.raw)!.content,
      jsonEncode(legacy['delta']),
    );
    expect(restored.summaryMarkdown, isNull);
    expect(restored.sproutMarkdown, isNull);
    expect(restored.aiAnnotations, isEmpty);
    expect(serialized['formatVersion'], HuahuoDocumentSnapshot.formatVersion);
    expect(serialized['note'], isA<Map<String, Object?>>());
  });

  test(
    'derives only materialized note stages and identifies their formats',
    () {
      final note = snapshot(
        summaryMarkdown: '## Summary\n\nA concise outline.',
        sproutMarkdown: '# AI insight\n\nA possible next direction.',
      );

      expect(note.availableNoteStages, <HuahuoNoteStage>[
        HuahuoNoteStage.raw,
        HuahuoNoteStage.summary,
        HuahuoNoteStage.sprout,
      ]);
      expect(note.stageContent(HuahuoNoteStage.raw)!.isMarkdown, isFalse);
      expect(
        note.stageContent(HuahuoNoteStage.summary)!.format,
        HuahuoNoteStageContentFormat.markdown,
      );
      expect(
        note.stageContent(HuahuoNoteStage.summary)!.content,
        '## Summary\n\nA concise outline.',
      );
      expect(
        note.stageContent(HuahuoNoteStage.sprout)!.content,
        '# AI insight\n\nA possible next direction.',
      );

      final rawOnly = snapshot(summaryMarkdown: '   ', sproutMarkdown: '\n');
      expect(rawOnly.availableNoteStages, <HuahuoNoteStage>[
        HuahuoNoteStage.raw,
      ]);
      expect(rawOnly.stageContent(HuahuoNoteStage.summary), isNull);
      expect(rawOnly.stageContent(HuahuoNoteStage.sprout), isNull);
    },
  );

  test('round trips structured AI annotations with their stage anchors', () {
    final annotations = <HuahuoAiAnnotation>[
      HuahuoAiAnnotation(
        id: 'annotation-raw-opening',
        stage: HuahuoNoteStage.raw,
        anchor: 'raw-opening',
        quote: 'Original draft',
        body: 'Open with a concrete scene before this statement.',
        createdAt: createdAt.add(const Duration(minutes: 8)),
      ),
      HuahuoAiAnnotation(
        id: 'annotation-sprout-direction',
        stage: HuahuoNoteStage.sprout,
        anchor: 'sprout-direction',
        quote: 'A possible next direction.',
        body: 'Turn this into a testable editorial angle.',
        createdAt: createdAt.add(const Duration(minutes: 9)),
      ),
    ];
    final restored = HuahuoDocumentSnapshot.fromJson(
      snapshot(
        sproutMarkdown: '# AI insight\n\nA possible next direction.',
        aiAnnotations: annotations,
      ).toJson(),
    );

    expect(restored.aiAnnotations, hasLength(2));
    expect(restored.aiAnnotations.first.id, 'annotation-raw-opening');
    expect(restored.aiAnnotations.first.stage, HuahuoNoteStage.raw);
    expect(restored.aiAnnotations.first.anchor, 'raw-opening');
    expect(restored.aiAnnotations.first.sectionId, 'raw-opening');
    expect(restored.aiAnnotations.first.quote, 'Original draft');
    expect(
      restored.aiAnnotations.first.createdAt,
      createdAt.add(const Duration(minutes: 8)),
    );
    expect(
      restored.annotationsForStage(HuahuoNoteStage.sprout).single.body,
      'Turn this into a testable editorial angle.',
    );
  });

  test('editor saves retain immutable note-stage metadata', () async {
    final annotation = HuahuoAiAnnotation(
      id: 'annotation-summary',
      stage: HuahuoNoteStage.summary,
      anchor: 'summary-main',
      quote: 'Summary',
      body: 'Keep the claim specific.',
      createdAt: createdAt,
    );
    final saved = <HuahuoDocumentSnapshot>[];
    final controller = HuahuoEditorController(
      initial: snapshot(
        summaryMarkdown: '# Summary',
        aiAnnotations: <HuahuoAiAnnotation>[annotation],
      ),
      autosaveDelay: const Duration(milliseconds: 10),
      onSave: (value) async => saved.add(value),
    );
    addTearDown(controller.dispose);

    controller.body.replaceText(
      0,
      0,
      'Edited ',
      const TextSelection.collapsed(offset: 7),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(saved, hasLength(1));
    expect(saved.single.summaryMarkdown, '# Summary');
    expect(saved.single.aiAnnotations.single.id, 'annotation-summary');
  });
}
