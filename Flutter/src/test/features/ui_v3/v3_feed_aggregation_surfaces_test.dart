import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_aggregation_surfaces.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('selection header remains readable with doubled text', (
    tester,
  ) async {
    _setPhoneViewport(tester, size: const Size(320, 568));
    var actions = 0;
    await tester.pumpWidget(
      _sheetApp(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: V3FeedAggregationSelectionSheet(
            notes: _sources,
            onClose: () => actions++,
            onReshuffle: () => actions++,
            onStart: () => actions++,
          ),
        ),
      ),
    );
    final title = tester.renderObject<RenderParagraph>(find.text('本次聚合'));
    expect(
      title.size.height,
      greaterThanOrEqualTo(title.getMaxIntrinsicHeight(title.size.width)),
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.tap(find.byKey(const ValueKey('aggregation-sheet-reshuffle')));
    await tester.tap(find.byKey(const ValueKey('aggregation-sheet-start')));
    expect(actions, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M01 aggregation selection matches Mobile V5 and acts', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var closeCalls = 0;
    var reshuffleCalls = 0;
    var startCalls = 0;
    await tester.pumpWidget(
      _sheetApp(
        V3FeedAggregationSelectionSheet(
          notes: _sources,
          onClose: () => closeCalls += 1,
          onReshuffle: () => reshuffleCalls += 1,
          onStart: () => startCalls += 1,
        ),
      ),
    );

    await expectLater(
      find.byType(V3FeedAggregationSelectionSheet),
      matchesGoldenFile('goldens/feed_aggregation_selection.png'),
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.tap(find.byKey(const ValueKey('aggregation-sheet-reshuffle')));
    await tester.tap(find.byKey(const ValueKey('aggregation-sheet-start')));
    expect(closeCalls, 1);
    expect(reshuffleCalls, 1);
    expect(startCalls, 1);
  });

  testWidgets('aggregation selection grows at compact 1.3 text scale', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setPhoneViewport(tester, size: size);
    await tester.pumpWidget(
      _sheetApp(
        MediaQuery(
          data: const MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(1.3),
          ),
          child: V3FeedAggregationSelectionSheet(
            notes: _sources,
            onClose: () {},
            onReshuffle: () {},
            onStart: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    for (var index = 0; index < 4; index++) {
      expect(
        tester
            .getSize(find.byKey(ValueKey('aggregation-source-row-$index')))
            .height,
        greaterThanOrEqualTo(60),
      );
    }
    expect(
      find.byKey(const ValueKey('aggregation-sheet-start')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('M01 aggregation processing matches Mobile V5 and acts', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    var backCalls = 0;
    await tester.pumpWidget(
      _pageApp(
        V3FeedAggregationProgressSurface(
          sourceCount: 4,
          onBack: () => backCalls += 1,
        ),
      ),
    );

    await expectLater(
      find.byType(V3FeedAggregationProgressSurface),
      matchesGoldenFile('goldens/feed_aggregation_processing.png'),
    );
    await tester.tap(find.byTooltip('返回'));
    expect(backCalls, 1);
  });

  testWidgets('processing offers an explicit non-cancelling leave action', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    var leaveCalls = 0;
    await tester.pumpWidget(
      _pageApp(
        V3FeedAggregationProgressSurface(
          sourceCount: 4,
          onBack: () {},
          onLeave: () => leaveCalls += 1,
        ),
      ),
    );
    final leave = find.byKey(const ValueKey('aggregation-processing-leave'));
    expect(leave.hitTestable(), findsOneWidget);
    expect(find.text('先返回，稍后查看'), findsOneWidget);
    expect(find.textContaining('消息通知'), findsOneWidget);
    await tester.tap(leave);
    expect(leaveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M01 aggregation failure exposes retry and back', (tester) async {
    _setPhoneViewport(tester, safeTop: 54);
    var backCalls = 0;
    var retryCalls = 0;
    await tester.pumpWidget(
      _pageApp(
        V3FeedAggregationProgressSurface(
          sourceCount: 4,
          failed: true,
          onBack: () => backCalls += 1,
          onRetry: () => retryCalls += 1,
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('aggregation-processing-retry')),
    );
    await tester.tap(find.byTooltip('返回'));
    expect(retryCalls, 1);
    expect(backCalls, 1);
  });

  testWidgets('M01 aggregation result matches Mobile V5 and acts', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    var backCalls = 0;
    var saveCalls = 0;
    var reshuffleCalls = 0;
    await tester.pumpWidget(
      _pageApp(
        V3FeedAggregationResultSurface(
          sources: _sources,
          generatedNote: _result,
          onBack: () => backCalls += 1,
          onSave: () => saveCalls += 1,
          onReshuffle: () => reshuffleCalls += 1,
        ),
      ),
    );

    await expectLater(
      find.byType(V3FeedAggregationResultSurface),
      matchesGoldenFile('goldens/feed_aggregation_result.png'),
    );
    await tester.tap(find.byKey(const ValueKey('aggregation-result-save')));
    await tester.tap(
      find.byKey(const ValueKey('aggregation-result-reshuffle')),
    );
    await tester.tap(find.byKey(const ValueKey('aggregation-result-back')));
    expect(saveCalls, 1);
    expect(reshuffleCalls, 1);
    expect(backCalls, 1);
  });

  testWidgets(
    'uncertain aggregation supports recovery with compact large text',
    (tester) async {
      _setPhoneViewport(tester, size: const Size(320, 568));
      var retries = 0;
      await tester.pumpWidget(
        _pageApp(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(1.3),
            ),
            child: V3FeedAggregationProgressSurface(
              sourceCount: 4,
              onBack: () {},
              statusTitle: '聚合受理结果待确认',
              statusMessage: '尚未确认云端是否受理，请继续确认同一次请求，不会重复创建任务。返回图谱不会取消已被受理的任务。',
              retryLabel: '继续确认受理',
              referenceId: 'topic-collision-request-reference',
              onRetry: () => retries++,
            ),
          ),
        ),
      );
      expect(find.text('观点聚合失败'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('aggregation-processing-retry')),
      );
      await tester.tap(
        find.byKey(const ValueKey('aggregation-processing-retry')),
      );
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preparation does not invent selected sources or generated content',
    (tester) async {
      _setPhoneViewport(tester, size: const Size(320, 568));
      await tester.pumpWidget(
        _pageApp(
          V3FeedAggregationProgressSurface(
            sourceCount: 0,
            statusTitle: '正在核对云端笔记',
            showSkeleton: false,
            onBack: () {},
          ),
        ),
      );
      expect(find.textContaining('已选中'), findsNothing);
      expect(find.text('正在核对云端笔记'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact result supports doubled text without clipped actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      _setPhoneViewport(tester, size: const Size(320, 568));
      var opened = 0;
      var restarted = 0;
      await tester.pumpWidget(
        _pageApp(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(2),
            ),
            child: V3FeedAggregationResultSurface(
              sources: _sources,
              generatedNote: _result,
              headline: '聚合后的完整观点标题',
              onBack: () {},
              onSave: () => opened++,
              onReshuffle: () => restarted++,
            ),
          ),
        ),
      );
      final primary = find.byKey(const ValueKey('aggregation-result-save'));
      final secondary = find.byKey(
        const ValueKey('aggregation-result-reshuffle'),
      );
      expect(primary.hitTestable(), findsOneWidget);
      expect(secondary.hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(secondary).dy,
        greaterThan(tester.getBottomLeft(primary).dy),
      );
      await tester.tap(primary);
      await tester.tap(secondary);
      expect(opened, 1);
      expect(restarted, 1);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('aggregation states render in a chromatic dark theme', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    final theme = HuahuoV3Theme.dark(palette: HuahuoV3Palette.mistBlue);
    final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: V3FeedAggregationSelectionSheet(
            notes: _sources,
            onClose: () {},
            onReshuffle: () {},
            onStart: () {},
          ),
        ),
      ),
    );
    final start = tester.widget<FilledButton>(
      find.byKey(const ValueKey('aggregation-sheet-start')),
    );
    expect(
      start.style?.backgroundColor?.resolve(<WidgetState>{}),
      tokens.primary,
    );
    expect(
      start.style?.foregroundColor?.resolve(<WidgetState>{}),
      tokens.onPrimary,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: V3FeedAggregationProgressSurface(sourceCount: 4, onBack: () {}),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

final _sources = <V3FeedItem>[
  _source(1, '产品设计', '把零散灵感整理成可持续生长的知识网络'),
  _source(2, '账户体系', 'Apple Account 官方说明全解'),
  _source(3, 'Flutter', '构建可复用的玻璃状态控件'),
  _source(4, '笔记系统', 'AI 笔记中心的信息聚合与检索方案'),
];

final _result = V3FeedItem(
  id: 'aggregation-result',
  title: '稳定的知识系统，是让旧记录在新语境中重新发生关系',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 24),
  rawBody: '四篇笔记共同指向一个结论：真正可持续的个人知识管理，需要把可靠资料、可复用结构和持续聚合的主题路径，放进同一套反馈循环。',
);

V3FeedItem _source(int index, String topic, String title) => V3FeedItem(
  id: 'aggregation-source-$index',
  title: title,
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 20 + index),
  rawBody: '本地视觉验收素材',
  topics: <String>[topic],
);

Widget _sheetApp(Widget sheet) => MaterialApp(
  theme: figmaGoldenTheme(),
  home: Scaffold(
    backgroundColor: const Color(0xffd2d2d2),
    body: Align(alignment: Alignment.bottomCenter, child: sheet),
  ),
);

Widget _pageApp(Widget page) => MaterialApp(
  theme: figmaGoldenTheme(),
  home: Scaffold(body: SafeArea(bottom: false, child: page)),
);

void _setPhoneViewport(
  WidgetTester tester, {
  Size size = const Size(402, 874),
  double safeTop = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = FakeViewPadding(top: safeTop);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}
