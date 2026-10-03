import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_layout.dart';

void main() {
  const layout = SphereGraphLayout();

  test('build is deterministic, order independent, and irregular', () {
    final first = layout.build(
      realNodeIds: const ['note-c', 'note-a', 'note-b'],
      minimumVisualNodeCount: 48,
    );
    final second = layout.build(
      realNodeIds: const ['note-b', 'note-c', 'note-a'],
      minimumVisualNodeCount: 48,
    );

    expect(first, second);
    expect(first, hasLength(48));
    expect(first.every((point) => point.radius <= 1), isTrue);
    expect(
      first.map((point) => point.radius).reduce(math.max),
      greaterThan(.9),
    );
    expect(
      first.map((point) => point.radius).reduce(math.max) -
          first.map((point) => point.radius).reduce(math.min),
      greaterThan(.2),
    );
    expect(
      first.where((point) => point.radius >= .75).length,
      greaterThan(first.length * .65),
    );
    final roundedNeighborDistances = <double>{
      for (var index = 1; index < first.length; index++)
        double.parse(
          _distance(first[index - 1], first[index]).toStringAsFixed(3),
        ),
    };
    expect(roundedNeighborDistances.length, greaterThan(12));
  });

  test('synthetic fillers never mutate or replace real graph IDs', () {
    final realIds = <String>['asset-2', 'asset-1'];
    final before = List<String>.of(realIds);
    final points = layout.build(
      realNodeIds: realIds,
      minimumVisualNodeCount: 20,
    );

    expect(realIds, before);
    expect(points.where((point) => !point.isSynthetic), hasLength(2));
    expect(
      points.where((point) => !point.isSynthetic).map((point) => point.id),
      unorderedEquals(realIds),
    );
    expect(points.where((point) => point.isSynthetic), hasLength(18));

    final dense = layout.build(
      realNodeIds: List<String>.generate(24, (index) => 'real-$index'),
      minimumVisualNodeCount: 12,
    );
    expect(dense, hasLength(24));
    expect(dense.every((point) => !point.isSynthetic), isTrue);
  });

  test('existing real coordinates survive changes below visual minimum', () {
    final initial = layout.build(
      realNodeIds: const ['asset-a', 'asset-b', 'asset-c'],
      minimumVisualNodeCount: 12,
    );
    final afterAddition = layout.build(
      realNodeIds: const ['asset-d', 'asset-c', 'asset-a', 'asset-b'],
      minimumVisualNodeCount: 12,
    );
    final afterRemoval = layout.build(
      realNodeIds: const ['asset-c', 'asset-a'],
      minimumVisualNodeCount: 12,
    );
    final initialById = {for (final point in initial) point.id: point};
    final additionById = {for (final point in afterAddition) point.id: point};
    final removalById = {for (final point in afterRemoval) point.id: point};

    for (final id in const ['asset-a', 'asset-b', 'asset-c']) {
      expect(additionById[id], initialById[id], reason: '$id moved on add');
    }
    for (final id in const ['asset-a', 'asset-c']) {
      expect(removalById[id], initialById[id], reason: '$id moved on remove');
    }
  });

  test('existing real coordinates survive crossing visual minimum', () {
    final belowIds = List<String>.generate(11, (index) => 'asset-$index');
    final atThresholdIds = <String>[...belowIds, 'asset-11'];
    final aboveIds = <String>[...atThresholdIds, 'asset-12', 'asset-13'];
    final below = layout.build(
      realNodeIds: belowIds,
      minimumVisualNodeCount: 12,
    );
    final atThreshold = layout.build(
      realNodeIds: atThresholdIds.reversed,
      minimumVisualNodeCount: 12,
    );
    final above = layout.build(
      realNodeIds: aboveIds,
      minimumVisualNodeCount: 12,
    );
    final belowById = {for (final point in below) point.id: point};
    final thresholdById = {for (final point in atThreshold) point.id: point};
    final aboveById = {for (final point in above) point.id: point};

    expect(below.where((point) => point.isSynthetic), hasLength(1));
    expect(atThreshold.every((point) => !point.isSynthetic), isTrue);
    expect(above.every((point) => !point.isSynthetic), isTrue);
    for (final id in belowIds) {
      expect(thresholdById[id], belowById[id], reason: '$id moved at limit');
      expect(aboveById[id], belowById[id], reason: '$id moved above limit');
    }
  });

  test('ID-derived volume spans front, back, inner, and outer regions', () {
    final points = layout.build(
      realNodeIds: List<String>.generate(160, (index) => 'volume-$index'),
      minimumVisualNodeCount: 0,
    );

    expect(points.any((point) => point.z < -.65), isTrue);
    expect(points.any((point) => point.z > .65), isTrue);
    expect(points.any((point) => point.radius < .65), isTrue);
    expect(points.any((point) => point.radius > .9), isTrue);
  });

  test('projection rotates depth and keeps perspective monotonic', () {
    const points = <SphereGraphLayoutPoint>[
      SphereGraphLayoutPoint(
        id: 'front',
        x: 0,
        y: 0,
        z: .9,
        isSynthetic: false,
      ),
      SphereGraphLayoutPoint(
        id: 'middle',
        x: .4,
        y: .1,
        z: 0,
        isSynthetic: false,
      ),
      SphereGraphLayoutPoint(
        id: 'back',
        x: 0,
        y: 0,
        z: -.9,
        isSynthetic: false,
      ),
    ];
    final neutral = layout.project(
      points: points,
      viewport: const Size(390, 520),
    );
    final byId = {for (final point in neutral) point.id: point};

    expect(neutral.map((point) => point.id), ['back', 'middle', 'front']);
    expect(byId['front']!.sizeFactor, greaterThan(byId['back']!.sizeFactor));
    expect(byId['front']!.opacity, greaterThan(byId['back']!.opacity));
    expect(
      byId['front']!.sizeFactor / byId['back']!.sizeFactor,
      greaterThan(2),
    );
    expect(byId['front']!.opacity / byId['back']!.opacity, greaterThan(4));
    expect(byId['front']!.depth, greaterThan(byId['middle']!.depth));
    expect(byId['middle']!.depth, greaterThan(byId['back']!.depth));

    final reversed = layout.project(
      points: points,
      viewport: const Size(390, 520),
      rotationY: math.pi,
    );
    final reversedById = {for (final point in reversed) point.id: point};
    expect(
      reversedById['front']!.cameraDepth,
      closeTo(-byId['front']!.cameraDepth, 1e-10),
    );
    expect(
      reversedById['back']!.cameraDepth,
      closeTo(-byId['back']!.cameraDepth, 1e-10),
    );
  });

  test('neutral projection stays in viewport and zoom expands positions', () {
    final points = layout.build(
      realNodeIds: List<String>.generate(64, (index) => 'node-$index'),
      minimumVisualNodeCount: 64,
    );
    const viewport = Size(390, 520);
    final neutral = layout.project(points: points, viewport: viewport);
    final zoomed = layout.project(
      points: points,
      viewport: viewport,
      rotationX: .31,
      rotationY: -.58,
      zoom: 1.8,
    );

    expect(
      neutral.every(
        (point) =>
            point.position.dx >= 0 &&
            point.position.dx <= viewport.width &&
            point.position.dy >= 0 &&
            point.position.dy <= viewport.height,
      ),
      isTrue,
    );
    final center = viewport.center(Offset.zero);
    final neutralAverage =
        neutral
            .map((point) => (point.position - center).distance)
            .reduce((left, right) => left + right) /
        neutral.length;
    final zoomedAverage =
        zoomed
            .map((point) => (point.position - center).distance)
            .reduce((left, right) => left + right) /
        zoomed.length;
    expect(zoomedAverage, greaterThan(neutralAverage * 1.5));
  });

  test('synthetic points retain depth but use quieter opacity', () {
    const real = SphereGraphLayoutPoint(
      id: 'real',
      x: .2,
      y: .1,
      z: .5,
      isSynthetic: false,
    );
    const synthetic = SphereGraphLayoutPoint(
      id: 'synthetic',
      x: .2,
      y: .1,
      z: .5,
      isSynthetic: true,
    );
    final projected = layout.project(
      points: const [real, synthetic],
      viewport: const Size(390, 520),
    );
    final byId = {for (final point in projected) point.id: point};

    expect(byId['real']!.position, byId['synthetic']!.position);
    expect(byId['real']!.depth, byId['synthetic']!.depth);
    expect(byId['real']!.sizeFactor, byId['synthetic']!.sizeFactor);
    expect(byId['synthetic']!.opacity, lessThan(byId['real']!.opacity));
  });

  test('visual links are deterministic, unique, and fully connected', () {
    final points = layout.build(
      realNodeIds: const ['one', 'two', 'three'],
      minimumVisualNodeCount: 36,
    );
    final first = layout.buildVisualLinks(points: points);
    final second = layout.buildVisualLinks(points: points);

    expect(first, second);
    expect(first.length, greaterThanOrEqualTo(points.length - 1));
    expect(first.every((link) => link.sourceId != link.targetId), isTrue);
    expect(
      first.map((link) => '${link.sourceId}\u0000${link.targetId}').toSet(),
      hasLength(first.length),
    );

    final reached = <String>{points.first.id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final link in first) {
        if (reached.contains(link.sourceId) && reached.add(link.targetId)) {
          changed = true;
        }
        if (reached.contains(link.targetId) && reached.add(link.sourceId)) {
          changed = true;
        }
      }
    }
    expect(reached, hasLength(points.length));
    expect(first.any((link) => link.touchesSyntheticPoint), isTrue);
  });

  test('product topology sizes stay connected with one nearest neighbor', () {
    for (final count in const <int>[20, 50, 72, 100, 500]) {
      final points = layout.build(
        realNodeIds: List<String>.generate(count, (index) => 'node-$index'),
        minimumVisualNodeCount: 72,
      );
      final links = layout.buildVisualLinks(
        points: points,
        neighborsPerPoint: 1,
      );
      final reached = <String>{points.first.id};
      var changed = true;
      while (changed) {
        changed = false;
        for (final link in links) {
          if (reached.contains(link.sourceId) && reached.add(link.targetId)) {
            changed = true;
          }
          if (reached.contains(link.targetId) && reached.add(link.sourceId)) {
            changed = true;
          }
        }
      }
      expect(reached, hasLength(points.length), reason: '$count nodes');
      expect(links.length, greaterThanOrEqualTo(points.length - 1));
    }
  });

  test('empty and one-node layouts do not invent links', () {
    expect(
      layout.build(realNodeIds: const [], minimumVisualNodeCount: 0),
      isEmpty,
    );
    final single = layout.build(
      realNodeIds: const ['only'],
      minimumVisualNodeCount: 1,
    );
    expect(layout.buildVisualLinks(points: single), isEmpty);
    expect(
      layout.project(points: const [], viewport: const Size(390, 520)),
      isEmpty,
    );
  });

  test('invalid IDs and arguments fail explicitly', () {
    expect(
      () => layout.build(realNodeIds: const ['same', 'same']),
      throwsArgumentError,
    );
    expect(() => layout.build(realNodeIds: const ['  ']), throwsArgumentError);
    expect(
      () => layout.build(realNodeIds: const [], minimumVisualNodeCount: -1),
      throwsRangeError,
    );
    expect(
      () => layout.project(
        points: const [
          SphereGraphLayoutPoint(
            id: 'node',
            x: 0,
            y: 0,
            z: 0,
            isSynthetic: false,
          ),
        ],
        viewport: const Size(100, 100),
        zoom: 0,
      ),
      throwsRangeError,
    );
    expect(
      () => layout.buildVisualLinks(
        points: const [
          SphereGraphLayoutPoint(
            id: 'node',
            x: 0,
            y: 0,
            z: 0,
            isSynthetic: false,
          ),
        ],
        neighborsPerPoint: -1,
      ),
      throwsRangeError,
    );
  });
}

double _distance(SphereGraphLayoutPoint left, SphereGraphLayoutPoint right) {
  final x = left.x - right.x;
  final y = left.y - right.y;
  final z = left.z - right.z;
  return math.sqrt(x * x + y * y + z * z);
}
