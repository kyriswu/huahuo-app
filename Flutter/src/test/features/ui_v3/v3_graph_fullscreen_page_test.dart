import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/app/performance/performance_policy.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_fullscreen_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_action_card.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_sphere_mesh_painter.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('fullscreen graph owns edge drags but preserves explicit back', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final library = KnowledgeLibraryController(initialNotes: const []);
    final graphRoute =
        buildAppRoutes(
          splashBuilder: (context, state) => const SizedBox(),
          restoreFailedBuilder: (context, state) => const SizedBox(),
          workspaceRetryBuilder: (context, state) => const SizedBox(),
        ).whereType<GoRoute>().singleWhere(
          (route) => route.path == '/v3/feed/graph',
        );
    final router = GoRouter(
      observers: [appRouteObserver],
      initialLocation: '/v3/feed',
      routes: [
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Scaffold(body: Text('思想图谱')),
        ),
        graphRoute,
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith(
            (ref) => FeedGraphController(library),
          ),
        ],
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.iOS),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    router.push<void>('/v3/feed/graph');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.timedDragFrom(
      const Offset(4, 400),
      const Offset(280, 0),
      const Duration(milliseconds: 100),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(V3GraphFullscreenPage), findsOneWidget);
    expect(router.canPop(), isTrue);
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(V3GraphFullscreenPage), findsNothing);
    router.push<void>('/v3/feed/graph');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(V3GraphFullscreenPage), findsNothing);
  });

  testWidgets('an empty sphere allocates its canvas only after visible entry', (
    tester,
  ) async {
    final library = KnowledgeLibraryController(initialNotes: const []);
    final repository = _StaticGraphRepository(
      GraphSnapshot(
        graphId: 'remote-graph',
        revision: 1,
        updatedAt: DateTime.utc(2026, 9, 9),
        nodes: const <V3GraphNode>[],
        edges: const <V3GraphEdge>[],
      ),
    );
    final graph = FeedGraphController(
      library,
      repository: repository,
      remoteGraphId: 'remote-graph',
    );
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, active, child) => V3InteractiveGraph(
                aggregated: false,
                active: active,
                height: 600,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('feed-graph-sphere-mesh')), findsNothing);
    expect(repository.requestCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(repository.requestCount, 1);
    final painter =
        tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('feed-graph-sphere-mesh')),
                )
                .painter!
            as V3GraphSphereMeshPainter;
    expect(painter.projection.topology.nodeCount, 72);
    expect(painter.projection.topology.realNodeCount, 0);
    final revision = painter.projection.revision;
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter.projection.revision, greaterThan(revision));
    visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('feed-graph-sphere-mesh')), findsNothing);
    expect(repository.requestCount, 1);
    expect(painter.projection.active, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('fullscreen graph is immersive without display toolbar', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final note = _note(id: 'refresh-note', title: '刷新节点');
    final library = KnowledgeLibraryController(initialNotes: [note]);
    library.depositContent(note.id);
    final graph = FeedGraphController(library);
    final router = await _pumpFullscreenGraph(
      tester,
      library: library,
      graph: graph,
    );
    addTearDown(router.dispose);

    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('graph-fullscreen-page')),
    );
    expect(scaffold.backgroundColor, Colors.white);
    expect(find.text('知识图谱'), findsOneWidget);
    expect(find.text('图谱暂时无法加载'), findsNothing);
    expect(find.bySemanticsLabel('返回'), findsOneWidget);
    expect(find.byType(V3InteractiveGraph), findsOneWidget);
    expect(
      tester.getSize(find.byType(V3InteractiveGraph)).height,
      closeTo(852, 1),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('feed-graph-interactive-viewer')))
          .height,
      greaterThan(760),
    );
    final graphWidget = tester.widget<V3InteractiveGraph>(
      find.byType(V3InteractiveGraph),
    );
    expect(graphWidget.aggregated, isTrue);
    expect(graphWidget.fullscreen, isTrue);
    expect(graphWidget.interactionsEnabled, isTrue);
    for (final key in const <String>[
      'feed-graph-aggregate',
      'feed-graph-edge-labels',
      'feed-graph-legend-toggle',
      'feed-graph-refresh',
      'feed-graph-fullscreen',
      'feed-graph-filter',
      'feed-graph-reset',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(
      find.byKey(const ValueKey('feed-graph-view-mode-tool')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('feed-graph-sphere-mesh')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<InteractiveViewer>(
            find.byKey(const ValueKey('feed-graph-interactive-viewer')),
          )
          .panEnabled,
      isFalse,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sphere rotates only while visible and pauses through touch cooldown',
    (tester) async {
      final note = _note(id: 'stable-sphere-note', title: '静态展示节点');
      final library = KnowledgeLibraryController(initialNotes: [note]);
      library.depositContent(note.id);
      final graph = FeedGraphController(library);
      final router = await _pumpFullscreenGraph(
        tester,
        library: library,
        graph: graph,
        animationsEnabled: true,
      );
      addTearDown(router.dispose);

      final mesh = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('feed-graph-sphere-mesh')),
      );
      final painter = mesh.painter! as V3GraphSphereMeshPainter;
      final beforeRevision = painter.projection.revision;
      final beforePosition = painter.projection.positionForId(note.id)!;
      await tester.pump(const Duration(milliseconds: 100));

      expect(painter.projection.revision, greaterThan(beforeRevision));
      expect(painter.projection.positionForId(note.id), isNot(beforePosition));
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('feed-graph-interactive-viewer')),
        ),
      );
      await tester.pump();
      final heldRevision = painter.projection.revision;
      await tester.pump(const Duration(seconds: 3));
      expect(painter.projection.revision, heldRevision);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(painter.projection.revision, heldRevision);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter.projection.revision, greaterThan(heldRevision));
      router.push('/v3/feed/items/${note.id}');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final coveredRevision = painter.projection.revision;
      await tester.pump(const Duration(seconds: 3));
      expect(painter.projection.active, isFalse);
      expect(painter.projection.revision, coveredRevision);
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter.projection.active, isTrue);
      expect(painter.projection.revision, greaterThan(coveredRevision));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'constrained sphere retains every note and only the visible neighbor mesh',
    (tester) async {
      final notes = List<V3FeedItem>.generate(
        160,
        (index) => _note(id: 'budget-note-$index', title: '预算节点 $index'),
      );
      final library = KnowledgeLibraryController(initialNotes: notes);
      for (final note in notes) {
        library.depositContent(note.id);
      }
      final graph = FeedGraphController(library);
      final router = await _pumpFullscreenGraph(
        tester,
        library: library,
        graph: graph,
        performancePolicy: const PerformancePolicy(
          visualQuality: AppVisualQuality.constrained,
          graphVisualQuality: AppVisualQuality.constrained,
          graphNodeBudget: 32,
          graphEdgeBudget: 48,
          allowIdleAnimation: false,
          allowImagePrefetch: false,
          maxNetworkConcurrency: 1,
          maxCpuJobs: 1,
          backgroundPollFloor: Duration(minutes: 15),
        ),
      );
      addTearDown(router.dispose);

      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('feed-graph-sphere-mesh')),
                  )
                  .painter!
              as V3GraphSphereMeshPainter;
      expect(graph.nodes.length, greaterThan(32));
      expect(painter.projection.topology.nodeIds, hasLength(160));
      expect(painter.projection.topology.realNodeCount, 160);
      expect(painter.projection.topology.semanticEdgeIds, isEmpty);
      expect(
        find.byKey(const ValueKey('feed-graph-edge-canvas')),
        findsNothing,
      );
    },
  );

  testWidgets('fullscreen graph stops visual work while app is inactive', (
    tester,
  ) async {
    final note = _note(id: 'inactive-note', title: '后台静止节点');
    final library = KnowledgeLibraryController(initialNotes: [note]);
    library.depositContent(note.id);
    final graph = FeedGraphController(library);
    final router = await _pumpFullscreenGraph(
      tester,
      library: library,
      graph: graph,
      animationsEnabled: true,
    );
    addTearDown(router.dispose);

    final painter =
        tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('feed-graph-sphere-mesh')),
                )
                .painter!
            as V3GraphSphereMeshPainter;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final inactiveRevision = painter.projection.revision;
    await tester.pump(const Duration(seconds: 2));

    expect(painter.projection.revision, inactiveRevision);
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen graph follows the active semantic canvas', (
    tester,
  ) async {
    final library = KnowledgeLibraryController(initialNotes: const []);
    final graph = FeedGraphController(library);
    final router = await _pumpFullscreenGraph(
      tester,
      library: library,
      graph: graph,
      theme: HuahuoV3Theme.dark(),
    );
    addTearDown(router.dispose);

    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('graph-fullscreen-page')),
    );
    expect(scaffold.backgroundColor, HuahuoV3Theme.darkTokens.canvas);
    expect(
      find.descendant(
        of: find.byType(V3InteractiveGraph),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.color == HuahuoV3Theme.darkTokens.canvas,
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('node card clears on canvas and opens detail and chat routes', (
    tester,
  ) async {
    final note = _note(id: 'node/id ?', title: '可操作节点');
    final library = KnowledgeLibraryController(initialNotes: [note]);
    library.depositContent(note.id);
    final graph = FeedGraphController(library);
    final router = await _pumpFullscreenGraph(
      tester,
      library: library,
      graph: graph,
    );
    addTearDown(router.dispose);

    final interactiveGraph = tester.widget<V3InteractiveGraph>(
      find.byType(V3InteractiveGraph),
    );
    final node = graph.nodes.firstWhere((candidate) => candidate.id == note.id);
    interactiveGraph.onNodeTap!(node);
    await tester.pump();

    expect(find.byType(V3GraphNodeActionCard), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(V3GraphNodeActionCard),
        matching: find.text('可操作节点'),
      ),
      findsOneWidget,
    );

    interactiveGraph.onSelectedNodeTap!(node);
    await tester.pumpAndSettle();
    expect(find.text('detail:node/id ?'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    interactiveGraph.onCanvasTap!();
    await tester.pump();
    expect(graph.selectedNodeId, isNull);
    expect(find.byType(V3GraphNodeActionCard), findsNothing);

    expect(
      find.byKey(const ValueKey('feed-graph-relation-detail-sheet')),
      findsNothing,
    );

    interactiveGraph.onNodeLongPress!(node);
    await tester.pump();
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('detail:node/id ?'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('聊一聊'));
    await tester.pumpAndSettle();
    expect(find.text('chat:node/id ?'), findsOneWidget);
  });

  testWidgets(
    'remote entity opens metadata detail without a local action card',
    (tester) async {
      final library = KnowledgeLibraryController(initialNotes: const []);
      final graph = FeedGraphController(
        library,
        repository: _StaticGraphRepository(_remoteEntitySnapshot()),
        remoteGraphId: 'remote-entity-graph',
      );
      await graph.refreshGraph();
      final router = await _pumpFullscreenGraph(
        tester,
        library: library,
        graph: graph,
      );
      addTearDown(router.dispose);

      final interactiveGraph = tester.widget<V3InteractiveGraph>(
        find.byType(V3InteractiveGraph),
      );
      final entity = graph.nodeForId('remote-person')!;
      interactiveGraph.onNodeTap!(entity);
      await tester.pumpAndSettle();

      expect(graph.selectedNodeId, entity.id);
      expect(find.byType(V3GraphNodeActionCard), findsNothing);
      expect(
        find.byKey(const ValueKey('feed-graph-node-detail-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('graph-node-detail-title-remote-person')),
        findsOneWidget,
      );
      expect(find.text('Person'), findsOneWidget);
      expect(find.textContaining('Person ·'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('feed-graph-node-detail-sheet')),
        const Offset(0, -320),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('合作于'), findsOneWidget);
    },
  );

  testWidgets('remote contentId resolves an existing local note action card', (
    tester,
  ) async {
    final note = _note(id: 'local-content', title: '本地关联笔记');
    final library = KnowledgeLibraryController(initialNotes: [note]);
    library.depositContent(note.id);
    final snapshot = GraphSnapshot(
      graphId: 'content-alias-graph',
      revision: 8,
      updatedAt: DateTime.utc(2026, 7, 23),
      nodes: const <V3GraphNode>[
        V3GraphNode(
          id: 'remote-alias',
          contentId: 'local-content',
          label: '远端别名实体',
          cluster: V3GraphCluster.viewpoint,
          position: Offset(160, 180),
          summary: '通过 contentId 指向本地内容。',
          entityType: 'Topic',
        ),
      ],
      edges: const <V3GraphEdge>[],
    );
    final graph = FeedGraphController(
      library,
      repository: _StaticGraphRepository(snapshot),
      remoteGraphId: snapshot.graphId,
    );
    await graph.refreshGraph();
    final router = await _pumpFullscreenGraph(
      tester,
      library: library,
      graph: graph,
    );
    addTearDown(router.dispose);

    final interactiveGraph = tester.widget<V3InteractiveGraph>(
      find.byType(V3InteractiveGraph),
    );
    interactiveGraph.onNodeTap!(graph.nodeForId('remote-alias')!);
    await tester.pump();

    expect(find.byType(V3GraphNodeActionCard), findsOneWidget);
    expect(find.text('本地关联笔记'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-node-detail-sheet')),
      findsNothing,
    );
  });

  testWidgets(
    'memory pressure releases and rebuilds sphere projection buffers',
    (tester) async {
      final note = _note(id: 'memory-note', title: '内存压力节点');
      final library = KnowledgeLibraryController(initialNotes: [note]);
      library.depositContent(note.id);
      final graph = FeedGraphController(library);
      final router = await _pumpFullscreenGraph(
        tester,
        library: library,
        graph: graph,
      );
      addTearDown(router.dispose);

      V3GraphSphereMeshPainter meshPainter() =>
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('feed-graph-sphere-mesh')),
                  )
                  .painter!
              as V3GraphSphereMeshPainter;
      final first = meshPainter().projection.projectedX;
      expect(meshPainter().projection.projectedX, same(first));

      final context = tester.element(find.byType(V3InteractiveGraph));
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appActivityCoordinatorProvider).didHaveMemoryPressure();
      await tester.pump();

      expect(meshPainter().projection.projectedX, isNot(same(first)));
      expect(meshPainter().projection.topology.realNodeCount, 1);
      expect(find.byType(V3InteractiveGraph), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<GoRouter> _pumpFullscreenGraph(
  WidgetTester tester, {
  required KnowledgeLibraryController library,
  required FeedGraphController graph,
  ThemeData? theme,
  bool animationsEnabled = false,
  PerformancePolicy? performancePolicy,
  RuntimeActivityMetrics? runtimeMetrics,
}) async {
  final router = GoRouter(
    observers: [appRouteObserver],
    initialLocation: '/v3/feed/graph',
    routes: [
      GoRoute(
        path: '/v3/feed',
        builder: (context, state) => const Scaffold(body: Text('思想图谱')),
      ),
      GoRoute(
        path: '/v3/feed/graph',
        builder: (context, state) => const V3GraphFullscreenPage(),
      ),
      GoRoute(
        path: '/v3/feed/items/:itemId',
        builder: (context, state) =>
            Scaffold(body: Text('detail:${state.pathParameters['itemId']}')),
      ),
      GoRoute(
        path: '/v3/feed/chat',
        builder: (context, state) =>
            Scaffold(body: Text('chat:${state.uri.queryParameters['itemId']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        feedGraphControllerProvider.overrideWith((ref) => graph),
        if (performancePolicy != null)
          performancePolicyProvider.overrideWithValue(performancePolicy),
        if (runtimeMetrics != null)
          runtimeActivityMetricsProvider.overrideWithValue(runtimeMetrics),
      ],
      child: MaterialApp.router(
        theme: theme ?? HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: !animationsEnabled),
          child: child!,
        ),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return router;
}

V3FeedItem _note({required String id, required String title}) => V3FeedItem(
  id: id,
  title: title,
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 7, 23),
  rawBody: '用于验证全屏图谱节点操作。',
  summaryBody: '全屏图谱节点摘要',
);

final class _StaticGraphRepository implements GraphRepository {
  _StaticGraphRepository(this.snapshot);

  final GraphSnapshot snapshot;
  int requestCount = 0;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async {
    requestCount += 1;
    return snapshot;
  }
}

GraphSnapshot _remoteEntitySnapshot() => GraphSnapshot(
  graphId: 'remote-entity-graph',
  revision: 7,
  updatedAt: DateTime.utc(2026, 7, 23),
  nodes: const <V3GraphNode>[
    V3GraphNode(
      id: 'remote-person',
      label: '远端人物',
      cluster: V3GraphCluster.industry,
      position: Offset(120, 160),
      summary: '来自远端知识图谱的实体摘要。',
      entityType: 'Person',
      materialSourceProvided: false,
      labels: <String>['人物'],
    ),
    V3GraphNode(
      id: 'remote-team',
      label: '远端团队',
      cluster: V3GraphCluster.industry,
      position: Offset(280, 250),
      summary: '远端组织实体。',
      entityType: 'Organization',
      materialSourceProvided: false,
    ),
  ],
  edges: const <V3GraphEdge>[
    V3GraphEdge(
      id: 'remote-cooperation',
      sourceId: 'remote-person',
      targetId: 'remote-team',
      kind: V3GraphRelationKind.other,
      label: '合作于',
      directed: true,
    ),
  ],
);
