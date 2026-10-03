import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/shared/markdown/markdown_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    const fontPath = 'assets/fonts/NotoSansSC-Variable.ttf';
    final textFont = FontLoader('NotoSansSC')..addFont(_loadFont(fontPath));
    final codeFont = FontLoader('Menlo')..addFont(_loadFont(fontPath));
    await Future.wait<void>(<Future<void>>[textFont.load(), codeFont.load()]);
  });

  testWidgets('uses the shared Assistant Markdown renderer', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: MarkdownPreviewPane(
              source: MarkdownPreviewSource(
                title: 'Writing preview',
                markdown: '# Preview heading\n\nA quiet **document** preview.',
                stage: 'Draft',
              ),
              preferences: MarkdownPreviewPreferences(),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('markdown-native-preview')),
      findsOneWidget,
    );
    expect(find.text('Writing preview'), findsOneWidget);
    expect(find.text('Preview heading'), findsNWidgets(2));
    expect(find.text('On this page'), findsOneWidget);
  });

  testWidgets(
    'companion preview keeps themed content without duplicate chrome',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: MarkdownPreviewPane(
                source: MarkdownPreviewSource(
                  title: 'Writing preview',
                  markdown:
                      '# Preview heading\n\nA quiet **document** preview.',
                  stage: 'Draft',
                ),
                preferences: MarkdownPreviewPreferences(),
                surface: MarkdownPreviewSurface.companion,
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('markdown-native-companion')),
        findsOneWidget,
      );
      expect(find.text('Writing preview'), findsNothing);
      expect(find.text('Preview heading'), findsOneWidget);
      expect(find.text('On this page'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('markdown-native-lead-quiet')),
        findsOneWidget,
      );
      final document = tester.widget<Container>(
        find.byKey(const ValueKey<String>('markdown-native-document-quiet')),
      );
      final decoration = document.decoration! as BoxDecoration;
      expect(decoration.gradient, isA<LinearGradient>());
      expect(decoration.borderRadius, isA<BorderRadius>());
      expect(decoration.boxShadow, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders an empty new draft as a native companion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: MarkdownPreviewPane(
              source: MarkdownPreviewSource(
                title: 'Untitled draft',
                markdown: '',
              ),
              preferences: MarkdownPreviewPreferences(),
              surface: MarkdownPreviewSurface.companion,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>('markdown-native-companion'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('markdown-preview-fallback'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the native renderer on Windows without a platform view', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: MarkdownPreviewPane(
                source: MarkdownPreviewSource(
                  title: 'Windows preview',
                  markdown: '# Preview heading',
                ),
                preferences: MarkdownPreviewPreferences(),
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('markdown-native-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('markdown-macos-platform-preview')),
        findsNothing,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('uses the same native renderer on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 640,
              child: MarkdownPreviewPane(
                source: MarkdownPreviewSource(
                  title: 'macOS preview',
                  markdown: '# Preview heading',
                ),
                preferences: MarkdownPreviewPreferences(),
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('markdown-native-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('markdown-macos-platform-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows a local fallback when Markdown compilation is unsafe', (
    tester,
  ) async {
    final oversized = List<String>.filled(
      MarkdownPreviewDocumentCompiler.maximumDocumentCharacters + 1,
      'x',
    ).join();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreviewPane(
            source: MarkdownPreviewSource(
              title: 'Oversized preview',
              markdown: oversized,
            ),
            preferences: const MarkdownPreviewPreferences(),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('markdown-preview-fallback')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native preview applies distinct quiet, editorial, and focus theme tokens',
    (tester) async {
      Future<(BoxConstraints, TextStyle?, Color?)> render(
        MarkdownPreviewTheme theme,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorSchemeSeed: const Color(0xFF2563EB),
              brightness: Brightness.light,
            ),
            home: Scaffold(
              body: SizedBox(
                width: 1100,
                height: 640,
                child: MarkdownPreviewPane(
                  source: const MarkdownPreviewSource(
                    title: 'Writing preview',
                    markdown:
                        '# Opening\n\n## Detail\n\nA quiet document preview.',
                    stage: 'Draft',
                  ),
                  preferences: MarkdownPreviewPreferences(theme: theme),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final width = tester.widget<ConstrainedBox>(
          find.byKey(
            ValueKey<String>('markdown-native-width-${theme.storageValue}'),
          ),
        );
        final title = tester.widget<Text>(
          find.byKey(
            ValueKey<String>('markdown-native-title-${theme.storageValue}'),
          ),
        );
        final canvas = tester.widget<Container>(
          find.byKey(
            ValueKey<String>('markdown-native-canvas-${theme.storageValue}'),
          ),
        );
        return (width.constraints, title.style, canvas.color);
      }

      final quiet = await render(MarkdownPreviewTheme.quiet);
      final editorial = await render(MarkdownPreviewTheme.editorial);
      final focus = await render(MarkdownPreviewTheme.focus);

      expect(quiet.$1.maxWidth, 820);
      expect(editorial.$1.maxWidth, 940);
      expect(focus.$1.maxWidth, 680);
      expect(quiet.$1.maxWidth, isNot(editorial.$1.maxWidth));
      expect(editorial.$1.maxWidth, isNot(focus.$1.maxWidth));
      expect(quiet.$2!.fontSize, 31);
      expect(editorial.$2!.fontSize, 40);
      expect(focus.$2!.fontSize, 34);
      expect(editorial.$2!.fontFamily, 'NotoSansSC');
      expect(quiet.$3, isNot(editorial.$3));
      expect(editorial.$3, isNot(focus.$3));
    },
  );

  testWidgets('native preview maps themes to distinct presentation layouts', (
    tester,
  ) async {
    Future<void> render(MarkdownPreviewTheme theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF2563EB),
            brightness: Brightness.light,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 760,
              child: MarkdownPreviewPane(
                source: const MarkdownPreviewSource(
                  title: 'Presentation layout',
                  stage: 'Draft',
                  markdown:
                      'A first paragraph becomes the document lead.\n\n## Detail\n\nSecond paragraph.',
                ),
                preferences: MarkdownPreviewPreferences(theme: theme),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await render(MarkdownPreviewTheme.editorial);
    expect(
      find.byKey(const ValueKey<String>('markdown-native-layout-magazine')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-native-magazine-deck')),
      findsOneWidget,
    );

    await render(MarkdownPreviewTheme.paper);
    expect(
      find.byKey(const ValueKey<String>('markdown-native-layout-parchment')),
      findsOneWidget,
    );

    await render(MarkdownPreviewTheme.focus);
    expect(
      find.byKey(const ValueKey<String>('markdown-native-layout-focus')),
      findsOneWidget,
    );

    await render(MarkdownPreviewTheme.research);
    expect(
      find.byKey(const ValueKey<String>('markdown-native-layout-research')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-native-research-rail')),
      findsOneWidget,
    );

    await render(MarkdownPreviewTheme.brief);
    expect(
      find.byKey(const ValueKey<String>('markdown-native-layout-brief')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-native-brief-summary')),
      findsOneWidget,
    );
  });

  testWidgets('renders resolved document-owned media in the Flutter fallback', (
    tester,
  ) async {
    const mediaUri = 'huahuo-media://asset/AbcdefghijklmnopQRSTUVWX';
    final imageBytes = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLZQAAAAABJRU5ErkJggg==',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: MarkdownPreviewPane(
              source: const MarkdownPreviewSource(
                title: 'Media preview',
                markdown: '![](huahuo-media://asset/AbcdefghijklmnopQRSTUVWX)',
              ),
              preferences: const MarkdownPreviewPreferences(),

              mediaResolver: (uri) async => uri.toString() == mediaUri
                  ? MarkdownPreviewMedia(
                      bytes: imageBytes,
                      mimeType: 'image/png',
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('does not send oversized local media to the image decoder', (
    tester,
  ) async {
    const mediaUri = 'huahuo-media://asset/AbcdefghijklmnopQRSTUVWX';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 640,
            child: MarkdownPreviewPane(
              source: const MarkdownPreviewSource(
                title: 'Large media preview',
                markdown: '![](huahuo-media://asset/AbcdefghijklmnopQRSTUVWX)',
              ),
              preferences: const MarkdownPreviewPreferences(),

              mediaResolver: (uri) async => uri.toString() == mediaUri
                  ? MarkdownPreviewMedia(
                      bytes: Uint8List(
                        MarkdownPreviewMedia.maximumPreviewBytes + 1,
                      ),
                      mimeType: 'image/png',
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final theme in <MarkdownPreviewTheme>[
    MarkdownPreviewTheme.quiet,
    MarkdownPreviewTheme.paper,
    MarkdownPreviewTheme.editorial,
    MarkdownPreviewTheme.focus,
    MarkdownPreviewTheme.research,
    MarkdownPreviewTheme.brief,
  ]) {
    testWidgets(
      'captures the Windows-native ${theme.storageValue} preview theme',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await _pumpPreviewThemeCapture(tester, theme);

          expect(
            find.byKey(const ValueKey<String>('markdown-native-preview')),
            findsOneWidget,
          );
          expect(
            find.byKey(
              const ValueKey<String>('markdown-macos-platform-preview'),
            ),
            findsNothing,
          );
          await expectLater(
            find.byKey(
              ValueKey<String>(
                'markdown-preview-capture-${theme.storageValue}',
              ),
            ),
            matchesGoldenFile(
              'goldens/markdown_preview_theme_${theme.storageValue}_1280x900.png',
            ),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

Future<ByteData> _loadFont(String path) async {
  final bytes = await File(path).readAsBytes();
  return ByteData.sublistView(bytes);
}

Future<void> _pumpPreviewThemeCapture(
  WidgetTester tester,
  MarkdownPreviewTheme theme,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

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
          key: ValueKey<String>(
            'markdown-preview-capture-${theme.storageValue}',
          ),
          child: SizedBox.expand(
            child: MarkdownPreviewPane(
              source: _captureSource,
              preferences: MarkdownPreviewPreferences(
                theme: theme,
                colorMode: MarkdownPreviewColorMode.light,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const MarkdownPreviewSource _captureSource = MarkdownPreviewSource(
  title: 'The shape of a deliberate writing day',
  stage: 'WORKING DRAFT',
  markdown: '''
# Begin with a clear idea

Writing becomes lighter when the page gives a thought enough room to arrive.
Keep the first pass honest, then return with a sharper question.

## Hold a steady rhythm

> A calm surface should make the next sentence easier to find.

- Notice what matters.
- Name it simply.
- Leave room to revise.

## Keep useful details close

```text
idea / outline / draft / revision
```
''',
);
