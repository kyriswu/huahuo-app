import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_layout.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_projection_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_render_topology.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_painter.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerLargeGraphPerformanceSuite();
}

void registerLargeGraphPerformanceSuite() {
  for (final scenario in const <_GraphScaleScenario>[
    _GraphScaleScenario(name: 'normal', nodeCount: 100, edgeCount: 200),
    _GraphScaleScenario(name: 'pressure', nodeCount: 250, edgeCount: 500),
    _GraphScaleScenario(name: 'target', nodeCount: 500, edgeCount: 1500),
    _GraphScaleScenario(name: 'target-max', nodeCount: 500, edgeCount: 3000),
  ]) {
    testWidgets(
      '${scenario.name} graph keeps data and bounded rendering work',
      (_) async {
        final fixture = _LargeGraphFixture.build(scenario);
        final timings = <String, Duration>{};
        final library = KnowledgeLibraryController(initialNotes: const []);
        final graph = FeedGraphController(
          library,
          repository: _FixtureGraphRepository(fixture.snapshot),
          remoteGraphId: fixture.snapshot.graphId,
        );
        addTearDown(() {
          graph.dispose();
          library.dispose();
        });

        final snapshotWatch = Stopwatch()..start();
        await graph.refreshGraph();
        snapshotWatch.stop();
        timings['snapshot'] = snapshotWatch.elapsed;

        expect(graph.loadingState, GraphLoadingState.ready);
        expect(graph.nodes, hasLength(scenario.nodeCount));
        expect(graph.semanticEdges, hasLength(scenario.edgeCount));

        const sphereLayout = SphereGraphLayout();
        late SphereGraphRenderTopology topology;
        timings['sphere-topology'] = _measure(() {
          final points = sphereLayout.build(
            realNodeIds: graph.nodes.map((node) => node.id),
            minimumVisualNodeCount: 72,
          );
          topology = SphereGraphRenderTopology.build(
            points: points,
            visualLinks: sphereLayout.buildVisualLinks(
              points: points,
              neighborsPerPoint: 1,
            ),
            semanticEdges: graph.semanticEdges,
          );
        });
        final projection = SphereGraphProjectionController()
          ..updateTopology(topology, notify: false);
        addTearDown(projection.dispose);
        projection.project(
          viewport: const Size(390, 520),
          rotationX: 0,
          rotationY: 0,
          notify: false,
        );
        final projectionX = projection.projectedX;
        final projectionOrder = projection.drawOrder;
        timings['sphere-project-120'] = _measure(() {
          for (var frame = 1; frame <= 120; frame++) {
            projection.project(
              viewport: const Size(390, 520),
              rotationX: frame * .003,
              rotationY: frame * .006,
              notify: false,
            );
          }
        });
        expect(projection.projectedX, same(projectionX));
        expect(projection.drawOrder, same(projectionOrder));
        expect(projection.positions, hasLength(scenario.nodeCount));
        expect(
          graph.semanticEdges.map((edge) => edge.id).toSet(),
          fixture.edges.map((edge) => edge.id).toSet(),
        );
        expect(
          graph.layoutEdges.length,
          lessThanOrEqualTo(scenario.edgeCount ~/ 2),
        );
        expect(
          graph.layoutEdges.fold<int>(
            0,
            (total, edge) =>
                total + (edge.attributes['semanticEdgeCount']! as int),
          ),
          scenario.edgeCount,
          reason: 'layout aggregation must account for every semantic edge',
        );

        expect(
          v3GraphUsesDenseCanvas(
            nodeCount: scenario.nodeCount,
            edgeCount: scenario.edgeCount,
          ),
          scenario.isDense,
        );
        if (scenario.isDense) {
          _exerciseDensePainter(
            fixture: fixture,
            graph: graph,
            timings: timings,
          );
        }

        debugPrint(_timingReport(scenario, graph, timings));
      },
    );
  }
}

void _exerciseDensePainter({
  required _LargeGraphFixture fixture,
  required FeedGraphController graph,
  required Map<String, Duration> timings,
}) {
  final selectedId = fixture.nodes.last.id;
  final searchIds = <String>{fixture.nodes[1].id, fixture.nodes[2].id};
  final roles = <String, V3GraphNodeRole>{
    for (final node in fixture.nodes) node.id: graph.roleForNode(node.id),
  };
  final overlayIds = v3GraphDenseOverlayNodeIds(
    nodes: fixture.nodes,
    roles: roles,
    selectedNodeId: selectedId,
    searchMatchNodeIds: searchIds,
  );
  final overlayIdsWithoutSelection = v3GraphDenseOverlayNodeIds(
    nodes: fixture.nodes,
    roles: roles,
    searchMatchNodeIds: searchIds,
  );
  expect(overlayIds, overlayIdsWithoutSelection);
  expect(overlayIds, containsAll(searchIds));
  expect(overlayIds.length, lessThanOrEqualTo(8));
  final labelNodeIds = <String>{
    for (final node in fixture.nodes)
      if (!overlayIds.contains(node.id) && !node.center) node.id,
  }.take(12).toSet();

  final repaint = ChangeNotifier();
  final recorder = PictureRecorder();
  final painter = V3GraphNodePainter(
    repaint: repaint,
    resolvePositions: () => fixture.positions,
    resolveZoom: () => 2,
    sceneOrigin: Offset.zero,
    nodes: fixture.nodes,
    nodeRadii: fixture.radii,
    nodeColors: const <String, Color>{},
    nodeOpacities: const <String, double>{},
    nodeDepths: <String, double>{for (final node in fixture.nodes) node.id: 1},
    overlayNodeIds: overlayIds,
    showAllLabels: true,
    labelNodeIds: labelNodeIds,
  );
  timings['dense-paint'] = _measure(
    () => painter.paint(Canvas(recorder), const Size(1000, 900)),
  );
  recorder.endRecording().dispose();
  expect(painter.paintedLabelCount, labelNodeIds.length);
  repaint.dispose();
}

Duration _measure(void Function() action) {
  final stopwatch = Stopwatch()..start();
  action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

String _timingReport(
  _GraphScaleScenario scenario,
  FeedGraphController graph,
  Map<String, Duration> timings,
) {
  final values = timings.entries
      .map((entry) => '${entry.key}=${entry.value.inMicroseconds}us')
      .join(', ');
  return 'graph-performance ${scenario.nodeCount}/${scenario.edgeCount}: '
      'semantic=${graph.semanticEdges.length}, '
      'layout=${graph.layoutEdges.length}, '
      '$values';
}

final class _FixtureGraphRepository implements GraphRepository {
  const _FixtureGraphRepository(this.snapshot);

  final GraphSnapshot snapshot;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async => snapshot;
}

final class _GraphScaleScenario {
  const _GraphScaleScenario({
    required this.name,
    required this.nodeCount,
    required this.edgeCount,
  });

  final String name;
  final int nodeCount;
  final int edgeCount;

  bool get isDense => nodeCount > 120 || edgeCount > 300;
}

final class _LargeGraphFixture {
  const _LargeGraphFixture({
    required this.snapshot,
    required this.nodes,
    required this.edges,
    required this.positions,
    required this.radii,
  });

  factory _LargeGraphFixture.build(_GraphScaleScenario scenario) {
    final columns = math.sqrt(scenario.nodeCount).ceil();
    final nodes = List<V3GraphNode>.generate(scenario.nodeCount, (index) {
      final position = Offset(
        36 + (index % columns) * 54,
        36 + (index ~/ columns) * 50,
      );
      return V3GraphNode(
        id: 'node-$index',
        label: '节点 $index',
        cluster: V3GraphCluster.values[index % V3GraphCluster.values.length],
        position: position,
        summary: '大规模图谱固定测试节点 $index',
        entityType: index.isEven ? 'Note' : 'Topic',
        weight: 1 + (index % 5) * .1,
        center: index == 0,
      );
    }, growable: false);
    final edges = List<V3GraphEdge>.generate(scenario.edgeCount, (index) {
      final sourceIndex = index % scenario.nodeCount;
      var targetIndex = (sourceIndex * 7 + 13) % scenario.nodeCount;
      if (targetIndex == sourceIndex) {
        targetIndex = (targetIndex + 1) % scenario.nodeCount;
      }
      final kind = switch (index % 4) {
        0 => V3GraphRelationKind.linkedMaterial,
        1 => V3GraphRelationKind.sharedTopic,
        2 => V3GraphRelationKind.sharedContentLine,
        _ => V3GraphRelationKind.other,
      };
      return V3GraphEdge(
        id: 'edge-$index',
        sourceId: 'node-$sourceIndex',
        targetId: 'node-$targetIndex',
        kind: kind,
        label: '${kind.label} $index',
        weight: 1 + (index % 5) * .1,
        directed: index.isEven,
      );
    }, growable: false);
    final positions = <String, Offset>{
      for (final node in nodes) node.id: node.position,
    };
    return _LargeGraphFixture(
      snapshot: GraphSnapshot(
        graphId: 'large-${scenario.nodeCount}-${scenario.edgeCount}',
        nodes: nodes,
        edges: edges,
        revision: scenario.nodeCount + scenario.edgeCount,
        updatedAt: DateTime.utc(2026, 7, 23),
      ),
      nodes: nodes,
      edges: edges,
      positions: Map<String, Offset>.unmodifiable(positions),
      radii: Map<String, double>.unmodifiable(<String, double>{
        for (final node in nodes) node.id: node.center ? 8 : 7,
      }),
    );
  }

  final GraphSnapshot snapshot;
  final List<V3GraphNode> nodes;
  final List<V3GraphEdge> edges;
  final Map<String, Offset> positions;
  final Map<String, double> radii;
}
