import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_text_editing.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('standard text actions use one Chinese label set', (
    tester,
  ) async {
    late BuildContext menuContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            menuContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    const expected = <ContextMenuButtonType, String>{
      ContextMenuButtonType.cut: '剪切',
      ContextMenuButtonType.copy: '复制',
      ContextMenuButtonType.paste: '粘贴',
      ContextMenuButtonType.selectAll: '全选',
      ContextMenuButtonType.delete: '删除',
      ContextMenuButtonType.lookUp: '查询',
      ContextMenuButtonType.searchWeb: '网页搜索',
      ContextMenuButtonType.share: '分享',
      ContextMenuButtonType.liveTextInput: '扫描文本',
    };
    for (final entry in expected.entries) {
      final item = ContextMenuButtonItem(
        onPressed: () {},
        type: entry.key,
        label: 'English fallback',
      );
      final localized = V3TextEditing.localizeButtonItems(menuContext, [item]);
      expect(localized.single.label, entry.value);
      expect(localized.single.type, entry.key);
      expect(localized.single.onPressed, same(item.onPressed));
    }
    expect(
      V3TextEditing.buttonLabel(
        menuContext,
        const ContextMenuButtonItem(onPressed: null, label: '业务操作'),
      ),
      '业务操作',
    );
  });

  testWidgets('input lines stay centered across heights and text scales', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    for (final (height, fontSize) in [
      (40.0, 12.0),
      (44.0, 14.0),
      (52.0, 16.0),
      (89.0, 22.0),
    ]) {
      for (final scale in [1.0, 1.5]) {
        for (final value in ['', '输入Aa123']) {
          controller.text = value;
          await _pumpInput(
            tester,
            controller: controller,
            height: height,
            fontSize: fontSize,
            scale: scale,
          );
          final target = tester.getRect(
            find.byKey(const ValueKey('input-target')),
          );
          final editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final line = editable.localToGlobal(
            editable.getLocalRectForCaret(const TextPosition(offset: 0)).center,
          );
          expect(
            line.dy,
            closeTo(target.center.dy, 1),
            reason: '$height/$fontSize/$scale/$value',
          );
          expect(
            editable.preferredLineHeight,
            lessThanOrEqualTo(target.height),
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('input padding focuses and multiline content grows naturally', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pumpInput(tester, controller: controller, height: 40, fontSize: 16);
    final target = find.byKey(const ValueKey('input-target'));
    final bounds = tester.getRect(target);
    await tester.tapAt(Offset(bounds.center.dx, bounds.top + 2));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), '第一行\n第二行\n第三行\n第四行');
    await tester.pump();
    expect(tester.getSize(target).height, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled inputs do not focus and external focus stays owned', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await _pumpInput(
      tester,
      controller: controller,
      height: 52,
      fontSize: 16,
      enabled: false,
      focusNode: focusNode,
    );
    await tester.tap(find.byKey(const ValueKey('input-target')));
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
    await tester.pumpWidget(const SizedBox());
    await _pumpInput(
      tester,
      controller: controller,
      height: 52,
      fontSize: 16,
      focusNode: focusNode,
    );
    await tester.tap(find.byKey(const ValueKey('input-target')));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpInput(
  WidgetTester tester, {
  required TextEditingController controller,
  required double height,
  required double fontSize,
  double scale = 1,
  bool enabled = true,
  FocusNode? focusNode,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HuahuoV3Theme.light(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: V3CenteredInput(
                key: const ValueKey('input-target'),
                minHeight: height,
                enabled: enabled,
                focusNode: focusNode,
                builder: (inputFocus) => TextField(
                  controller: controller,
                  focusNode: inputFocus,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 4,
                  style: TextStyle(fontSize: fontSize, height: 1.3),
                  decoration: V3TextEditing.inlineDecoration.copyWith(
                    hintText: '输入内容',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
