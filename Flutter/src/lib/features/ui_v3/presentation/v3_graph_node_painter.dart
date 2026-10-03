import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../domain/ui_v3_models.dart';

typedef GraphNodePositionResolver = Map<String, Offset> Function();
typedef GraphNodePaintOrderResolver = List<String> Function();

class V3GraphNodePainter extends CustomPainter {
  V3GraphNodePainter({
    required Listenable repaint,
    required this.resolvePositions,
    required this.resolveZoom,
    required this.sceneOrigin,
    required this.nodes,
    required this.nodeRadii,
    required this.nodeColors,
    required this.nodeOpacities,
    required this.overlayNodeIds,
    required this.showAllLabels,
    this.selectedNodeId,
    this.labelNodeIds = const <String>{},
    this.nodeDepths = const <String, double>{},
    this.labelColor = const Color(0xFF30312F),
    this.labelHaloColor = const Color(0xFFFFFFFF),
    this.onSemanticNodeTap,
    this.maximumSemanticNodes = 40,
    this.resolvePaintOrderIds,
  }) : _nodesById = <String, V3GraphNode>{
         for (final node in nodes) node.id: node,
       },
       super(repaint: repaint);

  final GraphNodePositionResolver resolvePositions;
  final double Function() resolveZoom;
  final Offset sceneOrigin;
  final List<V3GraphNode> nodes;
  final Map<String, double> nodeRadii;
  final Map<String, Color> nodeColors;
  final Map<String, double> nodeOpacities;
  final Map<String, double> nodeDepths;
  final Set<String> overlayNodeIds;
  final bool showAllLabels;
  final String? selectedNodeId;
  final Set<String> labelNodeIds;
  final Color labelColor;
  final Color labelHaloColor;
  final ValueChanged<String>? onSemanticNodeTap;
  final int maximumSemanticNodes;
  final GraphNodePaintOrderResolver? resolvePaintOrderIds;
  final Map<String, V3GraphNode> _nodesById;
  final Map<(String, int, int), TextPainter> _labelPainters = {};
  int _paintedLabelCount = 0;

  @visibleForTesting
  int get paintedLabelCount => _paintedLabelCount;

  @override
  void paint(Canvas canvas, Size size) {
    final positions = resolvePositions();
    final rawZoom = resolveZoom();
    final zoom = rawZoom.isFinite && rawZoom > .001 ? rawZoom : 1.0;
    _paintedLabelCount = 0;
    canvas.save();
    canvas.translate(sceneOrigin.dx, sceneOrigin.dy);
    final paintNodes = _orderedNodes();
    final haloPaint = Paint()..style = PaintingStyle.fill;
    final bloomPaint = Paint()..style = PaintingStyle.fill;
    final bodyPaint = Paint()..style = PaintingStyle.fill;
    final corePaint = Paint()..style = PaintingStyle.fill;
    final highlightPaint = Paint()..style = PaintingStyle.fill;
    for (final node in paintNodes) {
      if (overlayNodeIds.contains(node.id)) continue;
      final position = positions[node.id];
      if (position == null) continue;
      final opacity = (nodeOpacities[node.id] ?? 1).clamp(0.0, 1.0).toDouble();
      if (opacity <= .01) continue;
      final radius = (nodeRadii[node.id] ?? 7).clamp(4.0, 14.0).toDouble();
      final color =
          nodeColors[node.id] ?? Color.lerp(labelColor, labelHaloColor, .25)!;
      haloPaint.color = color.withValues(alpha: .18 * opacity);
      canvas.drawCircle(position, radius, haloPaint);
      bloomPaint.color = color.withValues(alpha: .68 * opacity);
      canvas.drawCircle(position, radius * .62, bloomPaint);
      bodyPaint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(position, radius * .36, bodyPaint);
      corePaint.color = Color.lerp(
        color,
        const Color(0xFFFFFFFF),
        .72,
      )!.withValues(alpha: .96 * opacity);
      canvas.drawCircle(position, radius * .19, corePaint);
      highlightPaint.color = const Color(
        0xFFFFFFFF,
      ).withValues(alpha: .9 * opacity);
      canvas.drawCircle(
        position - Offset(radius * .06, radius * .06),
        math.max(.5, radius * .07),
        highlightPaint,
      );
      if (node.isHotspot || node.isAggregated) {
        canvas.drawCircle(
          position,
          radius + 2.2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8
            ..color = color.withValues(alpha: .52 * opacity),
        );
      }
      if (node.id == selectedNodeId) {
        canvas.drawCircle(
          position,
          radius + 3.2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = color.withValues(alpha: .92 * opacity),
        );
      }
      if (showAllLabels &&
          (labelNodeIds.isEmpty || labelNodeIds.contains(node.id)) &&
          (nodeDepths[node.id] ?? .5) >= .54) {
        final label = _labelPainter(node.label, zoom, opacity);
        label.paint(
          canvas,
          Offset(
            position.dx - label.width / 2,
            position.dy + radius + 4 / zoom,
          ),
        );
        _paintedLabelCount++;
      }
    }
    canvas.restore();
  }

  Iterable<V3GraphNode> _orderedNodes() sync* {
    final resolvedOrder = resolvePaintOrderIds?.call();
    if (resolvedOrder != null) {
      for (final id in resolvedOrder) {
        final node = _nodesById[id];
        if (node != null) yield node;
      }
      return;
    }
    final sorted = List<V3GraphNode>.of(nodes)
      ..sort((left, right) {
        final byDepth = (nodeDepths[left.id] ?? .5).compareTo(
          nodeDepths[right.id] ?? .5,
        );
        return byDepth != 0 ? byDepth : left.id.compareTo(right.id);
      });
    yield* sorted;
  }

  @override
  bool shouldRepaint(covariant V3GraphNodePainter oldDelegate) =>
      oldDelegate.sceneOrigin != sceneOrigin ||
      oldDelegate.showAllLabels != showAllLabels ||
      oldDelegate.selectedNodeId != selectedNodeId ||
      !setEquals(oldDelegate.labelNodeIds, labelNodeIds) ||
      oldDelegate.labelColor != labelColor ||
      oldDelegate.labelHaloColor != labelHaloColor ||
      !listEquals(oldDelegate.nodes, nodes) ||
      !mapEquals(oldDelegate.nodeRadii, nodeRadii) ||
      !mapEquals(oldDelegate.nodeColors, nodeColors) ||
      !mapEquals(oldDelegate.nodeOpacities, nodeOpacities) ||
      !mapEquals(oldDelegate.nodeDepths, nodeDepths) ||
      !setEquals(oldDelegate.overlayNodeIds, overlayNodeIds);

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final positions = resolvePositions();
    final zoom = resolveZoom();
    final safeZoom = zoom.isFinite && zoom > .001 ? zoom : 1.0;
    final ranked =
        <V3GraphNode>[
          for (final node in nodes)
            if (!overlayNodeIds.contains(node.id) &&
                (nodeOpacities[node.id] ?? 1) > .04 &&
                (nodeDepths[node.id] ?? .5) >= .2 &&
                positions[node.id] != null)
              node,
        ]..sort((left, right) {
          final state = _nodeStateRank(right).compareTo(_nodeStateRank(left));
          if (state != 0) return state;
          final weight = right.weight.compareTo(left.weight);
          return weight != 0 ? weight : left.id.compareTo(right.id);
        });
    final limit = maximumSemanticNodes.clamp(0, 80);
    return <CustomPainterSemantics>[
      for (final node in ranked.take(limit))
        CustomPainterSemantics(
          rect: Rect.fromCircle(
            center: positions[node.id]! + sceneOrigin,
            radius: math.max(nodeRadii[node.id] ?? 7, 22 / safeZoom),
          ),
          properties: SemanticsProperties(
            label: '知识实体：${node.label}',
            textDirection: TextDirection.ltr,
            hint: node.summary.trim().isEmpty
                ? '双击选择实体'
                : '${node.summary.trim()}，双击选择实体',
            button: true,
            enabled: onSemanticNodeTap != null,
            onTap: onSemanticNodeTap == null
                ? null
                : () => onSemanticNodeTap!(node.id),
          ),
        ),
    ];
  };

  @override
  bool shouldRebuildSemantics(covariant V3GraphNodePainter oldDelegate) =>
      shouldRepaint(oldDelegate) ||
      oldDelegate.maximumSemanticNodes != maximumSemanticNodes ||
      oldDelegate.onSemanticNodeTap != onSemanticNodeTap;

  TextPainter _labelPainter(String text, double zoom, double opacity) {
    final zoomBucket = math.max(1, (zoom * 20).round());
    final opacityBucket = (opacity * 20).round().clamp(0, 20).toInt();
    final key = (text, zoomBucket, opacityBucket);
    return _labelPainters.putIfAbsent(key, () {
      final effectiveZoom = zoomBucket / 20;
      final effectiveOpacity = opacityBucket / 20;
      final labelWidth = v3GraphDenseLabelScreenWidth(effectiveZoom);
      if (_labelPainters.length > 320) _labelPainters.clear();
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: labelColor.withValues(alpha: effectiveOpacity),
            fontSize: v3GraphDenseLabelSceneFontSize(effectiveZoom),
            height: 1.15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            shadows: <Shadow>[
              Shadow(
                color: labelHaloColor.withValues(alpha: effectiveOpacity),
                blurRadius: 3 / effectiveZoom,
              ),
            ],
          ),
        ),
        maxLines: v3GraphDenseLabelMaxLines(effectiveZoom),
        ellipsis: '…',
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: labelWidth / effectiveZoom);
    });
  }
}

double v3GraphDenseLabelSceneFontSize(double zoom) {
  final safeZoom = zoom.isFinite && zoom > .001 ? zoom : 1.0;
  return 9 / safeZoom;
}

double v3GraphDenseLabelScreenWidth(double zoom) {
  final safeZoom = zoom.isFinite && zoom > .001 ? zoom : 1.0;
  if (safeZoom >= 1.78) return 180;
  if (safeZoom >= 1.12) return 144;
  return 76;
}

int v3GraphDenseLabelMaxLines(double zoom) {
  final safeZoom = zoom.isFinite && zoom > .001 ? zoom : 1.0;
  if (safeZoom >= 1.78) return 4;
  if (safeZoom >= 1.12) return 3;
  return 1;
}

bool v3GraphUsesDenseCanvas({required int nodeCount, required int edgeCount}) =>
    nodeCount > 120 || edgeCount > 300;

Set<String> v3GraphDenseOverlayNodeIds({
  required List<V3GraphNode> nodes,
  required Map<String, V3GraphNodeRole> roles,
  required Iterable<String> searchMatchNodeIds,
  String? selectedNodeId,
  int maximum = 8,
}) {
  final result = <String>{};
  void add(String? id) {
    if (id != null && id.isNotEmpty && result.length < maximum) result.add(id);
  }

  for (final id in searchMatchNodeIds) {
    add(id);
  }
  final ranked = List<V3GraphNode>.of(nodes)
    ..sort((left, right) {
      final leftRole = roles[left.id] ?? V3GraphNodeRole.satellite;
      final rightRole = roles[right.id] ?? V3GraphNodeRole.satellite;
      final role = leftRole.index.compareTo(rightRole.index);
      if (role != 0) return role;
      final state = _nodeStateRank(right).compareTo(_nodeStateRank(left));
      if (state != 0) return state;
      final weight = right.weight.compareTo(left.weight);
      return weight != 0 ? weight : left.id.compareTo(right.id);
    });
  for (final node in ranked) {
    final role = roles[node.id] ?? V3GraphNodeRole.satellite;
    if (node.center ||
        role == V3GraphNodeRole.core ||
        node.isHotspot ||
        node.isAggregated ||
        node.weight >= 1.35) {
      add(node.id);
    }
  }
  return Set<String>.unmodifiable(result);
}

V3GraphNode? hitTestV3GraphCanvasNode({
  required Offset scenePosition,
  required List<V3GraphNode> nodes,
  required Map<String, Offset> positions,
  required Map<String, double> radii,
  required Map<String, double> opacities,
  required double zoom,
  Map<String, double> depths = const <String, double>{},
  Set<String> excludedNodeIds = const <String>{},
}) {
  if (!scenePosition.dx.isFinite || !scenePosition.dy.isFinite) return null;
  final safeZoom = zoom.isFinite && zoom > .001 ? zoom : 1.0;
  V3GraphNode? nearest;
  var nearestDepth = double.negativeInfinity;
  var nearestDistance = double.infinity;
  for (final node in nodes) {
    if (excludedNodeIds.contains(node.id)) continue;
    if ((opacities[node.id] ?? 1) <= .01) continue;
    final position = positions[node.id];
    if (position == null) continue;
    final hitRadius = math.max(radii[node.id] ?? 7, 22 / safeZoom);
    final distance = (position - scenePosition).distance;
    if (distance > hitRadius) continue;
    final depth = depths[node.id] ?? .5;
    if (depth > nearestDepth + .0001 ||
        (depth - nearestDepth).abs() <= .0001 &&
            (distance < nearestDistance ||
                distance == nearestDistance &&
                    (nearest == null || node.id.compareTo(nearest.id) < 0))) {
      nearest = node;
      nearestDepth = depth;
      nearestDistance = distance;
    }
  }
  return nearest;
}

int _nodeStateRank(V3GraphNode node) =>
    (node.center ? 8 : 0) +
    (node.isHotspot ? 4 : 0) +
    (node.isAggregated ? 2 : 0) +
    (node.isRecent ? 1 : 0);
