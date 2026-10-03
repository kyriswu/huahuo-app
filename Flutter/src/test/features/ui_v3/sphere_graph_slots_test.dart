import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_layout.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_neighbors.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_slots.dart';

void main() {
  test(
    'empty slots are promoted in place and all real notes survive growth',
    () {
      final slots = SphereGraphSlots();
      final empty = slots.synchronize(const []);
      expect(empty, hasLength(72));
      expect(empty.every((point) => point.isSynthetic), isTrue);
      final first = slots.synchronize(const ['first-note']);
      final firstReal = first.singleWhere((point) => !point.isSynthetic);
      expect(first, hasLength(72));
      expect(empty.map(_coordinate), contains(_coordinate(firstReal)));
      final ids = [
        'first-note',
        ...List.generate(180, (index) => 'note-$index'),
      ];
      final grown = slots.synchronize(ids);
      expect(grown, hasLength(ids.length));
      expect(grown.map((point) => point.id), unorderedEquals(ids));
      expect(grown.every((point) => !point.isSynthetic), isTrue);
      expect(grown.singleWhere((point) => point.id == 'first-note'), firstReal);
      final retained = slots.synchronize(const ['first-note']);
      expect(retained, hasLength(72));
      expect(retained.singleWhere((point) => !point.isSynthetic), firstReal);
    },
  );

  test(
    'bounded neighbor graph is deterministic, connected, local and hub-free',
    () {
      const layout = SphereGraphLayout();
      for (final count in [2, 3, 4, 5, 6, 7, 12, 31, 72, 121, 500, 2000]) {
        final points = layout.build(
          realNodeIds: List.generate(count, (index) => 'mesh-$index'),
          minimumVisualNodeCount: 0,
        );
        final links = layout.buildVisualLinks(points: points);
        expect(layout.buildVisualLinks(points: points.reversed), links);
        final adjacency = {for (final point in points) point.id: <String>{}};
        for (final edge in links) {
          expect(edge.sourceId, isNot(edge.targetId));
          expect(adjacency[edge.sourceId]!.add(edge.targetId), isTrue);
          expect(adjacency[edge.targetId]!.add(edge.sourceId), isTrue);
        }
        for (final entry in adjacency.entries) {
          expect(
            entry.value.length,
            inInclusiveRange(math.min(3, count - 1), 4),
            reason: '$count points: ${entry.key}',
          );
        }
        final reached = <String>{};
        final pending = <String>[points.first.id];
        while (pending.isNotEmpty) {
          final next = pending.removeLast();
          if (reached.add(next)) pending.addAll(adjacency[next]!);
        }
        expect(reached, hasLength(count));
        expect(links.length, lessThanOrEqualTo(count * 2));
        if (count >= 72) {
          expect(
            adjacency.values.any((neighbors) => neighbors.length == 3),
            isTrue,
          );
          expect(
            adjacency.values.any((neighbors) => neighbors.length == 4),
            isTrue,
          );
          final byId = {for (final point in points) point.id: point};
          final nearestFour = {
            for (final point in points)
              point.id:
                  (points.where((other) => other.id != point.id).toList()..sort(
                        (left, right) => _distance(
                          point,
                          left,
                        ).compareTo(_distance(point, right)),
                      ))
                      .take(4)
                      .map((other) => other.id)
                      .toSet(),
          };
          for (final point in points) {
            expect(
              adjacency[point.id]!.any(
                (target) =>
                    !nearestFour[point.id]!.contains(target) &&
                    !nearestFour[target]!.contains(point.id),
              ),
              isTrue,
              reason: '$count points: ${point.id} needs a medium-range link',
            );
          }
          final averageLength =
              links.fold<double>(
                0,
                (sum, edge) =>
                    sum + _distance(byId[edge.sourceId]!, byId[edge.targetId]!),
              ) /
              links.length;
          expect(averageLength, lessThan(.8));
        }
      }
    },
  );

  test(
    'coincident points retain bounded degrees and deterministic fallback',
    () {
      final coordinates = List<SphereCoordinate>.filled(32, (0, 0, 0));
      final ids = List.generate(32, (index) => 'coincident-$index');
      final pairs = buildSphereNeighborPairs(
        coordinates: coordinates,
        ids: ids,
      );
      final degrees = List.filled(32, 0);
      for (final pair in pairs) {
        degrees[pair.$1]++;
        degrees[pair.$2]++;
      }
      expect(degrees, everyElement(inInclusiveRange(3, 4)));
      expect(pairs.toSet(), hasLength(pairs.length));
      expect(
        buildSphereNeighborPairs(coordinates: coordinates, ids: ids),
        pairs,
      );
    },
  );
}

(double, double, double) _coordinate(SphereGraphLayoutPoint point) =>
    (point.x, point.y, point.z);

double _distance(SphereGraphLayoutPoint source, SphereGraphLayoutPoint target) {
  final horizontal = source.x - target.x;
  final vertical = source.y - target.y;
  final depth = source.z - target.z;
  return math.sqrt(
    horizontal * horizontal + vertical * vertical + depth * depth,
  );
}
