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
  testWidgets('parallel relation paths never intercept canvas taps', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(430, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final library = KnowledgeLibraryController(initialNotes: const []);
    final snapshot = _parallelSnapshot();
    final graph = FeedGraphController(
      library,
      repository: _FixtureGraphRepository(snapshot),
      remoteGraphId: snapshot.graphId,
    );
    await graph.refreshGraph();
    var canvasTapCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 430,
                height: 520,
                child: V3InteractiveGraph(
                  aggregated: false,
                  onCanvasTap: () => canvasTapCount++,
                ),
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
      for (final id in ['a', 'b']) projection.positionForId(id)!,
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
    expect(canvasTapCount, 1);
    await tester.tap(find.byKey(const ValueKey('b')));
    await tester.pump(const Duration(milliseconds: 320));
    expect(graph.selectedNodeId, 'b');
    graph.setShowEdgeLabels(false);
    await tester.pump(const Duration(milliseconds: 320));
    expect(_meshPainter(tester).projection.topology, same(topology));
    await tester.tapAt(graphRect.topLeft + const Offset(20, 490));
    await tester.pump(const Duration(milliseconds: 320));
    expect(graph.selectedNodeId, isNull);
    expect(graph.selectedEdgeId, isNull);
    expect(canvasTapCount, 2);
    expect(tester.takeException(), isNull);
  });
}

GraphSnapshot _parallelSnapshot() => GraphSnapshot(
  graphId: 'parallel-interaction-fixture',
  revision: 1,
  updatedAt: DateTime.utc(2026, 7, 23),
  nodes: const [
    V3GraphNode(
      id: 'a',
      label: '甲节点',
      cluster: V3GraphCluster.viewpoint,
      position: Offset(280, 430),
      summary: '多重关系起点',
      entityType: '人物',
    ),
    V3GraphNode(
      id: 'b',
      label: '乙节点',
      cluster: V3GraphCluster.viewpoint,
      position: Offset(620, 430),
      summary: '多重关系终点',
      entityType: '人物',
    ),
  ],
  edges: const [
    V3GraphEdge(
      id: 'parallel-1',
      sourceId: 'a',
      targetId: 'b',
      kind: V3GraphRelationKind.linkedMaterial,
      label: '引用',
      directed: true,
    ),
    V3GraphEdge(
      id: 'parallel-2',
      sourceId: 'a',
      targetId: 'b',
      kind: V3GraphRelationKind.sharedTopic,
      label: '共同主题',
    ),
    V3GraphEdge(
      id: 'parallel-3',
      sourceId: 'a',
      targetId: 'b',
      kind: V3GraphRelationKind.communityAffinity,
      label: '语义关联',
    ),
    V3GraphEdge(
      id: 'parallel-4',
      sourceId: 'a',
      targetId: 'b',
      kind: V3GraphRelationKind.sharedContentLine,
      label: '同一内容线',
    ),
    V3GraphEdge(
      id: 'parallel-5',
      sourceId: 'b',
      targetId: 'a',
      kind: V3GraphRelationKind.other,
      label: '反向关注',
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
