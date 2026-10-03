import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/shared/markdown/markdown_preview.dart';

void main() {
  group('LocalMarkdownPreviewPreferencesStore', () {
    late Directory supportDirectory;

    setUp(() async {
      supportDirectory = await Directory.systemTemp.createTemp(
        'huahuo-markdown-preview-',
      );
    });

    tearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test('round trips a versioned Markdown preview envelope', () async {
      final store = LocalMarkdownPreviewPreferencesStore(
        supportDirectory: () async => supportDirectory,
      );
      const preferences = MarkdownPreviewPreferences(
        theme: MarkdownPreviewTheme.research,
        profile: MarkdownPreviewProfile.paper,
        colorMode: MarkdownPreviewColorMode.dark,
        textScale: 1.25,
        showTableOfContents: false,
        allowRemoteImages: true,
      );
      final updated = preferences.copyWith(
        theme: MarkdownPreviewTheme.brief,
        profile: MarkdownPreviewProfile.compact,
        textScale: 1.4,
      );

      await store.save(preferences);
      expect(await store.load(), preferences);
      await store.save(updated);

      expect(await store.load(), updated);
      final target = File(
        '${supportDirectory.path}${Platform.pathSeparator}settings'
        '${Platform.pathSeparator}desktop-preferences.json',
      );
      final payload = await target.readAsString();
      expect(payload, contains('"version":1'));
      expect(payload, contains('"markdownPreview"'));
    });

    test('returns safe defaults for malformed persisted data', () async {
      final store = LocalMarkdownPreviewPreferencesStore(
        supportDirectory: () async => supportDirectory,
      );
      await store.save(MarkdownPreviewPreferences.defaults);
      final target = File(
        '${supportDirectory.path}${Platform.pathSeparator}settings'
        '${Platform.pathSeparator}desktop-preferences.json',
      );
      await target.writeAsString('{not-json');

      expect(await store.load(), MarkdownPreviewPreferences.defaults);
    });
  });

  test('controller keeps the latest rapid update durable', () async {
    final store = _MemoryStore();
    final controller = MarkdownPreviewPreferencesController(store: store);
    addTearDown(controller.dispose);

    final paper = controller.value.copyWith(
      theme: MarkdownPreviewTheme.paper,
      profile: MarkdownPreviewProfile.paper,
    );
    final compact = controller.value.copyWith(
      theme: MarkdownPreviewTheme.focus,
      profile: MarkdownPreviewProfile.compact,
      textScale: 1.2,
    );

    await Future.wait<void>(<Future<void>>[
      controller.update(paper),
      controller.update(compact),
    ]);

    expect(controller.value, compact);
    expect(store.saved, <MarkdownPreviewPreferences>[paper, compact]);
    expect(store.value, compact);
  });
}

final class _MemoryStore implements MarkdownPreviewPreferencesStore {
  MarkdownPreviewPreferences value = MarkdownPreviewPreferences.defaults;
  final List<MarkdownPreviewPreferences> saved = <MarkdownPreviewPreferences>[];

  @override
  Future<MarkdownPreviewPreferences> load() async => value;

  @override
  Future<void> save(MarkdownPreviewPreferences preferences) async {
    saved.add(preferences);
    value = preferences;
  }
}
