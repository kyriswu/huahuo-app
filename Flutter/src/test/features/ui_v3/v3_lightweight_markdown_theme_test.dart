import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('light Markdown highlight stays readable in a dark theme', (
    tester,
  ) async {
    const highlight = Color(0xFFFFF0F0);
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.dark(),
        home: const Scaffold(
          body: V3AssistantReplyMarkdown(
            source: '<span data-hh-bg="#FFF0F0">高亮内容</span>',
          ),
        ),
      ),
    );

    final span = _inlineSpan(tester);
    expect(span.style?.backgroundColor, highlight);
    expect(
      HuahuoV3Theme.contrastRatio(span.style!.color!, highlight),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('dark Markdown highlight stays readable in a light theme', (
    tester,
  ) async {
    const highlight = Color(0xFF232323);
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: const Scaffold(
          body: V3AssistantReplyMarkdown(
            source: '<span data-hh-bg="#232323">高亮内容</span>',
          ),
        ),
      ),
    );

    final span = _inlineSpan(tester);
    expect(span.style?.backgroundColor, highlight);
    expect(
      HuahuoV3Theme.contrastRatio(span.style!.color!, highlight),
      greaterThanOrEqualTo(4.5),
    );
  });
}

TextSpan _inlineSpan(WidgetTester tester) {
  final richText = tester
      .widgetList<Text>(find.byType(Text))
      .where((text) => text.textSpan != null)
      .single;
  final root = richText.textSpan! as TextSpan;
  return root.children!.single as TextSpan;
}
