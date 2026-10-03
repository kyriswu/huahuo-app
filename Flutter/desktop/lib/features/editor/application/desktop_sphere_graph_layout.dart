import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

@immutable
final class DesktopSphereGraphLayoutPoint {
  const DesktopSphereGraphLayoutPoint({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.isSynthetic,
    this.shellIndex = 0,
  });

  final String id;
  final double x;
  final double y;
  final double z;
  final bool isSynthetic;
  final int shellIndex;

  double get radius => math.sqrt(x * x + y * y + z * z);

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphLayoutPoint &&
      other.id == id &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.isSynthetic == isSynthetic &&
      other.shellIndex == shellIndex;

  @override
  int get hashCode => Object.hash(id, x, y, z, isSynthetic, shellIndex);
}

@immutable
final class DesktopSphereGraphProjectedPoint {
  const DesktopSphereGraphProjectedPoint({
    required this.id,
    required this.position,
    required this.cameraDepth,
    required this.depth,
    required this.sizeFactor,
    required this.opacity,
    required this.isSynthetic,
    required this.shellIndex,
  });

  final String id;
  final Offset position;
  final double cameraDepth;
  final double depth;
  final double sizeFactor;
  final double opacity;
  final bool isSynthetic;
  final int shellIndex;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphProjectedPoint &&
      other.id == id &&
      other.position == position &&
      other.cameraDepth == cameraDepth &&
      other.depth == depth &&
      other.sizeFactor == sizeFactor &&
      other.opacity == opacity &&
      other.isSynthetic == isSynthetic &&
      other.shellIndex == shellIndex;

  @override
  int get hashCode => Object.hash(
    id,
    position,
    cameraDepth,
    depth,
    sizeFactor,
    opacity,
    isSynthetic,
    shellIndex,
  );
}

@immutable
final class DesktopSphereGraphVisualLink {
  const DesktopSphereGraphVisualLink({
    required this.sourceId,
    required this.targetId,
    required this.touchesSyntheticPoint,
  });

  final String sourceId;
  final String targetId;
  final bool touchesSyntheticPoint;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphVisualLink &&
      other.sourceId == sourceId &&
      other.targetId == targetId &&
      other.touchesSyntheticPoint == touchesSyntheticPoint;

  @override
  int get hashCode => Object.hash(sourceId, targetId, touchesSyntheticPoint);
}

/// A point sampled from the unit sphere along a great-circle path.
///
/// Graph links use these unit directions to trace their curved shell route.
@immutable
final class DesktopSphereGraphSurfaceSample {
  const DesktopSphereGraphSurfaceSample({
    required this.x,
    required this.y,
    required this.z,
  });

  final double x;
  final double y;
  final double z;

  double get radius => math.sqrt(x * x + y * y + z * z);

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphSurfaceSample &&
      other.x == x &&
      other.y == y &&
      other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

enum DesktopSphereGraphRouteSection { radialBridge, shellArc }

/// A shell-route sample after the desktop sphere camera projection.
@immutable
final class DesktopSphereGraphProjectedSurfaceSample {
  const DesktopSphereGraphProjectedSurfaceSample({
    required this.position,
    required this.cameraDepth,
    required this.depth,
    required this.radialDistance,
    this.routeSection = DesktopSphereGraphRouteSection.shellArc,
  });

  final Offset position;
  final double cameraDepth;
  final double depth;
  final double radialDistance;
  final DesktopSphereGraphRouteSection routeSection;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphProjectedSurfaceSample &&
      other.position == position &&
      other.cameraDepth == cameraDepth &&
      other.depth == depth &&
      other.radialDistance == radialDistance &&
      other.routeSection == routeSection;

  @override
  int get hashCode =>
      Object.hash(position, cameraDepth, depth, radialDistance, routeSection);
}

/// A curved shell-route graph link represented as depth-aware samples.
@immutable
final class DesktopSphereGraphProjectedSurfaceArc {
  const DesktopSphereGraphProjectedSurfaceArc({
    required this.sourceId,
    required this.targetId,
    required this.touchesSyntheticPoint,
    required this.samples,
  });

  final String sourceId;
  final String targetId;
  final bool touchesSyntheticPoint;
  final List<DesktopSphereGraphProjectedSurfaceSample> samples;

  double get averageCameraDepth => samples.isEmpty
      ? 0
      : samples.fold<double>(0, (total, sample) => total + sample.cameraDepth) /
            samples.length;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphProjectedSurfaceArc &&
      other.sourceId == sourceId &&
      other.targetId == targetId &&
      other.touchesSyntheticPoint == touchesSyntheticPoint &&
      listEquals(other.samples, samples);

  @override
  int get hashCode => Object.hash(
    sourceId,
    targetId,
    touchesSyntheticPoint,
    Object.hashAll(samples),
  );
}

/// Projected wireframe guides for one transparent concentric sphere.
@immutable
final class DesktopSphereGraphProjectedShellGuide {
  const DesktopSphereGraphProjectedShellGuide({
    required this.radius,
    required this.isAtmosphere,
    required this.contours,
  });

  final double radius;
  final bool isAtmosphere;
  final List<List<DesktopSphereGraphProjectedSurfaceSample>> contours;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphProjectedShellGuide &&
      other.radius == radius &&
      other.isAtmosphere == isAtmosphere &&
      other.contours.length == contours.length &&
      List<bool>.generate(
        contours.length,
        (index) => listEquals(other.contours[index], contours[index]),
      ).every((matches) => matches);

  @override
  int get hashCode => Object.hash(
    radius,
    isAtmosphere,
    Object.hashAll(contours.map(Object.hashAll)),
  );
}

/// A sparse external-atmosphere particle projected by the globe camera.
@immutable
final class DesktopSphereGraphProjectedAtmosphereDust {
  const DesktopSphereGraphProjectedAtmosphereDust({
    required this.id,
    required this.position,
    required this.cameraDepth,
    required this.depth,
  });

  final String id;
  final Offset position;
  final double cameraDepth;
  final double depth;

  @override
  bool operator ==(Object other) =>
      other is DesktopSphereGraphProjectedAtmosphereDust &&
      other.id == id &&
      other.position == position &&
      other.cameraDepth == cameraDepth &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(id, position, cameraDepth, depth);
}

/// Stable desktop layout for the graph's presentation-only 3D volume.
final class DesktopSphereGraphLayout {
  const DesktopSphereGraphLayout();

  static const String fillerPrefix = '__desktop_sphere_visual_filler__';
  // A stronger camera separation keeps the volume legible while the radius
  // factor below guarantees the projected silhouette stays in the viewport.
  static const double perspectiveStrength = .58;
  static const double canvasRadiusFactor = .56;
  static const _largeMeshThreshold = 320;
  static const _largeMeshSearchWindow = 16;
  static const int defaultSurfaceArcMinimumSegments = 3;
  static const int defaultSurfaceArcMaximumSegments = 18;
  static const int defaultSurfaceArcMaximumTotalSegments = 12000;
  static const int defaultShellGuideContourCount = 3;
  static const int defaultShellGuideSegments = 28;
  static const int defaultAtmosphereDustCount = 16;

  /// Content shells open around an enlarged, sparse conceptual core, compress
  /// into a denser middle field, and fan out again toward the periphery.
  static const List<double> contentShellRadii = <double>[
    .45,
    .60,
    .67,
    .72,
    .77,
    .82,
    .87,
    .95,
    1.05,
    1.13,
  ];

  /// The compact middle carries most information. The inner and outer zones
  /// stay intentionally sparse so the volume reads loose-tight-loose.
  static const List<double> contentShellWeights = <double>[
    .035,
    .055,
    .105,
    .14,
    .175,
    .165,
    .13,
    .09,
    .065,
    .04,
  ];

  /// Non-interactive outer space around the content volume. These guides fade
  /// in the painter instead of becoming a visible enclosing boundary.
  static const List<double> atmosphereShellRadii = <double>[1.17, 1.20];

  static const double _shellGuideGoldenAngle = 2.399963229728653;

  List<DesktopSphereGraphLayoutPoint> build({
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
        'IDs must not be empty',
      );
    }
    final realIds = suppliedIds.toSet().toList()..sort();
    if (realIds.length != suppliedIds.length) {
      throw ArgumentError.value(
        suppliedIds,
        'realNodeIds',
        'IDs must be unique',
      );
    }
    final pointCount = math.max(realIds.length, minimumVisualNodeCount);
    if (pointCount == 0) return const <DesktopSphereGraphLayoutPoint>[];

    final usedIds = realIds.toSet();
    final points = <DesktopSphereGraphLayoutPoint>[
      for (final id in realIds) _pointForId(id: id, isSynthetic: false),
    ];
    final fillerCount = pointCount - realIds.length;
    for (var index = 0; index < fillerCount; index++) {
      var suffix = 0;
      var id = '$fillerPrefix$index';
      while (usedIds.contains(id)) {
        suffix++;
        id = '$fillerPrefix${index}_$suffix';
      }
      usedIds.add(id);
      points.add(_pointForId(id: id, isSynthetic: true));
    }
    points.sort((left, right) => left.id.compareTo(right.id));
    return List<DesktopSphereGraphLayoutPoint>.unmodifiable(points);
  }

  List<DesktopSphereGraphProjectedPoint> project({
    required Iterable<DesktopSphereGraphLayoutPoint> points,
    required Size viewport,
    double rotationX = 0,
    double rotationY = 0,
    double zoom = 1,
    double padding = 12,
    Offset pan = Offset.zero,
  }) {
    final source = points.toList(growable: false);
    if (source.isEmpty || viewport.isEmpty) {
      return const <DesktopSphereGraphProjectedPoint>[];
    }
    final projection = _projectionContext(
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
      zoom: zoom,
      padding: padding,
      pan: pan,
    );
    final projected = <DesktopSphereGraphProjectedPoint>[];

    for (final point in source) {
      final coordinate = _projectCoordinates(
        x: point.x,
        y: point.y,
        z: point.z,
        projection: projection,
      );
      final sizeFactor = _lerp(
        .42,
        1.56,
        math.pow(coordinate.depth, 1.05).toDouble(),
      );
      final depthOpacity = _lerp(
        .12,
        .99,
        math.pow(coordinate.depth, 1.4).toDouble(),
      );
      final opacity = point.isSynthetic
          ? (depthOpacity * .64).clamp(.075, .64)
          : depthOpacity;
      projected.add(
        DesktopSphereGraphProjectedPoint(
          id: point.id,
          position: coordinate.position,
          cameraDepth: coordinate.cameraDepth,
          depth: coordinate.depth,
          sizeFactor: sizeFactor,
          opacity: opacity,
          isSynthetic: point.isSynthetic,
          shellIndex: point.shellIndex,
        ),
      );
    }
    projected.sort((left, right) {
      final byDepth = left.cameraDepth.compareTo(right.cameraDepth);
      return byDepth != 0 ? byDepth : left.id.compareTo(right.id);
    });
    return List<DesktopSphereGraphProjectedPoint>.unmodifiable(projected);
  }

  /// Samples the shortest great-circle route between two point directions.
  ///
  /// The returned coordinates are always on the unit sphere. Near-antipodal
  /// pairs have no unique shortest route, so a deterministic perpendicular
  /// plane is selected to keep the arc stable and finite across frames.
  List<DesktopSphereGraphSurfaceSample> sampleGreatCircle({
    required DesktopSphereGraphLayoutPoint source,
    required DesktopSphereGraphLayoutPoint target,
    required int segments,
  }) {
    if (segments < 1) {
      throw RangeError.value(segments, 'segments', 'must be at least one');
    }
    final sourceUnit = _unitVectorFor(source);
    final targetUnit = _unitVectorFor(target);
    final dot = sourceUnit.dot(targetUnit).clamp(-1.0, 1.0).toDouble();
    final omega = math.acos(dot);
    final sinOmega = math.sin(omega);
    final isNearlyIdentical = dot > .9995;
    final isNearlyAntipodal = dot < -.9995;
    final antipodalNormal = isNearlyAntipodal
        ? _deterministicPerpendicular(
            sourceUnit,
            sourceId: source.id,
            targetId: target.id,
          )
        : null;
    final samples = <DesktopSphereGraphSurfaceSample>[];

    for (var index = 0; index <= segments; index++) {
      final t = index / segments;
      final _SphereVector point;
      if (index == 0) {
        point = sourceUnit;
      } else if (index == segments) {
        point = targetUnit;
      } else if (isNearlyIdentical) {
        point = (sourceUnit * (1 - t) + targetUnit * t).normalized();
      } else if (isNearlyAntipodal) {
        point =
            (sourceUnit * math.cos(math.pi * t) +
                    antipodalNormal! * math.sin(math.pi * t))
                .normalized();
      } else {
        point =
            ((sourceUnit * math.sin((1 - t) * omega) +
                        targetUnit * math.sin(t * omega)) /
                    sinOmega)
                .normalized();
      }
      samples.add(
        DesktopSphereGraphSurfaceSample(x: point.x, y: point.y, z: point.z),
      );
    }
    return List<DesktopSphereGraphSurfaceSample>.unmodifiable(samples);
  }

  /// Projects visible graph-link routes across the concentric shells.
  ///
  /// Same-shell links follow that shell's great circle. Cross-shell links
  /// first travel radially to the outer of their two shells, follow its
  /// great-circle route, and travel radially back to the target. This keeps
  /// all endpoints attached while avoiding an interior screen-space chord.
  List<DesktopSphereGraphProjectedSurfaceArc> projectSurfaceArcs({
    required Iterable<DesktopSphereGraphLayoutPoint> points,
    required Iterable<DesktopSphereGraphVisualLink> links,
    required Size viewport,
    double rotationX = 0,
    double rotationY = 0,
    double zoom = 1,
    double padding = 12,
    Offset pan = Offset.zero,
    int minimumSegments = defaultSurfaceArcMinimumSegments,
    int maximumSegments = defaultSurfaceArcMaximumSegments,
    int maximumTotalSegments = defaultSurfaceArcMaximumTotalSegments,
  }) {
    if (minimumSegments < 1) {
      throw RangeError.value(
        minimumSegments,
        'minimumSegments',
        'must be at least one',
      );
    }
    if (maximumSegments < minimumSegments) {
      throw RangeError.value(
        maximumSegments,
        'maximumSegments',
        'must be greater than or equal to minimumSegments',
      );
    }
    if (maximumTotalSegments < 1) {
      throw RangeError.value(
        maximumTotalSegments,
        'maximumTotalSegments',
        'must be at least one',
      );
    }
    final source = points.toList(growable: false);
    final sourceLinks = links.toList(growable: false);
    if (source.isEmpty || sourceLinks.isEmpty || viewport.isEmpty) {
      return const <DesktopSphereGraphProjectedSurfaceArc>[];
    }
    final projection = _projectionContext(
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
      zoom: zoom,
      padding: padding,
      pan: pan,
    );
    final pointsById = <String, DesktopSphereGraphLayoutPoint>{
      for (final point in source) point.id: point,
    };
    final perArcMaximum = math
        .max(
          1,
          math.min(maximumSegments, maximumTotalSegments ~/ sourceLinks.length),
        )
        .toInt();
    final effectiveMinimum = math.min(minimumSegments, perArcMaximum).toInt();
    final arcs = <DesktopSphereGraphProjectedSurfaceArc>[];

    for (final link in sourceLinks) {
      final sourcePoint = pointsById[link.sourceId];
      final targetPoint = pointsById[link.targetId];
      if (sourcePoint == null || targetPoint == null) continue;
      final sourceRadius = sourcePoint.radius;
      final targetRadius = targetPoint.radius;
      final routeRadius = math.max(sourceRadius, targetRadius);
      final sourceBridge = (routeRadius - sourceRadius).abs() > 1e-9;
      final targetBridge = (routeRadius - targetRadius).abs() > 1e-9;
      final bridgeSegmentCount =
          (sourceBridge ? 1 : 0) + (targetBridge ? 1 : 0);
      final canUseShellRoute = perArcMaximum >= bridgeSegmentCount + 1;
      final routeSamples = <(_SphereVector, DesktopSphereGraphRouteSection)>[];

      if (canUseShellRoute) {
        final shellMaximum = math.max(1, perArcMaximum - bridgeSegmentCount);
        final shellMinimum = math.min(effectiveMinimum, shellMaximum).toInt();
        final shellSegmentCount = _adaptiveSurfaceArcSegmentCount(
          sourcePoint,
          targetPoint,
          minimum: shellMinimum,
          maximum: shellMaximum,
        );
        final shellDirections = sampleGreatCircle(
          source: sourcePoint,
          target: targetPoint,
          segments: shellSegmentCount,
        );
        final sourceVector = _SphereVector(
          sourcePoint.x,
          sourcePoint.y,
          sourcePoint.z,
        );
        final targetVector = _SphereVector(
          targetPoint.x,
          targetPoint.y,
          targetPoint.z,
        );
        routeSamples.add((
          sourceVector,
          sourceBridge
              ? DesktopSphereGraphRouteSection.radialBridge
              : DesktopSphereGraphRouteSection.shellArc,
        ));
        if (sourceBridge) {
          final firstDirection = shellDirections.first;
          routeSamples.add((
            _SphereVector(
              firstDirection.x * routeRadius,
              firstDirection.y * routeRadius,
              firstDirection.z * routeRadius,
            ),
            DesktopSphereGraphRouteSection.radialBridge,
          ));
        }
        for (var index = 1; index < shellDirections.length; index++) {
          final direction = shellDirections[index];
          routeSamples.add((
            _SphereVector(
              direction.x * routeRadius,
              direction.y * routeRadius,
              direction.z * routeRadius,
            ),
            DesktopSphereGraphRouteSection.shellArc,
          ));
        }
        if (targetBridge) {
          routeSamples.add((
            targetVector,
            DesktopSphereGraphRouteSection.radialBridge,
          ));
        }
      } else {
        // Very dense graphs can assign only one segment per background link.
        // Preserve the true endpoints and bend the radius continuously rather
        // than turning the fallback into a straight 2D chord.
        final fallbackSegments = math.max(1, perArcMaximum).toInt();
        final directions = sampleGreatCircle(
          source: sourcePoint,
          target: targetPoint,
          segments: fallbackSegments,
        );
        for (var index = 0; index < directions.length; index++) {
          final amount = index / fallbackSegments;
          final radius = _lerp(sourceRadius, targetRadius, amount);
          final direction = directions[index];
          routeSamples.add((
            _SphereVector(
              direction.x * radius,
              direction.y * radius,
              direction.z * radius,
            ),
            DesktopSphereGraphRouteSection.shellArc,
          ));
        }
      }
      arcs.add(
        DesktopSphereGraphProjectedSurfaceArc(
          sourceId: link.sourceId,
          targetId: link.targetId,
          touchesSyntheticPoint: link.touchesSyntheticPoint,
          samples: List<DesktopSphereGraphProjectedSurfaceSample>.unmodifiable([
            for (final sample in routeSamples)
              () {
                final coordinate = _projectCoordinates(
                  x: sample.$1.x,
                  y: sample.$1.y,
                  z: sample.$1.z,
                  projection: projection,
                );
                return DesktopSphereGraphProjectedSurfaceSample(
                  position: coordinate.position,
                  cameraDepth: coordinate.cameraDepth,
                  depth: coordinate.depth,
                  radialDistance: math.sqrt(sample.$1.lengthSquared),
                  routeSection: sample.$2,
                );
              }(),
          ]),
        ),
      );
    }
    return List<DesktopSphereGraphProjectedSurfaceArc>.unmodifiable(arcs);
  }

  /// Projects wire contours for every content and atmosphere sphere.
  ///
  /// The contours are true great circles on each hollow sphere, rather than
  /// screen-space rings. Keeping the sampling fixed and independent of graph
  /// size makes the material layer deterministic and cheap for large graphs.
  List<DesktopSphereGraphProjectedShellGuide> projectShellGuides({
    required Size viewport,
    double rotationX = 0,
    double rotationY = 0,
    double zoom = 1,
    double padding = 12,
    Offset pan = Offset.zero,
    int segments = defaultShellGuideSegments,
  }) {
    if (segments < 8) {
      throw RangeError.value(
        segments,
        'segments',
        'must be at least eight to preserve a closed spherical contour',
      );
    }
    if (viewport.isEmpty) {
      return const <DesktopSphereGraphProjectedShellGuide>[];
    }
    final projection = _projectionContext(
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
      zoom: zoom,
      padding: padding,
      pan: pan,
    );
    return List<DesktopSphereGraphProjectedShellGuide>.unmodifiable([
      for (var index = 0; index < contentShellRadii.length; index++)
        _projectShellGuide(
          radius: contentShellRadii[index],
          isAtmosphere: false,
          shellOrder: index,
          segments: segments,
          projection: projection,
        ),
      for (var index = 0; index < atmosphereShellRadii.length; index++)
        _projectShellGuide(
          radius: atmosphereShellRadii[index],
          isAtmosphere: true,
          shellOrder: contentShellRadii.length + index,
          segments: segments,
          projection: projection,
        ),
    ]);
  }

  DesktopSphereGraphProjectedShellGuide _projectShellGuide({
    required double radius,
    required bool isAtmosphere,
    required int shellOrder,
    required int segments,
    required _SphereProjectionContext projection,
  }) {
    final contours = <List<DesktopSphereGraphProjectedSurfaceSample>>[];
    for (final planeNormal in _shellGuidePlaneNormals(
      projection: projection,
      shellOrder: shellOrder,
    )) {
      final normal = planeNormal.normalized();
      final axisA = normal.cross(_leastAlignedBasis(normal)).normalized();
      final axisB = normal.cross(axisA).normalized();
      final samples = <DesktopSphereGraphProjectedSurfaceSample>[];
      for (var index = 0; index <= segments; index++) {
        final angle = math.pi * 2 * index / segments;
        final point =
            (axisA * math.cos(angle) + axisB * math.sin(angle)) * radius;
        final coordinate = _projectCoordinates(
          x: point.x,
          y: point.y,
          z: point.z,
          projection: projection,
        );
        samples.add(
          DesktopSphereGraphProjectedSurfaceSample(
            position: coordinate.position,
            cameraDepth: coordinate.cameraDepth,
            depth: coordinate.depth,
            radialDistance: radius,
          ),
        );
      }
      contours.add(
        List<DesktopSphereGraphProjectedSurfaceSample>.unmodifiable(samples),
      );
    }
    return DesktopSphereGraphProjectedShellGuide(
      radius: radius,
      isAtmosphere: isAtmosphere,
      contours:
          List<List<DesktopSphereGraphProjectedSurfaceSample>>.unmodifiable(
            contours,
          ),
    );
  }

  _SphereVector _leastAlignedBasis(_SphereVector vector) {
    final absoluteX = vector.x.abs();
    final absoluteY = vector.y.abs();
    final absoluteZ = vector.z.abs();
    if (absoluteX <= absoluteY && absoluteX <= absoluteZ) {
      return const _SphereVector(1, 0, 0);
    }
    if (absoluteY <= absoluteZ) {
      return const _SphereVector(0, 1, 0);
    }
    return const _SphereVector(0, 0, 1);
  }

  List<_SphereVector> _shellGuidePlaneNormals({
    required _SphereProjectionContext projection,
    required int shellOrder,
  }) {
    // The first contour is the central circle facing the active camera. It
    // establishes each hollow shell's outline. The other two are deliberately
    // staggered by shell, preventing ten shared equators from reading as an
    // orbital belt while still remaining fixed in the globe's own 3D space.
    final cameraAlignedNormal = _SphereVector(
      -projection.sinY * projection.cosX,
      projection.sinX,
      projection.cosY * projection.cosX,
    ).normalized();
    _SphereVector obliqueNormal(double phase, double vertical) {
      final horizontal = math.sqrt(math.max(0, 1 - vertical * vertical));
      return _SphereVector(
        math.cos(phase) * horizontal,
        vertical,
        math.sin(phase) * horizontal,
      );
    }

    final phase = shellOrder * _shellGuideGoldenAngle + .37;
    return <_SphereVector>[
      cameraAlignedNormal,
      obliqueNormal(phase, shellOrder.isEven ? .16 : -.22),
      obliqueNormal(phase + math.pi * .57, shellOrder % 3 == 0 ? -.10 : .28),
    ];
  }

  /// Projects sparse, deterministic particles outside the information shells.
  /// They are material only and never participate in graph selection.
  List<DesktopSphereGraphProjectedAtmosphereDust> projectAtmosphereDust({
    required Size viewport,
    double rotationX = 0,
    double rotationY = 0,
    double zoom = 1,
    double padding = 12,
    Offset pan = Offset.zero,
  }) {
    if (viewport.isEmpty) {
      return const <DesktopSphereGraphProjectedAtmosphereDust>[];
    }
    final projection = _projectionContext(
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
      zoom: zoom,
      padding: padding,
      pan: pan,
    );
    final dust = <DesktopSphereGraphProjectedAtmosphereDust>[];
    for (var index = 0; index < defaultAtmosphereDustCount; index++) {
      final point = _atmosphereDustPoint(index);
      final coordinate = _projectCoordinates(
        x: point.x,
        y: point.y,
        z: point.z,
        projection: projection,
      );
      dust.add(
        DesktopSphereGraphProjectedAtmosphereDust(
          id: 'high-altitude-dust-$index',
          position: coordinate.position,
          cameraDepth: coordinate.cameraDepth,
          depth: coordinate.depth,
        ),
      );
    }
    return List<DesktopSphereGraphProjectedAtmosphereDust>.unmodifiable(dust);
  }

  _SphereVector _atmosphereDustPoint(int index) {
    final id = 'external-particle-$index';
    final latitude = (1 - 2 * _unitInterval('$id|latitude')).clamp(-.94, .94);
    final longitude = math.pi * 2 * _unitInterval('$id|longitude');
    final horizontalRadius = math.sqrt(math.max(0, 1 - latitude * latitude));
    final shellRadius =
        atmosphereShellRadii.last + .008 + _unitInterval('$id|radius') * .022;
    return _SphereVector(
      math.cos(longitude) * horizontalRadius * shellRadius,
      latitude * shellRadius,
      math.sin(longitude) * horizontalRadius * shellRadius,
    );
  }

  _SphereProjectionContext _projectionContext({
    required Size viewport,
    required double rotationX,
    required double rotationY,
    required double zoom,
    required double padding,
    required Offset pan,
  }) {
    if (!rotationX.isFinite || !rotationY.isFinite) {
      throw ArgumentError('Rotation values must be finite');
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
    if (!pan.dx.isFinite || !pan.dy.isFinite) {
      throw ArgumentError.value(pan, 'pan', 'must contain finite coordinates');
    }
    final availableRadius = math.max(
      0.0,
      math.min(viewport.width, viewport.height) / 2 - padding,
    );
    return _SphereProjectionContext(
      center: viewport.center(Offset.zero) + pan,
      canvasRadius: availableRadius * canvasRadiusFactor * zoom,
      sinX: math.sin(rotationX),
      cosX: math.cos(rotationX),
      sinY: math.sin(rotationY),
      cosY: math.cos(rotationY),
    );
  }

  _SphereProjectedCoordinate _projectCoordinates({
    required double x,
    required double y,
    required double z,
    required _SphereProjectionContext projection,
  }) {
    final rotatedX = x * projection.cosY + z * projection.sinY;
    final zAfterYRotation = -x * projection.sinY + z * projection.cosY;
    final rotatedY = y * projection.cosX - zAfterYRotation * projection.sinX;
    final rotatedZ = y * projection.sinX + zAfterYRotation * projection.cosX;
    final depth = ((rotatedZ + 1) / 2).clamp(0.0, 1.0).toDouble();
    final perspective = 1 / (1 - rotatedZ * perspectiveStrength);
    return _SphereProjectedCoordinate(
      position:
          projection.center +
          Offset(rotatedX, rotatedY) * projection.canvasRadius * perspective,
      cameraDepth: rotatedZ,
      depth: depth,
    );
  }

  int _adaptiveSurfaceArcSegmentCount(
    DesktopSphereGraphLayoutPoint source,
    DesktopSphereGraphLayoutPoint target, {
    required int minimum,
    required int maximum,
  }) {
    final sourceUnit = _unitVectorFor(source);
    final targetUnit = _unitVectorFor(target);
    final angle = math.acos(
      sourceUnit.dot(targetUnit).clamp(-1.0, 1.0).toDouble(),
    );
    // Fifteen-degree samples stay visibly curved at the edge of the sphere,
    // while the caller's cap keeps large collections linear in work.
    final desired = math.max(1, (angle / (math.pi / 12)).ceil());
    return desired.clamp(minimum, maximum).toInt();
  }

  _SphereVector _unitVectorFor(DesktopSphereGraphLayoutPoint point) {
    final vector = _SphereVector(point.x, point.y, point.z);
    if (!vector.isFinite || vector.lengthSquared < 1e-12) {
      throw ArgumentError.value(
        point,
        'point',
        'surface arcs require a finite non-zero point direction',
      );
    }
    return vector.normalized();
  }

  _SphereVector _deterministicPerpendicular(
    _SphereVector vector, {
    required String sourceId,
    required String targetId,
  }) {
    final absoluteX = vector.x.abs();
    final absoluteY = vector.y.abs();
    final absoluteZ = vector.z.abs();
    final basis = absoluteX <= absoluteY && absoluteX <= absoluteZ
        ? const _SphereVector(1, 0, 0)
        : absoluteY <= absoluteZ
        ? const _SphereVector(0, 1, 0)
        : const _SphereVector(0, 0, 1);
    final orientation = sourceId.compareTo(targetId) <= 0 ? 1.0 : -1.0;
    return vector.cross(basis).normalized() * orientation;
  }

  List<DesktopSphereGraphVisualLink> buildVisualLinks({
    required Iterable<DesktopSphereGraphLayoutPoint> points,
    int neighborsPerPoint = 2,
  }) {
    if (neighborsPerPoint < 0) {
      throw RangeError.value(
        neighborsPerPoint,
        'neighborsPerPoint',
        'must not be negative',
      );
    }
    final source = points.toList(growable: false);
    if (source.length < 2) return const <DesktopSphereGraphVisualLink>[];
    if (source.map((point) => point.id).toSet().length != source.length) {
      throw ArgumentError.value(points, 'points', 'point IDs must be unique');
    }

    // The exact MST plus per-node nearest-neighbour sort is attractive on a
    // small canvas, but becomes quadratic when a user has thousands of notes.
    // This keeps every point and a connected mesh while making dense graphs
    // scale with a spatial ordering instead of an all-pairs search.
    if (source.length > _largeMeshThreshold) {
      return _buildLargeVisualLinks(source, neighborsPerPoint);
    }

    return _buildExactVisualLinks(source, neighborsPerPoint);
  }

  List<DesktopSphereGraphVisualLink> _buildExactVisualLinks(
    List<DesktopSphereGraphLayoutPoint> source,
    int neighborsPerPoint,
  ) {
    final pairs = <(int, int)>{};
    final included = List<bool>.filled(source.length, false);
    final bestDistance = List<double>.filled(source.length, double.infinity);
    final parent = List<int>.filled(source.length, -1);
    bestDistance[0] = 0;

    for (var step = 0; step < source.length; step++) {
      var next = -1;
      for (var candidate = 0; candidate < source.length; candidate++) {
        if (included[candidate]) continue;
        if (next == -1 ||
            bestDistance[candidate] < bestDistance[next] ||
            (bestDistance[candidate] == bestDistance[next] &&
                candidate < next)) {
          next = candidate;
        }
      }
      included[next] = true;
      if (parent[next] >= 0) pairs.add(_orderedPair(next, parent[next]));
      for (var candidate = 0; candidate < source.length; candidate++) {
        if (included[candidate]) continue;
        final distance = _distanceSquared(source[next], source[candidate]);
        if (distance < bestDistance[candidate] ||
            (distance == bestDistance[candidate] && next < parent[candidate])) {
          bestDistance[candidate] = distance;
          parent[candidate] = next;
        }
      }
    }

    if (neighborsPerPoint > 0) {
      for (var index = 0; index < source.length; index++) {
        final candidates =
            <int>[
              for (var other = 0; other < source.length; other++)
                if (other != index) other,
            ]..sort((left, right) {
              final byDistance = _distanceSquared(
                source[index],
                source[left],
              ).compareTo(_distanceSquared(source[index], source[right]));
              return byDistance != 0
                  ? byDistance
                  : source[left].id.compareTo(source[right].id);
            });
        for (final neighbor in candidates.take(
          math.min(neighborsPerPoint, candidates.length),
        )) {
          pairs.add(_orderedPair(index, neighbor));
        }
      }
    }

    final sortedPairs = pairs.toList()
      ..sort((left, right) {
        final bySource = left.$1.compareTo(right.$1);
        return bySource != 0 ? bySource : left.$2.compareTo(right.$2);
      });
    return List<DesktopSphereGraphVisualLink>.unmodifiable([
      for (final pair in sortedPairs)
        DesktopSphereGraphVisualLink(
          sourceId: source[pair.$1].id,
          targetId: source[pair.$2].id,
          touchesSyntheticPoint:
              source[pair.$1].isSynthetic || source[pair.$2].isSynthetic,
        ),
    ]);
  }

  List<DesktopSphereGraphVisualLink> _buildLargeVisualLinks(
    List<DesktopSphereGraphLayoutPoint> source,
    int neighborsPerPoint,
  ) {
    final ordered = List<DesktopSphereGraphLayoutPoint>.of(source)
      ..sort((left, right) {
        final byPosition = _spatialKey(left).compareTo(_spatialKey(right));
        return byPosition != 0 ? byPosition : left.id.compareTo(right.id);
      });
    final byId = <String, DesktopSphereGraphLayoutPoint>{
      for (final point in source) point.id: point,
    };
    final pairs = <(String, String)>{};

    void addPair(
      DesktopSphereGraphLayoutPoint left,
      DesktopSphereGraphLayoutPoint right,
    ) {
      if (left.id == right.id) return;
      pairs.add(
        left.id.compareTo(right.id) < 0
            ? (left.id, right.id)
            : (right.id, left.id),
      );
    }

    for (var index = 1; index < ordered.length; index++) {
      final point = ordered[index];
      DesktopSphereGraphLayoutPoint? parent;
      var parentDistance = double.infinity;
      final firstCandidate = math.max(0, index - _largeMeshSearchWindow);
      for (
        var candidateIndex = firstCandidate;
        candidateIndex < index;
        candidateIndex++
      ) {
        final candidate = ordered[candidateIndex];
        final distance = _distanceSquared(point, candidate);
        if (distance < parentDistance ||
            (distance == parentDistance &&
                (parent == null || candidate.id.compareTo(parent.id) < 0))) {
          parent = candidate;
          parentDistance = distance;
        }
      }
      addPair(point, parent!);

      if (neighborsPerPoint == 0) continue;
      final nearby = <DesktopSphereGraphLayoutPoint>[];
      final lastCandidate = math.min(
        ordered.length - 1,
        index + _largeMeshSearchWindow,
      );
      for (
        var candidateIndex = firstCandidate;
        candidateIndex <= lastCandidate;
        candidateIndex++
      ) {
        if (candidateIndex != index) nearby.add(ordered[candidateIndex]);
      }
      nearby.sort((left, right) {
        final byDistance = _distanceSquared(
          point,
          left,
        ).compareTo(_distanceSquared(point, right));
        return byDistance != 0 ? byDistance : left.id.compareTo(right.id);
      });
      for (final candidate in nearby.take(neighborsPerPoint)) {
        addPair(point, candidate);
      }
    }

    final sortedPairs = pairs.toList()
      ..sort((left, right) {
        final bySource = left.$1.compareTo(right.$1);
        return bySource != 0 ? bySource : left.$2.compareTo(right.$2);
      });
    return List<DesktopSphereGraphVisualLink>.unmodifiable([
      for (final pair in sortedPairs)
        DesktopSphereGraphVisualLink(
          sourceId: pair.$1,
          targetId: pair.$2,
          touchesSyntheticPoint:
              byId[pair.$1]!.isSynthetic || byId[pair.$2]!.isSynthetic,
        ),
    ]);
  }

  DesktopSphereGraphLayoutPoint _pointForId({
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
    final shellIndex = _shellIndexForId(id);
    final shellRadius = contentShellRadii[shellIndex];
    return DesktopSphereGraphLayoutPoint(
      id: id,
      x: math.cos(angle) * horizontalRadius * shellRadius,
      y: directionY * shellRadius,
      z: math.sin(angle) * horizontalRadius * shellRadius,
      isSynthetic: isSynthetic,
      shellIndex: shellIndex,
    );
  }

  static (int, int) _orderedPair(int left, int right) =>
      left < right ? (left, right) : (right, left);

  static int _shellIndexForId(String id) {
    final value = _unitInterval('$id|shell');
    var cumulative = 0.0;
    for (var index = 0; index < contentShellWeights.length; index++) {
      cumulative += contentShellWeights[index];
      if (value < cumulative) return index;
    }
    // A hash may map exactly to 1.0, and rounding must never leave a point
    // outside the outer sparse shell.
    return contentShellWeights.length - 1;
  }

  static int _spatialKey(DesktopSphereGraphLayoutPoint point) {
    int quantize(double value) =>
        (((value / contentShellRadii.last + 1) * .5 * 1023).round())
            .clamp(0, 1023)
            .toInt();
    final x = quantize(point.x);
    final y = quantize(point.y);
    final z = quantize(point.z);
    var key = 0;
    for (var bit = 0; bit < 10; bit++) {
      key |= ((x >> bit) & 1) << (bit * 3);
      key |= ((y >> bit) & 1) << (bit * 3 + 1);
      key |= ((z >> bit) & 1) << (bit * 3 + 2);
    }
    return key;
  }

  static double _distanceSquared(
    DesktopSphereGraphLayoutPoint left,
    DesktopSphereGraphLayoutPoint right,
  ) {
    final x = left.x - right.x;
    final y = left.y - right.y;
    final z = left.z - right.z;
    return x * x + y * y + z * z;
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    hash ^= hash >> 16;
    hash = (hash * 0x7feb352d) & 0xffffffff;
    hash ^= hash >> 15;
    hash = (hash * 0x846ca68b) & 0xffffffff;
    hash ^= hash >> 16;
    return hash;
  }

  static double _unitInterval(String value) => _stableHash(value) / 0xffffffff;

  static double _lerp(double start, double end, double amount) =>
      start + (end - start) * amount;
}

final class _SphereProjectionContext {
  const _SphereProjectionContext({
    required this.center,
    required this.canvasRadius,
    required this.sinX,
    required this.cosX,
    required this.sinY,
    required this.cosY,
  });

  final Offset center;
  final double canvasRadius;
  final double sinX;
  final double cosX;
  final double sinY;
  final double cosY;
}

final class _SphereProjectedCoordinate {
  const _SphereProjectedCoordinate({
    required this.position,
    required this.cameraDepth,
    required this.depth,
  });

  final Offset position;
  final double cameraDepth;
  final double depth;
}

final class _SphereVector {
  const _SphereVector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get lengthSquared => x * x + y * y + z * z;

  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  _SphereVector operator +(_SphereVector other) =>
      _SphereVector(x + other.x, y + other.y, z + other.z);

  _SphereVector operator *(double factor) =>
      _SphereVector(x * factor, y * factor, z * factor);

  _SphereVector operator /(double divisor) =>
      _SphereVector(x / divisor, y / divisor, z / divisor);

  double dot(_SphereVector other) => x * other.x + y * other.y + z * other.z;

  _SphereVector cross(_SphereVector other) => _SphereVector(
    y * other.z - z * other.y,
    z * other.x - x * other.z,
    x * other.y - y * other.x,
  );

  _SphereVector normalized() {
    final length = math.sqrt(lengthSquared);
    if (!length.isFinite || length < 1e-12) {
      throw ArgumentError('Cannot normalize a zero-length sphere vector');
    }
    return this / length;
  }
}
