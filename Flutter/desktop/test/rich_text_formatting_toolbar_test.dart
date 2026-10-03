import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/presentation/rich_text_formatting_toolbar.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  late HuahuoEditorController controller;

  setUp(() {
    final now = DateTime.utc(2026, 7, 28);
    controller = HuahuoEditorController(
      initial: HuahuoDocumentSnapshot(
        id: 'toolbar-test',
        title: 'Toolbar test',
        deltaJson: '[{"insert":"Hello world\\n"}]',
        revision: 0,
        createdAt: now,
        modifiedAt: now,
      ),
      onSave: (_) async {},
      autosaveDelay: const Duration(days: 1),
    );
  });

  tearDown(() => controller.dispose());

  Future<void> pumpToolbar(
    WidgetTester tester, {
    HuahuoEditorLinkResolver? onResolveLink,
    HuahuoEditorImageResolver? onResolveImage,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HuahuoRichTextFormattingToolbar(
            controller: controller,
            onResolveLink: onResolveLink,
            onResolveImage: onResolveImage,
            imageEmbeddingEnabled: onResolveImage != null,
          ),
        ),
      ),
    );
  }

  testWidgets('applies inline and block formatting to the selected range', (
    tester,
  ) async {
    await pumpToolbar(tester);
    controller.body.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('editor-format-bold')));
    await tester.pump();
    expect(
      controller.body.document.toDelta().operations.first.attributes?['bold'],
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('editor-format-heading')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题 2'));
    await tester.pump();
    expect(
      controller.body
          .getSelectionStyle()
          .attributes[Attribute.header.key]
          ?.value,
      2,
    );
  });

  testWidgets('uses resolvers to insert a link and an image embed', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      onResolveLink: (_, _) async =>
          const HuahuoEditorLink(text: 'Huahuo', url: 'https://huahuo.ai'),
      onResolveImage: (_) async => 'https://huahuo.ai/cover.png',
    );
    controller.body.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('editor-format-link')));
    await tester.pump();
    await tester.pump();
    expect(controller.body.document.toPlainText(), startsWith('Huahuo'));
    expect(
      controller.body.document.toDelta().operations.first.attributes?['link'],
      'https://huahuo.ai',
    );

    controller.body.updateSelection(
      const TextSelection.collapsed(offset: 7),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('editor-format-image')));
    await tester.pump();
    await tester.pump();
    final operations = controller.body.document.toDelta().toJson();
    expect(
      operations.any((operation) {
        final insert = operation['insert'];
        return insert is Map &&
            insert['image'] == 'https://huahuo.ai/cover.png';
      }),
      isTrue,
    );
  });

  testWidgets('accepts a document-owned local media image reference', (
    tester,
  ) async {
    const mediaUri = 'huahuo-media://asset/AbcdefghijklmnopQRSTUVWX';
    await pumpToolbar(tester, onResolveImage: (_) async => mediaUri);
    controller.body.updateSelection(
      const TextSelection.collapsed(offset: 7),
      ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('editor-format-image')));
    await tester.pump();
    await tester.pump();

    final operations = controller.body.document.toDelta().toJson();
    expect(
      operations.any((operation) {
        final insert = operation['insert'];
        return insert is Map && insert['image'] == mediaUri;
      }),
      isTrue,
    );
  });
}
