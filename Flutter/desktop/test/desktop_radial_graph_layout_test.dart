import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_graph_physics_simulation.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_radial_graph_layout.dart';

void main() {
  const layout = DesktopRadialGraphLayout();

  test('keeps settlement seeds stable when semantic input order changes', () {
    const nodes = <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'brain',
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.viewpointTrend,
      ),
      DesktopGraphPhysicsNode(
        id: 'alpha-core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.viewpointTrend,
        settlementId: 'alpha',
      ),
      DesktopGraphPhysicsNode(
        id: 'alpha-a',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.viewpointTrend,
        settlementId: 'alpha',
      ),
      DesktopGraphPhysicsNode(
        id: 'alpha-b',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.viewpointTrend,
        settlementId: 'alpha',
      ),
      DesktopGraphPhysicsNode(
        id: 'beta-core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.method,
        settlementId: 'beta',
      ),
      DesktopGraphPhysicsNode(
        id: 'beta-a',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.method,
        settlementId: 'beta',
      ),
    ];
    const edges = <DesktopGraphPhysicsEdge>[
      DesktopGraphPhysicsEdge(
        id: 'alpha-core-a',
        sourceId: 'alpha-core',
        targetId: 'alpha-a',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
      DesktopGraphPhysicsEdge(
        id: 'alpha-a-b',
        sourceId: 'alpha-a',
        targetId: 'alpha-b',
        kind: DesktopGraphRelationKind.linkedMaterial,
      ),
      DesktopGraphPhysicsEdge(
        id: 'beta-core-a',
        sourceId: 'beta-core',
        targetId: 'beta-a',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
    ];
    const communities = <DesktopGraphCommunitySnapshot>[
      DesktopGraphCommunitySnapshot(
        community: DesktopGraphCommunity.viewpointTrend,
        coreNodeId: 'alpha-core',
      ),
      DesktopGraphCommunitySnapshot(
        community: DesktopGraphCommunity.method,
        coreNodeId: 'beta-core',
      ),
    ];

    final first = layout.build(
      nodes: nodes,
      edges: edges,
      communities: communities,
      viewport: const Size(1440, 900),
    );
    final second = layout.build(
      nodes: nodes.reversed,
      edges: edges.reversed,
      communities: communities.reversed,
      viewport: const Size(1440, 900),
    );

    expect(first.placements.keys, orderedEquals(second.placements.keys));
    for (final nodeId in first.placements.keys) {
      expect(first.placements[nodeId], second.placements[nodeId]);
    }
  });

  test('uses settlement IDs rather than colour communities for geometry', () {
    const nodes = <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'brain',
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.inspiration,
      ),
      DesktopGraphPhysicsNode(
        id: 'north-core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'north',
      ),
      DesktopGraphPhysicsNode(
        id: 'north-note',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'north',
      ),
      DesktopGraphPhysicsNode(
        id: 'south-core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'south',
      ),
      DesktopGraphPhysicsNode(
        id: 'south-note',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'south',
      ),
    ];
    const edges = <DesktopGraphPhysicsEdge>[
      DesktopGraphPhysicsEdge(
        id: 'north-link',
        sourceId: 'north-core',
        targetId: 'north-note',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
      DesktopGraphPhysicsEdge(
        id: 'south-link',
        sourceId: 'south-core',
        targetId: 'south-note',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
    ];

    final result = layout.build(
      nodes: nodes,
      edges: edges,
      viewport: const Size(1200, 800),
    );
    final northCore = result.placements['north-core']!;
    final southCore = result.placements['south-core']!;

    expect(northCore.community, southCore.community);
    expect(northCore.settlementId, 'north');
    expect(southCore.settlementId, 'south');
    expect(northCore.isSettlementCore, isTrue);
    expect(southCore.isSettlementCore, isTrue);
    expect(northCore.localClusterCount, 2);
    expect(northCore.localClusterIndex, isNot(southCore.localClusterIndex));
    expect(
      (northCore.desiredPosition - southCore.desiredPosition).distance,
      greaterThan(24),
    );
  });

  test('keeps relationship tiers while leaves occupy later spiral bands', () {
    const nodes = <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'origin',
      ),
      DesktopGraphPhysicsNode(
        id: 'near',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'origin',
      ),
      DesktopGraphPhysicsNode(
        id: 'deep',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'origin',
      ),
      DesktopGraphPhysicsNode(
        id: 'leaf',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.inspiration,
        settlementId: 'origin',
      ),
    ];
    const edges = <DesktopGraphPhysicsEdge>[
      DesktopGraphPhysicsEdge(
        id: 'core-near',
        sourceId: 'core',
        targetId: 'near',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
      DesktopGraphPhysicsEdge(
        id: 'near-deep',
        sourceId: 'near',
        targetId: 'deep',
        kind: DesktopGraphRelationKind.linkedMaterial,
      ),
    ];

    final result = layout.build(
      nodes: nodes,
      edges: edges,
      viewport: const Size(1200, 800),
    );
    final core = result.placements['core']!;
    final near = result.placements['near']!;
    final deep = result.placements['deep']!;
    final leaf = result.placements['leaf']!;

    expect(core.isSettlementCore, isTrue);
    expect(core.radialTier, 0);
    expect(near.relationshipTier, 1);
    expect(deep.relationshipTier, 2);
    expect(leaf.isLeaf, isTrue);
    expect(leaf.radialTier, greaterThan(deep.radialTier));
    expect(
      (leaf.desiredPosition - core.desiredPosition).distance,
      greaterThan((deep.desiredPosition - core.desiredPosition).distance),
    );
  });

  test('keeps legacy callers in their fallback category settlement', () {
    const nodes = <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'legacy-core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.method,
      ),
      DesktopGraphPhysicsNode(
        id: 'legacy-note',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.method,
      ),
    ];

    final result = layout.build(nodes: nodes, viewport: const Size(900, 700));

    expect(
      result.placements.values
          .map((placement) => placement.settlementId)
          .toSet(),
      equals(<String>{'community-method'}),
    );
    expect(result.placements['legacy-core']!.localClusterCount, 1);
  });

  test('packs many real settlement cores into one compact central field', () {
    final nodes = <DesktopGraphPhysicsNode>[
      const DesktopGraphPhysicsNode(
        id: 'brain',
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.viewpointTrend,
      ),
    ];
    final edges = <DesktopGraphPhysicsEdge>[];
    for (var settlement = 0; settlement < 12; settlement++) {
      final settlementId = 'settlement-$settlement';
      final community = DesktopGraphCommunity
          .values[settlement % DesktopGraphCommunity.values.length];
      nodes.add(
        DesktopGraphPhysicsNode(
          id: '$settlementId-core',
          role: DesktopGraphNodeRole.core,
          community: community,
          settlementId: settlementId,
        ),
      );
      for (var member = 0; member < 9; member++) {
        final nodeId = '$settlementId-note-$member';
        nodes.add(
          DesktopGraphPhysicsNode(
            id: nodeId,
            role: DesktopGraphNodeRole.satellite,
            community: community,
            settlementId: settlementId,
          ),
        );
        edges.add(
          DesktopGraphPhysicsEdge(
            id: '$settlementId-edge-$member',
            sourceId: member < 3
                ? '$settlementId-core'
                : '$settlementId-note-${member - 1}',
            targetId: nodeId,
            kind: member.isEven
                ? DesktopGraphRelationKind.communityAffinity
                : DesktopGraphRelationKind.linkedMaterial,
          ),
        );
      }
    }

    final result = layout.build(
      nodes: nodes,
      edges: edges,
      viewport: const Size(1440, 900),
    );
    const center = Offset(720, 450);
    final cores = result.placements.values
        .where((placement) => placement.isSettlementCore)
        .toList(growable: false);

    expect(cores, hasLength(12));
    expect(
      cores.map((placement) => placement.settlementId).toSet(),
      hasLength(12),
    );
    expect(
      cores.every(
        (placement) => (placement.desiredPosition - center).distance < 260,
      ),
      isTrue,
    );
    for (var index = 0; index < cores.length; index++) {
      for (var other = index + 1; other < cores.length; other++) {
        expect(
          (cores[index].desiredPosition - cores[other].desiredPosition)
              .distance,
          greaterThan(12),
        );
      }
    }
  });

  test('spreads dense local bands instead of creating an equal-radius rim', () {
    final nodes = <DesktopGraphPhysicsNode>[
      const DesktopGraphPhysicsNode(
        id: 'core',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.caseIndustry,
        settlementId: 'orbit',
      ),
    ];
    final edges = <DesktopGraphPhysicsEdge>[];
    for (var index = 0; index < 128; index++) {
      final id = 'note-$index';
      nodes.add(
        DesktopGraphPhysicsNode(
          id: id,
          role: DesktopGraphNodeRole.satellite,
          community: DesktopGraphCommunity.caseIndustry,
          settlementId: 'orbit',
        ),
      );
      edges.add(
        DesktopGraphPhysicsEdge(
          id: 'membership-$index',
          sourceId: 'core',
          targetId: id,
          kind: DesktopGraphRelationKind.communityAffinity,
        ),
      );
    }

    final result = layout.build(
      nodes: nodes,
      edges: edges,
      viewport: const Size(1200, 800),
    );
    final core = result.placements['core']!;
    final byBand = <int, List<DesktopRadialGraphLayoutPlacement>>{};
    for (final placement in result.placements.values) {
      if (placement.id == core.id) continue;
      (byBand[placement.radialTier] ??= <DesktopRadialGraphLayoutPlacement>[])
          .add(placement);
    }
    final broadBand = byBand.values.reduce(
      (current, candidate) =>
          candidate.length > current.length ? candidate : current,
    );
    final radii =
        broadBand
            .map(
              (placement) =>
                  (placement.desiredPosition - core.desiredPosition).distance,
            )
            .toList()
          ..sort();

    expect(broadBand.length, greaterThanOrEqualTo(20));
    expect(radii.last - radii.first, greaterThan(8));
  });

  test('skews local settlements toward the shared content centre', () {
    const centre = Offset(720, 450);
    final nodes = <DesktopGraphPhysicsNode>[
      const DesktopGraphPhysicsNode(
        id: 'brain',
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.viewpointTrend,
      ),
    ];
    final edges = <DesktopGraphPhysicsEdge>[];
    for (var settlement = 0; settlement < 9; settlement++) {
      final settlementId = 'field-$settlement';
      final community = DesktopGraphCommunity
          .values[settlement % DesktopGraphCommunity.values.length];
      final coreId = '$settlementId-core';
      nodes.add(
        DesktopGraphPhysicsNode(
          id: coreId,
          role: DesktopGraphNodeRole.core,
          community: community,
          settlementId: settlementId,
        ),
      );
      for (var member = 0; member < 20; member++) {
        final memberId = '$settlementId-note-$member';
        nodes.add(
          DesktopGraphPhysicsNode(
            id: memberId,
            role: DesktopGraphNodeRole.satellite,
            community: community,
            settlementId: settlementId,
          ),
        );
        edges.add(
          DesktopGraphPhysicsEdge(
            id: '$settlementId-link-$member',
            sourceId: coreId,
            targetId: memberId,
            kind: DesktopGraphRelationKind.communityAffinity,
          ),
        );
      }
    }

    final result = layout.build(
      nodes: nodes,
      edges: edges,
      viewport: const Size(1440, 900),
    );

    for (var settlement = 0; settlement < 9; settlement++) {
      final settlementId = 'field-$settlement';
      final core = result.placements['$settlementId-core']!;
      final inward = centre - core.desiredPosition;
      final members = <DesktopRadialGraphLayoutPlacement>[
        for (var member = 0; member < 20; member++)
          result.placements['$settlementId-note-$member']!,
      ];
      final averageOffset =
          members
              .map(
                (placement) => placement.desiredPosition - core.desiredPosition,
              )
              .reduce((sum, offset) => sum + offset) /
          members.length.toDouble();

      expect(
        averageOffset.dx * inward.dx + averageOffset.dy * inward.dy,
        greaterThan(0),
        reason:
            '$settlementId should form a centripetal settlement, not a round rim.',
      );
    }
  });

  test('keeps 2000 notes bounded across many physical settlements', () {
    const settlementCount = 32;
    const totalSatellites = 1967;
    final nodes = <DesktopGraphPhysicsNode>[
      const DesktopGraphPhysicsNode(
        id: 'brain',
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.viewpointTrend,
      ),
    ];
    final edges = <DesktopGraphPhysicsEdge>[];
    var remaining = totalSatellites;
    for (var settlement = 0; settlement < settlementCount; settlement++) {
      final settlementId = 's-${settlement.toString().padLeft(2, '0')}';
      final community = DesktopGraphCommunity
          .values[settlement % DesktopGraphCommunity.values.length];
      final coreId = '$settlementId-core';
      nodes.add(
        DesktopGraphPhysicsNode(
          id: coreId,
          role: DesktopGraphNodeRole.core,
          community: community,
          settlementId: settlementId,
        ),
      );
      final memberCount = (remaining / (settlementCount - settlement)).ceil();
      remaining -= memberCount;
      for (var member = 0; member < memberCount; member++) {
        final nodeId =
            '$settlementId-note-${member.toString().padLeft(3, '0')}';
        nodes.add(
          DesktopGraphPhysicsNode(
            id: nodeId,
            role: DesktopGraphNodeRole.satellite,
            community: community,
            settlementId: settlementId,
          ),
        );
        edges.add(
          DesktopGraphPhysicsEdge(
            id: '$settlementId-edge-$member',
            sourceId: member < 4
                ? coreId
                : '$settlementId-note-${(member - 1).toString().padLeft(3, '0')}',
            targetId: nodeId,
            kind: member.isEven
                ? DesktopGraphRelationKind.communityAffinity
                : DesktopGraphRelationKind.linkedMaterial,
          ),
        );
      }
    }

    final result = layout.build(
      nodes: nodes.reversed,
      edges: edges.reversed,
      viewport: const Size(1440, 900),
    );

    expect(nodes, hasLength(2000));
    expect(result.placements, hasLength(nodes.length));
    expect(result.desiredPositions, hasLength(nodes.length));
    expect(result.normalizedDesiredPositions, hasLength(nodes.length));
    expect(
      result.placements.values
          .where((placement) => placement.localClusterIndex >= 0)
          .map((placement) => placement.settlementId)
          .toSet(),
      hasLength(settlementCount),
    );
    expect(
      result.placements.values.where((placement) => placement.isSettlementCore),
      hasLength(settlementCount),
    );
    expect(
      result.normalizedDesiredPositions.values.every(
        (position) =>
            position.dx >= 0 &&
            position.dx <= 1 &&
            position.dy >= 0 &&
            position.dy <= 1,
      ),
      isTrue,
    );
    final viewportBounds = DesktopGraphViewportBounds.forViewport(
      const Size(1440, 900),
    );
    expect(
      result.desiredPositions.values.every(viewportBounds.contains),
      isTrue,
    );

    final radialHistogram = <int, int>{};
    const center = Offset(720, 450);
    for (final placement in result.placements.values) {
      if (placement.localClusterIndex < 0) continue;
      final bucket = ((placement.desiredPosition - center).distance / 12)
          .round();
      radialHistogram[bucket] = (radialHistogram[bucket] ?? 0) + 1;
    }
    expect(
      radialHistogram.values.reduce(
        (maximum, count) => math.max(maximum, count),
      ),
      lessThan(260),
      reason: 'A single crowded radial bucket would reveal a global outer rim.',
    );
  });
}
