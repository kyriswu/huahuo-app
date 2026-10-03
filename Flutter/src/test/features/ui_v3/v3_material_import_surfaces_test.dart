import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_material_import_surfaces.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M01 link import sheet follows the shared V5 surface', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var closeCalls = 0;
    var confirmCalls = 0;
    var distillationChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: V3MaterialImportRouteSheet(
          title: '从链接导入',
          confirmLabel: '确定',
          onClose: () => closeCalls += 1,
          onConfirm: () => confirmCalls += 1,
          child: V3LinkImportSheetContent(
            controller: controller,
            onChanged: (_) {},
            onDistillationChanged: (_) => distillationChanges += 1,
            onDistillationHelp: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.transparent,
    );

    await expectLater(
      find.byType(V3MaterialImportRouteSheet),
      matchesGoldenFile('goldens/material_import_link_sheet.png'),
    );
    await tester.tap(find.text('确定'));
    await tester.tap(
      find.byKey(const ValueKey('link-import-distillation-option')),
    );
    await tester.tap(find.byTooltip('关闭'));
    expect(confirmCalls, 1);
    expect(distillationChanges, 1);
    expect(closeCalls, 1);
  });

  testWidgets('M01 link analysis uses the shared V5 progress surface', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var backCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(402, 874),
            padding: EdgeInsets.only(top: 54, bottom: 34),
          ),
          child: V3MaterialImportProgressSurface(
            sourceLabel: 'https://account.apple.com',
            sourceIcon: Icons.link_rounded,
            title: '链接分析中...',
            message: '约需 1-10 秒，可直接返回开始新笔记，部分平台视频链接处理较长。',
            onBack: () => backCalls += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byType(V3MaterialImportProgressSurface),
      matchesGoldenFile('goldens/material_import_link_progress.png'),
    );
    await tester.tap(find.byTooltip('返回'));
    expect(backCalls, 1);
  });

  testWidgets('import cards grow for scaled copy and validation errors', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setPhoneViewport(tester, size: size);

    Widget scaledApp(Widget home) => MaterialApp(
      theme: figmaGoldenTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      home: home,
    );

    await tester.pumpWidget(
      scaledApp(
        V3MaterialImportProgressSurface(
          sourceLabel: 'https://account.apple.com',
          sourceIcon: Icons.link_rounded,
          title: '链接分析中...',
          message: '约需 1-10 秒，可直接返回开始新笔记，部分平台视频链接处理较长。',
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('material-import-progress-status')),
          )
          .height,
      greaterThan(118),
    );
    expect(tester.takeException(), isNull);

    final controller = TextEditingController(text: 'invalid-link');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      scaledApp(
        Scaffold(
          body: V3LinkImportSheetContent(
            controller: controller,
            onChanged: (_) {},
            errorText: '请输入一个可公开访问的有效链接后重试',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('link-import-field'))).height,
      greaterThan(54),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('link-import-card'))).height,
      greaterThanOrEqualTo(270),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      scaledApp(
        Scaffold(
          body: V3FileImportSheetContent(
            kind: V3FileImportKind.media,
            onPick: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('file-import-card'))).height,
      greaterThan(270),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('import input keeps content across a chromatic dark keyboard', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    addTearDown(tester.view.resetViewInsets);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final theme = HuahuoV3Theme.dark(palette: HuahuoV3Palette.warmGold);
    final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: V3MaterialImportRouteSheet(
          title: '从链接导入',
          confirmLabel: '确定',
          onClose: () {},
          onConfirm: () {},
          child: V3LinkImportSheetContent(
            controller: controller,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'https://example.com/a');
    final inputTopBeforeKeyboard = tester.getTopLeft(
      find.byKey(const ValueKey('link-import-field')),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.text, 'https://example.com/a');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('link-import-field'))),
      inputTopBeforeKeyboard,
    );
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确定'),
    );
    expect(
      confirm.style?.backgroundColor?.resolve(<WidgetState>{}),
      tokens.primary,
    );
    expect(
      confirm.style?.foregroundColor?.resolve(<WidgetState>{}),
      tokens.onPrimary,
    );

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.text, 'https://example.com/a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('M01 document import sheet keeps picker and route actions live', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var pickCalls = 0;
    var distillationChanges = 0;
    var confirmCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: V3MaterialImportRouteSheet(
          title: '从文件导入',
          confirmLabel: '确定',
          onClose: () {},
          onConfirm: () => confirmCalls += 1,
          child: V3FileImportSheetContent(
            kind: V3FileImportKind.document,
            onPick: () => pickCalls += 1,
            distillToDigitalTwin: false,
            onDistillationChanged: (_) => distillationChanges += 1,
            onDistillationHelp: () {},
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3MaterialImportRouteSheet),
      matchesGoldenFile('goldens/material_import_document_sheet.png'),
    );
    await tester.tap(find.text('选择文件'));
    await tester.tap(
      find.byKey(const ValueKey('file-import-distillation-option')),
    );
    await tester.tap(find.text('确定'));
    expect(pickCalls, 1);
    expect(distillationChanges, 1);
    expect(confirmCalls, 1);
  });

  testWidgets('M01 media import sheet keeps picker and route actions live', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var pickCalls = 0;
    var distillationChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: V3MaterialImportRouteSheet(
          title: '导入录音音频',
          confirmLabel: '确定',
          onClose: () {},
          onConfirm: () {},
          child: V3FileImportSheetContent(
            kind: V3FileImportKind.media,
            onPick: () => pickCalls += 1,
            onDistillationChanged: (_) => distillationChanges += 1,
            onDistillationHelp: () {},
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3MaterialImportRouteSheet),
      matchesGoldenFile('goldens/material_import_media_sheet.png'),
    );
    await tester.tap(find.text('选择录音'));
    await tester.tap(
      find.byKey(const ValueKey('audio-import-distillation-option')),
    );
    expect(pickCalls, 1);
    expect(distillationChanges, 1);
  });

  testWidgets('M01 recording import sheet switches recording mode', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var selected = V3RecordingImportMode.external;
    var distillToDigitalTwin = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => V3MaterialImportRouteSheet(
            title: '录音导入',
            confirmLabel: '确定',
            onClose: () {},
            onConfirm: () {},
            child: V3RecordingImportSheetContent(
              selected: selected,
              onSelected: (value) => setState(() => selected = value),
              distillToDigitalTwin: distillToDigitalTwin,
              onDistillationChanged: (value) =>
                  setState(() => distillToDigitalTwin = value),
              onDistillationHelp: () {},
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3MaterialImportRouteSheet),
      matchesGoldenFile('goldens/material_import_recording_sheet.png'),
    );
    await tester.tap(find.text('内录'));
    await tester.pump();
    expect(selected, V3RecordingImportMode.internal);
    final distillationOption = find.byKey(
      const ValueKey('recording-import-distillation-option'),
    );
    expect(distillationOption, findsOneWidget);
    await tester.tap(distillationOption);
    await tester.pump();
    expect(distillToDigitalTwin, isTrue);
  });

  testWidgets('M01 document conversion uses the shared V5 progress surface', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _progressMediaQuery(
          V3MaterialImportProgressSurface(
            sourceLabel: '项目复盘报告.pdf',
            sourceIcon: Icons.description_outlined,
            sourceAccent: const Color(0xff111111),
            title: '文件转换中...',
            message: '正在解析文件内容，完成后会自动生成笔记。',
            onBack: () {},
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3MaterialImportProgressSurface),
      matchesGoldenFile('goldens/material_import_document_progress.png'),
    );
  });

  testWidgets('M01 media transcription uses the shared V5 progress surface', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _progressMediaQuery(
          V3MaterialImportProgressSurface(
            sourceLabel: '产品访谈录音.m4a',
            sourceIcon: Icons.audio_file_outlined,
            sourceAccent: const Color(0xff111111),
            title: '录音上传中...',
            message: '上传完成后会自动创建转写任务，并展示服务端识别文字。',
            onBack: () {},
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3MaterialImportProgressSurface),
      matchesGoldenFile('goldens/material_import_media_progress.png'),
    );
  });
}

void _setPhoneViewport(
  WidgetTester tester, {
  Size size = const Size(402, 874),
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _progressMediaQuery(Widget child) => MediaQuery(
  data: const MediaQueryData(
    size: Size(402, 874),
    padding: EdgeInsets.only(top: 54, bottom: 34),
  ),
  child: child,
);
