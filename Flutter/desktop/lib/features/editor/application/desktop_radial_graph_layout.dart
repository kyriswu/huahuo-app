import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'desktop_graph_physics_simulation.dart';

/// A stable target for one semantic node in the desktop 2D graph.
///
/// Coordinates are an initial, readable skeleton for the force simulation.
/// They are deliberately independent from the four-value [community] palette:
/// physical placement is driven by [settlementId].
@immutable
final class DesktopRadialGraphLayoutPlacement {
  const DesktopRadialGraphLayoutPlacement({
    required this.id,
    required this.community,
    this.settlementId = '',
    required this.desiredPosition,
    required this.normalizedDesiredPosition,
    required this.relationshipTier,
    required this.radialTier,
    required this.angle,
    required this.localClusterIndex,
    required this.localClusterCount,
    required this.isLeaf,
    required this.isCommunityCore,
  });

  final String id;

  /// Category and palette information only. It does not define geometry.
  final DesktopGraphCommunity community;

  /// The real physical settlement that owns this placement.
  final String settlementId;

  /// Pixel position for the detailed Forge2D graph path.
  final Offset desiredPosition;

  /// Viewport-relative position for the scalable dense graph path.
  final Offset normalizedDesiredPosition;

  /// Shortest semantic-path distance from this settlement's real core.
  final int relationshipTier;

  /// Visual radial band after preserving relationship tiers and local density.
  ///
  /// The value describes a broad annular band, not a literal equal-radius ring.
  final int radialTier;

  /// Stable polar direction from the local settlement anchor in radians.
  final double angle;

  /// Stable index of this settlement within the active central field.
  ///
  /// Center nodes use `-1`. The legacy name remains for existing consumers.
  final int localClusterIndex;

  /// Number of active physical settlements in this graph.
  final int localClusterCount;
  final bool isLeaf;

  /// Legacy name for a real settlement core.
  final bool isCommunityCore;

  bool get isSettlementCore => isCommunityCore;

  @override
  bool operator ==(Object other) =>
      other is DesktopRadialGraphLayoutPlacement &&
      other.id == id &&
      other.community == community &&
      other.settlementId == settlementId &&
      other.desiredPosition == desiredPosition &&
      other.normalizedDesiredPosition == normalizedDesiredPosition &&
      other.relationshipTier == relationshipTier &&
      other.radialTier == radialTier &&
      other.angle == angle &&
      other.localClusterIndex == localClusterIndex &&
      other.localClusterCount == localClusterCount &&
      other.isLeaf == isLeaf &&
      other.isCommunityCore == isCommunityCore;

  @override
  int get hashCode => Object.hash(
    id,
    community,
    settlementId,
    desiredPosition,
    normalizedDesiredPosition,
    relationshipTier,
    radialTier,
    angle,
    localClusterIndex,
    localClusterCount,
    isLeaf,
    isCommunityCore,
  );
}

/// Immutable output from [DesktopRadialGraphLayout.build].
@immutable
final class DesktopRadialGraphLayoutResult {
  const DesktopRadialGraphLayoutResult({
    required this.placements,
    required this.desiredPositions,
    required this.normalizedDesiredPositions,
  });

  const DesktopRadialGraphLayoutResult.empty()
    : placements = const <String, DesktopRadialGraphLayoutPlacement>{},
      desiredPositions = const <String, Offset>{},
      normalizedDesiredPositions = const <String, Offset>{};

  final Map<String, DesktopRadialGraphLayoutPlacement> placements;
  final Map<String, Offset> desiredPositions;
  final Map<String, Offset> normalizedDesiredPositions;

  DesktopRadialGraphLayoutPlacement? placementFor(String nodeId) =>
      placements[nodeId];
}

/// Deterministic, multi-settlement centripetal seed layout for the 2D graph.
///
/// A graph's category is intentionally not its physical group. Every resolved
/// settlement receives one anchor in an irregular central field, then its
/// members occupy a locally skewed spiral. The field deliberately has a dense
/// centre and uneven outer districts, so many settlements do not reconstruct
/// a decorative circular perimeter around the canvas.
final class DesktopRadialGraphLayout {
  const DesktopRadialGraphLayout();

  static const double _minimumPadding = 12;
  static const double _maximumPadding = 28;
  static final double _goldenAngle = math.pi * (3 - math.sqrt(5));

  // These are semantic neighbourhoods in the central field, not a radial
  // ring. The deliberately uneven offsets leave natural gaps at the outer
  // edge while keeping a dense focal area around the content brain.
  static const List<Offset> _fieldDistrictOffsets = <Offset>[
    Offset(-.04, .03),
    Offset(-.78, -.30),
    Offset(.34, -.82),
    Offset(.87, -.06),
    Offset(.43, .73),
    Offset(-.47, .66),
    Offset(-.86, .19),
  ];

  DesktopRadialGraphLayoutResult build({
    required Iterable<DesktopGraphPhysicsNode> nodes,
    Iterable<DesktopGraphPhysicsEdge> edges = const <DesktopGraphPhysicsEdge>[],
    Iterable<DesktopGraphCommunitySnapshot> communities =
        const <DesktopGraphCommunitySnapshot>[],
    required Size viewport,
  }) {
    if (!viewport.width.isFinite ||
        !viewport.height.isFinite ||
        viewport.width < 0 ||
        viewport.height < 0) {
      throw ArgumentError.value(
        viewport,
        'viewport',
        'must have finite, non-negative dimensions',
      );
    }

    final sourceNodes = nodes.toList(growable: false);
    _validateNodes(sourceNodes);
    if (sourceNodes.isEmpty || viewport.isEmpty) {
      return const DesktopRadialGraphLayoutResult.empty();
    }

    final nodesById = <String, DesktopGraphPhysicsNode>{
      for (final node in sourceNodes) node.id: node,
    };
    final nodesBySettlement = <String, List<DesktopGraphPhysicsNode>>{};
    final centerNodes = <DesktopGraphPhysicsNode>[];
    for (final node in sourceNodes) {
      if (node.role == DesktopGraphNodeRole.center) {
        centerNodes.add(node);
      } else {
        (nodesBySettlement[_settlementIdFor(node)] ??=
                <DesktopGraphPhysicsNode>[])
            .add(node);
      }
    }
    for (final group in nodesBySettlement.values) {
      group.sort((left, right) => left.id.compareTo(right.id));
    }
    centerNodes.sort((left, right) => left.id.compareTo(right.id));

    final activeSettlementIds = nodesBySettlement.keys.toList()
      ..sort(_compareSettlementIds);
    final edgesBySettlement = _internalEdgesBySettlement(
      edges: edges,
      nodesById: nodesById,
    );
    final snapshotCoreIds = _snapshotCoreIds(
      snapshots: communities,
      nodesById: nodesById,
    );
    final placements = <String, DesktopRadialGraphLayoutPlacement>{};
    final center = viewport.center(Offset.zero);
    final shortestSide = math.min(viewport.width, viewport.height).toDouble();
    final viewportBounds = DesktopGraphViewportBounds.forViewport(viewport);

    _placeCenterNodes(
      nodes: centerNodes,
      center: center,
      shortestSide: shortestSide,
      viewport: viewport,
      viewportBounds: viewportBounds,
      output: placements,
    );

    for (
      var settlementIndex = 0;
      settlementIndex < activeSettlementIds.length;
      settlementIndex++
    ) {
      final settlementId = activeSettlementIds[settlementIndex];
      final members = nodesBySettlement[settlementId]!;
      final coreId = _resolveCoreId(
        settlementId: settlementId,
        members: members,
        snapshotCoreIds: snapshotCoreIds,
      );
      final topology = _buildSettlementTopology(
        coreId: coreId,
        members: members,
        edges:
            edgesBySettlement[settlementId] ??
            const <DesktopGraphPhysicsEdge>[],
      );
      final anchor = _settlementAnchor(
        settlementId: settlementId,
        settlementIndex: settlementIndex,
        settlementCount: activeSettlementIds.length,
        center: center,
        shortestSide: shortestSide,
      );
      final coreNode = nodesById[coreId]!;
      placements[coreId] = _placement(
        id: coreId,
        community: coreNode.community,
        settlementId: settlementId,
        position: anchor,
        viewport: viewport,
        viewportBounds: viewportBounds,
        relationshipTier: 0,
        radialTier: 0,
        angle: math.atan2(anchor.dy - center.dy, anchor.dx - center.dx),
        localClusterIndex: settlementIndex,
        localClusterCount: activeSettlementIds.length,
        isLeaf: false,
        isCommunityCore: true,
      );

      final satelliteIds = members
          .where((node) => node.id != coreId)
          .map((node) => node.id)
          .toList(growable: false);
      if (satelliteIds.isEmpty) continue;

      final radialTiers = _assignSettlementTiers(
        nodeIds: satelliteIds,
        topology: topology,
      );
      var maximumRadialTier = 0;
      final nodesByRadialTier = <int, List<String>>{};
      for (final entry in radialTiers.entries) {
        maximumRadialTier = math.max(maximumRadialTier, entry.value).toInt();
        (nodesByRadialTier[entry.value] ??= <String>[]).add(entry.key);
      }
      final tierKeys = nodesByRadialTier.keys.toList()..sort();
      var spiralOrdinal = 0;
      for (final radialTier in tierKeys) {
        final tierNodeIds = nodesByRadialTier[radialTier]!
          ..sort(_compareAngularRank);
        for (var tierIndex = 0; tierIndex < tierNodeIds.length; tierIndex++) {
          final nodeId = tierNodeIds[tierIndex];
          final node = nodesById[nodeId]!;
          final angle = _settlementSpiralAngle(
            settlementId: settlementId,
            nodeId: nodeId,
            ordinal: spiralOrdinal++,
            radialTier: radialTier,
          );
          final radius = _settlementScatterRadius(
            settlementId: settlementId,
            nodeId: nodeId,
            radialTier: radialTier,
            maximumRadialTier: maximumRadialTier,
            tierIndex: tierIndex,
            tierCount: tierNodeIds.length,
            memberCount: satelliteIds.length,
            shortestSide: shortestSide,
          );
          final position = _settlementMemberPosition(
            settlementId: settlementId,
            nodeId: nodeId,
            anchor: anchor,
            fieldCenter: center,
            angle: angle,
            radius: radius,
            shortestSide: shortestSide,
          );
          placements[nodeId] = _placement(
            id: nodeId,
            community: node.community,
            settlementId: settlementId,
            position: position,
            viewport: viewport,
            viewportBounds: viewportBounds,
            relationshipTier: topology.relationshipTiers[nodeId]!,
            radialTier: radialTier,
            angle: angle,
            localClusterIndex: settlementIndex,
            localClusterCount: activeSettlementIds.length,
            isLeaf: topology.leafNodeIds.contains(nodeId),
            isCommunityCore: false,
          );
        }
      }
    }

    return _resultFor(placements);
  }

  static void _validateNodes(List<DesktopGraphPhysicsNode> nodes) {
    final ids = <String>{};
    for (final node in nodes) {
      if (node.id.trim().isEmpty) {
        throw ArgumentError.value(
          node.id,
          'nodes',
          'node IDs must not be empty',
        );
      }
      if (!ids.add(node.id)) {
        throw ArgumentError.value(node.id, 'nodes', 'node IDs must be unique');
      }
    }
  }

  static String _settlementIdFor(DesktopGraphPhysicsNode node) {
    final settlementId = node.settlementId.trim();
    return settlementId.isEmpty
        ? 'community-${node.community.name}'
        : settlementId;
  }

  static Map<String, List<DesktopGraphPhysicsEdge>> _internalEdgesBySettlement({
    required Iterable<DesktopGraphPhysicsEdge> edges,
    required Map<String, DesktopGraphPhysicsNode> nodesById,
  }) {
    final result = <String, List<DesktopGraphPhysicsEdge>>{};
    final source = edges.toList(growable: false)..sort(_compareEdges);
    for (final edge in source) {
      if (edge.isSelfLoop) continue;
      final sourceNode = nodesById[edge.sourceId];
      final targetNode = nodesById[edge.targetId];
      if (sourceNode == null ||
          targetNode == null ||
          sourceNode.role == DesktopGraphNodeRole.center ||
          targetNode.role == DesktopGraphNodeRole.center) {
        continue;
      }
      final settlementId = _settlementIdFor(sourceNode);
      if (settlementId != _settlementIdFor(targetNode)) continue;
      (result[settlementId] ??= <DesktopGraphPhysicsEdge>[]).add(edge);
    }
    return result;
  }

  static Map<String, String> _snapshotCoreIds({
    required Iterable<DesktopGraphCommunitySnapshot> snapshots,
    required Map<String, DesktopGraphPhysicsNode> nodesById,
  }) {
    final candidates = <String, List<String>>{};
    for (final snapshot in snapshots) {
      final node = nodesById[snapshot.coreNodeId];
      if (node == null ||
          node.role == DesktopGraphNodeRole.center ||
          node.community != snapshot.community) {
        continue;
      }
      (candidates[_settlementIdFor(node)] ??= <String>[]).add(node.id);
    }
    final result = <String, String>{};
    for (final entry in candidates.entries) {
      entry.value.sort();
      if (entry.value.isNotEmpty) result[entry.key] = entry.value.first;
    }
    return result;
  }

  static String _resolveCoreId({
    required String settlementId,
    required List<DesktopGraphPhysicsNode> members,
    required Map<String, String> snapshotCoreIds,
  }) {
    final snapshotCore = snapshotCoreIds[settlementId];
    if (snapshotCore != null) return snapshotCore;
    final declaredCores =
        members
            .where((node) => node.role == DesktopGraphNodeRole.core)
            .map((node) => node.id)
            .toList()
          ..sort();
    return declaredCores.isNotEmpty ? declaredCores.first : members.first.id;
  }

  static _SettlementTopology _buildSettlementTopology({
    required String coreId,
    required List<DesktopGraphPhysicsNode> members,
    required List<DesktopGraphPhysicsEdge> edges,
  }) {
    final adjacency = <String, Set<String>>{
      for (final member in members) member.id: <String>{},
    };
    final nonCoreDegree = <String, int>{
      for (final member in members) member.id: 0,
    };
    for (final edge in edges) {
      final sourceNeighbors = adjacency[edge.sourceId];
      final targetNeighbors = adjacency[edge.targetId];
      if (sourceNeighbors == null || targetNeighbors == null) continue;
      sourceNeighbors.add(edge.targetId);
      targetNeighbors.add(edge.sourceId);
      if (edge.sourceId != coreId && edge.targetId != coreId) {
        nonCoreDegree[edge.sourceId] = (nonCoreDegree[edge.sourceId] ?? 0) + 1;
        nonCoreDegree[edge.targetId] = (nonCoreDegree[edge.targetId] ?? 0) + 1;
      }
    }

    final relationshipTiers = <String, int>{coreId: 0};
    final pending = <String>[coreId];
    var cursor = 0;
    while (cursor < pending.length) {
      final current = pending[cursor++];
      final currentTier = relationshipTiers[current]!;
      final neighbors = adjacency[current]!.toList()..sort();
      for (final neighbor in neighbors) {
        if (relationshipTiers.containsKey(neighbor)) continue;
        relationshipTiers[neighbor] = currentTier + 1;
        pending.add(neighbor);
      }
    }

    var maximumKnownTier = 0;
    for (final tier in relationshipTiers.values) {
      maximumKnownTier = math.max(maximumKnownTier, tier).toInt();
    }
    for (final member in members) {
      relationshipTiers.putIfAbsent(member.id, () => maximumKnownTier + 1);
    }
    final leafNodeIds = <String>{
      for (final member in members)
        if (member.id != coreId &&
            member.role == DesktopGraphNodeRole.satellite &&
            (nonCoreDegree[member.id] ?? 0) == 0)
          member.id,
    };
    return _SettlementTopology(
      relationshipTiers: Map<String, int>.unmodifiable(relationshipTiers),
      leafNodeIds: Set<String>.unmodifiable(leafNodeIds),
    );
  }

  static Map<String, int> _assignSettlementTiers({
    required List<String> nodeIds,
    required _SettlementTopology topology,
  }) {
    final structured = <String>[];
    final leaves = <String>[];
    for (final nodeId in nodeIds) {
      (topology.leafNodeIds.contains(nodeId) ? leaves : structured).add(nodeId);
    }
    int byTopology(String left, String right) {
      final byTier = topology.relationshipTiers[left]!.compareTo(
        topology.relationshipTiers[right]!,
      );
      return byTier != 0 ? byTier : _compareAngularRank(left, right);
    }

    structured.sort(byTopology);
    leaves.sort(byTopology);
    final occupancy = <int, int>{};
    final result = <String, int>{};
    var highestStructuredTier = 0;

    int assign(String nodeId, int minimumTier) {
      var tier = math.max(1, minimumTier).toInt();
      while ((occupancy[tier] ?? 0) >= _tierCapacity(tier)) {
        tier++;
      }
      occupancy[tier] = (occupancy[tier] ?? 0) + 1;
      return tier;
    }

    for (final nodeId in structured) {
      final tier = assign(nodeId, topology.relationshipTiers[nodeId]!);
      result[nodeId] = tier;
      highestStructuredTier = math.max(highestStructuredTier, tier).toInt();
    }
    final leafMinimumTier = highestStructuredTier == 0
        ? 1
        : highestStructuredTier + 1;
    for (final nodeId in leaves) {
      result[nodeId] = assign(
        nodeId,
        math.max(leafMinimumTier, topology.relationshipTiers[nodeId]!).toInt(),
      );
    }
    return Map<String, int>.unmodifiable(result);
  }

  static int _tierCapacity(int radialTier) => math.max(6, radialTier * 7);

  static int _compareSettlementIds(String left, String right) {
    final byHash = _stableHash(
      '$left|settlement-anchor',
    ).compareTo(_stableHash('$right|settlement-anchor'));
    return byHash != 0 ? byHash : left.compareTo(right);
  }

  static int _compareAngularRank(String left, String right) {
    final byHash = _stableHash(
      '$left|angular-rank',
    ).compareTo(_stableHash('$right|angular-rank'));
    return byHash != 0 ? byHash : left.compareTo(right);
  }

  static Offset _settlementAnchor({
    required String settlementId,
    required int settlementIndex,
    required int settlementCount,
    required Offset center,
    required double shortestSide,
  }) {
    final districtCount = math.min(
      _fieldDistrictOffsets.length,
      math.max(1, math.sqrt(settlementCount).ceil()),
    );
    final districtIndex = settlementIndex % districtCount;
    final ordinalInDistrict = settlementIndex ~/ districtCount;
    final districtPopulation =
        ((settlementCount - 1 - districtIndex) ~/ districtCount) + 1;
    final fieldScale = (.150 + .020 * math.sqrt(settlementCount))
        .clamp(.175, .285)
        .toDouble();
    final districtCentre =
        center +
        _fieldDistrictOffsets[districtIndex] * shortestSide * fieldScale;
    final localPhase =
        ordinalInDistrict * _goldenAngle +
        _unitInterval('$settlementId|district-phase') * math.pi * 2;
    final localProgress = math.sqrt(
      ((ordinalInDistrict +
                  .30 +
                  _unitInterval('$settlementId|district-radius') * .32) /
              (districtPopulation + .36))
          .clamp(.04, .96)
          .toDouble(),
    );
    final localRadius =
        shortestSide *
        (.016 + (.030 + .012 * districtPopulation) * localProgress);
    return districtCentre +
        Offset(
          math.cos(localPhase) * localRadius,
          math.sin(localPhase) * localRadius,
        );
  }

  static double _settlementSpiralAngle({
    required String settlementId,
    required String nodeId,
    required int ordinal,
    required int radialTier,
  }) {
    final phase = _unitInterval('$settlementId|spiral-phase') * math.pi * 2;
    final jitter = (_unitInterval('$nodeId|spiral-angle') - .5) * .22;
    return phase + ordinal * _goldenAngle + radialTier * .17 + jitter;
  }

  static double _settlementScatterRadius({
    required String settlementId,
    required String nodeId,
    required int radialTier,
    required int maximumRadialTier,
    required int tierIndex,
    required int tierCount,
    required int memberCount,
    required double shortestSide,
  }) {
    final base = (shortestSide * .020).clamp(14.0, 25.0).toDouble();
    final outerFraction = (.050 + .0085 * math.sqrt(memberCount))
        .clamp(.072, .145)
        .toDouble();
    final outer = math.max(base + 9, shortestSide * outerFraction).toDouble();
    final denominator = maximumRadialTier + .35;
    final bandStart = (radialTier - 1) / denominator;
    final bandEnd = radialTier / denominator;
    final hashOffset =
        (_unitInterval('$settlementId|$nodeId|radius') - .5) * .42;
    final localProgress = ((tierIndex + .42 + hashOffset) / (tierCount + .12))
        .clamp(.04, .96)
        .toDouble();
    final bandProgress =
        bandStart + (bandEnd - bandStart) * (.14 + .74 * localProgress);
    final safeProgress = bandProgress.clamp(.01, .98).toDouble();
    return base + (outer - base) * math.sqrt(safeProgress);
  }

  static Offset _settlementMemberPosition({
    required String settlementId,
    required String nodeId,
    required Offset anchor,
    required Offset fieldCenter,
    required double angle,
    required double radius,
    required double shortestSide,
  }) {
    final towardCenter = fieldCenter - anchor;
    final inwardDirection = towardCenter.distanceSquared > .001
        ? towardCenter / towardCenter.distance
        : Offset(
            math.cos(_unitInterval('$settlementId|centre-axis') * math.pi * 2),
            math.sin(_unitInterval('$settlementId|centre-axis') * math.pi * 2),
          );
    final inwardAngle = math.atan2(inwardDirection.dy, inwardDirection.dx);
    final relativeAngle = math.atan2(
      math.sin(angle - inwardAngle),
      math.cos(angle - inwardAngle),
    );
    // Narrow each local spiral around the direction of the content brain. This
    // creates an inward-facing settlement while preserving the radius assigned
    // by semantic relationship tiers.
    final settledAngle = inwardAngle + relativeAngle * .64;
    final direction = Offset(math.cos(settledAngle), math.sin(settledAngle));
    final tangent = Offset(-direction.dy, direction.dx);
    final radialJitter =
        (_unitInterval('$settlementId|$nodeId|radial-jitter') - .5) *
        math.min(radius * .20, shortestSide * .018) *
        2;
    final tangentJitter =
        (_unitInterval('$settlementId|$nodeId|tangent-jitter') - .5) *
        math.min(radius * .16, shortestSide * .012) *
        2;
    return anchor +
        direction * (radius + radialJitter) +
        tangent * tangentJitter;
  }

  static void _placeCenterNodes({
    required List<DesktopGraphPhysicsNode> nodes,
    required Offset center,
    required double shortestSide,
    required Size viewport,
    required DesktopGraphViewportBounds viewportBounds,
    required Map<String, DesktopRadialGraphLayoutPlacement> output,
  }) {
    if (nodes.isEmpty) return;
    final radius = nodes.length == 1
        ? 0.0
        : math.min(shortestSide * .018, 16.0).toDouble();
    for (var index = 0; index < nodes.length; index++) {
      final phase = nodes.length == 1
          ? 0.0
          : math.pi * 2 * index / nodes.length;
      final position =
          center + Offset(math.cos(phase) * radius, math.sin(phase) * radius);
      final node = nodes[index];
      output[node.id] = _placement(
        id: node.id,
        community: node.community,
        settlementId: _settlementIdFor(node),
        position: position,
        viewport: viewport,
        viewportBounds: viewportBounds,
        relationshipTier: 0,
        radialTier: 0,
        angle: phase,
        localClusterIndex: -1,
        localClusterCount: 0,
        isLeaf: false,
        isCommunityCore: false,
      );
    }
  }

  static DesktopRadialGraphLayoutPlacement _placement({
    required String id,
    required DesktopGraphCommunity community,
    required String settlementId,
    required Offset position,
    required Size viewport,
    required DesktopGraphViewportBounds viewportBounds,
    required int relationshipTier,
    required int radialTier,
    required double angle,
    required int localClusterIndex,
    required int localClusterCount,
    required bool isLeaf,
    required bool isCommunityCore,
  }) {
    final shortestSide = math.min(viewport.width, viewport.height).toDouble();
    final edgeInset = (shortestSide * .025)
        .clamp(_minimumPadding, _maximumPadding)
        .toDouble();
    final desiredPosition = viewportBounds.clamp(position, inset: edgeInset);
    return DesktopRadialGraphLayoutPlacement(
      id: id,
      community: community,
      settlementId: settlementId,
      desiredPosition: desiredPosition,
      normalizedDesiredPosition: Offset(
        desiredPosition.dx / viewport.width,
        desiredPosition.dy / viewport.height,
      ),
      relationshipTier: relationshipTier,
      radialTier: radialTier,
      angle: angle,
      localClusterIndex: localClusterIndex,
      localClusterCount: localClusterCount,
      isLeaf: isLeaf,
      isCommunityCore: isCommunityCore,
    );
  }

  static DesktopRadialGraphLayoutResult _resultFor(
    Map<String, DesktopRadialGraphLayoutPlacement> placements,
  ) {
    final entries = placements.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final orderedPlacements =
        Map<String, DesktopRadialGraphLayoutPlacement>.unmodifiable(
          <String, DesktopRadialGraphLayoutPlacement>{
            for (final entry in entries) entry.key: entry.value,
          },
        );
    return DesktopRadialGraphLayoutResult(
      placements: orderedPlacements,
      desiredPositions: Map<String, Offset>.unmodifiable(<String, Offset>{
        for (final entry in entries) entry.key: entry.value.desiredPosition,
      }),
      normalizedDesiredPositions:
          Map<String, Offset>.unmodifiable(<String, Offset>{
            for (final entry in entries)
              entry.key: entry.value.normalizedDesiredPosition,
          }),
    );
  }

  static int _compareEdges(
    DesktopGraphPhysicsEdge left,
    DesktopGraphPhysicsEdge right,
  ) {
    final leftStart = left.sourceId.compareTo(left.targetId) <= 0
        ? left.sourceId
        : left.targetId;
    final leftEnd = leftStart == left.sourceId ? left.targetId : left.sourceId;
    final rightStart = right.sourceId.compareTo(right.targetId) <= 0
        ? right.sourceId
        : right.targetId;
    final rightEnd = rightStart == right.sourceId
        ? right.targetId
        : right.sourceId;
    final byStart = leftStart.compareTo(rightStart);
    if (byStart != 0) return byStart;
    final byEnd = leftEnd.compareTo(rightEnd);
    return byEnd != 0 ? byEnd : left.id.compareTo(right.id);
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    hash ^= hash >> 16;
    hash = (hash * 0x7feb352d) & 0x7fffffff;
    return hash;
  }

  static double _unitInterval(String value) => _stableHash(value) / 0x7fffffff;
}

final class _SettlementTopology {
  const _SettlementTopology({
    required this.relationshipTiers,
    required this.leafNodeIds,
  });

  final Map<String, int> relationshipTiers;
  final Set<String> leafNodeIds;
}
