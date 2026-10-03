import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

void main() {
  testWidgets('standalone code receives its host context-menu builder', (
    tester,
  ) async {
    Widget menuBuilder(BuildContext context, EditableTextState state) =>
        const SizedBox.shrink();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HuahuoMarkdown(
            source: '~~~text\ncopy me\n~~~',
            contextMenuBuilder: menuBuilder,
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .contextMenuBuilder,
      same(menuBuilder),
    );
  });

  testWidgets(
    'partial selection spans prose and code without a nested editor',
    (tester) async {
      const markdown = HuahuoMarkdown(
        source: 'before\n\n```text\nsample code\n```\n\nafter',
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: markdown)),
      );
      expect(find.byType(SelectableText), findsOneWidget);
      final originalStyle = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .style;
      SelectedContent? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              onSelectionChanged: (content) => selection = content,
              child: HuahuoMarkdown(
                source: markdown.source,
                unifiedSelection: true,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(SelectableText), findsNothing);
      expect(
        tester.widget<Text>(find.text('sample code')).style,
        originalStyle,
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('before'));
      await tester.pumpAndSettle();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll();
      await tester.pump();
      expect(selection?.plainText, 'before\nsample code\nafter');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy selection hosts retain document and direct code selection',
    (tester) async {
      const source = 'before\n\n```text\nsample code\n```\n\nafter';
      final code = HuahuoMarkdownDocument.parse(source).blocks.singleWhere(
        (block) => block.kind == HuahuoMarkdownBlockKind.code,
      );
      for (final directBlock in <bool>[false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SelectionArea(
                child: Builder(
                  builder: (context) {
                    final colors = HuahuoMarkdownColors.of(context);
                    return directBlock
                        ? HuahuoMarkdownBlockView(
                            block: code,
                            colors: colors,
                            bodyStyle: HuahuoMarkdown.bodyStyleFor(colors),
                          )
                        : const HuahuoMarkdown(source: source);
                  },
                ),
              ),
            ),
          ),
        );
        expect(find.byType(SelectableText), findsOneWidget);
        final renderedCode = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(renderedCode.data, 'sample code');
        expect(renderedCode.style?.fontFamily, 'Menlo');
        expect(renderedCode.style?.fontSize, 14);
        expect(tester.takeException(), isNull);
      }
    },
  );

  test('Assistant repair is the default for every document', () {
    const source = '##无空格标题\n\n正文\n\n###\n\n分离标题\n- [x] 已完成';
    final blocks = HuahuoMarkdownDocument.parse(source).blocks;
    final headings = blocks
        .where((block) => block.kind == HuahuoMarkdownBlockKind.heading)
        .toList();
    expect(headings.map((block) => block.text), ['无空格标题', '分离标题']);
    expect(headings.map((block) => block.sourceLine), [0, 4]);
    expect(blocks.last.kind, HuahuoMarkdownBlockKind.task);
    expect(blocks.last.checked, isTrue);
  });

  test(
    'source-line anchors survive blank-line collapse and repeated headings',
    () {
      const source = '# 重复\r\n\r\n\r\n正文\r\n\r\n\r\n## 重复\r\n\r\n末尾';
      final headings = HuahuoMarkdownDocument.parse(source).flattenedBlocks
          .where((block) => block.kind == HuahuoMarkdownBlockKind.heading);
      expect(headings.map((block) => block.sourceLine), [0, 6]);
    },
  );

  test('new inline headings do not consume later original heading anchors', () {
    const source = '说明 ## 标题\n\n\n## 标题';
    final headings = HuahuoMarkdownDocument.parse(source).flattenedBlocks.where(
      (block) => block.kind == HuahuoMarkdownBlockKind.heading,
    );
    expect(headings.map((block) => block.sourceLine), [0, 3]);
  });

  test('code fences protect tables, headings, tabs, and blank lines', () {
    const source =
        '```text\n| 名称 | 内容 |\n| --- | --- |\n| A | B |\n\n\n\n甲\t乙\n丙\t丁\n###原样\n```\n\n| 名称 | 内容 |\n| --- | --- |\n| A | B |';
    final blocks = HuahuoMarkdownDocument.parse(source).blocks;
    expect(
      blocks.where((block) => block.kind == HuahuoMarkdownBlockKind.table),
      hasLength(1),
    );
    final code = blocks.first;
    expect(code.kind, HuahuoMarkdownBlockKind.code);
    expect(code.text, contains('\n\n\n\n甲\t乙\n丙\t丁\n###原样'));
    expect(
      HuahuoMarkdownDocument.parse('~~~\n## 标题\n~~~').blocks.single.kind,
      HuahuoMarkdownBlockKind.code,
    );
  });

  test('nested alignment preserves headings and source identities', () {
    const source =
        '<div align="center">\n## 居中\n<div align="right">\n### 右侧\n</div>\n</div>';
    final document = HuahuoMarkdownDocument.parse(source);
    expect(document.blocks.single.kind, HuahuoMarkdownBlockKind.alignment);
    expect(
      document.flattenedBlocks
          .where((block) => block.kind == HuahuoMarkdownBlockKind.heading)
          .map((block) => block.sourceLine),
      [1, 3],
    );
  });

  test('shared inline syntax is presentation neutral', () {
    final nodes = parseHuahuoMarkdownInline(
      '**粗体** *斜体* ~~删除~~ `代码` <u>下划线</u> [目录](#section)',
    );
    expect(
      nodes
          .where((node) => node.kind != HuahuoMarkdownInlineKind.text)
          .map((node) => node.kind),
      [
        HuahuoMarkdownInlineKind.bold,
        HuahuoMarkdownInlineKind.italic,
        HuahuoMarkdownInlineKind.strike,
        HuahuoMarkdownInlineKind.code,
        HuahuoMarkdownInlineKind.underline,
        HuahuoMarkdownInlineKind.link,
      ],
    );
  });

  test('oversized documents have a bounded parsing failure', () {
    expect(
      () => HuahuoMarkdownDocument.parse(
        'x' * (HuahuoMarkdownDocument.maximumCharacters + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => HuahuoMarkdownDocument.parse(
        '# 标题\n' * (HuahuoMarkdownDocument.maximumHeadings + 1),
      ),
      throwsFormatException,
    );
  });

  testWidgets(
    'shared renderer preserves Assistant typography and anchor keys',
    (tester) async {
      final anchor = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HuahuoMarkdown(
              source: '普通正文\n\n\n## 标题\n[目录](#section)',
              headingKeysByLine: {3: anchor},
            ),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('普通正文')).style?.fontSize, 15);
      expect(tester.widget<Text>(find.text('普通正文')).style?.height, 1.52);
      expect(anchor.currentContext, isNotNull);
      expect(
        find.descendant(of: find.byKey(anchor), matching: find.text('标题')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('streamed source updates invalidate only the parsed document', (
    tester,
  ) async {
    Future<void> render(String source) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HuahuoMarkdown(source: source)),
      ),
    );
    await render('##初始');
    expect(find.text('初始'), findsOneWidget);
    await render('##完成\n\n**正文**');
    expect(find.text('初始'), findsNothing);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
  });

  testWidgets('images remain host-resolved rather than fetched by the parser', (
    tester,
  ) async {
    final resolved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HuahuoMarkdown(
            source: '![配图](private-image://opaque)',
            imageBuilder: (context, alt, source) {
              resolved.add(source);
              return Text('受控图片：$alt');
            },
          ),
        ),
      ),
    );
    expect(resolved, ['private-image://opaque']);
    expect(find.text('受控图片：配图'), findsOneWidget);
  });
}
