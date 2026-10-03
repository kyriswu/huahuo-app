import '../domain/graph_edge_geometry.dart';
import '../domain/ui_v3_models.dart';

enum GraphRenderQuality { idle, interacting, settling, inactive }

List<V3GraphNode> selectGraphVisualNodes({
  required Iterable<V3GraphNode> nodes,
  required int maximum,
  Iterable<String?> priorityNodeIds = const <String?>[],
}) {
  if (maximum <= 0) return const <V3GraphNode>[];
  final candidates = nodes.toList(growable: false);
  if (candidates.length <= maximum) return candidates;
  final byId = <String, V3GraphNode>{
    for (final node in candidates) node.id: node,
  };
  final selected = <String, V3GraphNode>{};
  void add(String? id) {
    if (id == null || selected.length >= maximum) return;
    final node = byId[id];
    if (node != null) selected.putIfAbsent(id, () => node);
  }

  for (final node in candidates.where((node) => node.center)) {
    add(node.id);
  }
  priorityNodeIds.forEach(add);
  for (final node in candidates) {
    add(node.id);
  }
  return selected.values.toList(growable: false);
}

final class GraphRenderBudget {
  const GraphRenderBudget({
    required this.maximumVisualNodeCount,
    required this.minimumVisualNodeCount,
    required this.ordinaryLabelCount,
    required this.priorityLabelCount,
    required this.ordinaryEdgeCount,
    required this.widgetNodeCount,
    required this.glowNodeCount,
    required this.semanticNodeCount,
    required this.semanticEdgeCount,
    required this.preciseEdgeHitTesting,
  });

  static const int maximumOrdinaryEdges = 300;

  factory GraphRenderBudget.resolve({
    required GraphGeometryLod lod,
    GraphRenderQuality quality = GraphRenderQuality.idle,
    int maximumVisualNodeCount = 120,
    int maximumOrdinaryEdgeCount = maximumOrdinaryEdges,
  }) {
    assert(maximumVisualNodeCount >= 0);
    assert(maximumOrdinaryEdgeCount >= 0);
    if (quality == GraphRenderQuality.inactive) {
      return const GraphRenderBudget(
        maximumVisualNodeCount: 0,
        minimumVisualNodeCount: 0,
        ordinaryLabelCount: 0,
        priorityLabelCount: 0,
        ordinaryEdgeCount: 0,
        widgetNodeCount: 0,
        glowNodeCount: 0,
        semanticNodeCount: 0,
        semanticEdgeCount: 0,
        preciseEdgeHitTesting: false,
      );
    }
    if (quality == GraphRenderQuality.interacting ||
        quality == GraphRenderQuality.settling) {
      final visualNodeCount = maximumVisualNodeCount;
      return GraphRenderBudget(
        maximumVisualNodeCount: visualNodeCount,
        minimumVisualNodeCount: _minimum(visualNodeCount, 24),
        ordinaryLabelCount: 0,
        priorityLabelCount: 6,
        ordinaryEdgeCount: _minimum(maximumOrdinaryEdgeCount, 80),
        widgetNodeCount: 8,
        glowNodeCount: 4,
        semanticNodeCount: 24,
        semanticEdgeCount: _minimum(maximumOrdinaryEdgeCount, 20),
        preciseEdgeHitTesting: false,
      );
    }
    final fillerTarget = _minimum(maximumVisualNodeCount, 72);
    return switch (lod) {
      GraphGeometryLod.far => GraphRenderBudget(
        maximumVisualNodeCount: maximumVisualNodeCount,
        minimumVisualNodeCount: fillerTarget,
        ordinaryLabelCount: 4,
        priorityLabelCount: 6,
        ordinaryEdgeCount: _minimum(maximumOrdinaryEdgeCount, 100),
        widgetNodeCount: 8,
        glowNodeCount: 6,
        semanticNodeCount: 32,
        semanticEdgeCount: _minimum(maximumOrdinaryEdgeCount, 30),
        preciseEdgeHitTesting: true,
      ),
      GraphGeometryLod.middle => GraphRenderBudget(
        maximumVisualNodeCount: maximumVisualNodeCount,
        minimumVisualNodeCount: fillerTarget,
        ordinaryLabelCount: 8,
        priorityLabelCount: 6,
        ordinaryEdgeCount: _minimum(maximumOrdinaryEdgeCount, 160),
        widgetNodeCount: 8,
        glowNodeCount: 8,
        semanticNodeCount: 40,
        semanticEdgeCount: _minimum(maximumOrdinaryEdgeCount, 40),
        preciseEdgeHitTesting: true,
      ),
      GraphGeometryLod.near => GraphRenderBudget(
        maximumVisualNodeCount: maximumVisualNodeCount,
        minimumVisualNodeCount: fillerTarget,
        ordinaryLabelCount: 12,
        priorityLabelCount: 6,
        ordinaryEdgeCount: _minimum(maximumOrdinaryEdgeCount, 220),
        widgetNodeCount: 8,
        glowNodeCount: 8,
        semanticNodeCount: 40,
        semanticEdgeCount: _minimum(maximumOrdinaryEdgeCount, 40),
        preciseEdgeHitTesting: true,
      ),
    };
  }

  final int maximumVisualNodeCount;
  final int minimumVisualNodeCount;
  final int ordinaryLabelCount;
  final int priorityLabelCount;
  final int ordinaryEdgeCount;
  final int widgetNodeCount;
  final int glowNodeCount;
  final int semanticNodeCount;
  final int semanticEdgeCount;
  final bool preciseEdgeHitTesting;

  @override
  bool operator ==(Object other) =>
      other is GraphRenderBudget &&
      maximumVisualNodeCount == other.maximumVisualNodeCount &&
      minimumVisualNodeCount == other.minimumVisualNodeCount &&
      ordinaryLabelCount == other.ordinaryLabelCount &&
      priorityLabelCount == other.priorityLabelCount &&
      ordinaryEdgeCount == other.ordinaryEdgeCount &&
      widgetNodeCount == other.widgetNodeCount &&
      glowNodeCount == other.glowNodeCount &&
      semanticNodeCount == other.semanticNodeCount &&
      semanticEdgeCount == other.semanticEdgeCount &&
      preciseEdgeHitTesting == other.preciseEdgeHitTesting;

  @override
  int get hashCode => Object.hash(
    maximumVisualNodeCount,
    minimumVisualNodeCount,
    ordinaryLabelCount,
    priorityLabelCount,
    ordinaryEdgeCount,
    widgetNodeCount,
    glowNodeCount,
    semanticNodeCount,
    semanticEdgeCount,
    preciseEdgeHitTesting,
  );

  static int _minimum(int left, int right) => left < right ? left : right;
}
