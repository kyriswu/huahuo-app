import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_layout.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_projection_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_render_topology.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('500 real nodes reuse finite projection buffers and stable order', () {
    const layout = SphereGraphLayout();
    final points = layout.build(
      realNodeIds: List<String>.generate(500, (index) => 'node-$index'),
      minimumVisualNodeCount: 72,
    );
    final topology = SphereGraphRenderTopology.build(
      points: points,
      visualLinks: layout.buildVisualLinks(
        points: points,
        neighborsPerPoint: 1,
      ),
      semanticEdges: List<V3GraphEdge>.generate(
        1500,
        (index) => V3GraphEdge(
          id: 'edge-$index',
          sourceId: 'node-${index % 500}',
          targetId: 'node-${(index + 1) % 500}',
          kind: V3GraphRelationKind.other,
          label: '关系 $index',
        ),
      ),
    );
    final controller = SphereGraphProjectionController()
      ..updateTopology(topology, notify: false);
    addTearDown(controller.dispose);

    expect(
      controller.project(
        viewport: const Size(390, 520),
        rotationX: -.12,
        rotationY: .24,
        notify: false,
      ),
      isTrue,
    );
    final xBuffer = controller.projectedX;
    final depthBuffer = controller.normalizedDepths;
    final orderBuffer = controller.drawOrder;
    final positionsView = controller.positions;
    expect(positionsView, hasLength(500));
    expect(topology.semanticEdgeIds, hasLength(1500));
    expect(
      positionsView.values.every(
        (position) => position.dx.isFinite && position.dy.isFinite,
      ),
      isTrue,
    );

    controller.project(
      viewport: const Size(390, 520),
      rotationX: .31,
      rotationY: -.52,
      notify: false,
    );
    expect(controller.projectedX, same(xBuffer));
    expect(controller.normalizedDepths, same(depthBuffer));
    expect(controller.drawOrder, same(orderBuffer));
    expect(controller.positions, same(positionsView));
    for (var index = 1; index < controller.drawOrder.length; index++) {
      final previous =
          controller.normalizedDepths[controller.drawOrder[index - 1]];
      final current = controller.normalizedDepths[controller.drawOrder[index]];
      expect(
        current + 1 / SphereGraphProjectionController.depthBucketCount,
        greaterThanOrEqualTo(previous),
      );
    }
  });

  test('manual positions persist and inactive projection does no work', () {
    const layout = SphereGraphLayout();
    final points = layout.build(realNodeIds: const ['a', 'b']);
    final topology = SphereGraphRenderTopology.build(
      points: points,
      visualLinks: const <SphereGraphVisualLink>[],
      semanticEdges: const <V3GraphEdge>[],
    );
    final controller = SphereGraphProjectionController()
      ..updateTopology(topology, notify: false)
      ..project(
        viewport: const Size(300, 300),
        rotationX: 0,
        rotationY: 0,
        notify: false,
      )
      ..setManualPosition('a', const Offset(42, 76), notify: false);
    addTearDown(controller.dispose);

    controller.project(
      viewport: const Size(300, 300),
      rotationX: .4,
      rotationY: .2,
      notify: false,
    );
    expect(controller.positionForId('a'), const Offset(42, 76));
    controller.clearManualPosition('a', notify: false);
    expect(controller.positionForId('a'), isNot(const Offset(42, 76)));
    final revision = controller.revision;
    controller.setActive(false);
    expect(
      controller.project(
        viewport: const Size(320, 320),
        rotationX: .7,
        rotationY: .8,
      ),
      isFalse,
    );
    expect(controller.revision, revision);
  });

  test('topology and projection retain notes beyond the 16-bit boundary', () {
    final topology = SphereGraphRenderTopology.build(
      points: List.generate(
        0x10001,
        (index) => SphereGraphLayoutPoint(
          id: 'note-$index',
          x: .2,
          y: .1,
          z: .3,
          isSynthetic: false,
        ),
      ),
      visualLinks: const [
        SphereGraphVisualLink(
          sourceId: 'note-0',
          targetId: 'note-65536',
          touchesSyntheticPoint: false,
        ),
      ],
      semanticEdges: const [],
    );
    expect(topology.visualLinkTargets.single, 65536);
    final controller = SphereGraphProjectionController()
      ..updateTopology(topology);
    addTearDown(controller.dispose);
    controller.project(
      viewport: const Size(300, 300),
      rotationX: 0,
      rotationY: 0,
    );
    expect(controller.drawOrder.toSet(), hasLength(65537));
    expect(controller.positions.length, 65537);
  });

  test('committed screen drag follows subsequent camera rotation', () {
    final controller = SphereGraphProjectionController()
      ..updateTopology(
        SphereGraphRenderTopology.build(
          points: const [
            SphereGraphLayoutPoint(
              id: 'note',
              x: .2,
              y: .1,
              z: .3,
              isSynthetic: false,
            ),
          ],
          visualLinks: const [],
          semanticEdges: const [],
        ),
      );
    addTearDown(controller.dispose);
    controller.project(
      viewport: const Size(300, 300),
      rotationX: -.2,
      rotationY: .3,
    );
    final target = controller.positionForId('note')! + const Offset(8, -5);
    controller.setManualPosition('note', target);
    final modelPoint = controller.commitManualPosition('note');
    expect(modelPoint, isNotNull);
    expect(
      (controller.positionForId('note')! - target).distance,
      lessThan(.001),
    );
    controller.project(
      viewport: const Size(300, 300),
      rotationX: -.2,
      rotationY: .7,
    );
    expect(
      (controller.positionForId('note')! - target).distance,
      greaterThan(1),
    );
  });
}
