import 'package:flutter/foundation.dart';

import 'ui_v3_models.dart';

enum GraphLoadingState { idle, loading, building, ready, empty, failure }

@immutable
final class GraphSnapshot {
  GraphSnapshot({
    required this.graphId,
    required List<V3GraphNode> nodes,
    required List<V3GraphEdge> edges,
    required this.revision,
    required this.updatedAt,
  }) : nodes = List<V3GraphNode>.unmodifiable(nodes),
       edges = List<V3GraphEdge>.unmodifiable(edges);

  final String graphId;
  final List<V3GraphNode> nodes;
  final List<V3GraphEdge> edges;
  final int revision;
  final DateTime updatedAt;
}
