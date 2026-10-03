import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  HuahuoDocumentSnapshot emptySnapshot() {
    final now = DateTime.utc(2026, 7, 27);
    return HuahuoDocumentSnapshot(
      id: 'doc-1',
      title: '新文稿',
      deltaJson: '[{"insert":"\\n"}]',
      revision: 0,
      createdAt: now,
      modifiedAt: now,
    );
  }

  test('snapshot round trip keeps canonical trailing newline', () {
    final snapshot = HuahuoDocumentSnapshot.fromJson(emptySnapshot().toJson());

    expect(snapshot.id, 'doc-1');
    expect(snapshot.toDocument().toPlainText(), '\n');
    expect(snapshot.deltaJson, '[{"insert":"\\n"}]');
  });

  test('typing increments revision and debounces persistence', () async {
    final saved = <HuahuoDocumentSnapshot>[];
    final controller = HuahuoEditorController(
      initial: emptySnapshot(),
      autosaveDelay: const Duration(milliseconds: 10),
      onSave: (snapshot) async => saved.add(snapshot),
    );
    addTearDown(controller.dispose);

    controller.body.replaceText(
      0,
      0,
      '自由创作',
      const TextSelection.collapsed(offset: 4),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(controller.revision, 1);
    expect(saved, hasLength(1));
    expect(saved.single.toDocument().toPlainText(), '自由创作\n');
    expect(controller.saveState, HuahuoSaveState.saved);
  });

  test('save failure is observable and leaves content intact', () async {
    final controller = HuahuoEditorController(
      initial: emptySnapshot(),
      onSave: (_) => Future<void>.error(StateError('disk unavailable')),
    );
    addTearDown(controller.dispose);
    controller.title.text = '仍然保留';

    await controller.saveNow();

    expect(controller.saveState, HuahuoSaveState.failed);
    expect(controller.snapshot.title, '仍然保留');
  });

  test(
    'snapshot failure releases the save lock for a corrected document',
    () async {
      final saved = <HuahuoDocumentSnapshot>[];
      final controller = HuahuoEditorController(
        initial: emptySnapshot(),
        onSave: (snapshot) async => saved.add(snapshot),
      );
      addTearDown(controller.dispose);
      controller.body.replaceText(
        0,
        0,
        BlockEmbed.custom(const CustomBlockEmbed('unsupported', 'value')),
        const TextSelection.collapsed(offset: 1),
      );
      await Future<void>.delayed(Duration.zero);

      await controller.saveNow();
      expect(controller.saveState, HuahuoSaveState.failed);

      controller.body.replaceText(
        0,
        1,
        '已修复',
        const TextSelection.collapsed(offset: 3),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.saveNow();

      expect(controller.saveState, HuahuoSaveState.saved);
      expect(saved.single.toDocument().toPlainText(), '已修复\n');
    },
  );

  test('body edits retain cross-device document metadata', () async {
    final base = emptySnapshot();
    final initial = HuahuoDocumentSnapshot(
      id: base.id,
      title: base.title,
      deltaJson: base.deltaJson,
      markdownProjection: '# 新文稿\n',
      linkedMaterials: <HuahuoLinkedMaterialRef>[
        HuahuoLinkedMaterialRef(
          id: 'meeting-1',
          source: 'meeting',
          title: '会议',
        ),
      ],
      sourceTopicId: 'topic-1',
      sourceTopicTitle: '选题',
      revision: base.revision,
      createdAt: base.createdAt,
      modifiedAt: base.modifiedAt,
    );
    final controller = HuahuoEditorController(
      initial: initial,
      onSave: (_) async {},
    );
    addTearDown(controller.dispose);

    controller.body.replaceText(
      0,
      0,
      '正文',
      const TextSelection.collapsed(offset: 2),
    );

    expect(controller.snapshot.markdownProjection, contains('正文'));
    expect(controller.snapshot.linkedMaterials.single.id, 'meeting-1');
    expect(controller.snapshot.sourceTopicId, 'topic-1');
    expect(controller.snapshot.sourceTopicTitle, '选题');
  });

  test('format toggle applies and clears bold', () {
    final controller = HuahuoEditorController(
      initial: emptySnapshot(),
      onSave: (_) async {},
    );
    addTearDown(controller.dispose);
    controller.body.replaceText(
      0,
      0,
      '重点',
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );

    controller.toggleAttribute(Attribute.bold);
    expect(
      controller.body.getSelectionStyle().attributes,
      contains(Attribute.bold.key),
    );
    controller.toggleAttribute(Attribute.bold);
    expect(
      controller.body.getSelectionStyle().attributes,
      isNot(contains(Attribute.bold.key)),
    );
  });
}
