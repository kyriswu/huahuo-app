import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/daily_topic_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_chat_mark.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('large inherited text keeps the compact feed Dock aligned', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(260, 120)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
            child: SizedBox(width: 224, child: V3FeedQuickDock(enabled: false)),
          ),
        ),
      ),
    );

    final dock = find.byType(V3FeedQuickDock);
    expect(tester.getSize(dock), const Size(224, 54));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Figma 3081:1877 exposes the canonical 1D Home controls', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final homeNotes = <V3FeedItem>[
      for (var index = 0; index < 5; index += 1)
        V3FeedItem(
          id: 'home-note-$index',
          title: '首页笔记 $index',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 8, 20 + index),
          rawBody: '正文 $index',
        ),
      V3FeedItem(
        id: 'home-hotspot',
        title: '首页热点',
        source: V3MaterialSource.hotspot,
        ownership: V3NoteOwnership.hotspot,
        createdAt: DateTime(2026, 8, 29),
        rawBody: '热点正文',
      ),
    ];
    final library = KnowledgeLibraryController(initialNotes: homeNotes);
    for (final note in homeNotes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final aggregationController = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 29)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith(
            (ref) => aggregationController,
          ),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: const V3AppShell(
            initialMode: V3HomeMode.feed,
            initialFeedNotes: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('思想图谱'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-feed-search')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-feed-notifications')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-notes-notifications')),
      findsNothing,
    );
    expect(find.text('Hi，今天想沉淀些什么？'), findsOneWidget);
    expect(find.text('你已经攒下 5 条笔记'), findsOneWidget);
    for (final mode in const ['1d', '3d']) {
      final choice = find.byKey(ValueKey<String>('feed-home-mode-$mode'));
      expect(choice, findsOneWidget);
      expect(tester.getSize(choice).height, greaterThanOrEqualTo(44));
    }
    expect(find.text('2D'), findsNothing);
    final filter = find.byKey(const ValueKey<String>('feed-notes-filter'));
    final aggregation = find.byKey(
      const ValueKey<String>('feed-notes-random-aggregation'),
    );
    final dock = find.byKey(const ValueKey<String>('home-feed-dock-frame'));
    expect(tester.getSize(filter), const Size.square(40));
    expect(tester.getSize(aggregation), const Size(310, 52));
    expect(tester.getSize(dock), const Size(224, 54));
    final feedSearch = find.byKey(const ValueKey<String>('home-feed-search'));
    final feedNotifications = find.byKey(
      const ValueKey<String>('home-feed-notifications'),
    );
    expect(tester.getSize(feedSearch), const Size.square(44));
    expect(tester.getSize(feedNotifications), const Size.square(44));
    final greeting = find.text('Hi，今天想沉淀些什么？');
    final oneDimensional = find.byKey(
      const ValueKey<String>('feed-home-mode-1d'),
    );
    expect(
      (tester.getTopLeft(greeting).dy - tester.getTopLeft(oneDimensional).dy)
          .abs(),
      lessThan(10),
    );
    expect(tester.getTopLeft(find.text('首页笔记 4')).dy, lessThan(240));
    expect(
      tester.getTopLeft(feedNotifications).dy,
      tester.getTopLeft(feedSearch).dy,
    );
    expect(
      tester.getTopLeft(feedNotifications).dx -
          tester.getTopRight(feedSearch).dx,
      8,
    );
    expect(
      tester.getSize(
        find.descendant(
          of: feedSearch,
          matching: find.byIcon(LucideIcons.search),
        ),
      ),
      const Size.square(22),
    );
    expect(
      tester.getSize(
        find.descendant(
          of: feedNotifications,
          matching: find.byIcon(LucideIcons.bell),
        ),
      ),
      const Size.square(22),
    );
    expect(find.byIcon(Icons.face_retouching_natural_outlined), findsOneWidget);
    expect(find.byIcon(LucideIcons.penLine), findsOneWidget);

    await tester.tap(aggregation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('aggregation-selection')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-notes-center')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final mode3d = find.byKey(const ValueKey<String>('feed-home-mode-3d'));
    final mode3dRect = tester.getRect(mode3d);
    await tester.tapAt(Offset(mode3dRect.center.dx, mode3dRect.bottom - 2));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
  });

  testWidgets('1D home waits for authoritative empty synchronization', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final port = _HomeQueuedKnowledgeNotePort(2);
    final library = KnowledgeLibraryController(
      notePort: port,
      includeDemoFixtures: false,
    );
    final initialization = library.initialize();
    final aggregationController = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 31)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith(
            (ref) => aggregationController,
          ),
        ],
        child: const MaterialApp(
          home: V3AppShell(
            initialMode: V3HomeMode.feed,
            initialFeedNotes: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在加载笔记'), findsOneWidget);
    expect(find.text('全部笔记暂无内容'), findsNothing);

    port.complete(
      0,
      const KnowledgeNoteRemoteLoadResult.failure('REMOTE_NOTES_FAILED'),
    );
    await initialization;
    await tester.pump();

    expect(find.text('笔记加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('全部笔记暂无内容'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('feed-notes-retry')));
    await tester.pump();
    expect(find.text('正在加载笔记'), findsOneWidget);

    port.complete(
      1,
      const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]),
    );
    await tester.pumpAndSettle();

    expect(find.text('正在加载笔记'), findsNothing);
    expect(find.text('笔记加载失败'), findsNothing);
    expect(find.text('全部笔记暂无内容'), findsOneWidget);
  });

  testWidgets('1D home keeps cached notes visible after refresh failure', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final note = V3FeedItem(
      id: 'cached-home-note',
      title: '缓存笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 30),
      rawBody: '上次同步成功的内容。',
    );
    final port = _HomeQueuedKnowledgeNotePort(1);
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: port,
      includeDemoFixtures: false,
    );
    library.depositContent(note.id);
    final initialization = library.initialize();
    final aggregationController = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 31)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith(
            (ref) => aggregationController,
          ),
        ],
        child: const MaterialApp(
          home: V3AppShell(
            initialMode: V3HomeMode.feed,
            initialFeedNotes: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('缓存笔记'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-notes-refresh-failure')),
      findsNothing,
    );

    port.complete(
      0,
      const KnowledgeNoteRemoteLoadResult.failure('REMOTE_NOTES_FAILED'),
    );
    await initialization;
    await tester.pump();

    expect(find.text('缓存笔记'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-notes-refresh-failure')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-notes-refresh-retry')),
      findsOneWidget,
    );
    expect(find.text('全部笔记暂无内容'), findsNothing);
  });

  testWidgets('home chrome releases editor space while keyboard is visible', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [resolvedDeviceIdProvider.overrideWithValue('test-device')],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: const V3AppShell(initialMode: V3HomeMode.feed),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('home-mode-indicator')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-feed-dock-frame')),
      findsOneWidget,
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(
      tester.widget<V3FeedPage>(find.byType(V3FeedPage)).bottomOverlayInset,
      0,
    );
    expect(
      find.byKey(const ValueKey<String>('home-mode-indicator')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-feed-dock-frame')),
      findsNothing,
    );

    tester.view.resetViewInsets();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('home-mode-indicator')),
      findsOneWidget,
    );
  });

  testWidgets(
    'direct workbench keeps profile and notifications without search',
    (tester) async {
      tester.view
        ..physicalSize = const Size(280, 700)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const V3AppShell(initialMode: V3HomeMode.workbench),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(V3FeedPage), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('home-workbench-surface')),
        findsOneWidget,
      );
      expect(find.byType(V3GraphSearchIcon), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('home-workbench-back')),
        findsNothing,
      );
      for (final key in const [
        'home-profile-menu',
        'home-workbench-notifications',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey<String>('workbench-free-creation')),
        findsOneWidget,
      );
      expect(find.text('今日推送'), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey<String>('workbench-home-scroll')),
        findsOneWidget,
      );
      for (final actionName in const [
        'persona',
        'lead',
        'influence',
        'video',
      ]) {
        final action = find.byKey(
          ValueKey<String>('workbench-inline-tool-$actionName'),
        );
        expect(tester.getRect(action).width, greaterThanOrEqualTo(44));
        expect(tester.getRect(action).height, greaterThanOrEqualTo(44));
      }
      expect(
        find.byKey(const ValueKey<String>('home-workbench-dock-frame')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('home-chat-workbench')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('聊一聊'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('M11 direct workbench shell matches the Mobile V5 fixture', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dailyTopics = await _goldenDailyTopics();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          dailyTopicControllerProvider.overrideWith((ref) => dailyTopics),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          home: const V3AppShell(initialMode: V3HomeMode.workbench),
        ),
      ),
    );
    await tester.pump();
    await precacheFigmaFixtureImages(tester);
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(
      find.byKey(const ValueKey<String>('home-workbench-back')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-profile-menu')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home-workbench-search')), findsNothing);
    final workbenchNotifications = find.byKey(
      const ValueKey<String>('home-workbench-notifications'),
    );
    expect(tester.getSize(workbenchNotifications), const Size.square(44));
    await expectLater(
      find.byType(V3AppShell),
      matchesGoldenFile('goldens/app_shell_workbench.png'),
    );
  });

  testWidgets('M01 create entry matches the two-option Mobile V5 sheet', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [resolvedDeviceIdProvider.overrideWithValue('test-device')],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          home: const V3AppShell(initialMode: V3HomeMode.feed),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('独白').hitTestable());
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(
      find.byKey(const ValueKey<String>('feed-create-note-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-create-monologue')),
      findsOneWidget,
    );
    expect(find.text('文字'), findsOneWidget);
    expect(find.text('导入本地文件'), findsNothing);
    expect(find.text('录音卡'), findsNothing);
    await expectLater(
      find.byKey(const ValueKey<String>('feed-create-note-sheet')),
      matchesGoldenFile('goldens/create_note_sheet.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('feed-create-note-close')),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(
      find.byKey(const ValueKey<String>('feed-create-note-sheet')),
      findsNothing,
    );

    await tester.tap(find.text('独白').hitTestable());
    await _pumpOverlayFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('feed-create-monologue')),
    );
    await _pumpOverlayFrames(tester);
    expect(
      find.byKey(const ValueKey<String>('monologue-quick-sheet')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭').hitTestable());
    await _pumpOverlayFrames(tester);

    await tester.tap(find.text('独白').hitTestable());
    await _pumpOverlayFrames(tester);
    await tester.tap(find.byKey(const ValueKey<String>('feed-create-text')));
    await _pumpOverlayFrames(tester);
    expect(
      find.byKey(const ValueKey<String>('text-quick-sheet')),
      findsOneWidget,
    );
  });

  testWidgets('M01 graph add opens More Ways directly', (tester) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [resolvedDeviceIdProvider.overrideWithValue('test-device')],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          home: const V3AppShell(initialMode: V3HomeMode.feed),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('新建').hitTestable());
    await _pumpOverlayFrames(tester);

    expect(find.byKey(const ValueKey('feed-more-ways-sheet')), findsOneWidget);
    expect(find.text('粘贴链接'), findsOneWidget);
    expect(find.text('导入本地文件'), findsOneWidget);
    expect(find.text('导入录音音频'), findsOneWidget);
    expect(find.text('外录 / 内录'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await _pumpOverlayFrames(tester);
    expect(find.byKey(const ValueKey('feed-more-ways-sheet')), findsNothing);
  });

  testWidgets('V5 home shell limits the graph to AI feed mode', (tester) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
        overrides: [resolvedDeviceIdProvider.overrideWithValue('test-device')],
        child: MaterialApp.router(
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('思想图谱'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-title')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-profile-menu')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    final profileAction = find.byKey(
      const ValueKey<String>('home-profile-menu'),
    );
    expect(
      find.descendant(
        of: profileAction,
        matching: find.byIcon(Icons.person_outline_rounded),
      ),
      findsOneWidget,
    );
    final feedChat = find.byKey(const ValueKey<String>('home-chat-feed'));
    final workbenchChat = find.byKey(
      const ValueKey<String>('home-chat-workbench'),
    );
    expect(feedChat, findsOneWidget);
    final settledChatCenter = tester.getCenter(feedChat);
    expect(tester.getSize(feedChat), const Size.square(48));
    final chatMark = tester.widget<V3ChatMark>(
      find.descendant(of: feedChat, matching: find.byType(V3ChatMark)),
    );
    expect(chatMark.size, 48);
    expect(
      find.descendant(of: feedChat, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(settledChatCenter.dx, lessThan(86));
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);

    // The graph consumes its own pan gesture; it must not change the mode.
    await tester.dragFrom(const Offset(196, 360), const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('思想图谱'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-title')),
      findsNothing,
    );

    final pager = find.byKey(const ValueKey<String>('home-content-mode-pager'));
    expect(pager, findsOneWidget);
    final pagerRect = tester.getRect(pager);
    final feedDock = find.byKey(const ValueKey<String>('home-feed-dock-frame'));
    expect(pagerRect.width, 393);
    expect(pagerRect.height, greaterThan(700));
    expect(tester.getRect(feedDock).width, 224);
    expect(tester.getRect(feedDock).right, 371);
    expect(
      find.descendant(of: feedDock, matching: find.text('创作空间')),
      findsOneWidget,
    );

    final edgeGesture = find.byKey(
      const ValueKey<String>('feed-right-edge-workbench-gesture'),
    );
    expect(edgeGesture, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-bottom-workbench-gesture')),
      findsOneWidget,
    );
    await tester.timedDragFrom(
      tester.getRect(edgeGesture).center,
      const Offset(-120, 0),
      const Duration(milliseconds: 50),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('创作空间'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-workbench-dock-frame')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('workbench-topic-section')),
      findsOneWidget,
    );
    for (final actionName in const ['persona', 'lead', 'influence', 'video']) {
      expect(
        find.byKey(ValueKey<String>('workbench-inline-tool-$actionName')),
        findsOneWidget,
      );
    }
    for (final legacy in const ['大曝光', '深价值', '强种草', '稳成交']) {
      expect(find.text(legacy), findsNothing);
    }
    expect(tester.getRect(pager).width, 393);
    expect(workbenchChat, findsNothing);
    expect(find.bySemanticsLabel('聊一聊'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('workbench-free-creation')),
      findsOneWidget,
    );
    expect(find.text('今日推送'), findsOneWidget);
    final workbenchScroll = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    expect(workbenchScroll, findsOneWidget);
    expect(find.byType(V3FeedPage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('feed-graph-interactive-viewer')),
      findsNothing,
    );
    expect(find.byType(V3GraphSearchIcon), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-search')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsOneWidget,
    );
    await tester.drag(workbenchScroll, const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.widget<PageView>(pager).controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);
    await tester.timedDrag(
      pager,
      const Offset(280, 0),
      const Duration(milliseconds: 50),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('思想图谱'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-title')),
      findsNothing,
    );
    expect(
      find.descendant(of: feedDock, matching: find.text('创作空间')),
      findsOneWidget,
    );
    expect(tester.getCenter(feedChat), settledChatCenter);
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    expect(find.byType(V3FeedPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    expect(find.byType(V3GraphSearchIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final profilePanel = find.byKey(
      const ValueKey<String>('v3-profile-side-panel'),
    );
    expect(profilePanel, findsOneWidget);
    expect(tester.getRect(profilePanel).left, 0);
    expect(
      find.descendant(of: profilePanel, matching: find.text('我的资产')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: profilePanel, matching: find.text('思想图谱')),
      findsNothing,
    );
    expect(
      find.descendant(of: profilePanel, matching: find.text('工作台')),
      findsNothing,
    );

    await tester.binding.handlePopRoute();
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(profilePanel, findsNothing);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
  });

  testWidgets(
    'M03 header actions retain notifications and Feed without workspace search',
    (tester) async {
      tester.view
        ..physicalSize = const Size(393, 852)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = GoRouter(
        initialLocation: '/v3/workbench',
        routes: [
          GoRoute(
            path: '/v3/workbench',
            builder: (context, state) =>
                const V3AppShell(initialMode: V3HomeMode.workbench),
          ),
          GoRoute(
            path: '/v3/notifications',
            builder: (context, state) => const Scaffold(body: Text('通知页面')),
          ),
          GoRoute(
            path: '/v3/search',
            builder: (context, state) => const Scaffold(body: Text('搜索页面')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('test-device'),
          ],
          child: MaterialApp.router(
            theme: HuahuoV3Theme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('home-workbench-notifications')),
      );
      await tester.pumpAndSettle();
      expect(find.text('通知页面'), findsOneWidget);

      router.go('/v3/workbench');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('home-workbench-back')),
        findsNothing,
      );
      final pager = find.byKey(
        const ValueKey<String>('home-content-mode-pager'),
      );
      await tester.timedDrag(
        pager,
        const Offset(280, 0),
        const Duration(milliseconds: 50),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('思想图谱'), findsOneWidget);

      final edgeGesture = find.byKey(
        const ValueKey<String>('feed-right-edge-workbench-gesture'),
      );
      await tester.timedDragFrom(
        tester.getRect(edgeGesture).center,
        const Offset(-120, 0),
        const Duration(milliseconds: 50),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(
        find.byKey(const ValueKey<String>('home-workbench-back')),
        findsNothing,
      );
      await tester.timedDrag(
        pager,
        const Offset(280, 0),
        const Duration(milliseconds: 50),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('思想图谱'), findsOneWidget);

      router.go('/v3/notifications');
      await tester.pumpAndSettle();
      router.go('/v3/workbench');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-workbench-search')), findsNothing);
      expect(find.text('搜索页面'), findsNothing);
    },
  );
}

Future<void> _pumpOverlayFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<DailyTopicController> _goldenDailyTopics() async {
  final controller = DailyTopicController(
    port: const _GoldenDailyTopicPort(),
    preferences: AppPreferencesDao(AppDatabase()),
    userScope: 'home-shell-golden-user',
    workspaceId: () => 'home-shell-golden-workspace',
    workspaceReady: () => true,
    cacheTtl: () => const Duration(minutes: 5),
  );
  await controller.initialize();
  return controller;
}

final class _GoldenDailyTopicPort implements DailyTopicPort {
  const _GoldenDailyTopicPort();

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async => _goldenSuccess(
    DailyTopicRecommendationPage(
      items: <DailyTopicRecommendation>[_goldenRecommendation(workspaceId)],
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) async => _goldenSuccess(_goldenRecommendation(workspaceId));

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _goldenSuccess(_goldenRecommendation(workspaceId, read: true));

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _goldenSuccess(_goldenRecommendation(workspaceId));

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => throw StateError('Golden recommendations are visual fixtures only.');
}

final class _HomeQueuedKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  _HomeQueuedKnowledgeNotePort(int responseCount)
    : _responses = List<Completer<KnowledgeNoteRemoteLoadResult>>.generate(
        responseCount,
        (_) => Completer<KnowledgeNoteRemoteLoadResult>(),
      );

  final List<Completer<KnowledgeNoteRemoteLoadResult>> _responses;
  int _requestIndex = 0;

  void complete(int index, KnowledgeNoteRemoteLoadResult result) {
    _responses[index].complete(result);
  }

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() =>
      _responses[_requestIndex++].future;

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

DailyTopicRecommendation _goldenRecommendation(
  String workspaceId, {
  bool read = false,
}) {
  const titles = <String>[
    '别只问“用哪个 AI”，先问它该看什么、能改什么、何时需要找我批准',
    '专业工具为什么更容易被相信：思维链、信息源和“看起来有人研究过”',
    '先给分析，再给选题：为什么把思考过程外显，用户反而更愿意信你',
    '口语化不是“嘿兄弟”：真正让人觉得像你自己的表达，到底长什么样',
    '真实内容仍然有效，但 AI 搜索正在改写内容被发现的方式',
    '品牌别只追热点：社区关系正在成为更稳定的增长入口',
    'AI 视频进入普及期：竞争从会不会做转向如何取舍',
    '小企业真正需要的不是更多 AI，而是一条能跑通的工作流',
    '从试用到生产：AI 项目卡住的往往不是模型，而是业务上下文',
    '自动化先做窄任务：能衡量、可回退，比全能 Agent 更可靠',
    '内容搜索正在社交化：用户先找可信的人，再找标准答案',
    'AI 生成越容易，个人经验、判断边界和证据链越值钱',
  ];
  return DailyTopicRecommendation.fromJson(<String, Object?>{
    'recommendationId': 'home-shell-golden-recommendation',
    'workspaceId': workspaceId,
    'businessDate': '2026-08-24',
    'recommendationKind': 'daily_topic_report',
    'status': 'ready',
    'title': '今日推送',
    'summaryMarkdown': '确定性视觉验收数据',
    'etag': '"home-shell-golden"',
    if (read) 'readAt': '2026-08-24T00:00:00Z',
    'topics': <Object?>[
      for (var index = 0; index < titles.length; index++)
        <String, Object?>{
          'topicId': 'home-shell-topic-${index + 1}',
          'title': titles[index],
          'briefMarkdown': '从真实内容与可执行行动之间，找到新的创作入口。',
          'sourceRefs': <Object?>[
            <String, Object?>{
              'kind': 'daily_hotspot',
              'hotspotId': 'home-shell-hotspot-${index + 1}',
              'label': '每日推荐',
            },
          ],
        },
    ],
  });
}

ApiResult<T> _goldenSuccess<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);
