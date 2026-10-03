import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/graph_render_budget.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_edge_geometry.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('idle LOD budgets match the 500-node product limits', () {
    final far = GraphRenderBudget.resolve(lod: GraphGeometryLod.far);
    final middle = GraphRenderBudget.resolve(lod: GraphGeometryLod.middle);
    final near = GraphRenderBudget.resolve(lod: GraphGeometryLod.near);

    expect((far.ordinaryLabelCount, far.ordinaryEdgeCount), (4, 100));
    expect((middle.ordinaryLabelCount, middle.ordinaryEdgeCount), (8, 160));
    expect((near.ordinaryLabelCount, near.ordinaryEdgeCount), (12, 220));
    expect([
      far.widgetNodeCount,
      middle.widgetNodeCount,
      near.widgetNodeCount,
    ], everyElement(8));
    expect(
      near.ordinaryEdgeCount,
      lessThanOrEqualTo(GraphRenderBudget.maximumOrdinaryEdges),
    );
  });

  test('interaction and inactive budgets stop expensive work', () {
    final interacting = GraphRenderBudget.resolve(
      lod: GraphGeometryLod.near,
      quality: GraphRenderQuality.interacting,
    );
    final inactive = GraphRenderBudget.resolve(
      lod: GraphGeometryLod.near,
      quality: GraphRenderQuality.inactive,
    );

    expect(interacting.ordinaryLabelCount, 0);
    expect(interacting.ordinaryEdgeCount, 80);
    expect(interacting.preciseEdgeHitTesting, isFalse);
    expect(inactive.ordinaryEdgeCount, 0);
    expect(inactive.widgetNodeCount, 0);
    expect(inactive.semanticNodeCount, 0);
  });

  test('central performance limits cap visual nodes and edges', () {
    final constrained = GraphRenderBudget.resolve(
      lod: GraphGeometryLod.near,
      maximumVisualNodeCount: 32,
      maximumOrdinaryEdgeCount: 48,
    );
    final interacting = GraphRenderBudget.resolve(
      lod: GraphGeometryLod.near,
      quality: GraphRenderQuality.interacting,
      maximumVisualNodeCount: 120,
      maximumOrdinaryEdgeCount: 220,
    );

    expect(constrained.maximumVisualNodeCount, 32);
    expect(constrained.minimumVisualNodeCount, 32);
    expect(constrained.ordinaryEdgeCount, 48);
    expect(interacting.maximumVisualNodeCount, 120);
    expect(interacting.minimumVisualNodeCount, 24);
  });

  test('visual selection retains priority context before ordinary nodes', () {
    final nodes = <V3GraphNode>[
      _node('ordinary-0'),
      _node('centre', center: true),
      _node('selected'),
      _node('aggregation'),
      _node('search'),
      _node('neighbor'),
      _node('ordinary-1'),
    ];

    final selected = selectGraphVisualNodes(
      nodes: nodes,
      maximum: 6,
      priorityNodeIds: const <String?>[
        'selected',
        'aggregation',
        'search',
        'neighbor',
      ],
    );

    expect(selected.map((node) => node.id), <String>[
      'centre',
      'selected',
      'aggregation',
      'search',
      'neighbor',
      'ordinary-0',
    ]);
  });
}

V3GraphNode _node(String id, {bool center = false}) => V3GraphNode(
  id: id,
  label: id,
  cluster: V3GraphCluster.viewpoint,
  position: Offset.zero,
  summary: id,
  center: center,
);
