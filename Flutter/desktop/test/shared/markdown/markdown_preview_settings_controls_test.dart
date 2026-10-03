import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/shared/markdown/markdown_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final textFont = FontLoader('NotoSansSC')
      ..addFont(_loadFont('assets/fonts/NotoSansSC-Variable.ttf'));
    await textFont.load();
  });

  testWidgets('captures the desktop template catalogue', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = MarkdownPreviewPreferencesController(
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'NotoSansSC',
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3F5E80),
            brightness: Brightness.light,
          ),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('markdown-template-catalogue-capture'),
            child: Builder(
              builder: (context) => Material(
                color: Theme.of(context).colorScheme.surface,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: MarkdownPreviewSettingsControls(
                    controller: controller,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('markdown-template-catalogue-capture')),
      matchesGoldenFile(
        'goldens/markdown_preview_template_catalogue_960x760.png',
      ),
    );
  });

  testWidgets('shows a structural miniature for every built-in template', (
    tester,
  ) async {
    final controller = MarkdownPreviewPreferencesController(
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: MarkdownPreviewSettingsControls(controller: controller),
          ),
        ),
      ),
    );

    for (final theme in MarkdownPreviewTheme.values) {
      final templateTile = find.byKey(
        ValueKey<String>('markdown-preview-theme-${theme.storageValue}'),
      );
      expect(
        find.byKey(
          ValueKey<String>(
            'markdown-preview-template-preview-${theme.storageValue}',
          ),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(templateTile);
      await tester.tap(templateTile);
      await tester.pump();
      expect(controller.value.theme, theme);
    }

    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-structure-quiet-article',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-structure-paper-parchment',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-structure-editorial-magazine',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-structure-focus-reader',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-research-outline-rail',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'markdown-preview-template-structure-brief-executive',
        ),
      ),
      findsOneWidget,
    );

    expect(find.text('长文'), findsOneWidget);
    expect(find.text('纸页'), findsOneWidget);
    expect(find.text('特写'), findsOneWidget);
    expect(find.text('专注'), findsOneWidget);
    expect(find.text('研读'), findsOneWidget);
    expect(find.text('简报'), findsOneWidget);
  });

  testWidgets('updates the shared preview preferences from Writing controls', (
    tester,
  ) async {
    final controller = MarkdownPreviewPreferencesController(
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: MarkdownPreviewSettingsControls(controller: controller),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('markdown-preview-profile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-preview-theme-editorial')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-preview-color-mode')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('markdown-preview-theme-editorial')),
    );
    await tester.pump();
    expect(controller.value.theme, MarkdownPreviewTheme.editorial);

    final paperProfile = find.text('纸张');
    await tester.ensureVisible(paperProfile);
    await tester.tap(paperProfile);
    await tester.pump();
    expect(controller.value.profile, MarkdownPreviewProfile.paper);

    final darkColorMode = find.text('暗黑');
    await tester.ensureVisible(darkColorMode);
    await tester.tap(darkColorMode);
    await tester.pump();
    expect(controller.value.colorMode, MarkdownPreviewColorMode.dark);

    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('markdown-preview-text-scale')),
    );
    slider.onChanged!(1.25);
    await tester.pump();
    expect(controller.value.textScale, 1.25);

    final tableOfContents = find.byKey(
      const ValueKey<String>('markdown-preview-table-of-contents'),
    );
    await tester.ensureVisible(tableOfContents);
    await tester.tap(tableOfContents);
    await tester.pump();
    expect(controller.value.showTableOfContents, isFalse);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('markdown-preview-remote-images')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('markdown-preview-remote-images')),
    );
    await tester.pump();
    expect(controller.value.allowRemoteImages, isTrue);
  });
}

Future<ByteData> _loadFont(String path) async {
  final bytes = await File(path).readAsBytes();
  return ByteData.sublistView(bytes);
}

final class _MemoryStore implements MarkdownPreviewPreferencesStore {
  MarkdownPreviewPreferences _value = MarkdownPreviewPreferences.defaults;

  @override
  Future<MarkdownPreviewPreferences> load() async => _value;

  @override
  Future<void> save(MarkdownPreviewPreferences preferences) async {
    _value = preferences;
  }
}
