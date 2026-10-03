import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_liquid_glass.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_overlays.dart';

void main() {
  testWidgets('compact action target meets iOS and Android tap guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3CompactActionTarget(
            semanticLabel: '连接录音卡',
            width: 62,
            onTap: () {},
            child: const SizedBox(width: 62, height: 34),
          ),
        ),
      ),
    );

    final ios = await iOSTapTargetGuideline.evaluate(tester);
    final android = await androidTapTargetGuideline.evaluate(tester);
    final labels = await labeledTapTargetGuideline.evaluate(tester);
    expect(ios.passed, isTrue, reason: ios.reason);
    expect(android.passed, isTrue, reason: android.reason);
    expect(labels.passed, isTrue, reason: labels.reason);
  });

  testWidgets('solid sheet isolates inherited glass home scope', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3GlassHomeScope(
          enabled: true,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showV3GlassBottomSheet<void>(
                  context: context,
                  builder: (_) => const V3Card(
                    key: ValueKey('modal-default-card'),
                    child: Text('modal-card'),
                  ),
                ),
                child: const Text('open-scoped-sheet'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-scoped-sheet'));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('modal-default-card'));
    final sheet = find.byType(V3GlassBottomSheet);
    final sheetRect = tester.getRect(sheet);
    expect(card, findsOneWidget);
    expect(sheetRect.left, 0);
    expect(
      sheetRect.right,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );
    expect(
      sheetRect.bottom,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
    final sheetMaterial = tester.widget<Material>(
      find.descendant(of: sheet, matching: find.byType(Material)).first,
    );
    final shape = sheetMaterial.shape! as RoundedRectangleBorder;
    final radius = shape.borderRadius as BorderRadius;
    expect(radius.topLeft.x, 30);
    expect(radius.topRight.x, 30);
    expect(radius.bottomLeft, Radius.zero);
    expect(radius.bottomRight, Radius.zero);
    expect(
      find.descendant(of: card, matching: find.byType(V3LiquidGlassSurface)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  testWidgets('action sheet keeps disabled rows and returns typed selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final result = ValueNotifier<int?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ValueListenableBuilder<int?>(
              valueListenable: result,
              builder: (context, value, child) => Column(
                children: [
                  Text('result:${value ?? '-'}'),
                  TextButton(
                    onPressed: () async {
                      result.value = await showV3ActionSheet<int>(
                        context: context,
                        title: '选择操作',
                        items: const <V3ActionSheetItem<int>>[
                          V3ActionSheetItem(
                            value: 1,
                            icon: Icons.check_circle_outline,
                            label: '当前项',
                            selected: true,
                          ),
                          V3ActionSheetItem(
                            value: 2,
                            icon: Icons.looks_two_outlined,
                            label: '第二项',
                          ),
                          V3ActionSheetItem(
                            value: 3,
                            icon: Icons.block,
                            label: '不可用',
                            enabled: false,
                          ),
                        ],
                      );
                    },
                    child: const Text('open-sheet'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(find.text('选择操作'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final sheet = find.byType(V3GlassBottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.byType(V3LiquidGlassSurface)),
      findsNothing,
    );
    expect(
      find.descendant(of: sheet, matching: find.byType(BackdropFilter)),
      findsNothing,
    );

    await tester.tap(find.text('不可用'));
    await tester.pump();
    expect(find.text('选择操作'), findsOneWidget);
    expect(find.text('result:-'), findsOneWidget);

    await tester.tap(find.text('第二项'));
    await tester.pumpAndSettle();
    expect(find.text('result:2'), findsOneWidget);
  });

  testWidgets('covered source route cannot stack a second shared modal', (
    tester,
  ) async {
    late BuildContext sourceContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Builder(
          builder: (context) {
            sourceContext = context;
            return Scaffold(
              body: TextButton(
                onPressed: () => showV3GlassBottomSheet<void>(
                  context: context,
                  builder: (_) => const Text('first-modal'),
                ),
                child: const Text('open-first-modal'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open-first-modal'));
    await tester.pumpAndSettle();
    final second = showV3GlassBottomSheet<void>(
      context: sourceContext,
      builder: (_) => const Text('second-modal'),
    );
    await tester.pump();

    await second;
    expect(find.text('first-modal'), findsOneWidget);
    expect(find.text('second-modal'), findsNothing);
    expect(find.byType(V3GlassBottomSheet), findsOneWidget);
  });

  testWidgets('text dialog validates then returns trimmed value', (
    tester,
  ) async {
    final result = ValueNotifier<String?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ValueListenableBuilder<String?>(
              valueListenable: result,
              builder: (context, value, child) => Column(
                children: [
                  Text('result:${value ?? '-'}'),
                  TextButton(
                    onPressed: () async {
                      result.value = await showV3TextInputDialog(
                        context: context,
                        title: '重命名',
                        initialValue: '',
                        label: '名称',
                        inputKey: const ValueKey('overlay-name-input'),
                        validator: (value) => value.isEmpty ? '名称不能为空' : null,
                      );
                    },
                    child: const Text('open-dialog'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('名称不能为空'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('overlay-name-input')),
      '  新名称  ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('result:新名称'), findsOneWidget);
  });

  testWidgets('text dialog keeps input and save above a landscape keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final result = ValueNotifier<String?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(
              padding: const EdgeInsets.only(top: 24),
              viewPadding: const EdgeInsets.only(top: 24),
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          );
        },
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await showV3TextInputDialog(
                  context: context,
                  title: '重命名这份录音资料',
                  initialValue: '原始名称',
                  label: '资料名称',
                  inputKey: const ValueKey('compact-dialog-input'),
                );
              },
              child: const Text('open-compact-dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-compact-dialog'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const keyboardTop = 320 - 160.0;
    final input = find.byKey(const ValueKey('compact-dialog-input'));
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(input);
    await tester.pump();
    expect(input.hitTestable(), findsOneWidget);
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(keyboardTop));
    expect(tester.takeException(), isNull);

    await tester.enterText(input, '  横屏名称  ');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(result.value, '横屏名称');
  });

  testWidgets('dark action sheet resolves ambient semantic colors', (
    tester,
  ) async {
    final result = ValueNotifier<int?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await showV3ActionSheet<int>(
                  context: context,
                  title: '暗黑操作',
                  items: const <V3ActionSheetItem<int>>[
                    V3ActionSheetItem(
                      value: 1,
                      icon: Icons.dark_mode_outlined,
                      label: '暗黑选项',
                      subtitle: '主题说明',
                      selected: true,
                    ),
                  ],
                );
              },
              child: const Text('open-dark-sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-dark-sheet'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Icon>(find.byIcon(Icons.dark_mode_outlined)).color,
      HuahuoV3Theme.darkTokens.ink,
    );
    expect(
      tester.widget<Text>(find.text('主题说明')).style?.color,
      HuahuoV3Theme.darkTokens.muted,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_rounded)).color,
      HuahuoV3Theme.darkTokens.ink,
    );

    await tester.tap(find.text('暗黑选项'));
    await tester.pumpAndSettle();
    expect(result.value, 1);
  });

  testWidgets('compact action sheet scrolls to its final safe action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final result = ValueNotifier<int?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(bottom: 24)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await showV3ActionSheet<int>(
                  context: context,
                  title: '小屏操作',
                  items: <V3ActionSheetItem<int>>[
                    for (var index = 1; index <= 14; index++)
                      V3ActionSheetItem<int>(
                        value: index,
                        icon: Icons.description_outlined,
                        label: '第 $index 项',
                        subtitle: '支持信息 $index',
                      ),
                  ],
                );
              },
              child: const Text('open-compact-sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-compact-sheet'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('第 14 项'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('第 14 项'));
    await tester.pumpAndSettle();

    expect(result.value, 14);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog keeps wrapped actions reachable with long content', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => V3GlassDialogFrame(
                  title: '确认操作',
                  content: const SizedBox(
                    height: 520,
                    child: Text('这是一段需要在紧凑屏幕中滚动查看的长内容。'),
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('稍后再处理'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('确认并继续处理'),
                    ),
                  ],
                ),
              ),
              child: const Text('open-long-dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-long-dialog'));
    await tester.pumpAndSettle();

    expect(find.text('稍后再处理'), findsOneWidget);
    expect(find.text('确认并继续处理'), findsOneWidget);
    final dialog = find.byType(V3GlassDialogFrame);
    expect(
      find.descendant(of: dialog, matching: find.byType(V3LiquidGlassSurface)),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('确认并继续处理'));
    await tester.pumpAndSettle();
    expect(find.text('确认操作'), findsNothing);
  });

  testWidgets('compatibility dialog bounds long scaled copy above actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var confirmed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => V3GlassDialog(
                  title: '确认一项需要仔细阅读的操作',
                  message: List<String>.filled(
                    12,
                    '这段说明用于验证紧凑屏幕中的长内容不会挤走操作按钮。',
                  ).join(),
                  primaryLabel: '确认并继续',
                  onPrimary: () {
                    confirmed = true;
                    Navigator.pop(dialogContext);
                  },
                ),
              ),
              child: const Text('open-compatibility-dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-compatibility-dialog'));
    await tester.pumpAndSettle();

    final contentScroll = find.byKey(
      const ValueKey('v3-glass-dialog-content-scroll'),
    );
    expect(contentScroll, findsOneWidget);
    final scrollable = find.descendant(
      of: contentScroll,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(find.text('取消').hitTestable(), findsOneWidget);
    expect(find.text('确认并继续').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('确认并继续'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('compatibility dialog actions survive a landscape keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24)
      ..viewPadding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    var confirmed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => V3GlassDialog(
                  title: '放弃本次编辑？',
                  message: '尚未保存的文字内容将不会保留。',
                  primaryLabel: '确认放弃',
                  onPrimary: () {
                    confirmed = true;
                    Navigator.pop(dialogContext);
                  },
                ),
              ),
              child: const Text('open-keyboard-compatibility-dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-keyboard-compatibility-dialog'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pumpAndSettle();

    final cancel = find.text('取消');
    final confirm = find.text('确认放弃');
    expect(cancel.hitTestable(), findsOneWidget);
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(160));
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('compact destructive sheet keeps actions above scrolling copy', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = ValueNotifier<bool?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await showV3DestructiveConfirmationSheet(
                  context: context,
                  title: '确认删除这份资料？',
                  message: '删除后，这份资料以及关联的整理结果将无法在当前设备中恢复。',
                  itemLabel: '一份标题很长、需要两行空间才能完整辨认的资料文件',
                  warning: List<String>.filled(
                    4,
                    '请确认资料已经完成云端备份，并且不再需要其中的原始内容和处理记录。',
                  ).join(),
                  confirmLabel: '确认删除',
                );
              },
              child: const Text('open-compact-destructive-sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-compact-destructive-sheet'));
    await tester.pumpAndSettle();

    final bodyScroll = find.descendant(
      of: find.byKey(const ValueKey('v3-destructive-confirmation-body-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(bodyScroll, findsOneWidget);
    expect(
      tester.state<ScrollableState>(bodyScroll).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(find.widgetWithText(OutlinedButton, '取消').hitTestable(), findsOne);
    final confirm = find.widgetWithText(FilledButton, '确认删除');
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result.value, isTrue);
  });

  testWidgets('compact text sheet keeps confirm above the keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final result = ValueNotifier<String?>(null);
    addTearDown(result.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await showV3TextInputSheet(
                  context: context,
                  title: '新建文件夹',
                  initialValue: '客户研究',
                  label: '文件夹名称',
                  confirmLabel: '使用这个名称',
                  inputKey: const ValueKey('compact-sheet-input'),
                  suggestions: const [
                    '客户研究与访谈资料',
                    '本周重点项目资料',
                    '长期内容创作素材',
                    '待整理的灵感记录',
                  ],
                );
              },
              child: const Text('open-compact-text-sheet'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-compact-text-sheet'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const keyboardTop = 568 - 300.0;
    final confirm = find.widgetWithText(FilledButton, '使用这个名称');
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(keyboardTop));
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('v3-text-input-sheet-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result.value, '客户研究');
  });
}
