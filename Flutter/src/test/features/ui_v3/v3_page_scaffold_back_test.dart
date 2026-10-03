import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_local_surfaces.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_liquid_glass.dart';

void main() {
  for (final destination in [
    '/v3/feed/chat?threadId=missing-purpose',
    '/missing-note',
    '/missing-knowledge',
  ]) {
    testWidgets('recovery action retains its parent: $destination', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/source',
        routes: [
          GoRoute(
            path: '/source',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => context.push(destination),
                child: const Text('来源列表'),
              ),
            ),
          ),
          GoRoute(
            path: '/missing-note',
            builder: (context, state) =>
                const V3NotePage(itemId: 'missing-navigation-note'),
          ),
          GoRoute(
            path: '/missing-knowledge',
            builder: (context, state) => const V3KnowledgeRouteRecoveryPage(
              recoveryKey: ValueKey('missing-navigation-knowledge'),
              title: '内容无法加载',
              message: '请返回后重试',
            ),
          ),
          for (final path in [
            AppRoutePaths.home,
            Uri.parse(AppRoutePaths.knowledgeSquare).path,
          ])
            GoRoute(
              path: path,
              builder: (context, state) => const Scaffold(body: Text('错误跳层')),
            ),
          ...buildAppRoutes(
            splashBuilder: (context, state) => const SizedBox.shrink(),
            restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
            workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
          ).whereType<GoRoute>().where(
            (route) => route.path == '/v3/feed/chat',
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith(
              (ref) => KnowledgeLibraryController(
                initialNotes: const [],
                includeDemoFixtures: false,
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.text('来源列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回上一级'));
      await tester.pumpAndSettle();
      expect(find.text('来源列表'), findsOneWidget);
      expect(find.text('错误跳层'), findsNothing);
      expect(router.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shared page back control is flat and consistently sized', (
    tester,
  ) async {
    var backCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3NavigationBackButton(
            key: const ValueKey<String>('standard-page-back'),
            onPressed: () => backCalls += 1,
          ),
        ),
      ),
    );

    final control = find.byKey(const ValueKey<String>('standard-page-back'));
    final icon = tester.widget<Icon>(
      find.descendant(of: control, matching: find.byType(Icon)),
    );
    final iconButton = tester.widget<IconButton>(
      find.descendant(of: control, matching: find.byType(IconButton)),
    );
    expect(tester.getSize(control), const Size.square(44));
    expect(icon.icon, Icons.arrow_back_ios_new_rounded);
    expect(icon.size, 20);
    expect(iconButton.style, isNull);

    await tester.tap(control);
    expect(backCalls, 1);
  });

  testWidgets('secondary back restores a parent before a deep-link fallback', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/v3/feed/detail',
      routes: [
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/v3/feed/source'),
                child: const Text('打开来源页'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/feed/source',
          builder: (context, state) => V3PageScaffold(
            title: '来源页',
            fallbackRoute: '/v3/feed',
            children: [
              TextButton(
                onPressed: () => context.push('/v3/feed/detail'),
                child: const Text('打开转写详情'),
              ),
            ],
          ),
        ),
        GoRoute(
          path: '/v3/feed/detail',
          builder: (context, state) => const V3PageScaffold(
            title: '转写详情',
            fallbackRoute: '/v3/feed',
            backBehavior: V3BackBehavior.fallbackOnly,
            children: [Text('转写内容')],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // A deep link has no prior page, so it uses the declared source fallback.
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(find.text('打开来源页'), findsOneWidget);

    router.go('/v3/feed/detail');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开来源页'), findsOneWidget);

    await tester.tap(find.text('打开来源页'));
    await tester.pumpAndSettle();
    expect(find.text('来源页'), findsOneWidget);

    await tester.tap(find.text('打开转写详情'));
    await tester.pumpAndSettle();
    expect(find.text('转写详情'), findsOneWidget);

    // The legacy fallbackOnly value must not skip this real intermediate page.
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(find.text('来源页'), findsOneWidget);

    await tester.tap(find.text('打开转写详情'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('来源页'), findsOneWidget);
  });

  testWidgets('shared Back closes the nested detail before its outer page', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/source',
      routes: [
        GoRoute(
          path: '/source',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/nested'),
              child: const Text('打开嵌套页面'),
            ),
          ),
        ),
        GoRoute(
          path: '/nested',
          builder: (context, state) => Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => V3PageScaffold(
                title: '嵌套列表',
                fallbackRoute: '/source',
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) => const V3PageScaffold(
                          title: '嵌套详情',
                          fallbackRoute: '/source',
                          children: [],
                        ),
                      ),
                    ),
                    child: const Text('打开嵌套详情'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('打开嵌套页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开嵌套详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(find.text('嵌套列表'), findsOneWidget);
    expect(find.text('打开嵌套页面'), findsNothing);
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(find.text('打开嵌套页面'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('shared page shell keeps the standard horizontal margin', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: V3PageScaffold(
          title: '统一页面',
          showBack: false,
          children: [Text('内容')],
        ),
      ),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.fromLTRB(20, 10, 20, 28));
  });

  testWidgets('normal bottom bar does not duplicate its scroll clearance', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: V3PageScaffold(
          title: '固定操作页',
          showBack: false,
          bottomBar: SizedBox(height: 48, child: Text('继续')),
          children: [Text('页面内容')],
        ),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(scaffold.bottomNavigationBar, isNotNull);
    expect(list.padding, const EdgeInsets.fromLTRB(20, 10, 20, 28));
  });

  testWidgets('shared page shell lazily builds optional sliver content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: V3PageScaffold(
          title: '长对话',
          showBack: false,
          slivers: <Widget>[
            SliverList.builder(
              itemCount: 100,
              itemBuilder: (context, index) =>
                  SizedBox(height: 60, child: Text('消息 $index')),
            ),
          ],
        ),
      ),
    );

    final padding = tester.widget<SliverPadding>(find.byType(SliverPadding));
    expect(padding.padding, const EdgeInsets.fromLTRB(20, 10, 20, 28));
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.text('消息 0'), findsOneWidget);
    expect(find.text('消息 99'), findsNothing);
  });

  testWidgets(
    'upward scrolling dismisses the keyboard but downward scrolling keeps it',
    (tester) async {
      final scrollController = ScrollController();
      final focusNode = FocusNode();
      addTearDown(scrollController.dispose);
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: 280),
            ),
            child: V3KeyboardDismissOnUpwardScroll(
              child: Scaffold(
                body: ListView(
                  controller: scrollController,
                  children: [
                    TextField(focusNode: focusNode),
                    const SizedBox(height: 900),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      expect(focusNode.hasFocus, isTrue);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      scrollController.jumpTo(0);
      await tester.pump();
      await tester.tap(find.byType(TextField));
      scrollController.jumpTo(180);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 100));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
    },
  );

  testWidgets(
    'overlay bottom bar stays inside the body above scrolling content',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: V3PageScaffold(
            title: '资产详情',
            showBack: false,
            bottomBarOverlaysBody: true,
            bottomBar: SizedBox(
              key: ValueKey<String>('overlay-bottom-action'),
              height: 48,
              child: Text('点火'),
            ),
            children: [Text('资产正文')],
          ),
        ),
      );

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(scaffold.bottomNavigationBar, isNull);
      expect(
        find.byKey(const ValueKey<String>('overlay-bottom-action')),
        findsOneWidget,
      );
      expect(list.padding, const EdgeInsets.fromLTRB(20, 10, 20, 120));
    },
  );

  testWidgets('page-owned back delegate keeps the standard back affordance', (
    tester,
  ) async {
    var backCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: V3PageScaffold(
          title: '受保护采集页',
          fallbackRoute: '/v3/feed',
          onBack: () => backCalls += 1,
          children: const [Text('内容')],
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('返回'));

    expect(backCalls, 1);
    expect(find.text('受保护采集页'), findsOneWidget);
  });

  testWidgets('shared page shell paints an opaque theme canvas', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.dark(),
        home: const V3PageScaffold(
          title: '深度定位',
          showBack: false,
          children: [Text('稀疏内容')],
        ),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, HuahuoV3Theme.darkTokens.canvas);
  });

  testWidgets('flat and outlined cards stay shadow-free', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              V3Card(
                key: ValueKey('flat-card'),
                variant: V3CardVariant.flat,
                child: Text('平面'),
              ),
              V3Card(
                key: ValueKey('outlined-card'),
                variant: V3CardVariant.outlined,
                child: Text('描边'),
              ),
            ],
          ),
        ),
      ),
    );

    Material materialOf(String key) => tester.widget<Material>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Material),
      ),
    );

    final flat = materialOf('flat-card');
    final outlined = materialOf('outlined-card');
    expect(flat.elevation, 0);
    expect((flat.shape! as RoundedRectangleBorder).side, BorderSide.none);
    expect(outlined.elevation, 0);
    expect(
      (outlined.shape! as RoundedRectangleBorder).side.style,
      BorderStyle.solid,
    );
  });

  testWidgets('default cards retain their variant across home scopes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              V3Card(
                key: ValueKey('secondary-default-card'),
                child: Text('普通内容'),
              ),
              V3GlassHomeScope(
                child: V3Card(
                  key: ValueKey('focal-default-card'),
                  child: Text('焦点内容'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final secondary = find.byKey(
      const ValueKey<String>('secondary-default-card'),
    );
    expect(
      find.descendant(
        of: secondary,
        matching: find.byType(V3LiquidGlassSurface),
      ),
      findsOneWidget,
    );
    final material = tester.widget<Material>(
      find.descendant(of: secondary, matching: find.byType(Material)).first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(HuahuoV3Theme.cardRadius));
    expect(shape.side, BorderSide.none);
    expect(material.elevation, 0);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('focal-default-card')),
        matching: find.byType(V3LiquidGlassSurface),
      ),
      findsOneWidget,
    );
  });

  testWidgets('disabled secondary action does not invoke its callback', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3OutlineButton(
            label: '暂不可用',
            enabled: false,
            onPressed: () => calls += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.text('暂不可用'));
    expect(calls, 0);
  });

  testWidgets('top bar title remains centered with a trailing command', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3PageTopBar(
            title: '页面标题',
            showBack: false,
            actions: [
              IconButton(
                tooltip: '更多',
                onPressed: () {},
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getCenter(find.text('页面标题')).dx,
      moreOrLessEquals(
        tester.view.physicalSize.width / tester.view.devicePixelRatio / 2,
      ),
    );
  });

  testWidgets('compact top bar title clears four trailing actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3PageTopBar(
            title: '自由创作',
            actions: [
              const SizedBox.square(
                key: ValueKey('top-action-undo'),
                dimension: 44,
              ),
              const SizedBox.square(
                key: ValueKey('top-action-redo'),
                dimension: 44,
              ),
              const SizedBox.square(
                key: ValueKey('top-action-more'),
                dimension: 44,
              ),
              TextButton(
                key: const ValueKey('top-action-save'),
                onPressed: () {},
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );

    final titleRect = tester.getRect(find.text('自由创作'));
    for (final key in const <String>[
      'top-action-undo',
      'top-action-redo',
      'top-action-more',
      'top-action-save',
    ]) {
      expect(
        titleRect.overlaps(tester.getRect(find.byKey(ValueKey(key)))),
        isFalse,
        reason: 'title overlaps $key',
      );
    }
  });
}
