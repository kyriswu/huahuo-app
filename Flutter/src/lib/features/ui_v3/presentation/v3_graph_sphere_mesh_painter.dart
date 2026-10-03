import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../application/sphere_graph_projection_controller.dart';

double _sphereNodeOpacity({
  required double semanticOpacity,
  required double depthOpacity,
  required bool emphasized,
}) {
  final boundedDepth = depthOpacity.clamp(0.0, 1.0).toDouble();
  final effectiveDepth = emphasized
      ? math.max(.78, boundedDepth)
      : boundedDepth;
  return (semanticOpacity * effectiveDepth).clamp(.03, 1.0).toDouble();
}

final class V3SphereNodeRadiusMap extends MapBase<String, double> {
  V3SphereNodeRadiusMap(this.projection);

  final SphereGraphProjectionController projection;

  @override
  double? operator [](Object? key) {
    final factor = projection.projectedSizeFactors[key];
    return factor == null ? null : 7.0 * factor.clamp(.5, 1.2);
  }

  @override
  Iterable<String> get keys => projection.positions.keys;

  @override
  void operator []=(String key, double value) =>
      throw UnsupportedError('projection views are read-only');

  @override
  void clear() => throw UnsupportedError('projection views are read-only');

  @override
  double? remove(Object? key) =>
      throw UnsupportedError('projection views are read-only');
}

final class V3SphereNodeOpacityMap extends MapBase<String, double> {
  V3SphereNodeOpacityMap({
    required this.projection,
    required this.semanticOpacities,
    required this.emphasizedNodeIds,
  });

  final SphereGraphProjectionController projection;
  final Map<String, double> semanticOpacities;
  final Set<String> emphasizedNodeIds;

  @override
  double? operator [](Object? key) {
    if (key is! String) return null;
    final semanticOpacity = semanticOpacities[key];
    final depthOpacity = projection.projectedOpacities[key];
    if (semanticOpacity == null || depthOpacity == null) return null;
    return _sphereNodeOpacity(
      semanticOpacity: semanticOpacity,
      depthOpacity: depthOpacity,
      emphasized: emphasizedNodeIds.contains(key),
    );
  }

  @override
  Iterable<String> get keys => semanticOpacities.keys;

  @override
  void operator []=(String key, double value) =>
      throw UnsupportedError('projection views are read-only');

  @override
  void clear() => throw UnsupportedError('projection views are read-only');

  @override
  double? remove(Object? key) =>
      throw UnsupportedError('projection views are read-only');
}

Color v3SphereSyntheticColorForId(String id, {required List<Color> palette}) {
  if (palette.isEmpty) return const Color(0xFF707070);
  var hash = 0x811c9dc5;
  for (final codeUnit in id.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return palette[hash % palette.length];
}

/// Paints visual-only structure directly from reusable projection buffers.
final class V3GraphSphereMeshPainter extends CustomPainter {
  V3GraphSphereMeshPainter({
    required this.projection,
    required this.nodeColors,
    required this.syntheticPalette,
    required this.sceneOrigin,
    this.canvasColor = const Color(0xFFFFFFFF),
    this.baseNodeRadius = 5.5,
    this.useEdgeGradients = true,
  }) : super(repaint: projection);

  final SphereGraphProjectionController projection;
  final Map<String, Color> nodeColors;
  final List<Color> syntheticPalette;
  final Offset sceneOrigin;
  final Color canvasColor;
  final double baseNodeRadius;
  final bool useEdgeGradients;

  List<String> _lastLinkPaintOrder = const <String>[];
  List<String> _lastSyntheticPointPaintOrder = const <String>[];
  List<String>? _colorNodeIds;
  List<Color> _colors = const [];

  @visibleForTesting
  List<String> get lastLinkPaintOrder => _lastLinkPaintOrder;

  @visibleForTesting
  List<String> get lastSyntheticPointPaintOrder =>
      _lastSyntheticPointPaintOrder;

  @override
  void paint(Canvas canvas, Size size) {
    final topology = projection.topology;
    if (!identical(_colorNodeIds, topology.nodeIds)) {
      _colorNodeIds = topology.nodeIds;
      _colors = [
        for (final id in topology.nodeIds)
          nodeColors[id] ??
              v3SphereSyntheticColorForId(id, palette: syntheticPalette),
      ];
    }
    assert(() {
      _lastLinkPaintOrder = List<String>.unmodifiable(<String>[
        for (final linkIndex in projection.visualLinkDrawOrder)
          '${topology.nodeIds[topology.visualLinkSources[linkIndex]]}->'
              '${topology.nodeIds[topology.visualLinkTargets[linkIndex]]}',
      ]);
      _lastSyntheticPointPaintOrder = List<String>.unmodifiable(<String>[
        for (final nodeIndex in projection.drawOrder)
          if (topology.isSynthetic(nodeIndex)) topology.nodeIds[nodeIndex],
      ]);
      return true;
    }());

    final origin = _isFiniteOffset(sceneOrigin) ? sceneOrigin : Offset.zero;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final pointPaint = Paint()..style = PaintingStyle.fill;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    for (final linkIndex in projection.visualLinkDrawOrder) {
      _paintLink(canvas, linkIndex, linePaint);
    }
    for (final nodeIndex in projection.drawOrder) {
      if (topology.isSynthetic(nodeIndex)) {
        _paintSyntheticPoint(canvas, nodeIndex, pointPaint);
      }
    }
    canvas.restore();
  }

  void _paintLink(Canvas canvas, int linkIndex, Paint linePaint) {
    final topology = projection.topology;
    final sourceIndex = topology.visualLinkSources[linkIndex];
    final targetIndex = topology.visualLinkTargets[linkIndex];
    final source = projection.positionAt(sourceIndex);
    final target = projection.positionAt(targetIndex);
    if (!_isFiniteOffset(source) || !_isFiniteOffset(target)) return;
    final sourceColor = _colorFor(sourceIndex);
    final targetColor = _colorFor(targetIndex);
    final depth =
        (projection.normalizedDepths[sourceIndex] +
            projection.normalizedDepths[targetIndex]) /
        2;
    final depthVisibility = _lerp(.58, .94, depth);
    final fadedSource = Color.lerp(canvasColor, sourceColor, depthVisibility)!;
    final fadedTarget = Color.lerp(canvasColor, targetColor, depthVisibility)!;
    final fadedColor = Color.lerp(fadedSource, fadedTarget, .5)!;
    final syntheticQuieting = topology.visualLinkSyntheticFlags[linkIndex] != 0
        ? .78
        : 1.0;
    final endpointContrast = math.min(
      _pointContrast(sourceIndex),
      _pointContrast(targetIndex),
    );
    final opacity =
        math.max(
          .003,
          math.min(
            _lerp(.09, .18, depth),
            endpointContrast * .45 / depthVisibility,
          ),
        ) *
        syntheticQuieting;
    final strokeWidth = _lerp(.45, .72, depth);
    final gradient = !useEdgeGradients || topology.nodeCount > 500
        ? null
        : _linkGradient(source, target, fadedSource, fadedTarget, opacity);
    linePaint
      ..strokeWidth = strokeWidth
      ..color = gradient == null
          ? fadedColor.withValues(alpha: opacity)
          : const Color(0xFFFFFFFF)
      ..shader = gradient;
    canvas.drawLine(source, target, linePaint);
  }

  double _pointContrast(int index) =>
      _lerp(.16, .96, projection.normalizedDepths[index].clamp(0.0, 1.0)) *
      projection.opacities[index].clamp(.05, .72);

  void _paintSyntheticPoint(Canvas canvas, int index, Paint paint) {
    final position = projection.positionAt(index);
    if (!_isFiniteOffset(position)) return;
    final radius =
        _safeBaseRadius * projection.sizeFactors[index].clamp(.35, 1.4);
    if (!radius.isFinite || radius <= 0) return;
    final depthVisibility = _lerp(
      .16,
      .96,
      projection.normalizedDepths[index].clamp(0.0, 1.0),
    );
    final color = Color.lerp(canvasColor, _colorFor(index), depthVisibility)!;
    final opacity = projection.opacities[index].clamp(.05, .72);
    paint.color = color.withValues(alpha: opacity * .48);
    canvas.drawCircle(position, radius * .82, paint);
    paint.color = color.withValues(alpha: opacity * .92);
    canvas.drawCircle(position, radius * .45, paint);
    paint.color = Color.lerp(
      color,
      const Color(0xFFFFFFFF),
      .76,
    )!.withValues(alpha: opacity);
    canvas.drawCircle(position, math.max(.45, radius * .18), paint);
  }

  Color _colorFor(int index) {
    return _colors[index];
  }

  double get _safeBaseRadius =>
      baseNodeRadius.isFinite && baseNodeRadius > 0 ? baseNodeRadius : 5.5;

  @override
  bool shouldRepaint(covariant V3GraphSphereMeshPainter oldDelegate) =>
      oldDelegate.projection != projection ||
      oldDelegate.sceneOrigin != sceneOrigin ||
      oldDelegate.canvasColor != canvasColor ||
      oldDelegate.baseNodeRadius != baseNodeRadius ||
      oldDelegate.useEdgeGradients != useEdgeGradients ||
      !mapEquals(oldDelegate.nodeColors, nodeColors) ||
      !listEquals(oldDelegate.syntheticPalette, syntheticPalette);
}

bool _isFiniteOffset(Offset offset) => offset.dx.isFinite && offset.dy.isFinite;

double _lerp(double start, double end, double amount) =>
    start + (end - start) * amount;

ui.Shader? _linkGradient(
  Offset start,
  Offset end,
  Color source,
  Color target,
  double opacity,
) {
  if ((end - start).distanceSquared < .01 || source == target) return null;
  return ui.Gradient.linear(start, end, <Color>[
    source.withValues(alpha: opacity),
    target.withValues(alpha: opacity),
  ]);
}
