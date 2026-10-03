import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_sphere_mesh_painter.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';

void main() {
  testWidgets('self-loop aggregate visuals never select a relation', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(430, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final library = KnowledgeLibraryController(initialNotes: const []);
    final snapshot = _selfLoopSnapshot();
    final graph = FeedGraphController(
      library,
      repository: _FixtureGraphRepository(snapshot),
      remoteGraphId: snapshot.graphId,
    );
    await graph.refreshGraph();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 430,
                height: 520,
                child: V3InteractiveGraph(aggregated: false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 320));

    final graphRect = tester.getRect(find.byType(V3InteractiveGraph));
    final painter = _meshPainter(tester);
    final projection = painter.projection;
    final topology = projection.topology;
    expect(graph.semanticEdges, hasLength(5));
    expect(topology.semanticEdgeIds, isEmpty);
    expect(find.byKey(const ValueKey('feed-graph-edge-canvas')), findsNothing);
    for (var index = 0; index < topology.visualLinkSources.length; index++) {
      expect(
        topology.visualLinkSources[index],
        isNot(topology.visualLinkTargets[index]),
      );
    }
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    final realPositions = [
      for (final id in ['loop-node']) projection.positionForId(id)!,
    ];
    final synthetic = List.generate(topology.nodeCount, (index) => index)
        .firstWhere(
          (index) =>
              topology.isSynthetic(index) &&
              realPositions.every(
                (position) =>
                    (position - projection.positionAt(index)).distance > 45,
              ),
        );
    await tester.tapAt(
      _toGlobal(
        graphRect: graphRect,
        transform: viewer.transformationController!.value,
        scenePosition: projection.positionAt(synthetic),
      ),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(graph.selectedNodeId, isNull);
    expect(graph.selectedEdgeId, isNull);
    expect(
      find.byKey(const ValueKey('feed-graph-relation-detail-sheet')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

GraphSnapshot _selfLoopSnapshot() => GraphSnapshot(
  graphId: 'self-loop-interaction-fixture',
  revision: 1,
  updatedAt: DateTime.utc(2026, 7, 23),
  nodes: const [
    V3GraphNode(
      id: 'loop-node',
      label: '复盘节点',
      cluster: V3GraphCluster.method,
      position: Offset(450, 430),
      summary: '承载五条可解释自关系',
      entityType: '笔记',
    ),
  ],
  edges: const [
    V3GraphEdge(
      id: 'loop-1',
      sourceId: 'loop-node',
      targetId: 'loop-node',
      kind: V3GraphRelationKind.other,
      label: '复盘',
    ),
    V3GraphEdge(
      id: 'loop-2',
      sourceId: 'loop-node',
      targetId: 'loop-node',
      kind: V3GraphRelationKind.linkedMaterial,
      label: '引用自己',
    ),
    V3GraphEdge(
      id: 'loop-3',
      sourceId: 'loop-node',
      targetId: 'loop-node',
      kind: V3GraphRelationKind.sharedTopic,
      label: '主题回环',
    ),
    V3GraphEdge(
      id: 'loop-4',
      sourceId: 'loop-node',
      targetId: 'loop-node',
      kind: V3GraphRelationKind.sharedContentLine,
      label: '内容延续',
    ),
    V3GraphEdge(
      id: 'loop-5',
      sourceId: 'loop-node',
      targetId: 'loop-node',
      kind: V3GraphRelationKind.communityAffinity,
      label: '自我关联',
      directed: true,
    ),
  ],
);

Offset _toGlobal({
  required Rect graphRect,
  required Matrix4 transform,
  required Offset scenePosition,
}) {
  const sceneOrigin = Offset(240, 240);
  return graphRect.topLeft +
      MatrixUtils.transformPoint(transform, scenePosition + sceneOrigin);
}

V3GraphSphereMeshPainter _meshPainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('feed-graph-sphere-mesh')),
            )
            .painter!
        as V3GraphSphereMeshPainter;

final class _FixtureGraphRepository implements GraphRepository {
  const _FixtureGraphRepository(this.snapshot);

  final GraphSnapshot snapshot;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async => snapshot;
}
