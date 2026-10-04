import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_profile_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_library_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_link_import_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_live_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_voiceprint_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';

const _viewportSuffix = String.fromEnvironment(
  'HUAHUO_V13_VIEWPORT',
  defaultValue: '393x852',
);
const _m02Only = bool.fromEnvironment('HUAHUO_M02_ONLY');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures Figma M02 note-detail states', (tester) async {
    _keepImplicitViewAttached(tester);
    final note = V3FeedItem(
      id: 'figma-m02-note',
      title: '内容不是堆数量，而是形成判断',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 8, 19),
      rawBody:
          '内容不是靠堆砌数量产生价值，而是通过整理、比较和提炼，形成自己的判断。\n\n'
          '这条笔记保留原始上下文，纲要和深度洞察会基于此内容继续生成。',
      summaryBody:
          '核心判断\n\n**内容的价值不在数量，而在能否形成稳定、可调用的判断。**\n\n'
          '---\n\n判断路径\n\n1. **整理**\n   先保留原始上下文，去掉重复与噪声。\n\n'
          '2. **比较**\n   把相近观点放在一起，看见差异与联系。\n\n'
          '3. **提炼**\n   将信息收束为能支持选择和行动的结论。',
      sproutStatus: V3SproutTaskStatus.succeeded,
      sproutReport: V3SproutReport(
        id: 'figma-m02-sprout',
        noteId: 'figma-m02-note',
        title: '深度洞察',
        markdown:
            '值得继续追问\n\n**当记录不再追求更多，而是追求更准，我们该如何重新设计日常的信息输入？**\n\n'
            '---\n\n可以继续创作的方向\n\n1. **从收藏到判断**\n   把“记下来”变成“想清楚”的过程。\n\n'
            '2. **建立筛选标准**\n   用价值、相关性与行动性判断什么值得留下。\n\n'
            '3. **让笔记进入下一步**\n   让每条记录落到一个问题、决定或行动。',
        generatedAt: DateTime(2026, 8, 19, 12),
      ),
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
    );
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const V3FeedItemDetailPage(itemId: 'figma-m02-note'),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('figma-m02-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: _routerApp(router, textScale: 1),
      ),
    );
    await _settle(tester);

    expect(find.text('资料详情'), findsOneWidget);
    await _capture(binding, 'm02_note_original_iphone17pro');
    await tester.tap(find.text('纲要'));
    await _settle(tester);
    await _capture(binding, 'm02_note_outline_iphone17pro');
    await tester.tap(find.text('深度洞察').first);
    await _settle(tester);
    await _capture(binding, 'm02_note_sprout_iphone17pro');

    await tester.tap(find.text('Agent 辅助创作'));
    await _settle(tester);
    expect(find.text('选择 Agent'), findsOneWidget);
    await _capture(binding, 'm02_note_agent_selector_iphone17pro');
    await tester.tap(find.byTooltip('关闭'));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
    await _settle(tester);
    expect(find.text('猜你想问'), findsOneWidget);
    await _capture(binding, 'm02_note_chat_sheet_iphone17pro');
  });

  if (_m02Only) return;

  testWidgets('captures knowledge tabs and explicit deposits', (tester) async {
    _keepImplicitViewAttached(tester);
    final library = KnowledgeLibraryController(
      now: () => DateTime(2026, 7, 19, 12),
    );
    final router = GoRouter(
      initialLocation: '/knowledge',
      routes: [
        GoRoute(
          path: '/knowledge',
          builder: (context, state) => const V3KnowledgeLibraryPage(),
        ),
        GoRoute(
          path: '/assets',
          builder: (context, state) =>
              const V3MyAssetsPage(initialSection: V3MyAssetsSection.deposited),
        ),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/v3/feed/note',
          builder: (context, state) => const V3NotePage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: _routerApp(router, textScale: 1),
      ),
    );
    await _settle(tester);

    expect(find.text('我创建的'), findsOneWidget);
    await _capture(binding, 'v13_knowledge_mine_${_viewportSuffix}_1x');
    await tester.tap(
      find.byKey(const ValueKey('knowledge-mine-source-recording')),
    );
    await _settle(tester);
    await _capture(
      binding,
      'v13_knowledge_source_filter_${_viewportSuffix}_1x',
    );
    await tester.tap(find.byKey(const ValueKey('knowledge-mine-source-all')));
    await tester.tap(
      find.byKey(const ValueKey('knowledge-card-display-switch')),
    );
    await _settle(tester);
    await _capture(binding, 'v13_knowledge_compact_${_viewportSuffix}_1x');
    await tester.tap(find.byKey(const ValueKey('knowledge-tab-subscribed')));
    await _settle(tester);
    await _capture(binding, 'v13_knowledge_subscribed_${_viewportSuffix}_1x');
    await tester.tap(find.byKey(const ValueKey('knowledge-tab-square')));
    await _settle(tester);
    expect(find.text('今日推荐'), findsOneWidget);
    await _capture(binding, 'v13_knowledge_square_${_viewportSuffix}_1x');

    await tester.tap(find.byKey(const ValueKey('knowledge-tab-mine')));
    await _settle(tester);
    final noteMenu = find
        .byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              (widget.tooltip?.startsWith('笔记操作 ') ?? false),
        )
        .hitTestable();
    expect(noteMenu, findsWidgets);
    await tester.tap(noteMenu.first);
    await _settle(tester);
    await tester.tap(find.text('管理标签'));
    await _settle(tester);
    await _capture(binding, 'v13_knowledge_tags_${_viewportSuffix}_1x');
    await tester.tap(find.byTooltip('关闭'));
    await _settle(tester);
    await tester.tap(noteMenu.first);
    await _settle(tester);
    await tester.tap(find.text('导出'));
    await _settle(tester);
    await _capture(binding, 'v13_knowledge_export_${_viewportSuffix}_1x');
    await tester.tapAt(const Offset(8, 8));
    await _settle(tester);
    await tester.tap(noteMenu.first);
    await _settle(tester);
    await tester.ensureVisible(find.text('沉淀'));
    await _settle(tester);
    await tester.tap(find.text('沉淀').last);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('deposit-picker-confirm')),
      findsOneWidget,
    );
    await _capture(binding, 'v13_deposit_confirmation_${_viewportSuffix}_1x');
    await tester.tap(find.byKey(const ValueKey('deposit-picker-confirm')));
    await _settle(tester);

    router.go('/assets');
    await _settle(tester);
    expect(find.text('我的资产'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asset-primary-deposits')),
      findsOneWidget,
    );
    await _capture(binding, 'v13_my_assets_deposited_${_viewportSuffix}_1x');
  });

  testWidgets('captures a Knowledge Square article body image', (tester) async {
    _keepImplicitViewAttached(tester);
    final article = V3FeedItem(
      id: 'screenshot-knowledge-article',
      title: '知识广场图片资产验收',
      source: V3MaterialSource.knowledgeSquare,
      ownership: V3NoteOwnership.knowledgeSquare,
      createdAt: DateTime.utc(2026, 8, 8),
      rawBody:
          '# 知识广场图片\n\n![文章主题配图](images/knowledge-cover.png)\n\n图片内容由文章版本的受控资产接口提供。',
      publicationId: 'screenshot-publication',
      articleId: 'screenshot-article',
      articleRevisionId: 'screenshot-revision',
      subscriptionArticleAssets: <V3SubscriptionArticleAssetRef>[
        V3SubscriptionArticleAssetRef(
          fileKey: 'screenshot-image-file',
          logicalPath: 'images/knowledge-cover.png',
        ),
      ],
    );
    final assetPort = _ScreenshotArticleAssetPort(article);
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      subscriptionPort: assetPort,
    );
    await library.reloadSubscriptions();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith(
            (ref) => ProfileHubController(),
          ),
        ],
        child: _pageApp(
          const V3FeedItemDetailPage(itemId: 'screenshot-knowledge-article'),
          textScale: 1,
        ),
      ),
    );
    await _settle(tester);

    expect(assetPort.assetCalls, 1);
    expect(
      find.byKey(
        const ValueKey(
          'subscription-article-image-screenshot-knowledge-article-images/knowledge-cover.png',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('images/knowledge-cover.png'), findsNothing);
    await _capture(
      binding,
      'v13_knowledge_article_image_${_viewportSuffix}_1x',
    );
  });

  testWidgets('captures near graph with all node titles', (tester) async {
    _keepImplicitViewAttached(tester);
    final library = KnowledgeLibraryController();
    final graph = FeedGraphController(library);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: _pageApp(
          const SafeArea(
            child: V3InteractiveGraph(aggregated: false, height: 760),
          ),
          textScale: 1,
        ),
      ),
    );
    await _settle(tester);
    final viewerFinder = find.byKey(
      const ValueKey('feed-graph-interactive-viewer'),
    );
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    final viewportSize = tester.getSize(viewerFinder);
    final viewportCenter = Offset(
      viewportSize.width / 2,
      viewportSize.height / 2,
    );
    final sceneCenter = viewportCenter + const Offset(240, 240);
    final translation = viewportCenter - sceneCenter * 2;
    viewer.transformationController?.value = Matrix4.identity()
      ..setEntry(0, 0, 2)
      ..setEntry(1, 1, 2)
      ..setEntry(0, 3, translation.dx)
      ..setEntry(1, 3, translation.dy);
    await _settle(tester);
    expect(_graphNodeLabels().evaluate().length, library.graphNotes.length);
    await _capture(binding, 'v13_graph_near_${_viewportSuffix}_1x');
  });

  testWidgets('captures voiceprint management and forced enrollment', (
    tester,
  ) async {
    _keepImplicitViewAttached(tester);
    final controller = _voiceprintController(withProfiles: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceprintControllerProvider.overrideWith((ref) => controller),
        ],
        child: _pageApp(const V3VoiceprintPage(), textScale: 1),
      ),
    );
    await _settle(tester);
    expect(find.text('声纹管理'), findsOneWidget);
    await _capture(binding, 'v13_voiceprint_management_${_viewportSuffix}_1x');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceprintControllerProvider.overrideWith(
            (ref) => _voiceprintController(withProfiles: true),
          ),
        ],
        child: _pageApp(
          const V3VoiceprintPage(enrollmentOnly: true),
          textScale: 1,
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('录入声纹'), findsOneWidget);
    expect(find.textContaining('你好，花火 AI'), findsOneWidget);
    await _capture(binding, 'v13_voiceprint_enrollment_${_viewportSuffix}_1x');
  });

  testWidgets('captures local chat thread rename', (tester) async {
    _keepImplicitViewAttached(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(const _ScreenshotChatApi()),
          resolvedDeviceIdProvider.overrideWithValue('screenshot-device'),
        ],
        child: _pageApp(const V3ChatPage(), textScale: 1),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byTooltip('会话列表'));
    await _settle(tester);
    expect(find.text('历史会话'), findsOneWidget);
    await _capture(binding, 'v13_chat_threads_${_viewportSuffix}_1x');

    await tester.tap(find.byKey(const ValueKey('chat-thread-more-feed-2')));
    await _settle(tester);
    await tester.tap(find.text('重命名'));
    await _settle(tester);
    await _capture(binding, 'v13_chat_rename_dialog_${_viewportSuffix}_1x');
    await tester.enterText(
      find.byKey(const ValueKey('chat-thread-name-input')),
      '项目复盘',
    );
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('项目复盘'), findsOneWidget);
    await _capture(binding, 'v13_chat_renamed_${_viewportSuffix}_1x');
  });

  testWidgets('captures link guidance at 375x812 and 1.2 text scale', (
    tester,
  ) async {
    _keepImplicitViewAttached(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('screenshot-device'),
        ],
        child: _pageApp(const V3LinkImportPage(), textScale: 1.2),
      ),
    );
    await _settle(tester);
    expect(find.text('支持导入公开内容'), findsOneWidget);
    await _capture(binding, 'v13_link_guidance_${_viewportSuffix}_1_2x');
  });

  testWidgets('captures note editor at 430x932 and 1.3 text scale', (
    tester,
  ) async {
    _keepImplicitViewAttached(tester);
    await tester.pumpWidget(
      ProviderScope(child: _pageApp(const V3NotePage(), textScale: 1.3)),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('note-save-button')), findsOneWidget);
    expect(find.byTooltip('删除线'), findsOneWidget);
    await _capture(binding, 'v13_note_editor_${_viewportSuffix}_1_3x');
  });

  testWidgets('captures recording-card device action sheet', (tester) async {
    _keepImplicitViewAttached(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardPortProvider.overrideWithValue(
            const UnavailableRecordingCardPort(),
          ),
          resolvedDeviceIdProvider.overrideWithValue('screenshot-device'),
        ],
        child: _pageApp(const V3RecordingCardLivePage(), textScale: 1),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byTooltip('设备操作'));
    await _settle(tester);
    expect(find.text('刷新设备状态'), findsOneWidget);
    expect(find.text('扫描附近设备'), findsOneWidget);
    expect(find.text('读取设备文件'), findsOneWidget);
    await _capture(binding, 'v13_recording_card_menu_${_viewportSuffix}_1x');
  });

  testWidgets('captures profile drawer recording-card battery', (tester) async {
    _keepImplicitViewAttached(tester);
    final router = GoRouter(
      initialLocation: '/v3/feed',
      routes: [
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) =>
              const V3AppShell(initialMode: V3HomeMode.feed),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('screenshot-device'),
        ],
        child: _routerApp(router, textScale: 1),
      ),
    );
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('profile-recording-card-battery')),
      findsOneWidget,
    );
    await _capture(binding, 'v13_profile_drawer_battery_${_viewportSuffix}_1x');
  });
}

Widget _pageApp(Widget page, {required double textScale}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HuahuoV3Theme.light(),
    builder: (context, child) => _scaledMediaQuery(context, child!, textScale),
    home: ColoredBox(color: Colors.white, child: page),
  );
}

Widget _routerApp(GoRouter router, {required double textScale}) {
  return MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: HuahuoV3Theme.light(),
    routerConfig: router,
    builder: (context, child) => _scaledMediaQuery(context, child!, textScale),
  );
}

Widget _scaledMediaQuery(BuildContext context, Widget child, double textScale) {
  return MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child,
  );
}

void _keepImplicitViewAttached(WidgetTester tester) {
  // Keep the simulator's implicit view attached so driver screenshots capture
  // the rendered app instead of the integration-test launch placeholder.
  expect(tester.view.physicalSize, isNot(Size.zero));
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty);
}

Finder _graphNodeLabels() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return widget is Text &&
        key is ValueKey<String> &&
        key.value.startsWith('feed-graph-node-label-');
  });
}

VoiceprintController _voiceprintController({required bool withProfiles}) {
  final database = AppDatabase();
  final dao = UserMetadataDao(database);
  if (withProfiles) {
    dao.upsertVoiceprintProfile(
      userScope: 'screenshot-user',
      profileId: 'host',
      name: '主持人',
      enrolledAt: '2026-07-18T09:00:00.000Z',
      updatedAt: '2026-07-18T09:00:00.000Z',
      isDemo: true,
    );
    dao.upsertVoiceprintProfile(
      userScope: 'screenshot-user',
      profileId: 'guest',
      name: '访谈嘉宾',
      enrolledAt: '2026-07-19T09:00:00.000Z',
      updatedAt: '2026-07-19T09:00:00.000Z',
      isDemo: true,
    );
  }
  return VoiceprintController(
    recorder: const UnavailableVoiceRecorderPort(),
    port: SessionMockVoiceprintPort(deleteLocalSample: (_) async => true),
    initialUserId: 'screenshot-user',
    profileRepository: VoiceprintProfileRepository(
      dao: dao,
      userScope: 'screenshot-user',
    ),
  );
}

final class _ScreenshotArticleAssetPort implements MobileSubscriptionPort {
  _ScreenshotArticleAssetPort(this.article);

  final V3FeedItem article;
  int assetCalls = 0;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async {
    return MobileSubscriptionCatalogResult.success(
      <MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: article.publicationId!,
          title: '知识广场图片验收',
          sectionCount: 1,
          articleCount: 1,
          updatedAt: article.updatedAt,
          articles: <V3FeedItem>[article],
          followed: false,
          available: true,
        ),
      ],
    );
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(
    V3FeedItem article,
  ) async => MobileSubscriptionActionResult.success(article);

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async {
    assetCalls += 1;
    return MobileSubscriptionArticleAssetResult.success(
      MobileSubscriptionArticleAsset(
        bytes: Uint8List.fromList(const <int>[
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          13,
          73,
          72,
          68,
          82,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
          8,
          6,
          0,
          0,
          0,
          31,
          21,
          196,
          137,
          0,
          0,
          0,
          13,
          73,
          68,
          65,
          84,
          8,
          215,
          99,
          248,
          207,
          192,
          240,
          31,
          0,
          5,
          0,
          1,
          255,
          137,
          153,
          61,
          29,
          0,
          0,
          0,
          0,
          73,
          69,
          78,
          68,
          174,
          66,
          96,
          130,
        ]),
        mimeType: 'image/png',
      ),
    );
  }

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async => const MobileSubscriptionActionResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async => const MobileSubscriptionActionResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );
}

final class _ScreenshotChatApi implements ChatRepository {
  const _ScreenshotChatApi();

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async {
    return _success(
      ChatThreadPage(
        items: [
          ChatThread(
            threadId: 'feed-1',
            scene: scene,
            title: 'AI 项目讨论',
            updatedAt: DateTime.utc(2026, 7, 19, 10),
          ),
          ChatThread(
            threadId: 'feed-2',
            scene: scene,
            title: '历史会话',
            updatedAt: DateTime.utc(2026, 7, 18, 10),
          ),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    return _success(
      ChatThreadDetail(
        thread: ChatThread(
          threadId: threadId,
          scene: ChatScene.feedAi,
          title: threadId == 'feed-2' ? '历史会话' : 'AI 项目讨论',
        ),
        messages: [
          ChatMessage(
            messageId: 'assistant-$threadId',
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '这里是服务端返回的会话内容。',
          ),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    return _success(
      ChatThread(threadId: 'feed-new', scene: scene, purpose: purpose),
    );
  }

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    return _success(
      ChatTextMutation(
        message: ChatMessage(
          messageId: 'message-1',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: content,
        ),
      ),
    );
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    return _success(
      ChatVoiceMutation(
        message: ChatMessage(
          messageId: 'voice-1',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.voice,
          status: 'sent',
        ),
      ),
    );
  }
}

ApiResult<T> _success<T>(T data) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}
