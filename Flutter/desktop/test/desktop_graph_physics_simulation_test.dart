import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_graph_preferences.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_graph_physics_simulation.dart';

void main() {
  group('DesktopGraphPhysicsSimulation', () {
    test('keeps the existing force constants at the default scales', () {
      final physics = DesktopGraphPhysicsSimulation();
      addTearDown(physics.dispose);
      physics.synchronize(
        viewport: const Size(640, 420),
        topologyRevision: 0,
        nodes: const <DesktopGraphPhysicsNode>[
          DesktopGraphPhysicsNode(
            id: 'note',
            role: DesktopGraphNodeRole.satellite,
            community: DesktopGraphCommunity.viewpointTrend,
            seedPosition: Offset(320, 210),
          ),
        ],
        edges: const <DesktopGraphPhysicsEdge>[],
        communities: const <DesktopGraphCommunitySnapshot>[],
      );

      expect(physics.parameters, const DesktopGraphPhysicsParameters());
      expect(physics.isIdleMotionEnabled, isFalse);
      expect(physics.bodyDampingFor('note'), 4.2);
      expect(physics.layoutJointCount, 0);
    });

    test('idle motion is deterministic and remains low amplitude', () {
      final first = _singleNodeSimulation();
      final second = _singleNodeSimulation();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      first.setIdleMotionEnabled(true, notify: false);
      second.setIdleMotionEnabled(true, notify: false);
      final origin = first.positionFor('note');
      var maximumDisplacement = 0.0;

      for (var secondIndex = 0; secondIndex < 40; secondIndex++) {
        first.stepFixed(60);
        second.stepFixed(60);
        expect(first.positionFor('note'), second.positionFor('note'));
        maximumDisplacement = math.max(
          maximumDisplacement,
          (first.positionFor('note') - origin).distance,
        );
      }

      expect(maximumDisplacement, greaterThan(.1));
      expect(maximumDisplacement, lessThan(8));
    });

    test('keeps a pixel-seeded core near its centripetal community anchor', () {
      final physics = DesktopGraphPhysicsSimulation();
      addTearDown(physics.dispose);
      const radialCore = Offset(470, 320);
      physics.synchronize(
        viewport: const Size(640, 420),
        topologyRevision: 99,
        nodes: const <DesktopGraphPhysicsNode>[
          DesktopGraphPhysicsNode(
            id: 'core',
            role: DesktopGraphNodeRole.core,
            community: DesktopGraphCommunity.viewpointTrend,
            seedPosition: radialCore,
          ),
        ],
        edges: const <DesktopGraphPhysicsEdge>[],
        communities: const <DesktopGraphCommunitySnapshot>[
          DesktopGraphCommunitySnapshot(
            community: DesktopGraphCommunity.viewpointTrend,
            coreNodeId: 'core',
          ),
        ],
        notify: false,
      );

      physics.stepFixed(60);

      expect((physics.positionFor('core') - radialCore).distance, lessThan(40));
    });

    test(
      'keeps a detailed graph and remote pointer drag inside the viewport',
      () {
        final physics = DesktopGraphPhysicsSimulation();
        addTearDown(physics.dispose);
        const viewport = Size(640, 420);
        final bounds = DesktopGraphViewportBounds.forViewport(viewport);
        physics.synchronize(
          viewport: viewport,
          topologyRevision: 101,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'note',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(600, 390),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[],
          communities: const <DesktopGraphCommunitySnapshot>[],
          notify: false,
        );

        const fixtureRadius = 15.0;
        expect(
          bounds.contains(physics.positionFor('note'), inset: fixtureRadius),
          isTrue,
        );
        expect(physics.beginDrag('note', physics.positionFor('note')), isTrue);
        physics.updateDrag(const Offset(1800, 1400));
        physics.advanceForPointerUpdate();
        physics.commitDraggedPosition(const Offset(1800, 1400));

        expect(
          bounds.contains(physics.positionFor('note'), inset: fixtureRadius),
          isTrue,
        );
      },
    );

    test('idle motion keeps the simulation and its nodes awake', () {
      final physics = _singleNodeSimulation();
      addTearDown(physics.dispose);
      physics.stepFixed(physics.maximumActiveSteps);
      expect(physics.isSleeping, isTrue);

      physics.setIdleMotionEnabled(true, notify: false);
      expect(physics.isSleeping, isFalse);

      physics.stepFixed(physics.maximumActiveSteps * 5);

      expect(physics.isIdleMotionEnabled, isTrue);
      expect(physics.isSleeping, isFalse);
      expect(physics.bodyIsAwakeFor('note'), isTrue);
    });

    test('disabling idle motion restores normal automatic sleep', () {
      final physics = _singleNodeSimulation();
      addTearDown(physics.dispose);
      physics.setIdleMotionEnabled(true, notify: false);
      physics.stepFixed(physics.maximumActiveSteps * 2);

      physics.setIdleMotionEnabled(false, notify: false);
      expect(physics.isSleeping, isFalse);
      physics.stepFixed(physics.maximumActiveSteps);

      expect(physics.isIdleMotionEnabled, isFalse);
      expect(physics.isSleeping, isTrue);
      expect(physics.bodyIsAwakeFor('note'), isFalse);
    });

    test('freezing suppresses idle motion until the graph is unfrozen', () {
      final physics = _singleNodeSimulation();
      addTearDown(physics.dispose);
      physics.setIdleMotionEnabled(true, notify: false);
      physics.freeze(notify: false);
      final before = physics.positions;

      physics.stepFixed(physics.maximumActiveSteps * 2);
      expect(physics.advanceFrame(const Duration(milliseconds: 16)), isFalse);
      expect(physics.advanceFrame(const Duration(milliseconds: 32)), isFalse);

      expect(physics.isFrozen, isTrue);
      expect(physics.isSleeping, isFalse);
      expect(physics.positions, before);

      physics.unfreeze(notify: false);
      physics.stepFixed(60);
      expect(physics.positions, isNot(before));
    });

    test(
      'separates overlapping nodes with the mobile collision and repulsion',
      () {
        final physics = DesktopGraphPhysicsSimulation();
        addTearDown(physics.dispose);
        physics.synchronize(
          viewport: const Size(640, 420),
          topologyRevision: 1,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'left',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(320, 210),
            ),
            DesktopGraphPhysicsNode(
              id: 'right',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.method,
              seedPosition: Offset(320, 210),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[],
          communities: const <DesktopGraphCommunitySnapshot>[],
        );

        expect(physics.isSleeping, isFalse);
        expect(physics.maximumActiveSteps, 180);
        physics.stepFixed(12);

        final separation =
            (physics.positionFor('left') - physics.positionFor('right'))
                .distance;
        expect(separation, greaterThan(1));
      },
    );

    test('uses settlement IDs for detailed local repulsion', () {
      DesktopGraphPhysicsSimulation build(String rightSettlementId) {
        final physics = DesktopGraphPhysicsSimulation();
        physics.synchronize(
          viewport: const Size(640, 420),
          topologyRevision: 140,
          nodes: <DesktopGraphPhysicsNode>[
            const DesktopGraphPhysicsNode(
              id: 'left',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              settlementId: 'settlement-amber',
              seedPosition: Offset(280, 210),
            ),
            DesktopGraphPhysicsNode(
              id: 'right',
              role: DesktopGraphNodeRole.satellite,
              // Same palette category on purpose: only the physical
              // settlement may decide the local-repulsion strength.
              community: DesktopGraphCommunity.viewpointTrend,
              settlementId: rightSettlementId,
              seedPosition: const Offset(315, 210),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[],
          communities: const <DesktopGraphCommunitySnapshot>[],
          notify: false,
        );
        return physics;
      }

      final sameSettlement = build('settlement-amber');
      final separateSettlements = build('settlement-cobalt');
      addTearDown(sameSettlement.dispose);
      addTearDown(separateSettlements.dispose);

      sameSettlement.stepFixed(8);
      separateSettlements.stepFixed(8);

      final sameDistance =
          (sameSettlement.positionFor('left') -
                  sameSettlement.positionFor('right'))
              .distance;
      final separateDistance =
          (separateSettlements.positionFor('left') -
                  separateSettlements.positionFor('right'))
              .distance;
      expect(sameDistance, greaterThan(separateDistance + .1));
    });

    test('uses distinct no-seed anchors for detailed settlements', () {
      final physics = DesktopGraphPhysicsSimulation();
      addTearDown(physics.dispose);
      physics.synchronize(
        viewport: const Size(640, 420),
        topologyRevision: 141,
        nodes: const <DesktopGraphPhysicsNode>[
          DesktopGraphPhysicsNode(
            id: 'amber-core',
            role: DesktopGraphNodeRole.core,
            community: DesktopGraphCommunity.viewpointTrend,
            settlementId: 'settlement-amber',
          ),
          DesktopGraphPhysicsNode(
            id: 'cobalt-core',
            role: DesktopGraphNodeRole.core,
            // Deliberately the same palette category as amber.
            community: DesktopGraphCommunity.viewpointTrend,
            settlementId: 'settlement-cobalt',
          ),
        ],
        edges: const <DesktopGraphPhysicsEdge>[],
        communities: const <DesktopGraphCommunitySnapshot>[],
        notify: false,
      );

      expect(physics.anchorBodyCount, 2);
      expect(
        (physics.positionFor('amber-core') - physics.positionFor('cobalt-core'))
            .distance,
        greaterThan(20),
      );
    });

    test(
      'attracts related nodes through a mobile-equivalent distance joint',
      () {
        final physics = DesktopGraphPhysicsSimulation();
        addTearDown(physics.dispose);
        physics.synchronize(
          viewport: const Size(640, 420),
          topologyRevision: 2,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'core',
              role: DesktopGraphNodeRole.core,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(120, 110),
            ),
            DesktopGraphPhysicsNode(
              id: 'material',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(520, 320),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[
            DesktopGraphPhysicsEdge(
              id: 'relation',
              sourceId: 'core',
              targetId: 'material',
              kind: DesktopGraphRelationKind.communityAffinity,
            ),
          ],
          communities: const <DesktopGraphCommunitySnapshot>[
            DesktopGraphCommunitySnapshot(
              community: DesktopGraphCommunity.viewpointTrend,
              coreNodeId: 'core',
            ),
          ],
        );

        final before =
            (physics.positionFor('core') - physics.positionFor('material'))
                .distance;
        expect(physics.physicalJointCount, 1);
        physics.stepFixed(30);
        final after =
            (physics.positionFor('core') - physics.positionFor('material'))
                .distance;

        expect(after, lessThan(before));
      },
    );

    test('attraction scale changes how quickly related nodes converge', () {
      final low = _relatedPair(attractionScale: .35);
      final high = _relatedPair(attractionScale: 2);
      addTearDown(low.dispose);
      addTearDown(high.dispose);

      low.stepFixed(8);
      high.stepFixed(8);

      final lowDistance =
          (low.positionFor('left') - low.positionFor('right')).distance;
      final highDistance =
          (high.positionFor('left') - high.positionFor('right')).distance;
      expect(highDistance, lessThan(lowDistance));
    });

    test('repulsion scale changes how quickly nearby nodes separate', () {
      final low = _overlappingPair(repulsionScale: .25);
      final high = _overlappingPair(repulsionScale: 2.25);
      addTearDown(low.dispose);
      addTearDown(high.dispose);

      low.stepFixed(8);
      high.stepFixed(8);

      final lowSeparation =
          (low.positionFor('left') - low.positionFor('right')).distance;
      final highSeparation =
          (high.positionFor('left') - high.positionFor('right')).distance;
      expect(highSeparation, greaterThan(lowSeparation));
    });

    test('damping scale changes how much momentum nodes retain', () {
      final low = _overlappingPair(dampingScale: .2);
      final high = _overlappingPair(dampingScale: 2);
      addTearDown(low.dispose);
      addTearDown(high.dispose);

      expect(
        low.bodyDampingFor('left'),
        closeTo(4.2 * DesktopGraphPreferences.dampingResponseFor(.2), .000001),
      );
      expect(
        high.bodyDampingFor('left'),
        closeTo(4.2 * DesktopGraphPreferences.dampingResponseFor(2), .000001),
      );
      low.stepFixed(16);
      high.stepFixed(16);

      final lowSeparation =
          (low.positionFor('left') - low.positionFor('right')).distance;
      final highSeparation =
          (high.positionFor('left') - high.positionFor('right')).distance;
      expect(lowSeparation, greaterThan(highSeparation));
    });

    test('updates parameters in place without leaking layout resources', () {
      final physics = _relatedPair(
        attractionScale: 1,
        includeCommunityAnchor: true,
      );
      addTearDown(physics.dispose);
      final positions = physics.positions;

      expect(physics.physicalJointCount, 1);
      expect(physics.layoutJointCount, 2);
      expect(physics.anchorBodyCount, 1);
      expect(physics.worldJointCount, 2);
      expect(physics.worldBodyCount, 4);

      physics.updateParameters(
        attractionScale: 1.5,
        repulsionScale: 1.25,
        dampingScale: 1.2,
      );

      expect(physics.positions, positions);
      expect(physics.layoutRevision, 1);
      expect(physics.layoutJointCount, 2);
      expect(physics.anchorBodyCount, 1);
      expect(physics.worldJointCount, 2);
      expect(physics.worldBodyCount, 4);

      physics.updateParameters(
        attractionScale: 1.5,
        repulsionScale: 1.25,
        dampingScale: 1.2,
      );
      expect(physics.layoutRevision, 1);
      expect(physics.worldJointCount, 2);
      expect(physics.worldBodyCount, 4);

      for (var index = 0; index < 6; index++) {
        physics.updateParameters(
          attractionScale: index.isEven ? .8 : 1.5,
          repulsionScale: 1.25,
          dampingScale: index.isEven ? .7 : 1.2,
        );
        expect(physics.layoutJointCount, 2);
        expect(physics.anchorBodyCount, 1);
        expect(physics.worldJointCount, 2);
        expect(physics.worldBodyCount, 4);
      }
    });

    test(
      'parameter changes wake sleeping nodes but never move while frozen',
      () {
        final sleeper = DesktopGraphPhysicsSimulation();
        addTearDown(sleeper.dispose);
        sleeper.synchronize(
          viewport: const Size(640, 420),
          topologyRevision: 20,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'still',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(320, 210),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[],
          communities: const <DesktopGraphCommunitySnapshot>[],
        );
        sleeper.stepFixed(sleeper.maximumActiveSteps);
        expect(sleeper.isSleeping, isTrue);

        sleeper.updateParameters(
          attractionScale: 1,
          repulsionScale: 1.5,
          dampingScale: 1,
        );
        expect(sleeper.isSleeping, isFalse);

        final frozen = _overlappingPair();
        addTearDown(frozen.dispose);
        frozen.freeze();
        final before = frozen.positions;
        frozen.updateParameters(
          attractionScale: 1.4,
          repulsionScale: 2.25,
          dampingScale: .6,
        );

        expect(frozen.isFrozen, isTrue);
        expect(frozen.isSleeping, isFalse);
        frozen.stepFixed(12);
        expect(frozen.positions, before);
        expect(frozen.advanceFrame(const Duration(milliseconds: 16)), isFalse);
        expect(frozen.advanceFrame(const Duration(milliseconds: 32)), isFalse);
        expect(frozen.positions, before);

        frozen.unfreeze();
        frozen.stepFixed(12);
        expect(
          (frozen.positionFor('left') - frozen.positionFor('right')).distance,
          greaterThan(1),
        );
      },
    );

    test(
      'drags with a mouse joint then returns the node to live simulation',
      () {
        final physics = DesktopGraphPhysicsSimulation();
        addTearDown(physics.dispose);
        physics.synchronize(
          viewport: const Size(640, 420),
          topologyRevision: 3,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'note',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.caseIndustry,
              seedPosition: Offset(120, 110),
            ),
          ],
          edges: const <DesktopGraphPhysicsEdge>[],
          communities: const <DesktopGraphCommunitySnapshot>[],
        );

        expect(physics.beginDrag('note', const Offset(120, 110)), isTrue);
        expect(physics.draggedNodeId, 'note');
        final beforeLiveUpdate = physics.positionFor('note');
        physics.updateDrag(const Offset(560, 320));
        physics.advanceForPointerUpdate();

        final movedDuringDrag = physics.positionFor('note');
        expect(movedDuringDrag.dx, greaterThan(beforeLiveUpdate.dx));
        expect(movedDuringDrag.dy, greaterThan(beforeLiveUpdate.dy));

        physics.stepFixed(9);
        final moved = physics.positionFor('note');
        expect(moved.dx, greaterThan(movedDuringDrag.dx));
        expect(moved.dy, greaterThan(movedDuringDrag.dy));

        const previewTarget = Offset(560, 320);
        physics.commitDraggedPosition(previewTarget);
        final committed = physics.positionFor('note');
        final expectedTarget = DesktopGraphViewportBounds.forViewport(
          const Size(640, 420),
        ).clamp(previewTarget, inset: 16);
        expect(committed.dx, closeTo(expectedTarget.dx, .001));
        expect(committed.dy, closeTo(expectedTarget.dy, .001));

        final released = physics.endDrag();
        expect(released, isNotNull);
        expect(physics.draggedNodeId, isNull);
        expect(physics.isSleeping, isFalse);
      },
    );
  });

  group('DesktopDenseGraphPhysicsSimulation', () {
    test('keeps every large-graph point in a bounded force layout', () {
      final physics = _denseSimulation(documentCount: 2000);
      addTearDown(physics.dispose);

      expect(
        DesktopDenseGraphPhysicsSimulation.fixedStep,
        closeTo(1 / 60, 1e-12),
      );
      expect(physics.bodyCount, 1996);
      expect(physics.communityCount, 4);
      expect(physics.positions, hasLength(2001));

      physics.setIdleMotionEnabled(true, notify: false);
      physics.stepFixed(4);

      expect(
        physics.positions.values.every((position) {
          return position.dx >= .025 &&
              position.dx <= .975 &&
              position.dy >= .025 &&
              position.dy <= .975;
        }),
        isTrue,
      );
      final bounds = DesktopGraphViewportBounds.forViewport(
        const Size(1440, 900),
      );
      expect(
        physics.positions.values.every(
          (position) => bounds.contains(bounds.fromNormalized(position)),
        ),
        isTrue,
      );
      expect(physics.activeNeighborPairCount, lessThan(50000));
    });

    test('keeps explicit large-graph settlements physically independent', () {
      const settlementCount = 32;
      const documentCount = 2000;
      const goldenAngle = 2.399963229728653;
      final nodes = <DesktopGraphPhysicsNode>[
        const DesktopGraphPhysicsNode(
          id: 'brain',
          role: DesktopGraphNodeRole.center,
          community: DesktopGraphCommunity.viewpointTrend,
        ),
        for (var index = 0; index < settlementCount; index++)
          DesktopGraphPhysicsNode(
            id: 'settlement-core-$index',
            role: DesktopGraphNodeRole.core,
            community: DesktopGraphCommunity
                .values[index % DesktopGraphCommunity.values.length],
            settlementId: 'settlement-$index',
            seedPosition: Offset(
              .5 + math.cos(index * goldenAngle) * (.035 + index * .004),
              .5 + math.sin(index * goldenAngle) * (.035 + index * .004),
            ),
          ),
        for (var index = 0; index < documentCount - settlementCount; index++)
          DesktopGraphPhysicsNode(
            id: 'settlement-note-${index.toString().padLeft(4, '0')}',
            role: DesktopGraphNodeRole.satellite,
            community: DesktopGraphCommunity
                .values[index % DesktopGraphCommunity.values.length],
            settlementId: 'settlement-${index % settlementCount}',
          ),
      ];
      final physics = DesktopDenseGraphPhysicsSimulation();
      addTearDown(physics.dispose);

      physics.synchronize(
        viewport: const Size(1440, 900),
        topologyRevision: 2000,
        nodes: nodes,
        notify: false,
      );

      expect(physics.settlementCount, settlementCount);
      expect(physics.bodyCount, documentCount - settlementCount);
      expect(physics.positions, hasLength(documentCount + 1));
      expect(<Offset>{
        for (var index = 0; index < settlementCount; index++)
          physics.positionFor('settlement-core-$index'),
      }, hasLength(settlementCount));
    });

    test('keeps dense community cores as a compact central constellation', () {
      final physics = _denseSimulation(documentCount: 64);
      addTearDown(physics.dispose);
      const viewport = Size(1440, 900);
      final bounds = DesktopGraphViewportBounds.forViewport(viewport);
      final center = bounds.center;

      physics.setIdleMotionEnabled(false, notify: false);
      physics.stepFixed(72);

      final corePositions = <Offset>[
        for (final community in DesktopGraphCommunity.values)
          bounds.fromNormalized(physics.positionFor('core-${community.name}')),
      ];
      expect(
        corePositions.every(
          (position) => (position - center).distance < viewport.height * .22,
        ),
        isTrue,
      );
      for (var index = 0; index < corePositions.length; index++) {
        for (
          var otherIndex = index + 1;
          otherIndex < corePositions.length;
          otherIndex++
        ) {
          expect(
            (corePositions[index] - corePositions[otherIndex]).distance,
            greaterThan(24),
          );
        }
      }
    });

    test(
      'uses normalized centripetal seeds as dense homes and note spring targets',
      () {
        final physics = DesktopDenseGraphPhysicsSimulation();
        addTearDown(physics.dispose);
        const nodes = <DesktopGraphPhysicsNode>[
          DesktopGraphPhysicsNode(
            id: 'brain',
            role: DesktopGraphNodeRole.center,
            community: DesktopGraphCommunity.viewpointTrend,
          ),
          DesktopGraphPhysicsNode(
            id: 'core',
            role: DesktopGraphNodeRole.core,
            community: DesktopGraphCommunity.viewpointTrend,
            seedPosition: Offset(.32, .36),
          ),
          DesktopGraphPhysicsNode(
            id: 'note',
            role: DesktopGraphNodeRole.satellite,
            community: DesktopGraphCommunity.viewpointTrend,
            seedPosition: Offset(.41, .57),
          ),
        ];

        physics.synchronize(
          viewport: const Size(1440, 900),
          topologyRevision: 500,
          nodes: nodes,
          notify: false,
        );

        expect(physics.positionFor('core').dx, closeTo(.32, .000001));
        expect(physics.positionFor('core').dy, closeTo(.36, .000001));
        expect(physics.positionFor('note').dx, closeTo(.41, .000001));
        expect(physics.positionFor('note').dy, closeTo(.57, .000001));

        physics.reset(notify: false);
        expect(physics.positionFor('note').dx, closeTo(.41, .000001));
        expect(physics.positionFor('note').dy, closeTo(.57, .000001));

        final beforeDrag = physics.positionFor('note');
        expect(physics.beginDrag('note', beforeDrag), isTrue);
        physics.updateDrag(beforeDrag + const Offset(.09, -.06), notify: false);
        physics.advanceForPointerUpdate();
        final livePosition = physics.positionFor('note');

        physics.synchronize(
          viewport: const Size(1440, 900),
          topologyRevision: 500,
          nodes: const <DesktopGraphPhysicsNode>[
            DesktopGraphPhysicsNode(
              id: 'brain',
              role: DesktopGraphNodeRole.center,
              community: DesktopGraphCommunity.viewpointTrend,
            ),
            DesktopGraphPhysicsNode(
              id: 'core',
              role: DesktopGraphNodeRole.core,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(.72, .71),
            ),
            DesktopGraphPhysicsNode(
              id: 'note',
              role: DesktopGraphNodeRole.satellite,
              community: DesktopGraphCommunity.viewpointTrend,
              seedPosition: Offset(.83, .77),
            ),
          ],
          notify: false,
        );

        expect(physics.positionFor('note'), livePosition);
      },
    );

    test('attraction, repulsion, and damping change dense graph motion', () {
      final lowAttraction = _denseSimulation(documentCount: 28);
      final highAttraction = _denseSimulation(documentCount: 28);
      final lowRepulsion = _denseSimulation(documentCount: 28);
      final highRepulsion = _denseSimulation(documentCount: 28);
      final lowDamping = _denseSimulation(documentCount: 28);
      final highDamping = _denseSimulation(documentCount: 28);
      addTearDown(lowAttraction.dispose);
      addTearDown(highAttraction.dispose);
      addTearDown(lowRepulsion.dispose);
      addTearDown(highRepulsion.dispose);
      addTearDown(lowDamping.dispose);
      addTearDown(highDamping.dispose);

      const satelliteId = 'satellite-0000';
      final initial = lowAttraction.positionFor(satelliteId);
      final pullTarget = initial + const Offset(.17, -.11);
      for (final physics in <DesktopDenseGraphPhysicsSimulation>[
        lowAttraction,
        highAttraction,
        lowDamping,
        highDamping,
      ]) {
        expect(physics.beginDrag(satelliteId, initial), isTrue);
        physics.updateDrag(pullTarget);
        physics.stepFixed(4);
        physics.endDrag();
      }

      lowAttraction.updateParameters(
        attractionScale: .35,
        repulsionScale: 1,
        dampingScale: 1,
        notify: false,
      );
      highAttraction.updateParameters(
        attractionScale: 2,
        repulsionScale: 1,
        dampingScale: 1,
        notify: false,
      );
      lowDamping.updateParameters(
        attractionScale: 1,
        repulsionScale: 1,
        dampingScale: .2,
        notify: false,
      );
      highDamping.updateParameters(
        attractionScale: 1,
        repulsionScale: 1,
        dampingScale: 2,
        notify: false,
      );
      lowRepulsion.updateParameters(
        attractionScale: 1,
        repulsionScale: .25,
        dampingScale: 1,
        notify: false,
      );
      highRepulsion.updateParameters(
        attractionScale: 1,
        repulsionScale: 2.25,
        dampingScale: 1,
        notify: false,
      );

      for (var index = 0; index < 18; index++) {
        lowAttraction.stepFixed();
        highAttraction.stepFixed();
        lowRepulsion.stepFixed();
        highRepulsion.stepFixed();
        lowDamping.stepFixed();
        highDamping.stepFixed();
      }

      final lowAttractionDistance =
          (lowAttraction.positionFor(satelliteId) - initial).distance;
      final highAttractionDistance =
          (highAttraction.positionFor(satelliteId) - initial).distance;
      expect(highAttractionDistance, lessThan(lowAttractionDistance));

      const coreId = 'core-viewpointTrend';
      final lowRepulsionDistance =
          (lowRepulsion.positionFor(satelliteId) -
                  lowRepulsion.positionFor(coreId))
              .distance;
      final highRepulsionDistance =
          (highRepulsion.positionFor(satelliteId) -
                  highRepulsion.positionFor(coreId))
              .distance;
      expect(highRepulsionDistance, greaterThan(lowRepulsionDistance));

      expect(
        lowDamping.velocityFor(satelliteId).distance,
        greaterThan(highDamping.velocityFor(satelliteId).distance),
      );
    });

    test('dragging a dense core pulls its community through springs', () {
      final physics = _denseSimulation(documentCount: 64);
      addTearDown(physics.dispose);
      const coreId = 'core-viewpointTrend';
      const satelliteId = 'satellite-0000';
      final coreBefore = physics.positionFor(coreId);
      final satelliteBefore = physics.positionFor(satelliteId);

      expect(physics.beginDrag(coreId, coreBefore), isTrue);
      physics.updateDrag(coreBefore + const Offset(.16, .08));
      physics.advanceForPointerUpdate();

      final coreDelta = (physics.positionFor(coreId) - coreBefore).distance;
      final satelliteDelta =
          (physics.positionFor(satelliteId) - satelliteBefore).distance;
      expect(coreDelta, greaterThan(.02));
      expect(satelliteDelta, greaterThan(0));
      expect(satelliteDelta, lessThan(coreDelta));

      physics.endDrag();
      physics.stepFixed(24);
      expect(
        (physics.positionFor(satelliteId) - satelliteBefore).distance,
        greaterThan(satelliteDelta),
      );
    });

    test('dense live drag preserves the active ticker clock', () {
      final physics = _denseSimulation(documentCount: 64);
      addTearDown(physics.dispose);
      const coreId = 'core-viewpointTrend';
      final start = physics.positionFor(coreId);

      expect(physics.beginDrag(coreId, start), isTrue);
      expect(physics.advanceFrame(Duration.zero), isFalse);

      physics.updateDrag(start + const Offset(.12, .06));

      expect(physics.advanceFrame(const Duration(milliseconds: 40)), isTrue);
    });

    test(
      'dense release commits the final pointer preview without a return jump',
      () {
        final physics = _denseSimulation(documentCount: 64);
        addTearDown(physics.dispose);
        const coreId = 'core-viewpointTrend';
        final start = physics.positionFor(coreId);
        final previewTarget = start + const Offset(.16, .08);

        expect(physics.beginDrag(coreId, start), isTrue);
        physics.updateDrag(previewTarget, notify: false);
        physics.commitDraggedPosition(previewTarget);

        final committed = physics.positionFor(coreId);
        expect(committed.dx, closeTo(previewTarget.dx, .001));
        expect(committed.dy, closeTo(previewTarget.dy, .001));
        expect(physics.endDrag(), isNotNull);
      },
    );

    test('keeps a dense remote drag inside the viewport', () {
      final physics = _denseSimulation(documentCount: 64);
      addTearDown(physics.dispose);
      const viewport = Size(1440, 900);
      final bounds = DesktopGraphViewportBounds.forViewport(viewport);
      const coreId = 'core-viewpointTrend';
      final start = physics.positionFor(coreId);

      expect(physics.beginDrag(coreId, start), isTrue);
      physics.updateDrag(const Offset(1.8, 1.6), notify: false);
      physics.commitDraggedPosition(const Offset(1.8, 1.6));

      expect(
        bounds.contains(bounds.fromNormalized(physics.positionFor(coreId))),
        isTrue,
      );
    });

    test('dragging a dense satellite does not hard-move its core', () {
      final physics = _denseSimulation(documentCount: 64);
      addTearDown(physics.dispose);
      const coreId = 'core-viewpointTrend';
      const satelliteId = 'satellite-0000';
      final coreBefore = physics.positionFor(coreId);
      final satelliteBefore = physics.positionFor(satelliteId);

      expect(physics.beginDrag(satelliteId, satelliteBefore), isTrue);
      physics.updateDrag(satelliteBefore + const Offset(.18, .08));
      physics.stepFixed();

      expect(
        (physics.positionFor(satelliteId) - satelliteBefore).distance,
        greaterThan(.02),
      );
      expect(
        (physics.positionFor(coreId) - coreBefore).distance,
        lessThan(.002),
      );
    });
  });
}

DesktopGraphPhysicsSimulation _singleNodeSimulation() {
  final physics = DesktopGraphPhysicsSimulation();
  physics.synchronize(
    viewport: const Size(640, 420),
    topologyRevision: 100,
    nodes: const <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'note',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.viewpointTrend,
        seedPosition: Offset(320, 210),
      ),
    ],
    edges: const <DesktopGraphPhysicsEdge>[],
    communities: const <DesktopGraphCommunitySnapshot>[],
    notify: false,
  );
  return physics;
}

DesktopGraphPhysicsSimulation _relatedPair({
  double attractionScale = 1,
  double repulsionScale = 1,
  double dampingScale = 1,
  bool includeCommunityAnchor = false,
}) {
  final physics = DesktopGraphPhysicsSimulation();
  physics.updateParameters(
    attractionScale: attractionScale,
    repulsionScale: repulsionScale,
    dampingScale: dampingScale,
    notify: false,
  );
  physics.synchronize(
    viewport: const Size(640, 420),
    topologyRevision: 101,
    nodes: const <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'left',
        role: DesktopGraphNodeRole.core,
        community: DesktopGraphCommunity.viewpointTrend,
        seedPosition: Offset(100, 210),
      ),
      DesktopGraphPhysicsNode(
        id: 'right',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.viewpointTrend,
        seedPosition: Offset(540, 210),
      ),
    ],
    edges: const <DesktopGraphPhysicsEdge>[
      DesktopGraphPhysicsEdge(
        id: 'relation',
        sourceId: 'left',
        targetId: 'right',
        kind: DesktopGraphRelationKind.communityAffinity,
      ),
    ],
    communities: includeCommunityAnchor
        ? const <DesktopGraphCommunitySnapshot>[
            DesktopGraphCommunitySnapshot(
              community: DesktopGraphCommunity.viewpointTrend,
              coreNodeId: 'left',
            ),
          ]
        : const <DesktopGraphCommunitySnapshot>[],
    notify: false,
  );
  return physics;
}

DesktopGraphPhysicsSimulation _overlappingPair({
  double attractionScale = 1,
  double repulsionScale = 1,
  double dampingScale = 1,
}) {
  final physics = DesktopGraphPhysicsSimulation();
  physics.updateParameters(
    attractionScale: attractionScale,
    repulsionScale: repulsionScale,
    dampingScale: dampingScale,
    notify: false,
  );
  physics.synchronize(
    viewport: const Size(640, 420),
    topologyRevision: 102,
    nodes: const <DesktopGraphPhysicsNode>[
      DesktopGraphPhysicsNode(
        id: 'left',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.viewpointTrend,
        seedPosition: Offset(320, 210),
      ),
      DesktopGraphPhysicsNode(
        id: 'right',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity.method,
        seedPosition: Offset(320, 210),
      ),
    ],
    edges: const <DesktopGraphPhysicsEdge>[],
    communities: const <DesktopGraphCommunitySnapshot>[],
    notify: false,
  );
  return physics;
}

DesktopDenseGraphPhysicsSimulation _denseSimulation({
  required int documentCount,
}) {
  final nodes = <DesktopGraphPhysicsNode>[
    const DesktopGraphPhysicsNode(
      id: 'brain',
      role: DesktopGraphNodeRole.center,
      community: DesktopGraphCommunity.viewpointTrend,
    ),
    for (final community in DesktopGraphCommunity.values)
      DesktopGraphPhysicsNode(
        id: 'core-${community.name}',
        role: DesktopGraphNodeRole.core,
        community: community,
      ),
    for (
      var index = 0;
      index < math.max(0, documentCount - DesktopGraphCommunity.values.length);
      index++
    )
      DesktopGraphPhysicsNode(
        id: 'satellite-${index.toString().padLeft(4, '0')}',
        role: DesktopGraphNodeRole.satellite,
        community: DesktopGraphCommunity
            .values[index % DesktopGraphCommunity.values.length],
      ),
  ];
  final physics = DesktopDenseGraphPhysicsSimulation();
  physics.synchronize(
    viewport: const Size(1440, 900),
    topologyRevision: documentCount,
    nodes: nodes,
    notify: false,
  );
  return physics;
}
