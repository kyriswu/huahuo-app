import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_search_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  test(
    'asset filters use calendar days, real tags and complete candidates',
    () {
      final now = DateTime(2026, 8, 20, 1);
      final notes = [
        for (var index = 0; index < 45; index++)
          _note(
            'note-$index',
            '客户笔记 $index',
            updatedAt: now,
            tags: index == 44 ? ['客户研究'] : [],
          ),
        _note('yesterday', '昨天的笔记', updatedAt: DateTime(2026, 8, 19, 23)),
        _note('week-start', '六天前', updatedAt: DateTime(2026, 8, 14)),
        _note('before-week', '七天前', updatedAt: DateTime(2026, 8, 13, 23, 59)),
      ];
      List<V3FeedItem> apply(KnowledgeAssetSearchFilters filters) => filters
          .apply(notes, query: '', tagsFor: (note) => note.topics, now: now);
      expect(
        apply(KnowledgeAssetSearchFilters(tags: const ['客户研究'])).single.id,
        'note-44',
      );
      expect(
        apply(KnowledgeAssetSearchFilters(time: KnowledgeTimeFilter.today)),
        hasLength(45),
      );
      final week = apply(
        KnowledgeAssetSearchFilters(time: KnowledgeTimeFilter.last7Days),
      );
      expect(week.map((note) => note.id), contains('week-start'));
      expect(week.map((note) => note.id), isNot(contains('before-week')));
      expect(apply(KnowledgeAssetSearchFilters()), hasLength(48));
    },
  );

  test('asset filter groups intersect and selected tags use union', () {
    final notes = [
      _note(
        'recording',
        '访谈录音',
        source: V3MaterialSource.monologue,
        tags: ['客户研究'],
      ),
      _note('link', '访谈链接', source: V3MaterialSource.link, tags: ['产品']),
      _note('manual', '访谈手记', tags: ['其他']),
    ];
    final filters = KnowledgeAssetSearchFilters(tags: const ['客户研究', '产品']);
    expect(
      filters.apply(notes, query: '访谈', tagsFor: (note) => note.topics),
      hasLength(2),
    );
    expect(
      filters
          .copyWith(source: KnowledgeSourceCategory.recording)
          .apply(notes, query: '访谈', tagsFor: (note) => note.topics)
          .single
          .id,
      'recording',
    );
    expect(
      filters
          .copyWith(source: KnowledgeSourceCategory.manual)
          .apply(notes, query: '', tagsFor: (note) => note.topics),
      isEmpty,
    );
  });

  testWidgets('assets search expands inline and combines real filters', (
    tester,
  ) async {
    final library = await _pumpAssets(tester);
    expect(find.byKey(const ValueKey('asset-search-filters')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('my-assets-search')));
    await tester.pump();
    expect(find.byKey(const ValueKey('asset-search-filters')), findsOneWidget);
    expect(find.textContaining('搜索范围：全部资产'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asset-search-group-tags')));
    await tester.pump();
    expect(find.byKey(const ValueKey('asset-search-tag-客户研究')), findsOneWidget);
    expect(find.byKey(const ValueKey('asset-search-tag-知识管理')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('asset-search-tag-客户研究')));
    await tester.pump();
    expect(find.text('客户访谈录音'), findsOneWidget);
    expect(find.text('阅读链接'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.byKey(const ValueKey('asset-search-group-source')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('asset-search-source-recording')),
    );
    await tester.pump();
    expect(find.textContaining('1 条匹配'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('my-assets-search')),
      '客户',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asset-search-all')));
    await tester.pump();
    expect(library.depositQuery, '客户');
    expect(find.textContaining('2 条匹配'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asset-search-cancel')));
    await tester.pump();
    expect(library.depositQuery, isEmpty);
    expect(find.byKey(const ValueKey('asset-search-filters')), findsNothing);
    expect(find.byKey(const ValueKey('asset-create-note')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asset search clear and empty feedback work with a keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final library = await _pumpAssets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('my-assets-search')),
      '不存在的关键词',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 140);
    await tester.pump();
    expect(find.byKey(const ValueKey('asset-search-filters')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('asset-search-clear-query')));
    await tester.pump();
    expect(library.depositQuery, isEmpty);
    tester.view.resetViewInsets();
    await tester.pump();
    expect(find.textContaining('3 条匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy search entry opens assets instead of an extra filter page',
    (tester) async {
      await _pumpAssets(
        tester,
        home: const V3FeedSearchPage(initialQuery: '客户'),
      );
      await tester.pump();
      expect(find.byType(V3MyAssetsPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('asset-search-filters')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('feed-search-filter-sheet')),
        findsNothing,
      );
    },
  );
}

Future<KnowledgeLibraryController> _pumpAssets(
  WidgetTester tester, {
  Widget home = const V3MyAssetsPage(),
}) async {
  final library = KnowledgeLibraryController(
    includeDemoFixtures: false,
    initialNotes: [
      _note(
        'recording',
        '客户访谈录音',
        source: V3MaterialSource.monologue,
        tags: ['客户研究'],
      ),
      _note('manual', '客户需求手记', tags: ['产品']),
      _note('link', '阅读链接', source: V3MaterialSource.link, tags: ['阅读']),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
      ],
      child: MaterialApp(theme: HuahuoV3Theme.light(), home: home),
    ),
  );
  await tester.pump();
  return library;
}

V3FeedItem _note(
  String id,
  String title, {
  V3MaterialSource source = V3MaterialSource.note,
  List<String> tags = const [],
  DateTime? updatedAt,
}) => V3FeedItem(
  id: id,
  title: title,
  source: source,
  createdAt: updatedAt ?? DateTime.now(),
  updatedAt: updatedAt ?? DateTime.now(),
  rawBody: '原始正文：$title',
  folderName: '资料',
  topics: tags,
);
