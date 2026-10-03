import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_fullscreen_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:integration_test/integration_test.dart';

const _overviewScreenshot = 'graph_mirofish_01_overview_actual';
const _parallelScreenshot = 'graph_mirofish_02_parallel_near_actual';
const _selfLoopScreenshot = 'graph_mirofish_03_self_loops_actual';
const _statusScreenshot = 'graph_mirofish_05_building_status_actual';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures MiroFish graph parity states on the real renderer', (
    tester,
  ) async {
    final fixture = _MiroFishFixture.build();
    final library = KnowledgeLibraryController(initialNotes: const []);
    final graph = FeedGraphController(
      library,
      repository: _FixtureGraphRepository(fixture.snapshot),
      remoteGraphId: fixture.snapshot.graphId,
    );
    await graph.refreshGraph();

    expect(graph.loadingState, GraphLoadingState.ready);
    expect(graph.nodes, hasLength(20));
    expect(graph.semanticEdges, hasLength(50));
    expect(graph.semanticEdges.where((edge) => edge.isSelfLoop), hasLength(5));
    expect(fixture.parallelEdges, hasLength(5));
    expect(fixture.parallelEdges.where((edge) => edge.directed), isNotEmpty);

    // Mark fixture positions as intentional so the renderer starts from the
    // same topology on every simulator run before Forge2D settles it.
    for (final node in fixture.nodes) {
      graph.setNodePosition(node.id, node.position);
    }

    final router = _buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await _settleGraph(tester);

    expect(find.byKey(const ValueKey('graph-fullscreen-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    final viewerSize = tester.getSize(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    final deviceSize = MediaQuery.sizeOf(
      tester.element(find.byType(V3GraphFullscreenPage)),
    );
    debugPrint('graph-mirofish-viewport=$viewerSize device=$deviceSize');
    expect(viewerSize.height, greaterThanOrEqualTo(deviceSize.height * .9));
    expect(
      find.byKey(const ValueKey('feed-graph-sphere-mesh')),
      findsOneWidget,
    );
    for (final key in const <String>[
      'feed-graph-aggregate',
      'feed-graph-edge-labels',
      'feed-graph-legend-toggle',
      'feed-graph-refresh',
      'feed-graph-fullscreen',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    await _capture(binding, tester, _overviewScreenshot);

    graph.selectEdge('parallel-2');
    await tester.pump();
    await _focusOnNodes(tester, const <String>[
      'node-0',
      'node-1',
    ], scale: 2.22);
    expect(graph.selectedEdgeId, 'parallel-2');
    expect(graph.showEdgeLabels, isTrue);
    await _capture(binding, tester, _parallelScreenshot);

    graph.selectEdge('self-loop-2');
    await tester.pump();
    await _focusOnNodes(tester, const <String>['node-4'], scale: 2.38);
    expect(graph.selectedEdgeId, 'self-loop-2');
    await _capture(binding, tester, _selfLoopScreenshot);

    graph.clearSelection();
    await tester.pump();
    router.go('/building');
    await _pumpFrames(tester, 8);
    expect(
      find.byKey(const ValueKey('feed-graph-status-building')),
      findsOneWidget,
    );
    expect(find.text('正在构建关系'), findsOneWidget);
    await _capture(binding, tester, _statusScreenshot);
  });
}

GoRouter _buildRouter() => GoRouter(
  initialLocation: '/graph',
  routes: [
    GoRoute(
      path: '/graph',
      builder: (context, state) => const V3GraphFullscreenPage(),
    ),
    GoRoute(
      path: '/building',
      builder: (context, state) => const _BuildingGraphPage(),
    ),
    GoRoute(
      path: '/v3/feed',
      builder: (context, state) => const Scaffold(body: Text('思想图谱')),
    ),
    GoRoute(
      path: '/v3/feed/note',
      builder: (context, state) => const Scaffold(body: Text('新建笔记')),
    ),
  ],
);

class _BuildingGraphPage extends StatelessWidget {
  const _BuildingGraphPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SizedBox.expand(
      child: Stack(
        children: [
          const Positioned.fill(
            child: V3InteractiveGraph(
              aggregated: false,
              aggregating: true,
              aggregationProgress: .58,
              fullscreen: true,
              height: double.infinity,
            ),
          ),
          SafeArea(
            bottom: false,
            child: V3PageTopBar(
              title: '知识图谱构建',
              onBack: () => context.go('/graph'),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _focusOnNodes(
  WidgetTester tester,
  List<String> nodeIds, {
  required double scale,
}) async {
  final viewerFinder = find.byKey(
    const ValueKey('feed-graph-interactive-viewer'),
  );
  final viewer = tester.widget<InteractiveViewer>(viewerFinder);
  final transformationController = viewer.transformationController!;
  final viewportTopLeft = tester.getTopLeft(viewerFinder);
  final viewportSize = tester.getSize(viewerFinder);
  var viewportPoint = Offset.zero;
  for (final nodeId in nodeIds) {
    viewportPoint +=
        tester.getCenter(find.byKey(ValueKey(nodeId))) - viewportTopLeft;
  }
  viewportPoint /= nodeIds.length.toDouble();
  final scenePoint = transformationController.toScene(viewportPoint);
  final target = Offset(viewportSize.width * .46, viewportSize.height * .48);
  transformationController.value = Matrix4.identity()
    ..setEntry(0, 0, scale)
    ..setEntry(1, 1, scale)
    ..setEntry(0, 3, target.dx - scenePoint.dx * scale)
    ..setEntry(1, 3, target.dy - scenePoint.dy * scale);
  await _pumpFrames(tester, 12);
  expect(
    transformationController.value.getMaxScaleOnAxis(),
    closeTo(scale, .01),
  );
}

Future<void> _settleGraph(WidgetTester tester) => _pumpFrames(tester, 54);

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await _pumpFrames(tester, 7);
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty, reason: name);
}

final class _FixtureGraphRepository implements GraphRepository {
  const _FixtureGraphRepository(this.snapshot);

  final GraphSnapshot snapshot;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async => snapshot;
}

final class _MiroFishFixture {
  const _MiroFishFixture({
    required this.snapshot,
    required this.nodes,
    required this.parallelEdges,
  });

  factory _MiroFishFixture.build() {
    const entityTypes = <String>['人物', '组织', '项目', '观点', '方法', '案例'];
    const labels = <String>[
      '商业顾问访谈',
      'AI 落地项目',
      '制造业客户',
      '增长方法论',
      '项目复盘中心',
      '数据治理',
      '组织协同',
      '交付流程',
      '客户成功',
      '行业趋势',
      '访谈证据',
      '解决方案',
      '业务价值',
      '产品能力',
      '案例验证',
      '决策角色',
      '采购路径',
      '风险清单',
      '实施计划',
      '复用模板',
    ];
    const sources = <V3MaterialSource>[
      V3MaterialSource.meeting,
      V3MaterialSource.note,
      V3MaterialSource.link,
      V3MaterialSource.documentImport,
      V3MaterialSource.recordingCard,
    ];
    final nodes = List<V3GraphNode>.generate(20, (index) {
      final angle = math.pi * 2 * index / 20;
      return V3GraphNode(
        id: 'node-$index',
        label: labels[index],
        cluster: V3GraphCluster.values[index % V3GraphCluster.values.length],
        position: Offset(
          450 + math.cos(angle) * (index.isEven ? 330 : 270),
          420 + math.sin(angle) * (index.isEven ? 300 : 238),
        ),
        summary: '${labels[index]}的固定知识图谱验收摘要。',
        entityType: entityTypes[index % entityTypes.length],
        attributes: <String, Object?>{
          'priority': index % 4 + 1,
          'fixture': 'mirofish-parity',
        },
        labels: <String>[entityTypes[index % entityTypes.length], '验收节点'],
        contentId: 'content-$index',
        weight: 1 + (index % 5) * .16,
        source: sources[index % sources.length],
        updatedAt: DateTime.utc(2026, 7, 23, 8, index),
        topics: const <String>['MiroFish', '知识图谱'],
        isHotspot: index == 9,
        isAggregated: index == 4,
        isRecent: index < 4,
      );
    }, growable: false);

    final parallelEdges = List<V3GraphEdge>.generate(5, (index) {
      final reverse = index == 2 || index == 4;
      const names = <String>['共同参与', '客户合作', '反向反馈', '引用案例', '验证结论'];
      return _edge(
        id: 'parallel-$index',
        source: reverse ? 1 : 0,
        target: reverse ? 0 : 1,
        kind: V3GraphRelationKind.values[(index + 1) % 5],
        label: names[index],
        directed: index != 3,
        weight: 1.35 + index * .08,
      );
    }, growable: false);
    final selfLoops = List<V3GraphEdge>.generate(
      5,
      (index) => _edge(
        id: 'self-loop-$index',
        source: 4,
        target: 4,
        kind: index.isEven
            ? V3GraphRelationKind.sharedTopic
            : V3GraphRelationKind.other,
        label: '自我复盘 ${index + 1}',
        directed: true,
        weight: 1.1 + index * .06,
      ),
      growable: false,
    );
    final ringEdges = List<V3GraphEdge>.generate(
      20,
      (index) => _edge(
        id: 'ring-$index',
        source: index,
        target: (index + 1) % 20,
        kind: V3GraphRelationKind.values[index % 5],
        label: index.isEven ? '推动' : '支撑',
        directed: index.isEven,
        weight: .88 + (index % 4) * .09,
      ),
      growable: false,
    );
    final chordEdges = List<V3GraphEdge>.generate(
      20,
      (index) => _edge(
        id: 'chord-$index',
        source: index,
        target: (index + 5) % 20,
        kind: V3GraphRelationKind.values[(index + 2) % 5],
        label: index % 3 == 0 ? '关键依据' : '语义关联',
        directed: index % 3 != 1,
        weight: .72 + (index % 5) * .08,
      ),
      growable: false,
    );
    final edges = <V3GraphEdge>[
      ...parallelEdges,
      ...selfLoops,
      ...ringEdges,
      ...chordEdges,
    ];
    return _MiroFishFixture(
      snapshot: GraphSnapshot(
        graphId: 'mirofish-parity-20-50',
        nodes: nodes,
        edges: edges,
        revision: 95,
        updatedAt: DateTime.utc(2026, 7, 23, 9, 30),
      ),
      nodes: List<V3GraphNode>.unmodifiable(nodes),
      parallelEdges: List<V3GraphEdge>.unmodifiable(parallelEdges),
    );
  }

  final GraphSnapshot snapshot;
  final List<V3GraphNode> nodes;
  final List<V3GraphEdge> parallelEdges;
}

V3GraphEdge _edge({
  required String id,
  required int source,
  required int target,
  required V3GraphRelationKind kind,
  required String label,
  required bool directed,
  required double weight,
}) => V3GraphEdge(
  id: id,
  sourceId: 'node-$source',
  targetId: 'node-$target',
  kind: kind,
  label: label,
  fact: '固定验收事实：$label连接节点 $source 与节点 $target。',
  attributes: <String, Object?>{
    'confidence': double.parse(
      (weight / 1.6).clamp(.45, .98).toStringAsFixed(2),
    ),
    'fixture': 'mirofish-parity',
  },
  episodes: const <String>['2026-07-23 固定验收资料'],
  weight: weight,
  directed: directed,
  createdAt: DateTime.utc(2026, 7, 23, 8),
  validAt: DateTime.utc(2026, 7, 23, 9),
);
