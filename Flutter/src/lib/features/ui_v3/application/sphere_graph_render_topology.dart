import 'dart:typed_data';

import '../domain/ui_v3_models.dart';
import 'sphere_graph_layout.dart';

final class SphereGraphRenderTopology {
  SphereGraphRenderTopology._({
    required this.nodeIds,
    required this.nodeIndexById,
    required this.baseCoordinates,
    required this.syntheticFlags,
    required this.visualLinkSources,
    required this.visualLinkTargets,
    required this.visualLinkSyntheticFlags,
    required this.semanticEdgeIds,
    required this.semanticEdgeSources,
    required this.semanticEdgeTargets,
  });

  factory SphereGraphRenderTopology.empty() => SphereGraphRenderTopology.build(
    points: const <SphereGraphLayoutPoint>[],
    visualLinks: const <SphereGraphVisualLink>[],
    semanticEdges: const <V3GraphEdge>[],
  );

  factory SphereGraphRenderTopology.build({
    required List<SphereGraphLayoutPoint> points,
    required List<SphereGraphVisualLink> visualLinks,
    required List<V3GraphEdge> semanticEdges,
  }) {
    final nodeIds = List<String>.unmodifiable(points.map((point) => point.id));
    final nodeIndexById = <String, int>{};
    for (var index = 0; index < nodeIds.length; index++) {
      if (nodeIds[index].trim().isEmpty ||
          nodeIndexById.containsKey(nodeIds[index])) {
        throw ArgumentError.value(nodeIds, 'points', 'IDs must be unique');
      }
      nodeIndexById[nodeIds[index]] = index;
    }
    final coordinates = Float32List(points.length * 3);
    final syntheticFlags = Uint8List(points.length);
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      coordinates[index * 3] = point.x;
      coordinates[index * 3 + 1] = point.y;
      coordinates[index * 3 + 2] = point.z;
      syntheticFlags[index] = point.isSynthetic ? 1 : 0;
    }

    final visualSources = <int>[];
    final visualTargets = <int>[];
    final visualSynthetic = <int>[];
    for (final link in visualLinks) {
      final source = nodeIndexById[link.sourceId];
      final target = nodeIndexById[link.targetId];
      if (source == null || target == null || source == target) continue;
      visualSources.add(source);
      visualTargets.add(target);
      visualSynthetic.add(link.touchesSyntheticPoint ? 1 : 0);
    }

    final semanticIds = <String>[];
    final semanticSources = <int>[];
    final semanticTargets = <int>[];
    for (final edge in semanticEdges) {
      final source = nodeIndexById[edge.sourceId];
      final target = nodeIndexById[edge.targetId];
      if (source == null || target == null) continue;
      semanticIds.add(edge.id);
      semanticSources.add(source);
      semanticTargets.add(target);
    }
    return SphereGraphRenderTopology._(
      nodeIds: nodeIds,
      nodeIndexById: Map<String, int>.unmodifiable(nodeIndexById),
      baseCoordinates: coordinates,
      syntheticFlags: syntheticFlags,
      visualLinkSources: Uint32List.fromList(visualSources),
      visualLinkTargets: Uint32List.fromList(visualTargets),
      visualLinkSyntheticFlags: Uint8List.fromList(visualSynthetic),
      semanticEdgeIds: List<String>.unmodifiable(semanticIds),
      semanticEdgeSources: Uint32List.fromList(semanticSources),
      semanticEdgeTargets: Uint32List.fromList(semanticTargets),
    );
  }

  final List<String> nodeIds;
  final Map<String, int> nodeIndexById;
  final Float32List baseCoordinates;
  final Uint8List syntheticFlags;
  final Uint32List visualLinkSources;
  final Uint32List visualLinkTargets;
  final Uint8List visualLinkSyntheticFlags;
  final List<String> semanticEdgeIds;
  final Uint32List semanticEdgeSources;
  final Uint32List semanticEdgeTargets;

  int get nodeCount => nodeIds.length;
  int get realNodeCount => syntheticFlags.where((flag) => flag == 0).length;
  bool isSynthetic(int index) => syntheticFlags[index] != 0;
}
