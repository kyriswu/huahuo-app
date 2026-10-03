import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/desktop_theme.dart';
import '../application/desktop_graph_preferences.dart';

/// Settings controls for the desktop knowledge graph.
///
/// Slider changes stay in memory while the pointer is moving and are persisted
/// only when the interaction ends. This keeps the live preview responsive
/// without replacing the preferences file on every frame.
class DesktopGraphSettingsControls extends StatelessWidget {
  const DesktopGraphSettingsControls({required this.controller, super.key});

  final DesktopGraphPreferencesController controller;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<DesktopGraphPreferences>(
    valueListenable: controller,
    builder: (context, preferences, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeading(
          title: '视觉',
          detail: '节点尺寸与颜色在 2D、3D 和密集图谱中保持一致。',
          trailing: Tooltip(
            message: '恢复图谱默认设置',
            child: TextButton.icon(
              key: const ValueKey<String>('graph-preferences-reset'),
              onPressed: preferences == DesktopGraphPreferences.defaults
                  ? null
                  : () => unawaited(controller.reset()),
              icon: const Icon(LucideIcons.rotateCcw, size: 14),
              label: const Text('恢复默认'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ForceGraphPreview(preferences: preferences),
        const SizedBox(height: 14),
        _GraphScaleControl(
          sliderKey: const ValueKey<String>('graph-node-scale'),
          label: '点大小',
          detail: '同步调整节点尺寸与点击范围。',
          value: preferences.nodeScale,
          minimum: DesktopGraphPreferences.minimumNodeScale,
          maximum: DesktopGraphPreferences.maximumNodeScale,
          divisions: 19,
          onChanged: (value) =>
              controller.preview(controller.value.copyWith(nodeScale: value)),
          onChangeEnd: (value) => unawaited(
            controller.commit(controller.value.copyWith(nodeScale: value)),
          ),
        ),
        const SizedBox(height: 8),
        Text('图谱配色', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 3),
        Text(
          '低饱和颜色让节点层级清楚，同时避免干扰正文阅读。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        _GraphPaletteGrid(
          value: preferences.colorPreset,
          onChanged: (preset) => unawaited(
            controller.commit(controller.value.copyWith(colorPreset: preset)),
          ),
        ),
        const Divider(height: 33),
        const _SectionHeading(title: '2D 动态布局', detail: '调整节点相互靠近、分离和停止运动的方式。'),
        const SizedBox(height: 8),
        _GraphScaleControl(
          sliderKey: const ValueKey<String>('graph-attraction-scale'),
          label: '引力',
          detail: '数值越高，关联节点越快回到彼此附近。',
          value: preferences.attractionScale,
          minimum: DesktopGraphPreferences.minimumAttractionScale,
          maximum: DesktopGraphPreferences.maximumAttractionScale,
          divisions: 33,
          onChanged: (value) => controller.preview(
            controller.value.copyWith(attractionScale: value),
          ),
          onChangeEnd: (value) => unawaited(
            controller.commit(
              controller.value.copyWith(attractionScale: value),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _GraphScaleControl(
          sliderKey: const ValueKey<String>('graph-repulsion-scale'),
          label: '斥力',
          detail: '数值越高，节点越主动保持间距。',
          value: preferences.repulsionScale,
          minimum: DesktopGraphPreferences.minimumRepulsionScale,
          maximum: DesktopGraphPreferences.maximumRepulsionScale,
          divisions: 40,
          onChanged: (value) => controller.preview(
            controller.value.copyWith(repulsionScale: value),
          ),
          onChangeEnd: (value) => unawaited(
            controller.commit(controller.value.copyWith(repulsionScale: value)),
          ),
        ),
        const SizedBox(height: 8),
        _GraphScaleControl(
          sliderKey: const ValueKey<String>('graph-damping-scale'),
          label: '阻尼',
          detail: '数值越高，惯性和回弹越克制。',
          value: preferences.dampingScale,
          minimum: DesktopGraphPreferences.minimumDampingScale,
          maximum: DesktopGraphPreferences.maximumDampingScale,
          divisions: 36,
          onChanged: (value) => controller.preview(
            controller.value.copyWith(dampingScale: value),
          ),
          onChangeEnd: (value) => unawaited(
            controller.commit(controller.value.copyWith(dampingScale: value)),
          ),
        ),
        const SizedBox(height: 10),
        _StaticLayoutNotice(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.detail,
    this.trailing,
  });

  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: textTheme.titleSmall),
              const SizedBox(height: 3),
              Text(
                detail,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (trailing case final Widget trailing) ...<Widget>[
          const SizedBox(width: 12),
          trailing,
        ],
      ],
    );
  }
}

class _GraphScaleControl extends StatelessWidget {
  const _GraphScaleControl({
    required this.sliderKey,
    required this.label,
    required this.detail,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Key sliderKey;
  final String label;
  final String detail;
  final double value;
  final double minimum;
  final double maximum;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final percentage = '${(value * 100).round()}%';
    return Semantics(
      container: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(label, style: textTheme.labelLarge)),
              SizedBox(
                width: 46,
                child: Text(
                  percentage,
                  textAlign: TextAlign.right,
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTickMarkColor: Colors.transparent,
              inactiveTickMarkColor: Colors.transparent,
            ),
            child: Slider(
              key: sliderKey,
              value: value,
              min: minimum,
              max: maximum,
              divisions: divisions,
              label: percentage,
              semanticFormatterCallback: (sliderValue) =>
                  '${(sliderValue * 100).round()}%',
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticLayoutNotice extends StatelessWidget {
  const _StaticLayoutNotice({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '布局范围说明',
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.info, size: 14, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '引力、斥力和阻尼会实时作用于所有 2D 图谱，包括大型社群。3D 球面保持静态布局；点大小与配色在所有视图中生效。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color, height: 1.45),
          ),
        ),
      ],
    ),
  );
}

class _GraphPaletteGrid extends StatelessWidget {
  const _GraphPaletteGrid({required this.value, required this.onChanged});

  final DesktopGraphColorPreset value;
  final ValueChanged<DesktopGraphColorPreset> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final availableWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : 600.0;
      final columns = availableWidth >= 660
          ? 3
          : availableWidth >= 420
          ? 2
          : 1;
      final tileWidth = (availableWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: <Widget>[
          for (final preset in DesktopGraphColorPreset.values)
            SizedBox(
              width: tileWidth,
              child: _GraphPaletteTile(
                preset: preset,
                selected: value == preset,
                onTap: () => onChanged(preset),
              ),
            ),
        ],
      );
    },
  );
}

class _GraphPaletteTile extends StatelessWidget {
  const _GraphPaletteTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final DesktopGraphColorPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final palette = _paletteFor(preset);
    final selectedSurface = Color.alphaBlend(
      colors.primary.withValues(alpha: .065),
      colors.surfaceContainerLow,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${palette.label}图谱配色，${palette.description}',
      child: Material(
        color: selected ? selectedSurface : colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        child: InkWell(
          key: ValueKey<String>('graph-palette-${preset.storageValue}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            constraints: const BoxConstraints(minHeight: 82),
            padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 1.25 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        palette.label,
                        style: textTheme.labelLarge?.copyWith(
                          color: selected ? colors.primary : colors.onSurface,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(LucideIcons.check, size: 15, color: colors.primary),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    for (final swatch in palette.swatches) ...<Widget>[
                      Container(
                        width: 19,
                        height: 7,
                        decoration: BoxDecoration(
                          color: swatch,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  palette.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ForceGraphPreview extends StatefulWidget {
  const _ForceGraphPreview({required this.preferences});

  final DesktopGraphPreferences preferences;

  @override
  State<_ForceGraphPreview> createState() => _ForceGraphPreviewState();
}

class _ForceGraphPreviewState extends State<_ForceGraphPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  late final List<_PreviewNode> _nodes;
  int _lastElapsedMicroseconds = 0;
  int _frame = 0;
  double _simulationTime = 0;

  static const List<_PreviewEdge> _edges = <_PreviewEdge>[
    _PreviewEdge(0, 1, .20),
    _PreviewEdge(0, 5, .23),
    _PreviewEdge(1, 2, .21),
    _PreviewEdge(1, 6, .24),
    _PreviewEdge(2, 3, .22),
    _PreviewEdge(2, 6, .20),
    _PreviewEdge(2, 7, .24),
    _PreviewEdge(3, 4, .20),
    _PreviewEdge(3, 8, .24),
    _PreviewEdge(4, 7, .23),
    _PreviewEdge(5, 6, .21),
    _PreviewEdge(6, 7, .20),
    _PreviewEdge(7, 8, .21),
  ];

  @override
  void initState() {
    super.initState();
    _nodes = <_PreviewNode>[
      _PreviewNode(.16, .38, 1.3),
      _PreviewNode(.32, .25, 1.8),
      _PreviewNode(.49, .43, 3.0),
      _PreviewNode(.67, .24, 1.7),
      _PreviewNode(.84, .40, 1.2),
      _PreviewNode(.24, .70, 1.1),
      _PreviewNode(.42, .66, 1.6),
      _PreviewNode(.65, .70, 2.1),
      _PreviewNode(.82, .67, 1.0),
    ];
    _ticker = AnimationController(
      vsync: this,
      duration: DesktopMotionTokens.ambientLoop,
    )..addListener(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    if (animationsDisabled) {
      _ticker.stop();
      _lastElapsedMicroseconds = 0;
    } else if (!_ticker.isAnimating) {
      _lastElapsedMicroseconds = 0;
      _ticker.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _ForceGraphPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.preferences;
    final current = widget.preferences;
    final forceDelta =
        (DesktopGraphPreferences.attractionResponseFor(old.attractionScale) -
                DesktopGraphPreferences.attractionResponseFor(
                  current.attractionScale,
                ))
            .abs() +
        (DesktopGraphPreferences.repulsionResponseFor(old.repulsionScale) -
                DesktopGraphPreferences.repulsionResponseFor(
                  current.repulsionScale,
                ))
            .abs() +
        (DesktopGraphPreferences.dampingResponseFor(old.dampingScale) -
                DesktopGraphPreferences.dampingResponseFor(
                  current.dampingScale,
                ))
            .abs();
    if (forceDelta > .001) _nudge(math.min(.14, .018 + forceDelta * .032));
  }

  void _nudge(double strength) {
    for (var index = 0; index < _nodes.length; index += 1) {
      final angle = index * 2.17 + _simulationTime;
      _nodes[index]
        ..vx += math.cos(angle) * strength
        ..vy += math.sin(angle) * strength;
    }
  }

  void _onTick() {
    final elapsedMicroseconds =
        _ticker.lastElapsedDuration?.inMicroseconds ?? 0;
    if (_lastElapsedMicroseconds == 0) {
      _lastElapsedMicroseconds = elapsedMicroseconds;
      return;
    }
    final elapsedSeconds =
        (elapsedMicroseconds - _lastElapsedMicroseconds) /
        Duration.microsecondsPerSecond;
    _lastElapsedMicroseconds = elapsedMicroseconds;
    if (elapsedSeconds <= 0) return;
    _step(elapsedSeconds.clamp(1 / 240, 1 / 30));
    if (mounted) setState(() => _frame += 1);
  }

  void _step(double elapsedSeconds) {
    _simulationTime += elapsedSeconds;
    final preferences = widget.preferences;
    final attraction = DesktopGraphPreferences.attractionResponseFor(
      preferences.attractionScale,
    );
    final repulsion = DesktopGraphPreferences.repulsionResponseFor(
      preferences.repulsionScale,
    );
    final damping = DesktopGraphPreferences.dampingResponseFor(
      preferences.dampingScale,
    );
    final forceX = List<double>.filled(_nodes.length, 0);
    final forceY = List<double>.filled(_nodes.length, 0);
    final anchorX = .5 + math.sin(_simulationTime * .72) * .018;
    final anchorY = .5 + math.cos(_simulationTime * .61) * .014;

    for (var index = 0; index < _nodes.length; index += 1) {
      final node = _nodes[index];
      forceX[index] += (anchorX - node.x) * .30 * attraction;
      forceY[index] += (anchorY - node.y) * .30 * attraction;
      final phase = _simulationTime * (.8 + index * .017) + index * 1.3;
      forceX[index] += math.cos(phase) * .009;
      forceY[index] += math.sin(phase * .91) * .009;
    }

    for (final edge in _edges) {
      final first = _nodes[edge.first];
      final second = _nodes[edge.second];
      final dx = second.x - first.x;
      final dy = second.y - first.y;
      final distance = math.max(.001, math.sqrt(dx * dx + dy * dy));
      final spring = (distance - edge.restLength) * 2.45 * attraction;
      final fx = dx / distance * spring;
      final fy = dy / distance * spring;
      forceX[edge.first] += fx;
      forceY[edge.first] += fy;
      forceX[edge.second] -= fx;
      forceY[edge.second] -= fy;
    }

    for (var firstIndex = 0; firstIndex < _nodes.length; firstIndex += 1) {
      for (
        var secondIndex = firstIndex + 1;
        secondIndex < _nodes.length;
        secondIndex += 1
      ) {
        final first = _nodes[firstIndex];
        final second = _nodes[secondIndex];
        var dx = first.x - second.x;
        var dy = first.y - second.y;
        final distanceSquared = math.max(.0025, dx * dx + dy * dy);
        final distance = math.sqrt(distanceSquared);
        dx /= distance;
        dy /= distance;
        final separation = .0024 * repulsion / distanceSquared;
        final fx = dx * separation;
        final fy = dy * separation;
        forceX[firstIndex] += fx;
        forceY[firstIndex] += fy;
        forceX[secondIndex] -= fx;
        forceY[secondIndex] -= fy;
      }
    }

    final velocityRetention = math.exp(
      -(1.25 + damping * 2.85) * elapsedSeconds,
    );
    for (var index = 0; index < _nodes.length; index += 1) {
      final node = _nodes[index];
      final inverseMass = 1 / (.78 + node.weight * .10);
      node
        ..vx =
            (node.vx + forceX[index] * inverseMass * elapsedSeconds) *
            velocityRetention
        ..vy =
            (node.vy + forceY[index] * inverseMass * elapsedSeconds) *
            velocityRetention;
      final speed = math.sqrt(node.vx * node.vx + node.vy * node.vy);
      if (speed > .20) {
        node
          ..vx = node.vx / speed * .20
          ..vy = node.vy / speed * .20;
      }
      node
        ..x += node.vx * elapsedSeconds
        ..y += node.vy * elapsedSeconds;
      _contain(node);
    }
  }

  void _contain(_PreviewNode node) {
    if (node.x < .055 || node.x > .945) {
      node
        ..x = node.x.clamp(.055, .945)
        ..vx *= -.32;
    }
    if (node.y < .075 || node.y > .925) {
      node
        ..y = node.y.clamp(.075, .925)
        ..vy *= -.32;
    }
  }

  @override
  void dispose() {
    _ticker
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = _paletteFor(widget.preferences.colorPreset);
    final previewBackground = Color.alphaBlend(
      palette.swatches.first.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? .055 : .035,
      ),
      colors.surfaceContainerLowest,
    );
    return Semantics(
      image: true,
      label: '当前图谱参数的动态力场预览',
      child: Container(
        height: 178,
        decoration: BoxDecoration(
          color: previewBackground,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 9, 11, 7),
              child: Row(
                children: <Widget>[
                  Icon(
                    LucideIcons.network,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '实时力场预览',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  Text(
                    '2D',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _ForceGraphPainter(
                    nodes: _nodes,
                    edges: _edges,
                    frame: _frame,
                    nodeScale: widget.preferences.nodeScale,
                    palette: palette,
                    background: previewBackground,
                    outline: colors.outlineVariant,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForceGraphPainter extends CustomPainter {
  const _ForceGraphPainter({
    required this.nodes,
    required this.edges,
    required this.frame,
    required this.nodeScale,
    required this.palette,
    required this.background,
    required this.outline,
  });

  final List<_PreviewNode> nodes;
  final List<_PreviewEdge> edges;
  final int frame;
  final double nodeScale;
  final _GraphPalette palette;
  final Color background;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final graphRect = Rect.fromLTWH(14, 4, size.width - 28, size.height - 13);
    final positions = <Offset>[
      for (final node in nodes)
        Offset(
          graphRect.left + node.x * graphRect.width,
          graphRect.top + node.y * graphRect.height,
        ),
    ];
    final linePaint = Paint()
      ..color = Color.lerp(
        outline,
        palette.swatches.first,
        .32,
      )!.withValues(alpha: .62)
      ..strokeWidth = .8
      ..strokeCap = StrokeCap.round;
    for (final edge in edges) {
      canvas.drawLine(positions[edge.first], positions[edge.second], linePaint);
    }

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: .12)
      ..maskFilter = const MaskFilter.blur(
        BlurStyle.normal,
        DesktopEffectTokens.graphPreviewShadowSigma,
      );
    for (var index = 0; index < nodes.length; index += 1) {
      final node = nodes[index];
      final center = positions[index];
      final radius = (2.8 + node.weight * .78) * nodeScale;
      final color = palette.swatches[index % palette.swatches.length];
      canvas.drawCircle(
        center + const Offset(0, 1.3),
        radius + .6,
        shadowPaint,
      );
      canvas.drawCircle(center, radius + .7, Paint()..color = background);
      canvas.drawCircle(center, radius, Paint()..color = color);
      canvas.drawCircle(
        center + Offset(-radius * .25, -radius * .28),
        math.max(.65, radius * .23),
        Paint()..color = Colors.white.withValues(alpha: .24),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ForceGraphPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.nodeScale != nodeScale ||
      oldDelegate.palette != palette ||
      oldDelegate.background != background ||
      oldDelegate.outline != outline;
}

class _PreviewNode {
  _PreviewNode(this.x, this.y, this.weight);

  double x;
  double y;
  final double weight;
  double vx = 0;
  double vy = 0;
}

class _PreviewEdge {
  const _PreviewEdge(this.first, this.second, this.restLength);

  final int first;
  final int second;
  final double restLength;
}

@immutable
class _GraphPalette {
  const _GraphPalette({
    required this.label,
    required this.description,
    required this.swatches,
  });

  final String label;
  final String description;
  final List<Color> swatches;
}

const Map<DesktopGraphColorPreset, _GraphPalette>
_graphPalettes = <DesktopGraphColorPreset, _GraphPalette>{
  DesktopGraphColorPreset.mistSilver: _GraphPalette(
    label: '雾银',
    description: '石墨 · 雾蓝 · 鼠尾草',
    swatches: <Color>[Color(0xFF56616B), Color(0xFF7893A2), Color(0xFF83978B)],
  ),
  DesktopGraphColorPreset.tide: _GraphPalette(
    label: '潮汐',
    description: '深海蓝 · 海沫绿 · 柔珊瑚',
    swatches: <Color>[Color(0xFF376579), Color(0xFF67978E), Color(0xFFC28A82)],
  ),
  DesktopGraphColorPreset.mountainMist: _GraphPalette(
    label: '山岚',
    description: '冷杉 · 岩灰 · 淡琥珀',
    swatches: <Color>[Color(0xFF4E7167), Color(0xFF747C7E), Color(0xFFB79A69)],
  ),
  DesktopGraphColorPreset.editorial: _GraphPalette(
    label: '刊物',
    description: '墨色 · 铅蓝 · 低饱和酒红',
    swatches: <Color>[Color(0xFF42484E), Color(0xFF687B8B), Color(0xFF90686C)],
  ),
  DesktopGraphColorPreset.nightVoyage: _GraphPalette(
    label: '夜航',
    description: '蓝灰 · 烟紫 · 暖铜',
    swatches: <Color>[Color(0xFF566B7B), Color(0xFF756F83), Color(0xFFA27E67)],
  ),
  DesktopGraphColorPreset.electricYouth: _GraphPalette(
    label: '电气青年',
    description: '钴蓝 · 酸柠 · 樱桃',
    swatches: <Color>[Color(0xFF1837D7), Color(0xFF8EDB21), Color(0xFFFF594D)],
  ),
  DesktopGraphColorPreset.candySignal: _GraphPalette(
    label: '糖果信号',
    description: '糖果粉 · 晴空蓝 · 芒果',
    swatches: <Color>[Color(0xFFEE1C85), Color(0xFF20B6D7), Color(0xFFFF8A3D)],
  ),
  DesktopGraphColorPreset.egoPulse: _GraphPalette(
    label: 'EGO 脉冲',
    description: '电紫 · 野莓 · 珊瑚',
    swatches: <Color>[Color(0xFF612CEB), Color(0xFFE12D9C), Color(0xFFF05D3C)],
  ),
  DesktopGraphColorPreset.pureInk: _GraphPalette(
    label: '纯墨',
    description: '石墨 · 铅灰 · 雾白',
    swatches: <Color>[Color(0xFF42484E), Color(0xFF747C83), Color(0xFFA8ADB2)],
  ),
};

_GraphPalette _paletteFor(DesktopGraphColorPreset preset) =>
    _graphPalettes[preset]!;
