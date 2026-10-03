import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'sphere_graph_neighbors.dart';

/// A deterministic point in the graph's presentation-only 3D sphere.
@immutable
final class SphereGraphLayoutPoint {
  const SphereGraphLayoutPoint({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.isSynthetic,
  });

  final String id;
  final double x;
  final double y;
  final double z;
  final bool isSynthetic;

  double get radius => math.sqrt(x * x + y * y + z * z);

  @override
  bool operator ==(Object other) {
    return other is SphereGraphLayoutPoint &&
        other.id == id &&
        other.x == x &&
        other.y == y &&
        other.z == z &&
        other.isSynthetic == isSynthetic;
  }

  @override
  int get hashCode => Object.hash(id, x, y, z, isSynthetic);
}

/// A point after camera rotation and perspective projection.
@immutable
final class SphereGraphProjectedPoint {
  const SphereGraphProjectedPoint({
    required this.id,
    required this.position,
    required this.cameraDepth,
    required this.depth,
    required this.sizeFactor,
    required this.opacity,
    required this.isSynthetic,
  });

  final String id;
  final Offset position;

  /// Rotated Z coordinate in the normalized range `-1...1`.
  final double cameraDepth;

  /// Far-to-near normalized depth in the range `0...1`.
  final double depth;
  final double sizeFactor;
  final double opacity;
  final bool isSynthetic;

  @override
  bool operator ==(Object other) {
    return other is SphereGraphProjectedPoint &&
        other.id == id &&
        other.position == position &&
        other.cameraDepth == cameraDepth &&
        other.depth == depth &&
        other.sizeFactor == sizeFactor &&
        other.opacity == opacity &&
        other.isSynthetic == isSynthetic;
  }

  @override
  int get hashCode => Object.hash(
    id,
    position,
    cameraDepth,
    depth,
    sizeFactor,
    opacity,
    isSynthetic,
  );
}

/// A visual-only mesh link. It never represents a semantic graph relation.
@immutable
final class SphereGraphVisualLink {
  const SphereGraphVisualLink({
    required this.sourceId,
    required this.targetId,
    required this.touchesSyntheticPoint,
  });

  final String sourceId;
  final String targetId;
  final bool touchesSyntheticPoint;

  @override
  bool operator ==(Object other) {
    return other is SphereGraphVisualLink &&
        other.sourceId == sourceId &&
        other.targetId == targetId &&
        other.touchesSyntheticPoint == touchesSyntheticPoint;
  }

  @override
  int get hashCode => Object.hash(sourceId, targetId, touchesSyntheticPoint);
}

/// Builds an irregular spherical volume and projects it onto the graph canvas.
///
/// Synthetic points and links are presentation artifacts. Callers must keep
/// them outside graph snapshots, deposits, selection, and persistence.
final class SphereGraphLayout {
  const SphereGraphLayout();

  static const String _fillerPrefix = '__sphere_visual_filler__';

  /// Returns every real ID plus enough explicitly marked fillers to reach the
  /// requested visual minimum. Input order does not affect the result.
  List<SphereGraphLayoutPoint> build({
    required Iterable<String> realNodeIds,
    int minimumVisualNodeCount = 72,
  }) {
    if (minimumVisualNodeCount < 0) {
      throw RangeError.value(
        minimumVisualNodeCount,
        'minimumVisualNodeCount',
        'must not be negative',
      );
    }
    final suppliedIds = realNodeIds.toList(growable: false);
    if (suppliedIds.any((id) => id.trim().isEmpty)) {
      throw ArgumentError.value(
        suppliedIds,
        'realNodeIds',
        'node IDs must not be empty',
      );
    }
    final realIds = suppliedIds.toSet().toList()..sort();
    if (realIds.length != suppliedIds.length) {
      throw ArgumentError.value(
        suppliedIds,
        'realNodeIds',
        'node IDs must be unique',
      );
    }
    final pointCount = math.max(realIds.length, minimumVisualNodeCount);
    if (pointCount == 0) return const <SphereGraphLayoutPoint>[];

    final usedIds = realIds.toSet();
    final points = <SphereGraphLayoutPoint>[
      for (final id in realIds) _pointForId(id: id, isSynthetic: false),
    ];
    final fillerCount = pointCount - realIds.length;
    for (var fillerIndex = 0; fillerIndex < fillerCount; fillerIndex++) {
      var suffix = 0;
      var id = '$_fillerPrefix$fillerIndex';
      while (usedIds.contains(id)) {
        suffix++;
        id = '$_fillerPrefix${fillerIndex}_$suffix';
      }
      usedIds.add(id);
      points.add(_pointForId(id: id, isSynthetic: true));
    }
    points.sort((left, right) => left.id.compareTo(right.id));
    return List<SphereGraphLayoutPoint>.unmodifiable(points);
  }

  /// Rotates immutable base points and returns stable far-to-near paint order.
  List<SphereGraphProjectedPoint> project({
    required Iterable<SphereGraphLayoutPoint> points,
    required Size viewport,
    double rotationX = 0,
    double rotationY = 0,
    double zoom = 1,
    double padding = 12,
  }) {
    final source = points.toList(growable: false);
    if (source.isEmpty || viewport.isEmpty) {
      return const <SphereGraphProjectedPoint>[];
    }
    if (!rotationX.isFinite || !rotationY.isFinite) {
      throw ArgumentError('rotation values must be finite');
    }
    if (!zoom.isFinite || zoom <= 0) {
      throw RangeError.value(zoom, 'zoom', 'must be finite and positive');
    }
    if (!padding.isFinite || padding < 0) {
      throw RangeError.value(
        padding,
        'padding',
        'must be finite and non-negative',
      );
    }

    final center = viewport.center(Offset.zero);
    final availableRadius = math.max(
      0.0,
      math.min(viewport.width, viewport.height) / 2 - padding,
    );
    final canvasRadius = availableRadius * .91 * zoom;
    final sinX = math.sin(rotationX);
    final cosX = math.cos(rotationX);
    final sinY = math.sin(rotationY);
    final cosY = math.cos(rotationY);
    final projected = <SphereGraphProjectedPoint>[];

    for (final point in source) {
      final rotatedX = point.x * cosY + point.z * sinY;
      final yAfterYRotation = point.y;
      final zAfterYRotation = -point.x * sinY + point.z * cosY;
      final rotatedY = yAfterYRotation * cosX - zAfterYRotation * sinX;
      final rotatedZ = yAfterYRotation * sinX + zAfterYRotation * cosX;
      final normalizedDepth = ((rotatedZ + 1) / 2).clamp(0.0, 1.0);
      final perspective = 1 / (1 - rotatedZ * .32);
      final sizeFactor = _lerp(
        .44,
        1.32,
        math.pow(normalizedDepth, .95).toDouble(),
      );
      final depthOpacity = _lerp(
        .08,
        .98,
        math.pow(normalizedDepth, 1.55).toDouble(),
      );
      final opacity = point.isSynthetic
          ? (depthOpacity * .7).clamp(.055, .7)
          : depthOpacity;
      projected.add(
        SphereGraphProjectedPoint(
          id: point.id,
          position:
              center + Offset(rotatedX, rotatedY) * canvasRadius * perspective,
          cameraDepth: rotatedZ,
          depth: normalizedDepth,
          sizeFactor: sizeFactor,
          opacity: opacity,
          isSynthetic: point.isSynthetic,
        ),
      );
    }
    projected.sort((left, right) {
      final byDepth = left.cameraDepth.compareTo(right.cameraDepth);
      return byDepth != 0 ? byDepth : left.id.compareTo(right.id);
    });
    return List<SphereGraphProjectedPoint>.unmodifiable(projected);
  }

  /// Builds a connected, bounded visual mesh without creating semantic edges.
  List<SphereGraphVisualLink> buildVisualLinks({
    required Iterable<SphereGraphLayoutPoint> points,
    int neighborsPerPoint = 2,
  }) {
    if (neighborsPerPoint < 0) {
      throw RangeError.value(
        neighborsPerPoint,
        'neighborsPerPoint',
        'must not be negative',
      );
    }
    final source = points.toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    if (source.length < 2) return const <SphereGraphVisualLink>[];
    if (source.map((point) => point.id).toSet().length != source.length) {
      throw ArgumentError.value(points, 'points', 'point IDs must be unique');
    }

    final sortedPairs = buildSphereNeighborPairs(
      coordinates: [for (final point in source) (point.x, point.y, point.z)],
      ids: [for (final point in source) point.id],
    );
    return List<SphereGraphVisualLink>.unmodifiable([
      for (final pair in sortedPairs)
        SphereGraphVisualLink(
          sourceId: source[pair.$1].id,
          targetId: source[pair.$2].id,
          touchesSyntheticPoint:
              source[pair.$1].isSynthetic || source[pair.$2].isSynthetic,
        ),
    ]);
  }

  SphereGraphLayoutPoint _pointForId({
    required String id,
    required bool isSynthetic,
  }) {
    final directionY = (1 - 2 * _unitInterval('$id|latitude')).clamp(
      -.985,
      .985,
    );
    final angle = math.pi * 2 * _unitInterval('$id|longitude');
    final horizontalRadius = math.sqrt(
      math.max(0, 1 - directionY * directionY),
    );
    final shellRadius = _lerp(
      .48,
      .995,
      math.pow(_unitInterval('$id|radius'), .3).toDouble(),
    );
    return SphereGraphLayoutPoint(
      id: id,
      x: math.cos(angle) * horizontalRadius * shellRadius,
      y: directionY * shellRadius,
      z: math.sin(angle) * horizontalRadius * shellRadius,
      isSynthetic: isSynthetic,
    );
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    // Keep sequential IDs from exposing FNV's weaker low-bit distribution.
    hash ^= hash >> 16;
    hash = (hash * 0x7feb352d) & 0xffffffff;
    hash ^= hash >> 15;
    hash = (hash * 0x846ca68b) & 0xffffffff;
    hash ^= hash >> 16;
    return hash;
  }

  static double _unitInterval(String value) {
    return _stableHash(value) / 0xffffffff;
  }

  static double _lerp(double start, double end, double amount) {
    return start + (end - start) * amount;
  }
}
