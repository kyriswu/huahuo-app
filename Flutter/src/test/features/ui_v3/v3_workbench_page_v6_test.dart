import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart'
    show dailyTopicControllerProvider, resolvedDeviceIdProvider;
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/daily_topic_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/ui_v3_mock_data.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

String _maximumLengthKuaishouSourceUrl() {
  const prefix =
      'https://www.kuaishou.com/short-video/3x4testvideo?shareToken=';
  const suffix = '#comment';
  return '$prefix${List<String>.filled(4096 - prefix.length - suffix.length, 'x').join()}$suffix';
}

void main() {
  test('only persona and lead are valid workbench purposes', () {
    expect(workbenchPurposeFromRoute('persona'), WorkbenchPurpose.persona);
    expect(workbenchPurposeFromRoute('lead'), WorkbenchPurpose.lead);
    expect(workbenchPurposeFromRoute('exposure'), isNull);
    expect(workbenchPurposeFromRoute('unknown'), isNull);
  });

  test('asset analysis uses the unified Huahuo framework prompt', () {
    const expected = '基于我上传的资产，按照huahuo的分析框架帮我分析';
    expect(WorkbenchPurpose.persona.assetAnalysisPrompt, expected);
    expect(WorkbenchPurpose.lead.assetAnalysisPrompt, expected);
  });

  test('daily topic canvas seed accepts a title and brief without sources', () {
    final seed = DailyTopicCanvasSeed(
      recommendationId: 'daily-recommendation-1',
      topicId: 'daily-topic-1',
      title: '没有来源引用的选题',
      briefMarkdown: '仍应作为可编辑素材带入画布。',
      sourceRefs: const <DailyTopicCanvasSourceRef>[],
    );

    expect(seed.isValid, isTrue);
    expect(seed.editableMarkdown, '仍应作为可编辑素材带入画布。');
  });

  testWidgets('surface exposes one topic feed, free creation and four tools', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = KnowledgeLibraryController(initialNotes: v3KnowledgeNotes);
    final dailyTopics = await _readyDailyTopics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
          feedAiChatControllerProvider.overrideWith(
            (ref) => ChatController(
              api: _WorkbenchChatApi(),
              scene: ChatScene.feedAi,
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: V3WorkbenchHomeSurface(bottomContentInset: 16)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('今日推送'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
    expect(find.byTooltip('刷新今日推送'), findsNothing);
    expect(find.text('8月14日素材'), findsOneWidget);
    expect(find.text('今天'), findsNothing);
    expect(library.notes.where((note) => note.isHotspot), isEmpty);
    expect(find.text('碰撞'), findsNothing);
    expect(find.text('大师升级'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('workbench-feed-pages')),
      findsNothing,
    );
    final freeCreation = find.byKey(
      const ValueKey<String>('workbench-free-creation'),
    );
    expect(tester.getSize(freeCreation).width, 349);
    expect(tester.getSize(freeCreation).height, 80);
    final freeCreationIcon = tester.widget<Icon>(
      find.descendant(of: freeCreation, matching: find.byType(Icon)).first,
    );
    final freeCreationLabel = tester.widget<Text>(
      find.descendant(of: freeCreation, matching: find.text('开始自由创作')),
    );
    expect(freeCreationIcon.size, 26);
    expect(freeCreationIcon.icon, LucideIcons.filePlus2);
    expect(freeCreationIcon.icon, isNot(LucideIcons.penLine));
    expect(freeCreationLabel.style?.fontSize, 22);
    expect(freeCreationLabel.style?.fontWeight, FontWeight.w500);
    expect(find.text('今天想创作什么？'), findsOneWidget);
    expect(find.text('把零散灵感，整理成可以表达的内容。'), findsOneWidget);
    for (final label in const ['个人 IP', '获客营销', '视觉设计', '视频分析']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey<String>('workbench-inline-tools')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('workbench-topic-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('workbench-quick-action-row')),
      findsNothing,
    );
    for (final id in const ['persona', 'lead', 'influence', 'video']) {
      expect(
        find.byKey(ValueKey<String>('workbench-inline-tool-$id')),
        findsOneWidget,
      );
    }
    for (final entry in const <String, String>{
      'persona': 'assets/images/workbench_personal_ip.png',
      'lead': 'assets/images/workbench_lead_marketing.png',
      'influence': 'assets/images/workbench_visual_design.png',
      'video': 'assets/images/workbench_video_analysis.png',
    }.entries) {
      _expectToolAsset(tester, id: entry.key, assetPath: entry.value);
    }
    final topicList = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    final topicCard = find.byKey(
      const ValueKey<String>('workbench-today-topic-daily-topic-1'),
    );
    expect(topicCard, findsOneWidget);
    expect(tester.getSize(topicCard).height, 100);
    await tester.drag(topicList, const Offset(0, -180));
    await tester.pump();
    expect(find.text('今日推送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily topic card grows for enlarged two-line copy', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dailyTopics = await _readyDailyTopics(
      topicTitle: '捷克开始拒绝乌克兰难民临时保护：欧洲难民政策的裂缝从哪里开始',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.1)),
            child: child!,
          ),
          home: const Scaffold(
            body: V3WorkbenchHomeSurface(bottomContentInset: 16),
          ),
        ),
      ),
    );
    await tester.pump();

    final topicCard = find.byKey(
      const ValueKey<String>('workbench-today-topic-daily-topic-1'),
    );
    expect(topicCard, findsOneWidget);
    expect(tester.getSize(topicCard).height, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successful empty recommendation explains the backend reason and links positioning',
    (tester) async {
      tester.view
        ..physicalSize = const Size(393, 852)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dailyTopics = await _readyDailyTopics(
        empty: true,
        summaryMarkdown: _emptyRecommendationReason,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(
              body: V3WorkbenchHomeSurface(bottomContentInset: 16),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.positioningReport,
            builder: (context, state) => const Scaffold(body: Text('定位资料页')),
          ),
          GoRoute(
            path: '/v3/workbench/recommendations/:recommendationId',
            builder: (context, state) => V3WorkbenchRecommendationPage(
              recommendationId: state.pathParameters['recommendationId'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本期没有生成选题'), findsOneWidget);
      expect(find.text('8月14日素材'), findsOneWidget);
      expect(find.text('今天暂无可用选题'), findsNothing);
      final homeReason = tester.widget<V3AssistantReplyMarkdown>(
        find.byKey(const ValueKey('workbench-empty-recommendation-reason')),
      );
      expect(homeReason.source, _emptyRecommendationReason);

      await tester.tap(
        find.byKey(
          const ValueKey('workbench-empty-recommendation-positioning'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('定位资料页'), findsOneWidget);

      router.go('/v3/workbench/recommendations/daily-recommendation-1');
      await tester.pumpAndSettle();
      expect(find.text('本期没有生成选题'), findsOneWidget);
      final detailReason = tester.widget<V3AssistantReplyMarkdown>(
        find.byKey(const ValueKey('workbench-empty-recommendation-reason')),
      );
      expect(detailReason.source, _emptyRecommendationReason);
      expect(
        find.byKey(const ValueKey('workbench-topic-creation-guide')),
        findsNothing,
      );
      expect(find.text('基于这个选题，继续往下创作'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('four fixed tools keep 44dp targets at compact width', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(280, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = KnowledgeLibraryController(initialNotes: v3KnowledgeNotes);
    final dailyTopics = await _readyDailyTopics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
        ],
        child: const MaterialApp(
          home: Scaffold(body: V3WorkbenchHomeSurface(bottomContentInset: 16)),
        ),
      ),
    );
    await tester.pump();

    final tools = <Finder>[
      for (final id in const ['persona', 'lead', 'influence', 'video'])
        find.byKey(ValueKey<String>('workbench-inline-tool-$id')),
    ];
    for (final tool in tools) {
      expect(tester.getSize(tool).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(tool).height, greaterThanOrEqualTo(44));
    }
    final freeCreation = find.byKey(
      const ValueKey<String>('workbench-free-creation'),
    );
    expect(tester.getSize(freeCreation), const Size(236, 80));
    final rowTops = tools
        .map((tool) => tester.getTopLeft(tool).dy.round())
        .toSet();
    expect(rowTops, hasLength(1));

    await tester.drag(
      find.byKey(const PageStorageKey<String>('workbench-home-scroll')),
      const Offset(0, -180),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('free creation and every recommendation preserve back history', (
    tester,
  ) async {
    const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final launchedUrls = <String>[];
    final launchArguments = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncherChannel,
      (call) async {
        if (call.method != 'launch') return false;
        final arguments = call.arguments as Map<Object?, Object?>;
        launchedUrls.add(arguments['url']! as String);
        launchArguments.add(arguments);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        urlLauncherChannel,
        null,
      ),
    );
    final notePort = _WorkbenchKnowledgeNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        ...v3KnowledgeNotes,
        V3FeedItem(
          id: 'daily-hotspot-1',
          title: '今日热点来源',
          source: V3MaterialSource.hotspot,
          ownership: V3NoteOwnership.hotspot,
          createdAt: DateTime.utc(2026, 8, 14),
          rawBody: '已同步的推荐来源正文。',
        ),
        V3FeedItem(
          id: 'local-workspace-note-1',
          title: '我的工作区笔记',
          source: V3MaterialSource.note,
          ownership: V3NoteOwnership.mine,
          createdAt: DateTime.utc(2026, 8, 13),
          rawBody: '工作区笔记的真实资产正文。',
          remoteNoteId: 'workspace-note-1',
          syncState: NoteSyncState.synced,
        ),
      ],
      notePort: notePort,
    );
    final dailyTopics = await _readyDailyTopics();
    final maximumLengthKuaishouUrl = _maximumLengthKuaishouSourceUrl();
    expect(maximumLengthKuaishouUrl.length, 4096);
    final hotspotSource =
        dailyTopics.state.recommendation!.topics.single.sourceRefs.first
            as DailyTopicHotspotSourceRef;
    expect(
      hotspotSource.sourceUrl,
      'https://weibo.com/6506823885/RgWMA2J03?from=topic#share',
    );
    Uri? latestChatUri;
    CanvasEntryIntent? latestCanvasIntent;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: V3WorkbenchHomeSurface(bottomContentInset: 16),
          ),
        ),
        GoRoute(
          path: '/v3/workbench/canvas',
          builder: (context, state) {
            final extra = state.extra;
            latestCanvasIntent = extra is CanvasEntryIntent ? extra : null;
            final dailyTopicSeed = switch (extra) {
              CanvasDailyTopicEntryIntent intent => intent.seed,
              DailyTopicCanvasSeed seed => seed,
              _ => null,
            };
            final sourceRef =
                dailyTopicSeed == null || dailyTopicSeed.sourceRefs.isEmpty
                ? null
                : dailyTopicSeed.sourceRefs.first;
            return Scaffold(
              body: Column(
                children: [
                  Text(
                    'canvas|${state.uri.queryParameters['topicId'] ?? '-'}|'
                    '${state.uri.queryParameters['topicTitle'] ?? '-'}',
                  ),
                  if (dailyTopicSeed != null)
                    Text(
                      'canvas-seed|${dailyTopicSeed.recommendationId}|'
                      '${dailyTopicSeed.topicId}|${dailyTopicSeed.title}|'
                      '${dailyTopicSeed.briefMarkdown}|'
                      '${sourceRef?.displayLabel ?? '-'}|'
                      '${sourceRef?.hotspotId ?? '-'}',
                    ),
                ],
              ),
            );
          },
        ),
        GoRoute(
          path: '/v3/workbench/recommendations/:recommendationId',
          builder: (context, state) => V3WorkbenchRecommendationPage(
            recommendationId: state.pathParameters['recommendationId'] ?? '',
            initialTopicId: state.uri.queryParameters['topicId'],
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:itemId',
          builder: (context, state) => Scaffold(
            body: Text('source-note|${state.pathParameters['itemId']}'),
          ),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            latestChatUri = state.uri;
            return Scaffold(
              body: Text(
                'chat|${state.uri.queryParameters['threadId'] ?? '-'}|'
                '${state.uri.queryParameters['window'] ?? '-'}|'
                '${state.uri.queryParameters['itemId'] ?? '-'}|'
                '${state.uri.queryParameters['dailyTopicTitle'] ?? '-'}|'
                '${state.uri.queryParameters['agentProfileId'] ?? '-'}|'
                '${state.uri.queryParameters['materialIds'] ?? '-'}',
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
          resolvedDeviceIdProvider.overrideWithValue('workbench-v6-device'),
          feedAiChatControllerProvider.overrideWith(
            (ref) => ChatController(
              api: _WorkbenchChatApi(),
              scene: ChatScene.feedAi,
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('workbench-free-creation')),
    );
    await tester.pumpAndSettle();
    expect(find.text('canvas|-|-'), findsOneWidget);
    expect(latestCanvasIntent, isA<CanvasBlankEntryIntent>());
    expect(latestCanvasIntent!.requiresInitialDraftGeneration, isFalse);

    router.pop();
    await tester.pumpAndSettle();
    final row = find.byKey(
      const ValueKey<String>('workbench-today-topic-daily-topic-1'),
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsOneWidget);
    router.go(
      '/v3/workbench/recommendations/daily-recommendation-1'
      '?topicId=daily-topic-1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/v3/workbench/recommendations/daily-recommendation-1',
    );
    final detailScroll = find.byKey(
      const PageStorageKey<String>('v3-page-scroll-选题推荐'),
    );
    expect(tester.getSize(detailScroll).height, greaterThan(0));
    final detailScrollable = find.descendant(
      of: detailScroll,
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(detailScrollable).position.pixels, 0);
    final detailText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList(growable: false);
    expect(detailText, contains('公开每日选题'));
    expect(detailText, contains('选题推荐'));
    expect(detailText, contains('内容来源'));
    expect(detailText, isNot(contains('笔记原文来源')));
    expect(detailText, contains('微博原文'));
    expect(detailText, contains('快手原文'));
    expect(detailText, isNot(contains('来源：不脱妆气垫快手视频')));
    expect(detailText, isNot(contains('微博热门视频')));
    expect(detailText, contains('我的工作区笔记'));
    expect(detailText, contains('未同步工作区笔记'));
    expect(detailText, contains('weibo.com'));
    expect(detailText, contains('打开我的资产中的原始笔记'));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '查看热点原文 微博原文',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '查看来源笔记 我的工作区笔记',
      ),
      findsOneWidget,
    );
    expect(detailText, contains('8月15日推荐 · 8月14日素材'));
    expect(
      find.byKey(const ValueKey('workbench-recommendation-summary')),
      findsNothing,
    );
    final topicContent = find.byKey(
      const ValueKey('workbench-recommendation-topic-content'),
    );
    await tester.scrollUntilVisible(
      topicContent,
      240,
      scrollable: detailScrollable,
    );
    final body = tester.widget<V3AssistantReplyMarkdown>(topicContent);
    expect(body.source, contains(_workbenchTopicBrief));
    expect(body.source, contains('## 这条选题能讲什么'));
    expect(body.source, contains(_workbenchTopicPromise));
    expect(body.source, contains('## 为什么值得写'));
    expect(body.source, contains(_workbenchTopicReason));
    expect(body.source, contains('## 写作提纲'));
    expect(body.source, contains(_workbenchTopicSketch));
    expect(find.text('使用此选题'), findsNothing);
    expect(find.byTooltip('忽略今日推送'), findsNothing);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);

    final weiboSource = find.byKey(
      const ValueKey(
        'workbench-recommendation-source-daily_hotspot-daily-hotspot-1',
      ),
    );
    await tester.scrollUntilVisible(
      weiboSource,
      -240,
      scrollable: detailScrollable,
    );
    await tester.tap(weiboSource);
    await tester.pumpAndSettle();
    expect(launchedUrls, const <String>[
      'https://weibo.com/6506823885/RgWMA2J03?from=topic#share',
    ]);
    expect(launchArguments.single['useSafariVC'], isFalse);
    expect(launchArguments.single['useWebView'], isFalse);
    expect(launchArguments.single['universalLinksOnly'], isFalse);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/v3/workbench/recommendations/daily-recommendation-1',
    );
    expect(find.text('source-note|daily-hotspot-1'), findsNothing);

    final kuaishouSource = find.byKey(
      const ValueKey(
        'workbench-recommendation-source-daily_hotspot-daily-hotspot-kuaishou',
      ),
    );
    await tester.ensureVisible(kuaishouSource);
    await tester.tap(kuaishouSource);
    await tester.pumpAndSettle();
    expect(launchedUrls, <String>[
      'https://weibo.com/6506823885/RgWMA2J03?from=topic#share',
      maximumLengthKuaishouUrl,
    ]);
    expect(
      launchArguments.every(
        (arguments) =>
            arguments['useSafariVC'] == false &&
            arguments['useWebView'] == false &&
            arguments['universalLinksOnly'] == false,
      ),
      isTrue,
    );

    await tester.tap(
      find.byKey(
        const ValueKey(
          'workbench-recommendation-source-workspace_note-workspace-note-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('source-note|local-workspace-note-1'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey(
          'workbench-recommendation-source-workspace_note-workspace-note-missing',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(notePort.loadCalls, 1);
    expect(find.text('该来源笔记尚未同步到我的资产'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(
        find.byKey(const ValueKey('workbench-recommendation-topic-content')),
      ),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey(
          'workbench-recommendation-source-daily_hotspot-daily-hotspot-missing',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('该热点原文链接不可用'), findsOneWidget);

    expect(
      find.byKey(const ValueKey('workbench-topic-creation-guide')),
      findsNothing,
    );
    expect(find.text('基于这个选题，继续往下创作'), findsNothing);
    expect(find.text('可生成逐字稿、图文脚本，或延展成更多内容。'), findsNothing);
    expect(
      find.byKey(const ValueKey('workbench-topic-guide-close')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('workbench-topic-guide-never')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
    await tester.pumpAndSettle();
    expect(find.text('选择 Agent'), findsNothing);
    expect(find.text('聊一聊'), findsWidgets);
    expect(find.text('猜你想问'), findsOneWidget);
    final deposited = library.notes.singleWhere(
      (note) =>
          note.ownership == V3NoteOwnership.mine && note.title == '公开每日选题',
    );
    expect(deposited.rawBody, contains(_workbenchTopicBrief));
    expect(deposited.rawBody, contains(_workbenchTopicPromise));
    expect(deposited.rawBody, contains(_workbenchTopicReason));
    expect(deposited.rawBody, contains(_workbenchTopicSketch));
    expect(deposited.rawBody, contains('daily-hotspot-1'));
    expect(deposited.syncState, NoteSyncState.synced);
    expect(deposited.remoteNoteId, isNotNull);
    expect(deposited.rawPartRevisionId, isNotNull);
    expect(notePort.requests, hasLength(1));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择 Agent'), findsOneWidget);
    expect(find.text('视觉设计 Agent'), findsNothing);
    expect(find.text('个人 IP 设计 Agent'), findsOneWidget);
    await tester.tap(find.text('个人 IP 设计 Agent'));
    await tester.pumpAndSettle();
    expect(find.text('选择创作方式'), findsNothing);
    expect(find.text('直接生成'), findsNothing);
    expect(latestChatUri?.queryParameters['entry'], 'agent-assisted-creation');
    expect(latestChatUri?.queryParameters['skill'], 'persona');
    expect(latestChatUri?.queryParameters['materialIds'], deposited.id);
    expect(latestChatUri?.queryParameters['analyzeAssets'], isNull);
    expect(latestChatUri?.queryParameters['autoSend'], '1');
    expect(
      latestChatUri?.queryParameters['prompt'],
      '现在开始做选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
    );
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
    );
    await tester.pumpAndSettle();
    expect(find.text('视觉设计 Agent'), findsNothing);
    await tester.tap(find.text('获客营销选题 Agent'));
    await tester.pumpAndSettle();
    expect(latestChatUri?.queryParameters['skill'], 'lead');
    expect(latestChatUri?.queryParameters['materialIds'], deposited.id);
    expect(latestChatUri?.queryParameters['analyzeAssets'], isNull);
    expect(latestChatUri?.queryParameters['autoSend'], '1');
    expect(
      latestChatUri?.queryParameters['prompt'],
      '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
    );
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
    );
    await tester.pumpAndSettle();
    expect(find.text('canvas|-|-'), findsOneWidget);
    expect(
      find.textContaining(
        'canvas-seed|daily-recommendation-1|daily-topic-1|公开每日选题|',
      ),
      findsOneWidget,
    );
    expect(latestCanvasIntent, isA<CanvasDailyTopicEntryIntent>());
    final canvasSeed =
        (latestCanvasIntent! as CanvasDailyTopicEntryIntent).seed;
    expect(canvasSeed.briefMarkdown, contains(_workbenchTopicBrief));
    expect(canvasSeed.briefMarkdown, contains(_workbenchTopicPromise));
    expect(canvasSeed.briefMarkdown, contains(_workbenchTopicReason));
    expect(canvasSeed.briefMarkdown, contains(_workbenchTopicSketch));
    expect(latestCanvasIntent!.requiresInitialDraftGeneration, isTrue);
    expect(notePort.requests, hasLength(1));
    expect(library.notes.where((note) => note.title == '公开每日选题'), hasLength(1));

    router.pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workbench-recommendation-topic-content')),
      findsOneWidget,
    );
    router.go('/');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('workbench-topic-section')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('workbench-inline-tool-persona')),
    );
    await tester.pumpAndSettle();
    expect(find.text('chat|-|-|-|-|renshe_content|-'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('workbench-inline-tool-lead')),
    );
    await tester.pumpAndSettle();
    expect(find.text('chat|-|-|-|-|huoke_content|-'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('workbench-inline-tool-influence')),
    );
    await tester.pumpAndSettle();
    expect(latestChatUri?.queryParameters['skill'], 'visual-design');
  });

  testWidgets('daily recommendation uses the shared Agent-assisted route', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notePort = _WorkbenchKnowledgeNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: v3KnowledgeNotes,
      notePort: notePort,
    );
    final dailyTopics = await _readyDailyTopics();
    Uri? chatUri;
    final router = GoRouter(
      initialLocation:
          '/v3/workbench/recommendations/daily-recommendation-1'
          '?topicId=daily-topic-1',
      routes: [
        GoRoute(
          path: '/v3/workbench/recommendations/:recommendationId',
          builder: (context, state) => V3WorkbenchRecommendationPage(
            recommendationId: state.pathParameters['recommendationId'] ?? '',
            initialTopicId: state.uri.queryParameters['topicId'],
          ),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            chatUri = state.uri;
            return const Scaffold(body: Text('Agent chat'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
          resolvedDeviceIdProvider.overrideWithValue('workbench-v6-device'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('获客营销选题 Agent'));
    await tester.pumpAndSettle();
    expect(find.text('选择创作方式'), findsNothing);
    expect(find.text('直接生成'), findsNothing);

    final deposited = library.notes.singleWhere(
      (note) =>
          note.ownership == V3NoteOwnership.mine && note.title == '公开每日选题',
    );
    expect(notePort.requests, hasLength(1));
    expect(chatUri?.queryParameters['entry'], 'agent-assisted-creation');
    expect(chatUri?.queryParameters['skill'], 'lead');
    expect(chatUri?.queryParameters['materialIds'], deposited.id);
    expect(chatUri?.queryParameters['autoSend'], '1');
    expect(
      chatUri?.queryParameters['prompt'],
      '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
    );
  });

  testWidgets(
    'historical detail survives a newer recommendation refresh before source navigation',
    (tester) async {
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'local-workspace-note-1',
            title: '我的工作区笔记',
            source: V3MaterialSource.note,
            ownership: V3NoteOwnership.mine,
            createdAt: DateTime.utc(2026, 9, 4),
            rawBody: '历史推荐引用的工作区笔记。',
            remoteNoteId: 'workspace-note-1',
            syncState: NoteSyncState.synced,
          ),
        ],
      );
      final dailyTopics = DailyTopicController(
        port: const _HistoricalWorkbenchDailyTopicPort(),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'workbench-historical-test-user',
        workspaceId: () => 'workbench-test-workspace',
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
      );
      await dailyTopics.initialize();
      final router = GoRouter(
        initialLocation:
            '/v3/workbench/recommendations/historical-recommendation'
            '?topicId=daily-topic-1',
        routes: [
          GoRoute(
            path: '/v3/workbench/recommendations/:recommendationId',
            builder: (context, state) => V3WorkbenchRecommendationPage(
              recommendationId: state.pathParameters['recommendationId'] ?? '',
              initialTopicId: state.uri.queryParameters['topicId'],
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (context, state) => Scaffold(
              body: Text('source-note|${state.pathParameters['itemId']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.text('历史非空推荐'), findsOneWidget);
      await dailyTopics.load(force: true);
      await tester.pumpAndSettle();
      expect(
        dailyTopics.state.recommendation?.recommendationId,
        'newer-recommendation',
      );
      expect(find.text('历史非空推荐'), findsOneWidget);
      expect(find.text('较新的空推荐'), findsNothing);

      await tester.tap(
        find.byKey(
          const ValueKey(
            'workbench-recommendation-source-workspace_note-workspace-note-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('source-note|local-workspace-note-1'), findsOneWidget);
    },
  );
}

final class _WorkbenchChatApi extends Fake implements ChatRepository {}

Future<DailyTopicController> _readyDailyTopics({
  String topicTitle = '公开每日选题',
  bool empty = false,
  String summaryMarkdown = '# 每日推荐摘要',
}) async {
  final controller = DailyTopicController(
    port: _WorkbenchDailyTopicPort(
      topicTitle: topicTitle,
      empty: empty,
      summaryMarkdown: summaryMarkdown,
    ),
    preferences: AppPreferencesDao(AppDatabase()),
    userScope: 'workbench-test-user',
    workspaceId: () => 'workbench-test-workspace',
    workspaceReady: () => true,
    cacheTtl: () => const Duration(minutes: 5),
  );
  await controller.initialize();
  return controller;
}

final class _WorkbenchDailyTopicPort implements DailyTopicPort {
  const _WorkbenchDailyTopicPort({
    this.topicTitle = '公开每日选题',
    this.empty = false,
    this.summaryMarkdown = '# 每日推荐摘要',
  });

  final String topicTitle;
  final bool empty;
  final String summaryMarkdown;

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async => _workbenchSuccess(
    DailyTopicRecommendationPage(
      items: <DailyTopicRecommendation>[
        _workbenchRecommendation(
          workspaceId,
          topicTitle: topicTitle,
          empty: empty,
          summaryMarkdown: summaryMarkdown,
        ),
      ],
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) async => _workbenchSuccess(
    _workbenchRecommendation(
      workspaceId,
      topicTitle: topicTitle,
      empty: empty,
      summaryMarkdown: summaryMarkdown,
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _workbenchSuccess(
    _workbenchRecommendation(
      workspaceId,
      read: true,
      topicTitle: topicTitle,
      empty: empty,
      summaryMarkdown: summaryMarkdown,
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _workbenchSuccess(
    _workbenchRecommendation(
      workspaceId,
      topicTitle: topicTitle,
      empty: empty,
      summaryMarkdown: summaryMarkdown,
    ),
  );

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => throw StateError('daily-topic use must not back a fresh chat');
}

final class _HistoricalWorkbenchDailyTopicPort implements DailyTopicPort {
  const _HistoricalWorkbenchDailyTopicPort();

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async => _workbenchSuccess(
    DailyTopicRecommendationPage(
      items: <DailyTopicRecommendation>[
        _workbenchRecommendation(
          workspaceId,
          recommendationId: 'newer-recommendation',
          businessDate: '2026-09-08',
          topicTitle: '较新的空推荐',
        ),
      ],
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) async => _workbenchSuccess(_historicalRecommendation(workspaceId));

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async =>
      _workbenchSuccess(_historicalRecommendation(workspaceId, read: true));

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => throw StateError('historical recommendation must not be dismissed');

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => throw StateError('historical recommendation must not be used');
}

DailyTopicRecommendation _historicalRecommendation(
  String workspaceId, {
  bool read = false,
}) => _workbenchRecommendation(
  workspaceId,
  read: read,
  recommendationId: 'historical-recommendation',
  businessDate: '2026-09-04',
  topicTitle: '历史非空推荐',
);

final class _WorkbenchKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  final List<KnowledgeNoteUpdateRequest> requests =
      <KnowledgeNoteUpdateRequest>[];
  int loadCalls = 0;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    loadCalls += 1;
    return const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]);
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requests.add(request);
    return KnowledgeNotePortResult.success(
      V3FeedItem(
        id: request.noteId,
        title: request.draft.title,
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 20),
        rawBody: request.draft.rawBody,
        localRevision: request.localRevision,
        remoteRevision: 1,
        remoteNoteId: 'remote-${request.noteId}',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-part-revision-1',
        etag: '"daily-topic-note-1"',
        contentCursor: 'cursor-1',
      ),
    );
  }
}

DailyTopicRecommendation _workbenchRecommendation(
  String workspaceId, {
  bool read = false,
  String recommendationId = 'daily-recommendation-1',
  String businessDate = '2026-08-14',
  String topicTitle = '公开每日选题',
  bool empty = false,
  String summaryMarkdown = '# 每日推荐摘要',
}) => DailyTopicRecommendation.fromJson(<String, Object?>{
  'recommendationId': recommendationId,
  'workspaceId': workspaceId,
  'businessDate': businessDate,
  'recommendationKind': 'daily_topic_report',
  'status': 'ready',
  'title': '测试每日推荐',
  'summaryMarkdown': summaryMarkdown,
  'generatedAt': '2026-08-15T01:00:00Z',
  'etag': '"$recommendationId"',
  if (read) 'readAt': '2026-08-14T00:00:00Z',
  'topics': <Object?>[
    if (!empty)
      <String, Object?>{
        'topicId': 'daily-topic-1',
        'title': topicTitle,
        'briefMarkdown': _workbenchTopicBrief,
        'primarySupply': 'method',
        'positioningMode': 'applied',
        'audience': '需要稳定选题的创作者',
        'contentPromise': _workbenchTopicPromise,
        'reasonMarkdown': _workbenchTopicReason,
        'writingSketchMarkdown': _workbenchTopicSketch,
        'sourceRefs': <Object?>[
          <String, Object?>{
            'kind': 'daily_hotspot',
            'hotspotId': 'daily-hotspot-1',
            'sourceUrl':
                'https://weibo.com/6506823885/RgWMA2J03?from=topic#share',
            'label': '来源：不脱妆气垫快手视频',
          },
          <String, Object?>{
            'kind': 'daily_hotspot',
            'hotspotId': 'daily-hotspot-kuaishou',
            'sourceUrl': _maximumLengthKuaishouSourceUrl(),
            'label': '微博热门视频',
          },
          <String, Object?>{
            'kind': 'daily_hotspot',
            'hotspotId': 'daily-hotspot-missing',
            'label': '未同步热点来源',
          },
          <String, Object?>{
            'kind': 'workspace_note',
            'noteId': 'workspace-note-1',
            'label': '我的工作区笔记',
          },
          <String, Object?>{
            'kind': 'workspace_note',
            'noteId': 'workspace-note-missing',
            'label': '未同步工作区笔记',
          },
        ],
      },
  ],
});

const _workbenchTopicBrief = '素材原文（概括）：公开热点形成一条具体内容方向。';
const _workbenchTopicPromise = '你可以借这条素材讲清选题判断方法';
const _workbenchTopicReason = '这条选题要讲：素材判断比追逐数量更重要。';
const _workbenchTopicSketch = '你可以这样写：1.摆素材 2.提问题 3.讲判断 4.给行动。';
const _emptyRecommendationReason = '当前定位只确认了服务范围，产品、典型客户和真实业务场景仍不完整，因此没有生成选题。';

ApiResult<T> _workbenchSuccess<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

void _expectToolAsset(
  WidgetTester tester, {
  required String id,
  required String assetPath,
}) {
  final finder = find.descendant(
    of: find.byKey(ValueKey<String>('workbench-inline-tool-$id')),
    matching: find.byType(Image),
  );
  expect(finder, findsOneWidget);
  final rendered = tester.widget<Image>(finder);
  expect((rendered.image as AssetImage).assetName, assetPath);
}
