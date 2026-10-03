import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_liquid_glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../support/figma_golden_test_support.dart';

const _frameKey = ValueKey('component-appearance-frame');

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('all palettes keep one appearance across incidental contexts', (
    tester,
  ) async {
    const scenarios = <_Scene>[
      _Scene(),
      _Scene(runtimeReady: false),
      _Scene(home: false),
      _Scene(quality: V3VisualQuality.balanced),
      _Scene(quality: V3VisualQuality.constrained),
      _Scene(scrollable: true),
      _Scene(reduceMotion: true),
      _Scene(highContrast: true),
      _Scene(reduceTransparency: true),
      _Scene(background: Colors.pink),
    ];
    for (final palette in HuahuoV3Palette.values) {
      for (final brightness in Brightness.values) {
        final theme = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: brightness,
        );
        Uint8List? reference;
        Size? referenceSize;
        var taps = 0;
        for (final scene in scenarios) {
          await tester.pumpWidget(
            _harness(
              theme: theme,
              scene: scene,
              child: _Gallery(onTap: () => taps += 1),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(BackdropFilter), findsNothing);
          expect(find.byType(GlassButton), findsNothing);
          final pixels = await _capture(tester);
          final size = tester.getSize(find.byKey(_frameKey));
          if (reference == null) {
            reference = pixels;
            referenceSize = size;
            const output = String.fromEnvironment('HUAHUO_UI_AUDIT_DIR');
            if (output.isNotEmpty) {
              await tester.runAsync(() async {
                await Directory(output).create(recursive: true);
                await File(
                  '$output/${palette.name}-${brightness.name}.png',
                ).writeAsBytes(pixels);
              });
            }
          } else {
            expect(
              pixels,
              orderedEquals(reference),
              reason: '$palette $brightness $scene',
            );
            expect(size, referenceSize);
          }
        }
        await tester.tap(find.bySemanticsLabel('稳定圆形按钮'));
        await tester.tap(find.text('创作空间'));
        expect(taps, 2);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('glass cards have one fill and shadow owner', (tester) async {
    const explicitColor = Color(0xFF345678);
    await tester.pumpWidget(
      _harness(
        theme: HuahuoV3Theme.light(),
        child: const V3Card(
          color: explicitColor,
          child: SizedBox(width: 100, height: 40),
        ),
      ),
    );
    final card = find.byType(V3Card);
    expect(
      find.descendant(of: card, matching: find.byType(Material)),
      findsOneWidget,
    );
    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(of: card, matching: find.byType(DecoratedBox)),
        )
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .toList();
    expect(
      decorations.where(
        (decoration) => decoration.boxShadow?.isNotEmpty ?? false,
      ),
      hasLength(1),
    );
    final fills = decorations
        .where((decoration) => decoration.gradient != null)
        .toList();
    expect(fills, hasLength(1));
    expect(fills.single.gradient!.colors, everyElement(explicitColor));
  });

  testWidgets('button interaction and disabled styling use the same state', (
    tester,
  ) async {
    var taps = 0;
    final theme = HuahuoV3Theme.dark();
    final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
    await tester.pumpWidget(
      _harness(
        theme: theme,
        child: Column(
          children: [
            V3PrimaryButton(
              label: '处理中',
              busy: true,
              onPressed: () => taps += 1,
            ),
            const V3PrimaryButton(label: '缺少回调', onPressed: null),
            const V3OutlineButton(label: '无法操作', onPressed: null),
            V3PrimaryButton(label: '可操作', onPressed: () => taps += 1),
          ],
        ),
      ),
    );
    for (final label in ['处理中', '缺少回调']) {
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, label),
      );
      expect(button.onPressed, isNull);
      expect(button.style!.elevation!.resolve({WidgetState.disabled}), 0);
    }
    final outline = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(outline.onPressed, isNull);
    expect(
      outline.style!.side!.resolve({WidgetState.disabled})!.color,
      tokens.line.withValues(alpha: .55),
    );
    await tester.tap(find.text('处理中'));
    await tester.tap(find.text('缺少回调'));
    await tester.tap(find.text('无法操作'));
    expect(taps, 0);
    await tester.tap(find.text('可操作'));
    expect(taps, 1);
  });

  testWidgets('Material surfaces and snacks share declared theme colors', (
    tester,
  ) async {
    for (final palette in HuahuoV3Palette.values) {
      for (final brightness in Brightness.values) {
        final theme = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: brightness,
        );
        final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
        expect(theme.applyElevationOverlayColor, isFalse);
        expect(theme.colorScheme.surfaceTint, Colors.transparent);
        expect(theme.colorScheme.surfaceContainerHighest, tokens.surfaceMuted);
        await tester.pumpWidget(
          _harness(
            theme: theme,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showV3Snack(
                  context,
                  '提示内容',
                  actionLabel: '重试',
                  onAction: () {},
                ),
                child: const Text('显示提示'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('显示提示'));
        await tester.pumpAndSettle();
        final content = tester.element(find.text('提示内容'));
        final foreground = tester.widget<Text>(find.text('提示内容')).style!.color!;
        expect(foreground, theme.snackBarTheme.contentTextStyle!.color);
        expect(
          HuahuoV3Theme.contrastRatio(
            foreground,
            theme.snackBarTheme.backgroundColor!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          tester.widget<SnackBarAction>(find.byType(SnackBarAction)).textColor,
          foreground,
        );
        ScaffoldMessenger.of(content).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    }
    final localTheme = HuahuoV3Theme.dark(palette: HuahuoV3Palette.sakura);
    await tester.pumpWidget(
      _harness(
        theme: HuahuoV3Theme.light(),
        child: Theme(
          data: localTheme,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showV3Snack(context, '跨主题提示'),
              child: const Text('局部主题'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('局部主题'));
    await tester.pumpAndSettle();
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.backgroundColor, localTheme.snackBarTheme.backgroundColor);
    expect(
      (snack.content as Text).style!.color,
      localTheme.snackBarTheme.contentTextStyle!.color,
    );
  });
}

Future<Uint8List> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frameKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

class _Gallery extends StatelessWidget {
  const _Gallery({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return RepaintBoundary(
      key: _frameKey,
      child: SizedBox(
        width: 300,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  V3LiquidGlassCircle(
                    diameter: 60,
                    semanticLabel: '稳定圆形按钮',
                    onTap: onTap,
                    tone: V3GlassTone.warm,
                    child: const Icon(Icons.add),
                  ),
                  V3LiquidGlassCircle(
                    diameter: 60,
                    semanticLabel: '已选按钮',
                    onTap: onTap,
                    tone: V3GlassTone.cool,
                    selected: true,
                    child: const Icon(Icons.check),
                  ),
                  V3LiquidGlassIconAction(
                    tooltip: '更多',
                    semanticLabel: '更多',
                    icon: const Icon(Icons.more_horiz),
                    onTap: onTap,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              V3LiquidGlassSurface(
                padding: const EdgeInsets.all(16),
                child: Text('面板 · 思想图谱', style: TextStyle(color: colors.text)),
              ),
              const SizedBox(height: 20),
              V3Card(
                child: Text('卡片 · 我的资产', style: TextStyle(color: colors.text)),
              ),
              const SizedBox(height: 20),
              V3FeedQuickDock(onOpenWorkbench: onTap),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Scene {
  const _Scene({
    this.runtimeReady = true,
    this.home = true,
    this.quality = V3VisualQuality.high,
    this.scrollable = false,
    this.reduceMotion = false,
    this.highContrast = false,
    this.reduceTransparency = false,
    this.background = Colors.white,
  });

  final bool runtimeReady;
  final bool home;
  final V3VisualQuality quality;
  final bool scrollable;
  final bool reduceMotion;
  final bool highContrast;
  final bool reduceTransparency;
  final Color background;

  @override
  String toString() =>
      'runtime=$runtimeReady home=$home quality=$quality scroll=$scrollable motion=$reduceMotion contrast=$highContrast transparency=$reduceTransparency background=$background';
}

Widget _harness({
  required ThemeData theme,
  required Widget child,
  _Scene scene = const _Scene(),
}) => MaterialApp(
  theme: theme,
  themeAnimationDuration: Duration.zero,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: scene.reduceMotion,
      highContrast: scene.highContrast,
    ),
    child: GlassAccessibilityScope(
      reduceMotion: scene.reduceMotion,
      reduceTransparency: scene.reduceTransparency,
      child: child!,
    ),
  ),
  home: Scaffold(
    backgroundColor: scene.background,
    body: V3GlassRuntimeScope(
      enabled: scene.runtimeReady,
      child: V3GlassHomeScope(
        enabled: scene.home,
        child: V3GlassPerformanceScope(
          quality: scene.quality,
          adaptiveQuality: true,
          child: scene.scrollable
              ? SingleChildScrollView(child: Center(child: child))
              : Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    ),
  ),
);
