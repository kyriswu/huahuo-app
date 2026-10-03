import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_note_filter_sheet.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  test('source filtering ignores folders, ownership and creation origin', () {
    const cases = <V3FeedNoteSourceFilter, Set<V3MaterialSource>>{
      V3FeedNoteSourceFilter.manual: {V3MaterialSource.note},
      V3FeedNoteSourceFilter.chatExcerpt: {V3MaterialSource.chatExcerpt},
      V3FeedNoteSourceFilter.noteImport: {V3MaterialSource.documentImport},
      V3FeedNoteSourceFilter.transcription: {
        V3MaterialSource.meeting,
        V3MaterialSource.internalRecording,
        V3MaterialSource.monologue,
        V3MaterialSource.recordingCard,
        V3MaterialSource.mediaImport,
      },
      V3FeedNoteSourceFilter.history: {V3MaterialSource.materialMigration},
      V3FeedNoteSourceFilter.externalKnowledge: {
        V3MaterialSource.knowledgeSquare,
      },
      V3FeedNoteSourceFilter.subscriptionRewrite: {
        V3MaterialSource.subscription,
      },
    };
    for (final entry in cases.entries) {
      final selection = V3FeedNoteFilterSelection(sources: {entry.key});
      for (final source in V3MaterialSource.values) {
        final note = _note(source);
        for (final candidate in [
          note,
          note.copyWith(
            folderId: 'history-folder',
            folderName: '历史资料',
            ownership: V3NoteOwnership.knowledgeSquare,
            contentOrigin: V3ContentOrigin.freeCreation,
          ),
        ]) {
          expect(
            selection.includes(candidate),
            entry.value.contains(source),
            reason: '${entry.key.name}: ${source.name}',
          );
        }
      }
    }
  });

  test(
    'empty source selection includes all notes and multiple sources use OR',
    () {
      const empty = V3FeedNoteFilterSelection();
      for (final source in V3MaterialSource.values) {
        expect(empty.includes(_note(source)), isTrue);
      }
      final selected = empty
          .toggleSource(V3FeedNoteSourceFilter.chatExcerpt)
          .toggleSource(V3FeedNoteSourceFilter.history);
      expect(empty.isEmpty, isTrue);
      expect(selected.activeCount, 2);
      expect(selected.includes(_note(V3MaterialSource.chatExcerpt)), isTrue);
      expect(
        selected.includes(_note(V3MaterialSource.materialMigration)),
        isTrue,
      );
      expect(selected.includes(_note(V3MaterialSource.note)), isFalse);
      expect(
        selected
            .toggleSource(V3FeedNoteSourceFilter.chatExcerpt)
            .toggleSource(V3FeedNoteSourceFilter.history)
            .isEmpty,
        isTrue,
      );
    },
  );

  testWidgets('default source-only note filter hugs its content', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var closeCalls = 0;
    V3FeedNoteFilterSelection? applied;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: Scaffold(
          backgroundColor: const Color(0xffe2e2e2),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: V3FeedNoteFilterSheet(
              initialSelection: const V3FeedNoteFilterSelection(),
              matchingCount: (_) => 12,
              onClose: () => closeCalls += 1,
              onApply: (selection) => applied = selection,
            ),
          ),
        ),
      ),
    );

    expect(find.text('文件夹'), findsNothing);
    expect(find.text('创作空间'), findsNothing);
    expect(find.text('纪要文件'), findsNothing);
    expect(find.text('按来源缩小笔记范围'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('feed-note-filter-sheet')))
          .height,
      lessThan(530),
    );
    await expectLater(
      find.byType(V3FeedNoteFilterSheet),
      matchesGoldenFile('goldens/feed_note_filter_default.png'),
    );
    await tester.tap(find.byKey(const ValueKey('feed-note-filter-close')));
    await tester.tap(find.byKey(const ValueKey('feed-note-filter-apply')));
    expect(closeCalls, 1);
    expect(applied?.isEmpty, isTrue);
  });

  testWidgets('selected source-only note filter supports toggling and reset', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    V3FeedNoteFilterSelection? applied;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: Scaffold(
          backgroundColor: const Color(0xffe2e2e2),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: V3FeedNoteFilterSheet(
              initialSelection: const V3FeedNoteFilterSelection(
                sources: {
                  V3FeedNoteSourceFilter.transcription,
                  V3FeedNoteSourceFilter.externalKnowledge,
                },
              ),
              matchingCount: (_) => 5,
              onClose: () {},
              onApply: (selection) => applied = selection,
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(V3FeedNoteFilterSheet),
      matchesGoldenFile('goldens/feed_note_filter_selected.png'),
    );
    expect(find.text('已选择 2 项'), findsOneWidget);
    expect(find.text('查看 5 条笔记'), findsOneWidget);
    await tester.tap(find.text('录音转写'));
    await tester.pump();
    expect(find.text('已选择 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feed-note-filter-reset')));
    await tester.pump();
    expect(find.text('未选择筛选条件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feed-note-filter-apply')));
    expect(applied?.isEmpty, isTrue);
  });

  for (final viewport in [
    (name: 'compact', size: const Size(320, 568), textScale: 1.3),
    (name: 'large text', size: const Size(320, 568), textScale: 2.0),
    (name: 'landscape', size: const Size(568, 320), textScale: 1.3),
  ]) {
    testWidgets('source filter route adapts to ${viewport.name}', (
      tester,
    ) async {
      _setPhoneViewport(tester, size: viewport.size);
      V3FeedNoteFilterSelection? applied;
      await tester.pumpWidget(
        MaterialApp(
          theme: figmaGoldenTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(viewport.textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  applied =
                      await showModalBottomSheet<V3FeedNoteFilterSelection>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (sheetContext) => V3FeedNoteFilterSheet(
                          initialSelection: const V3FeedNoteFilterSelection(),
                          matchingCount: (_) => 7,
                          onClose: () => Navigator.of(sheetContext).pop(),
                          onApply: (selection) =>
                              Navigator.of(sheetContext).pop(selection),
                        ),
                      );
                },
                child: const Text('打开筛选'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开筛选'));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSize(find.byKey(const ValueKey('feed-note-filter-sheet')))
            .height,
        lessThanOrEqualTo(viewport.size.height),
      );
      expect(
        find.byKey(const ValueKey('feed-note-filter-apply')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      expect(
        find.byKey(const ValueKey('feed-note-filter-close')).hitTestable(),
        findsOneWidget,
      );
      for (final label in [
        '手动创建',
        '聊天摘录',
        '笔记导入',
        '录音转写',
        '历史资料',
        '外部知识',
        '订阅修订',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('feed-note-filter-apply')));
      await tester.pumpAndSettle();
      expect(applied?.activeCount, 7);
      expect(find.byType(V3FeedNoteFilterSheet), findsNothing);
      await tester.tap(find.text('打开筛选'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('聊天摘录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('聊天摘录'));
      await tester.pump();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('feed-note-filter-close')));
      await tester.pumpAndSettle();
      expect(applied, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('filter controls follow every palette and brightness', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    for (final palette in HuahuoV3Palette.values) {
      for (final brightness in Brightness.values) {
        final theme = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: brightness,
        );
        final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: V3FeedNoteFilterSheet(
                  initialSelection: const V3FeedNoteFilterSelection(
                    sources: {V3FeedNoteSourceFilter.chatExcerpt},
                  ),
                  matchingCount: (_) => 5,
                  onClose: () {},
                  onApply: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final apply = tester.widget<FilledButton>(
          find.byKey(const ValueKey('feed-note-filter-apply')),
        );
        expect(
          apply.style?.backgroundColor?.resolve(<WidgetState>{}),
          tokens.primary,
        );
        expect(
          apply.style?.foregroundColor?.resolve(<WidgetState>{}),
          tokens.onPrimary,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}

V3FeedItem _note(V3MaterialSource source) => V3FeedItem(
  id: source.name,
  title: source.label,
  source: source,
  createdAt: DateTime.utc(2026, 9, 8),
  rawBody: '来源筛选测试',
);

void _setPhoneViewport(
  WidgetTester tester, {
  Size size = const Size(402, 874),
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(bottom: 34);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}
