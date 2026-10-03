import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/huahuo_v3_theme.dart';
import 'v3_glass_blur_tokens.dart';
import 'v3_glass_foundations.dart';
import 'v3_glass_painters.dart';

export 'v3_glass_foundations.dart';

class V3LiquidGlassCircle extends StatelessWidget {
  const V3LiquidGlassCircle({
    required this.diameter,
    required this.child,
    required this.semanticLabel,
    required this.onTap,
    required this.tone,
    this.selected = false,
    this.selectedRingColor,
    super.key,
  });

  final double diameter;
  final Widget child;
  final String semanticLabel;
  final VoidCallback onTap;
  final V3GlassTone tone;
  final bool selected;
  final Color? selectedRingColor;

  @override
  Widget build(BuildContext context) {
    _debugAssertNoInteractiveGlassSurfaceAncestor(context, runtimeType);
    final tokens = HuahuoV3Theme.tokensOf(context);
    final resolvedSelectedRingColor = selectedRingColor ?? tokens.warmGlass.rim;

    const border = CircleBorder();
    return SizedBox.square(
      dimension: diameter,
      child: Semantics(
        button: true,
        selected: selected,
        label: semanticLabel,
        child: CustomPaint(
          painter: _V3GlassOuterHaloPainter(
            tone: tone,
            selected: selected,
            selectedRingColor: resolvedSelectedRingColor,
            tokens: tokens,
          ),
          child: Material(
            color: V3GlassSpec.fallbackSurfaceFor(
              tone,
              selected: selected,
              tokens: tokens,
            ),
            surfaceTintColor: Colors.transparent,
            animationDuration: Duration.zero,
            shape: border,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: border,
              onTap: onTap,
              child: _V3CircleContent(
                tone: tone,
                selected: selected,
                selectedRingColor: resolvedSelectedRingColor,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact V3 icon action with one stable opaque surface.
class V3LiquidGlassIconAction extends StatelessWidget {
  const V3LiquidGlassIconAction({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.onTap,
    super.key,
  });

  final Widget icon;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: SizedBox.square(
          dimension: V3GlassSpec.iconActionDiameter,
          child: Material(
            color: tokens.surface,
            elevation: 2,
            shadowColor: tokens.ink.withValues(alpha: .12),
            surfaceTintColor: Colors.transparent,
            shape: CircleBorder(side: BorderSide(color: tokens.line)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: IconTheme(
                data: IconThemeData(
                  color: tokens.ink,
                  size: HuahuoV3Theme.topIconSize,
                ),
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A decorative V3 glass surface.
///
/// Do not place interactive glass controls inside this widget. In debug mode,
/// [V3LiquidGlassCircle] reports the invalid nested interaction when it finds
/// this surface in its ancestor tree.
class V3LiquidGlassSurface extends StatelessWidget {
  const V3LiquidGlassSurface({
    required this.child,
    this.tone = V3GlassTone.neutral,
    this.padding = EdgeInsets.zero,
    this.borderRadius = V3GlassSpec.surfaceRadius,
    this.borderShape,
    this.style = V3GlassSurfaceStyle.panel,
    this.opacity = .84,
    this.color,
    super.key,
  });

  final Widget child;
  final V3GlassTone tone;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final BorderRadiusGeometry? borderShape;
  final V3GlassSurfaceStyle style;
  final double opacity;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    final radius = math.max(0.0, borderRadius);
    final borderRadiusGeometry = (borderShape ?? BorderRadius.circular(radius))
        .resolve(Directionality.of(context));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = HuahuoV3Theme.tokensOf(context);
    final effectiveOpacity =
        (opacity * V3GlassOpacityScope.alphaScaleOf(context))
            .clamp(0.0, 1.0)
            .toDouble();
    final base = V3GlassSpec.fallbackSurfaceFor(tone, tokens: tokens);
    final fill = color == null
        ? _surfaceFill(style, tone, isDark: isDark, tokens: tokens)
              .map(
                (fill) => Color.alphaBlend(
                  fill.withValues(alpha: fill.a * effectiveOpacity),
                  base,
                ),
              )
              .toList(growable: false)
        : List<Color>.filled(3, Color.alphaBlend(color!, tokens.surface));
    return _V3GlassSurfaceScope(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadiusGeometry,
          boxShadow: _surfaceShadows(style, tokens),
        ),
        child: ClipRRect(
          borderRadius: borderRadiusGeometry,
          child: CustomPaint(
            foregroundPainter: _V3GlassEdgePainter(
              tone: tone,
              borderRadius: borderRadiusGeometry,
              style: style,
              isDark: isDark,
              rim: V3GlassSpec.rimFor(tone, tokens: tokens),
              coolRim: tokens.coolGlass.rim,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadiusGeometry,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: fill,
                  stops: const <double>[0, .48, 1],
                ),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Borderless floating glass used by the compact home docks and selection lens.
class V3FloatingGlassDockSurface extends StatelessWidget {
  const V3FloatingGlassDockSurface({
    required this.child,
    this.borderRadius = 28,
    this.selection = false,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final bool selection;

  @override
  Widget build(BuildContext context) {
    final radius = math.max(0.0, borderRadius);
    final tokens = HuahuoV3Theme.tokensOf(context);
    final alphaScale = V3GlassOpacityScope.alphaScaleOf(context);
    final base = selection
        ? tokens.coolGlass.selectedFallback
        : tokens.coolGlass.fallback;
    final fill =
        <Color>[
              tokens.surface.withValues(alpha: selection ? .25 : .29),
              tokens.coolGlass.fallback.withValues(alpha: .18),
              tokens.coolGlass.selectedFallback.withValues(
                alpha: selection ? .13 : .12,
              ),
            ]
            .map(
              (fill) => Color.alphaBlend(
                fill.withValues(alpha: (fill.a * alphaScale).clamp(0.0, 1.0)),
                base,
              ),
            )
            .toList(growable: false);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _buildContactShadow(tokens),
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(
            foregroundPainter: V3FloatingDockRefractionPainter(
              borderRadius: radius,
              selection: selection,
              tokens: tokens,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: fill,
                  stops: const [0, .52, 1],
                ),
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContactShadow(HuahuoV3ThemeTokens tokens) {
    return Positioned(
      left: selection ? 5 : 18,
      right: selection ? 5 : 18,
      bottom: selection ? 1 : 0,
      height: selection ? 7 : 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Color.lerp(
                Colors.black,
                tokens.coolGlass.rim,
                .10,
              )!.withValues(alpha: selection ? .12 : .26),
              blurRadius: selection ? 11 : 22,
              spreadRadius: selection ? -2 : 0,
              offset: Offset(0, selection ? 4 : 9),
            ),
            if (!selection)
              BoxShadow(
                color: tokens.coolGlass.rim.withValues(alpha: .10),
                blurRadius: 14,
                spreadRadius: -2,
                offset: const Offset(2, 4),
              ),
          ],
        ),
      ),
    );
  }
}

class _V3GlassEdgePainter extends CustomPainter {
  const _V3GlassEdgePainter({
    required this.tone,
    required this.borderRadius,
    required this.style,
    required this.isDark,
    required this.rim,
    required this.coolRim,
  });

  final V3GlassTone tone;
  final BorderRadius borderRadius;
  final V3GlassSurfaceStyle style;
  final bool isDark;
  final Color rim;
  final Color coolRim;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    final shape = borderRadius.toRRect(rect);
    final edge = shape.deflate(V3GlassSpec.edgeInset(.45));
    final strength = switch (style) {
      V3GlassSurfaceStyle.panel => 1.0,
      V3GlassSurfaceStyle.dock => 1.12,
      V3GlassSurfaceStyle.dockSelection => .84,
      V3GlassSurfaceStyle.subtle => .88,
    };
    canvas.save();
    canvas.clipRRect(shape);

    final upperReflection = Paint()
      ..color = Colors.white.withValues(alpha: .07 * strength)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.upperReflect);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          edge.left + math.min(edge.width * .22, 92),
          edge.top + math.min(edge.height * .16, 32),
        ),
        width: math.min(edge.width * .28, 120),
        height: math.min(edge.height * .26, 30),
      ),
      upperReflection,
    );

    final lowerReflection = Paint()
      ..color = coolRim.withValues(alpha: .045 * strength)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.lowerReflect);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          edge.right - math.min(edge.width * .18, 76),
          edge.bottom - math.min(edge.height * .14, 28),
        ),
        width: math.min(edge.width * .24, 108),
        height: math.min(edge.height * .22, 28),
      ),
      lowerReflection,
    );

    final meniscus = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(3.6)
      ..color = Colors.white.withValues(alpha: (isDark ? .10 : .12) * strength)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.edgeMeniscus);
    canvas.drawRRect(shape.deflate(V3GlassSpec.edgeInset(2.2)), meniscus);

    final compression = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(.9)
      ..color = (isDark ? Colors.black : const Color(0xFF65717A)).withValues(
        alpha: (isDark ? .12 : .08) * strength,
      )
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.edgeCompression);
    canvas.drawRRect(shape.deflate(V3GlassSpec.edgeInset(4.2)), compression);

    final upperLeftPath = Path()
      ..moveTo(edge.left + .7, edge.top + math.max(4, edge.tlRadiusY * .88))
      ..cubicTo(
        edge.left + .2,
        edge.top + math.max(2, edge.tlRadiusY * .42),
        edge.left + math.max(3, edge.tlRadiusX * .34),
        edge.top + .5,
        edge.left + math.max(7, edge.tlRadiusX * .92),
        edge.top + .45,
      )
      ..cubicTo(
        edge.left + edge.width * .18,
        edge.top + .1,
        edge.left + edge.width * .32,
        edge.top + .15,
        edge.left + edge.width * .43,
        edge.top + 1.1,
      );
    final upperLeftHighlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(1.15)
      ..color = Colors.white.withValues(alpha: .68 * strength)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.upperHighlight);
    canvas.drawPath(upperLeftPath, upperLeftHighlight);

    final lowerRightPath = Path()
      ..moveTo(edge.right - edge.width * .36, edge.bottom - .55)
      ..cubicTo(
        edge.right - math.max(7, edge.brRadiusX * .92),
        edge.bottom - .1,
        edge.right - math.max(3, edge.brRadiusX * .34),
        edge.bottom - .4,
        edge.right - .6,
        edge.bottom - math.max(3, edge.brRadiusY * .38),
      )
      ..cubicTo(
        edge.right - .15,
        edge.bottom - math.max(6, edge.brRadiusY * .68),
        edge.right - .3,
        edge.bottom - math.max(8, edge.brRadiusY * .92),
        edge.right - 1.1,
        edge.bottom - math.max(10, edge.brRadiusY * 1.12),
      );
    final lowerRightRefraction = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(1.10)
      ..color = HuahuoV3Theme.glassCoolRim.withValues(alpha: .30 * strength)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.lowerRefract);
    canvas.drawPath(lowerRightPath, lowerRightRefraction);

    if (tone != V3GlassTone.neutral) {
      final warmGlint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = V3GlassSpec.edgeStroke(.9)
        ..color = Color.lerp(
          rim,
          Colors.white,
          .22,
        )!.withValues(alpha: .18 * strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.edgeWarmGlint);
      canvas.drawLine(
        Offset(edge.left + edge.width * .56, edge.top + 1.4),
        Offset(edge.left + edge.width * .69, edge.top + 2.0),
        warmGlint,
      );
    }

    final outerCatch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(.65)
      ..color = Colors.white.withValues(alpha: (isDark ? .28 : .36) * strength);
    canvas.drawRRect(edge, outerCatch);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _V3GlassEdgePainter oldDelegate) {
    return oldDelegate.tone != tone ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.style != style ||
        oldDelegate.isDark != isDark ||
        oldDelegate.rim != rim ||
        oldDelegate.coolRim != coolRim;
  }
}

List<Color> _surfaceFill(
  V3GlassSurfaceStyle style,
  V3GlassTone tone, {
  required bool isDark,
  required HuahuoV3ThemeTokens tokens,
}) {
  if (isDark) {
    final base = tokens.surfaceMuted;
    final lower = Color.lerp(
      base,
      V3GlassSpec.rimFor(tone, tokens: tokens),
      .10,
    )!;
    return switch (style) {
      V3GlassSurfaceStyle.panel => <Color>[
        base.withValues(alpha: .70),
        base.withValues(alpha: .57),
        lower.withValues(alpha: .48),
      ],
      V3GlassSurfaceStyle.dock => <Color>[
        base.withValues(alpha: .75),
        base.withValues(alpha: .62),
        lower.withValues(alpha: .52),
      ],
      V3GlassSurfaceStyle.dockSelection => <Color>[
        base.withValues(alpha: .58),
        base.withValues(alpha: .48),
        lower.withValues(alpha: .41),
      ],
      V3GlassSurfaceStyle.subtle => <Color>[
        base.withValues(alpha: .56),
        base.withValues(alpha: .46),
        lower.withValues(alpha: .38),
      ],
    };
  }
  final lowerTint = Color.lerp(
    tokens.surface,
    V3GlassSpec.rimFor(tone, tokens: tokens),
    .12,
  )!;
  return switch (style) {
    V3GlassSurfaceStyle.panel => <Color>[
      tokens.surface.withValues(alpha: .74),
      tokens.surface.withValues(alpha: .62),
      lowerTint.withValues(alpha: .53),
    ],
    V3GlassSurfaceStyle.dock => <Color>[
      tokens.surface.withValues(alpha: .63),
      tokens.surface.withValues(alpha: .49),
      lowerTint.withValues(alpha: .38),
    ],
    V3GlassSurfaceStyle.dockSelection => <Color>[
      tokens.surface.withValues(alpha: .43),
      tokens.surface.withValues(alpha: .36),
      lowerTint.withValues(alpha: .30),
    ],
    V3GlassSurfaceStyle.subtle => <Color>[
      tokens.surface.withValues(alpha: .47),
      tokens.surface.withValues(alpha: .38),
      lowerTint.withValues(alpha: .30),
    ],
  };
}

List<BoxShadow> _surfaceShadows(
  V3GlassSurfaceStyle style,
  HuahuoV3ThemeTokens tokens,
) {
  final strength = switch (style) {
    V3GlassSurfaceStyle.dock => 1.2,
    V3GlassSurfaceStyle.dockSelection => .7,
    V3GlassSurfaceStyle.panel => 1.0,
    V3GlassSurfaceStyle.subtle => 1.0,
  };
  return <BoxShadow>[
    BoxShadow(
      color: tokens.ink.withValues(alpha: .035 * strength),
      blurRadius: 8,
      spreadRadius: -1,
      offset: const Offset(0, 3),
    ),
    BoxShadow(
      color: tokens.neutralGlass.rim.withValues(alpha: .028 * strength),
      blurRadius: 24,
      spreadRadius: -6,
      offset: const Offset(0, 10),
    ),
  ];
}

class _V3CircleContent extends StatelessWidget {
  const _V3CircleContent({
    required this.tone,
    required this.child,
    this.selected = false,
    this.selectedRingColor = HuahuoV3Theme.glassWarmRim,
  });

  final V3GlassTone tone;
  final Widget child;
  final bool selected;
  final Color selectedRingColor;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: CustomPaint(
            painter: _V3GlassFacePainter(
              tone: tone,
              selected: selected,
              tokens: tokens,
            ),
          ),
        ),
        Center(
          child: IconTheme.merge(
            data: IconThemeData(
              color: V3GlassSpec.iconColorFor(tone, tokens: tokens),
            ),
            child: child,
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _V3GlassRimPainter(
              tone: tone,
              selected: selected,
              selectedRingColor: selectedRingColor,
              tokens: tokens,
            ),
          ),
        ),
      ],
    );
  }
}

class _V3GlassOuterHaloPainter extends CustomPainter {
  const _V3GlassOuterHaloPainter({
    required this.tone,
    required this.selected,
    required this.selectedRingColor,
    required this.tokens,
  });

  final V3GlassTone tone;
  final bool selected;
  final Color selectedRingColor;
  final HuahuoV3ThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = shortest / 2;
    final rim = V3GlassSpec.rimFor(tone, tokens: tokens);
    final liftRim = selected ? selectedRingColor : rim;

    final contact = Paint()
      ..color = Colors.black.withValues(alpha: selected ? 0.050 : 0.042)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.outerHaloContact(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(0, radius * 0.12),
        width: radius * 1.78,
        height: radius * 0.30,
      ),
      contact,
    );

    final colouredLift = Paint()
      ..color = liftRim.withValues(
        alpha: selected ? 0.105 : (tone == V3GlassTone.warm ? 0.095 : 0.14),
      )
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.outerHaloLift(radius),
      );
    canvas.drawCircle(
      center + Offset(0, radius * 0.03),
      radius * 0.98,
      colouredLift,
    );

    final upperAir = Paint()
      ..color = Colors.white.withValues(alpha: 0.84)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.outerHaloUpperAir(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.98),
      ),
      math.pi * 1.03,
      math.pi * 0.72,
      false,
      upperAir
        ..style = PaintingStyle.stroke
        ..strokeWidth = V3GlassSpec.edgeStroke(
          (radius * 0.024).clamp(1.0, 2.1).toDouble(),
        )
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _V3GlassOuterHaloPainter oldDelegate) {
    return oldDelegate.tone != tone ||
        oldDelegate.selected != selected ||
        oldDelegate.selectedRingColor != selectedRingColor ||
        oldDelegate.tokens != tokens;
  }
}

class _V3GlassFacePainter extends CustomPainter {
  const _V3GlassFacePainter({
    required this.tone,
    required this.selected,
    required this.tokens,
  });

  final V3GlassTone tone;
  final bool selected;
  final HuahuoV3ThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = shortest / 2;
    final circle = Rect.fromCircle(center: center, radius: radius);
    final rim = V3GlassSpec.rimFor(tone, tokens: tokens);
    final warm = tone == V3GlassTone.warm;

    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.26, -0.34),
        radius: 0.98,
        colors: <Color>[
          Colors.white.withValues(alpha: 0.42),
          Colors.white.withValues(alpha: 0.15),
          const Color(0xFFCDD3D9).withValues(alpha: 0.215),
          rim.withValues(alpha: warm ? 0.026 : 0.038),
          Colors.white.withValues(alpha: 0.14),
        ],
        stops: const <double>[0.0, 0.36, 0.62, 0.84, 1.0],
      ).createShader(circle);
    canvas.drawCircle(center, radius * V3GlassSpec.edgeRadius(0.965), body);

    final innerMist = Paint()
      ..color = const Color(
        0xFFABB1B7,
      ).withValues(alpha: selected ? 0.170 : 0.145)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceInnerMist(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(-radius * 0.06, -radius * 0.02),
        width: radius * 1.42,
        height: radius * 1.12,
      ),
      innerMist,
    );

    final centerAperture = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.14 : 0.115)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceCenterAperture(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(-radius * 0.03, -radius * 0.02),
        width: radius * 0.88,
        height: radius * 0.72,
      ),
      centerAperture,
    );

    void drawSoftPatch({
      required Offset offset,
      required double width,
      required double height,
      required Color color,
      required double blur,
    }) {
      final paint = Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * blur);
      canvas.drawOval(
        Rect.fromCenter(
          center: center + Offset(radius * offset.dx, radius * offset.dy),
          width: radius * width,
          height: radius * height,
        ),
        paint,
      );
    }

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    drawSoftPatch(
      offset: const Offset(-0.30, -0.40),
      width: 0.66,
      height: 0.19,
      color: const Color(
        0xFF8F969E,
      ).withValues(alpha: selected ? 0.044 : 0.036),
      blur: 0.072,
    );
    drawSoftPatch(
      offset: const Offset(0.12, -0.43),
      width: 0.52,
      height: 0.17,
      color: Colors.white.withValues(alpha: selected ? 0.28 : 0.24),
      blur: 0.034,
    );
    drawSoftPatch(
      offset: const Offset(0.47, -0.25),
      width: 0.16,
      height: 0.42,
      color: Colors.white.withValues(alpha: selected ? 0.36 : 0.31),
      blur: 0.024,
    );
    drawSoftPatch(
      offset: const Offset(0.39, -0.02),
      width: 0.23,
      height: 0.33,
      color: const Color(
        0xFF9AA1A8,
      ).withValues(alpha: selected ? 0.030 : 0.026),
      blur: 0.052,
    );
    drawSoftPatch(
      offset: const Offset(-0.42, 0.13),
      width: 0.24,
      height: 0.46,
      color: const Color(
        0xFF90979E,
      ).withValues(alpha: selected ? 0.038 : 0.032),
      blur: 0.064,
    );
    drawSoftPatch(
      offset: const Offset(0.05, 0.56),
      width: 0.78,
      height: 0.22,
      color: const Color(
        0xFF8F969D,
      ).withValues(alpha: selected ? 0.032 : 0.028),
      blur: 0.070,
    );
    canvas.restore();

    final opticalBandWidth = (radius * 0.085).clamp(3.0, 7.5).toDouble();
    final opticalBand = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(opticalBandWidth)
      ..shader = SweepGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: selected ? .68 : .60),
          const Color(0xFF90979F).withValues(alpha: selected ? .20 : .17),
          Colors.white.withValues(alpha: selected ? .34 : .29),
          rim.withValues(alpha: selected ? .34 : .29),
          Colors.white.withValues(alpha: selected ? .72 : .64),
        ],
        stops: const <double>[0, .23, .48, .75, 1],
        transform: const GradientRotation(math.pi * 1.08),
      ).createShader(circle)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceOpticalBand(radius),
      );
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(.912),
      opticalBand,
    );

    final opticalCompression = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(
        (radius * .014).clamp(.8, 1.35).toDouble(),
      )
      ..shader = SweepGradient(
        colors: <Color>[
          const Color(0xFF7F8790).withValues(alpha: .27),
          Colors.white.withValues(alpha: .70),
          const Color(0xFF858E97).withValues(alpha: .18),
          Colors.white.withValues(alpha: .50),
          const Color(0xFF7F8790).withValues(alpha: .27),
        ],
        stops: const <double>[0, .28, .52, .78, 1],
        transform: const GradientRotation(math.pi * 1.10),
      ).createShader(circle)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceOpticalCompression,
      );
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(.858),
      opticalCompression,
    );

    final edgeMeniscus = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.112)
      ..shader = SweepGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: selected ? 0.20 : 0.17),
          const Color(0xFF9299A1).withValues(alpha: selected ? 0.024 : 0.020),
          Colors.white.withValues(alpha: selected ? 0.15 : 0.13),
          const Color(0xFF899098).withValues(alpha: selected ? 0.030 : 0.025),
          Colors.white.withValues(alpha: selected ? 0.21 : 0.18),
        ],
        stops: const <double>[0.0, 0.28, 0.52, 0.72, 1.0],
        transform: const GradientRotation(math.pi * 1.02),
      ).createShader(circle)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceEdgeMeniscus(radius),
      );
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(0.875),
      edgeMeniscus,
    );

    final upperMeniscusLight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.066)
      ..color = Colors.white.withValues(alpha: selected ? 0.26 : 0.22)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperMeniscusLight(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.866),
      ),
      math.pi * 1.02,
      math.pi * 0.58,
      false,
      upperMeniscusLight,
    );

    final upperGlassWash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.080)
      ..color = Colors.white.withValues(alpha: selected ? 0.22 : 0.18)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperGlassWash(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.760),
      ),
      math.pi * 1.06,
      math.pi * 0.48,
      false,
      upperGlassWash,
    );

    final lowerMeniscusPress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.064)
      ..color = Colors.black.withValues(alpha: selected ? 0.010 : 0.008)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLowerMeniscusPress(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.862),
      ),
      math.pi * 0.20,
      math.pi * 0.54,
      false,
      lowerMeniscusPress,
    );

    final lowerGlassCatch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.060)
      ..color = Colors.white.withValues(alpha: selected ? 0.20 : 0.17)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLowerGlassCatch(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.872),
      ),
      math.pi * 0.24,
      math.pi * 0.46,
      false,
      lowerGlassCatch,
    );

    final upperBloom = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.45 : 0.38)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperBloom(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(-radius * 0.18, -radius * 0.36),
        width: radius * 1.18,
        height: radius * 0.40,
      ),
      upperBloom,
    );

    final topSurfaceSheen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.050)
      ..color = Colors.white.withValues(alpha: selected ? 0.24 : 0.19)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceTopSurfaceSheen(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.805),
      ),
      math.pi * 1.04,
      math.pi * 0.54,
      false,
      topSurfaceSheen,
    );

    final upperLensLip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.082)
      ..color = Colors.white.withValues(alpha: selected ? 0.22 : 0.19)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperLensLip(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.835),
      ),
      math.pi * 1.03,
      math.pi * 0.58,
      false,
      upperLensLip,
    );

    final upperLensShade = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.056)
      ..color = const Color(
        0xFF8C939A,
      ).withValues(alpha: selected ? 0.058 : 0.048)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperLensShade(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.772),
      ),
      math.pi * 1.10,
      math.pi * 0.48,
      false,
      upperLensShade,
    );

    final upperFoldShade = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.046)
      ..color = const Color(
        0xFF858C94,
      ).withValues(alpha: selected ? 0.052 : 0.044)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceUpperFoldShade(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.716),
      ),
      math.pi * 1.08,
      math.pi * 0.52,
      false,
      upperFoldShade,
    );

    final rightBloom = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.27 : 0.23)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceRightBloom(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(radius * 0.39, -radius * 0.17),
        width: radius * 0.25,
        height: radius * 0.70,
      ),
      rightBloom,
    );

    final rightSpark = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.58 : 0.50)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceRightSpark(radius),
      );
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(radius * 0.43, -radius * 0.31),
        width: radius * 0.16,
        height: radius * 0.26,
      ),
      rightSpark,
    );

    void drawCausticPath({
      required List<Offset> points,
      required double strokeWidth,
      required Color color,
      required double blur,
    }) {
      if (points.length < 3 || points.length.isEven) return;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i += 2) {
        path.quadraticBezierTo(
          points[i].dx,
          points[i].dy,
          points[i + 1].dx,
          points[i + 1].dy,
        );
      }
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * strokeWidth)
        ..color = color
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3GlassSpec.edgeBlur(radius * blur),
        );
      canvas.drawPath(path, paint);
    }

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.74, -radius * 0.20),
        center + Offset(-radius * 0.68, -radius * 0.46),
        center + Offset(-radius * 0.40, -radius * 0.51),
        center + Offset(-radius * 0.22, -radius * 0.56),
        center + Offset(-radius * 0.03, -radius * 0.46),
      ],
      strokeWidth: 0.034,
      color: Colors.white.withValues(alpha: selected ? 0.24 : 0.20),
      blur: 0.022,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.08, -radius * 0.48),
        center + Offset(radius * 0.36, -radius * 0.58),
        center + Offset(radius * 0.58, -radius * 0.34),
      ],
      strokeWidth: 0.028,
      color: Colors.white.withValues(alpha: selected ? 0.23 : 0.19),
      blur: 0.018,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.60, -radius * 0.55),
        center + Offset(-radius * 0.42, -radius * 0.72),
        center + Offset(-radius * 0.10, -radius * 0.68),
        center + Offset(radius * 0.14, -radius * 0.66),
        center + Offset(radius * 0.32, -radius * 0.52),
      ],
      strokeWidth: 0.019,
      color: Colors.white.withValues(alpha: selected ? 0.21 : 0.18),
      blur: 0.015,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.32, radius * 0.58),
        center + Offset(-radius * 0.04, radius * 0.66),
        center + Offset(radius * 0.24, radius * 0.54),
      ],
      strokeWidth: 0.020,
      color: const Color(0xFF8F969D).withValues(alpha: 0.032),
      blur: 0.030,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.58, -radius * 0.54),
        center + Offset(radius * 0.78, -radius * 0.38),
        center + Offset(radius * 0.76, -radius * 0.08),
        center + Offset(radius * 0.75, radius * 0.15),
        center + Offset(radius * 0.60, radius * 0.28),
      ],
      strokeWidth: 0.030,
      color: Colors.white.withValues(alpha: selected ? 0.21 : 0.18),
      blur: 0.014,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.66, -radius * 0.66),
        center + Offset(radius * 0.77, -radius * 0.59),
        center + Offset(radius * 0.82, -radius * 0.47),
      ],
      strokeWidth: 0.018,
      color: Colors.white.withValues(alpha: selected ? 0.42 : 0.36),
      blur: 0.006,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.78, -radius * 0.36),
        center + Offset(radius * 0.88, -radius * 0.27),
        center + Offset(radius * 0.84, -radius * 0.10),
      ],
      strokeWidth: 0.014,
      color: Colors.white.withValues(alpha: selected ? 0.30 : 0.26),
      blur: 0.007,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.70, -radius * 0.26),
        center + Offset(-radius * 0.66, -radius * 0.55),
        center + Offset(-radius * 0.34, -radius * 0.68),
        center + Offset(-radius * 0.10, -radius * 0.74),
        center + Offset(radius * 0.18, -radius * 0.60),
      ],
      strokeWidth: 0.034,
      color: const Color(
        0xFF8C939A,
      ).withValues(alpha: selected ? 0.044 : 0.036),
      blur: 0.034,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.80, -radius * 0.46),
        center + Offset(radius * 0.93, -radius * 0.24),
        center + Offset(radius * 0.84, radius * 0.10),
      ],
      strokeWidth: 0.012,
      color: Colors.white.withValues(alpha: selected ? 0.31 : 0.27),
      blur: 0.007,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(radius * 0.70, -radius * 0.36),
        center + Offset(radius * 0.80, -radius * 0.06),
        center + Offset(radius * 0.66, radius * 0.22),
      ],
      strokeWidth: 0.026,
      color: const Color(
        0xFF899098,
      ).withValues(alpha: selected ? 0.038 : 0.032),
      blur: 0.030,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.12, -radius * 0.84),
        center + Offset(radius * 0.18, -radius * 0.90),
        center + Offset(radius * 0.40, -radius * 0.72),
      ],
      strokeWidth: 0.011,
      color: Colors.white.withValues(alpha: selected ? 0.30 : 0.25),
      blur: 0.006,
    );
    drawCausticPath(
      points: <Offset>[
        center + Offset(-radius * 0.22, radius * 0.78),
        center + Offset(radius * 0.12, radius * 0.90),
        center + Offset(radius * 0.48, radius * 0.76),
      ],
      strokeWidth: 0.016,
      color: Colors.white.withValues(alpha: selected ? 0.16 : 0.13),
      blur: 0.020,
    );
    canvas.restore();

    void drawInnerWall({
      required double radiusScale,
      required double start,
      required double sweep,
      required double strokeWidth,
      required Color color,
      required double blur,
    }) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * strokeWidth)
        ..color = color
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3GlassSpec.edgeBlur(radius * blur),
        );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(radiusScale),
        ),
        math.pi * start,
        math.pi * sweep,
        false,
        paint,
      );
    }

    drawInnerWall(
      radiusScale: 0.842,
      start: 1.02,
      sweep: 0.34,
      strokeWidth: 0.070,
      color: Colors.white.withValues(alpha: selected ? 0.23 : 0.19),
      blur: 0.032,
    );
    drawInnerWall(
      radiusScale: 0.838,
      start: 1.36,
      sweep: 0.23,
      strokeWidth: 0.052,
      color: const Color(
        0xFF8F969E,
      ).withValues(alpha: selected ? 0.074 : 0.064),
      blur: 0.038,
    );
    drawInnerWall(
      radiusScale: 0.852,
      start: 1.76,
      sweep: 0.24,
      strokeWidth: 0.052,
      color: Colors.white.withValues(alpha: selected ? 0.18 : 0.15),
      blur: 0.030,
    );
    drawInnerWall(
      radiusScale: 0.818,
      start: 0.04,
      sweep: 0.24,
      strokeWidth: 0.058,
      color: const Color(
        0xFF8E959C,
      ).withValues(alpha: selected ? 0.058 : 0.050),
      blur: 0.040,
    );

    final topDepth = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.070)
      ..color = const Color(
        0xFF8F969E,
      ).withValues(alpha: selected ? 0.088 : 0.078)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceTopDepth(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.765),
      ),
      math.pi * 1.08,
      math.pi * 0.62,
      false,
      topDepth,
    );

    final lowerInternalDepth = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.058)
      ..color = const Color(
        0xFF8F969D,
      ).withValues(alpha: selected ? 0.054 : 0.047)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLowerInternalDepth(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.745),
      ),
      math.pi * 0.10,
      math.pi * 0.78,
      false,
      lowerInternalDepth,
    );

    final lowerInternalSheen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.052)
      ..color = Colors.white.withValues(alpha: selected ? 0.28 : 0.23)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLowerInternalSheen(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.840),
      ),
      math.pi * 0.20,
      math.pi * 0.48,
      false,
      lowerInternalSheen,
    );

    final leftWall = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.052)
      ..color = const Color(0xFF9DA3AA).withValues(alpha: 0.040)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLeftWall(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.805),
      ),
      math.pi * 0.76,
      math.pi * 0.46,
      false,
      leftWall,
    );

    final lowerShade = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.070)
      ..color = Colors.black.withValues(alpha: selected ? 0.014 : 0.012)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.faceLowerShade(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.80),
      ),
      math.pi * 0.20,
      math.pi * 0.58,
      false,
      lowerShade,
    );
  }

  @override
  bool shouldRepaint(covariant _V3GlassFacePainter oldDelegate) {
    return oldDelegate.tone != tone ||
        oldDelegate.selected != selected ||
        oldDelegate.tokens != tokens;
  }
}

class _V3GlassRimPainter extends CustomPainter {
  const _V3GlassRimPainter({
    required this.tone,
    required this.selected,
    required this.selectedRingColor,
    required this.tokens,
  });

  final V3GlassTone tone;
  final bool selected;
  final Color selectedRingColor;
  final HuahuoV3ThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = shortest / 2;
    final rim = V3GlassSpec.rimFor(tone, tokens: tokens);
    final warm = tone == V3GlassTone.warm;
    final accentRim = selected ? selectedRingColor : rim;
    final sweepTint = Color.lerp(rim, accentRim, selected ? 0.42 : 0.0)!;

    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(
        radius * (selected ? 0.011 : 0.012),
      )
      ..shader = SweepGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: 0.62),
          sweepTint.withValues(alpha: selected ? 0.18 : (warm ? 0.34 : 0.22)),
          Colors.white.withValues(alpha: 0.52),
          const Color(
            0xFFCDEEFF,
          ).withValues(alpha: selected ? 0.14 : (warm ? 0.12 : 0.19)),
          Colors.white.withValues(alpha: 0.60),
        ],
        stops: const <double>[0.0, 0.22, 0.48, 0.72, 1.0],
        transform: const GradientRotation(math.pi * 1.07),
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius * V3GlassSpec.edgeRadius(0.960), sweep);

    final outerHairline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(
        radius * (selected ? 0.007 : (warm ? 0.0095 : 0.008)),
      )
      ..color = accentRim.withValues(
        alpha: selected ? 0.30 : (warm ? 0.52 : 0.24),
      );
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(selected ? 0.994 : 0.985),
      outerHairline,
    );

    if (selected) {
      final selectedSoftEdge = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.024)
        ..color = selectedRingColor.withValues(alpha: 0.058)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3Blur.rimSelectedSoftEdge(radius),
        );
      canvas.drawCircle(
        center,
        radius * V3GlassSpec.edgeRadius(0.982),
        selectedSoftEdge,
      );

      final selectedArc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.010)
        ..color = selectedRingColor.withValues(alpha: 0.30)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3Blur.rimSelectedArc(radius),
        );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(0.994),
        ),
        math.pi * 1.06,
        math.pi * 0.46,
        false,
        selectedArc,
      );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(0.990),
        ),
        math.pi * 0.38,
        math.pi * 0.28,
        false,
        selectedArc
          ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.008)
          ..color = selectedRingColor.withValues(alpha: 0.38),
      );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(0.986),
        ),
        math.pi * 0.64,
        math.pi * 0.11,
        false,
        selectedArc
          ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.0055)
          ..color = selectedRingColor.withValues(alpha: 0.22),
      );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(0.996),
        ),
        math.pi * 1.69,
        math.pi * 0.15,
        false,
        selectedArc
          ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.006)
          ..color = selectedRingColor.withValues(alpha: 0.20),
      );

      final selectedTopWash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.014)
        ..color = Colors.white.withValues(alpha: 0.52)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3Blur.rimSelectedTopWash(radius),
        );
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(0.998),
        ),
        math.pi * 1.07,
        math.pi * 0.44,
        false,
        selectedTopWash,
      );
    }

    void drawEdgeReflection({
      required double radiusScale,
      required double start,
      required double sweep,
      required double strokeWidth,
      required Color color,
      required double blur,
    }) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * strokeWidth)
        ..color = color;
      if (blur > 0) {
        paint.maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3GlassSpec.edgeBlur(radius * blur),
        );
      }
      canvas.drawArc(
        Rect.fromCircle(
          center: center,
          radius: radius * V3GlassSpec.edgeRadius(radiusScale),
        ),
        math.pi * start,
        math.pi * sweep,
        false,
        paint,
      );
    }

    drawEdgeReflection(
      radiusScale: 0.978,
      start: 1.075,
      sweep: 0.34,
      strokeWidth: 0.021,
      color: Colors.white.withValues(alpha: selected ? 0.46 : 0.40),
      blur: 0.010,
    );
    drawEdgeReflection(
      radiusScale: 0.995,
      start: 1.155,
      sweep: 0.20,
      strokeWidth: 0.0055,
      color: Colors.white.withValues(alpha: selected ? 0.58 : 0.52),
      blur: 0.004,
    );
    drawEdgeReflection(
      radiusScale: 0.982,
      start: 1.735,
      sweep: 0.20,
      strokeWidth: 0.013,
      color: const Color(0xFFE8F8FF).withValues(alpha: selected ? 0.26 : 0.32),
      blur: 0.006,
    );
    drawEdgeReflection(
      radiusScale: 0.952,
      start: 0.32,
      sweep: 0.38,
      strokeWidth: 0.020,
      color: Colors.white.withValues(alpha: selected ? 0.29 : 0.26),
      blur: 0.015,
    );
    drawEdgeReflection(
      radiusScale: 0.973,
      start: selected ? 0.81 : 0.84,
      sweep: selected ? 0.18 : 0.16,
      strokeWidth: 0.007,
      color: (selected ? selectedRingColor : rim).withValues(
        alpha: selected ? 0.22 : 0.13,
      ),
      blur: 0.004,
    );
    drawEdgeReflection(
      radiusScale: 0.996,
      start: 1.69,
      sweep: 0.085,
      strokeWidth: 0.0055,
      color: Colors.white.withValues(alpha: selected ? 0.54 : 0.47),
      blur: 0.003,
    );
    drawEdgeReflection(
      radiusScale: 0.988,
      start: 1.82,
      sweep: 0.10,
      strokeWidth: 0.008,
      color: const Color(0xFFEAF8FF).withValues(alpha: selected ? 0.24 : 0.29),
      blur: 0.006,
    );
    drawEdgeReflection(
      radiusScale: 0.966,
      start: 0.97,
      sweep: 0.13,
      strokeWidth: 0.010,
      color: const Color(
        0xFF90979E,
      ).withValues(alpha: selected ? 0.040 : 0.034),
      blur: 0.014,
    );
    drawEdgeReflection(
      radiusScale: 0.986,
      start: 0.02,
      sweep: 0.10,
      strokeWidth: 0.0065,
      color: const Color(0xFFCDEEFF).withValues(alpha: selected ? 0.18 : 0.26),
      blur: 0.006,
    );

    void drawEdgeCurve({
      required List<Offset> points,
      required double strokeWidth,
      required Color color,
      required double blur,
    }) {
      if (points.length < 3 || points.length.isEven) return;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i += 2) {
        path.quadraticBezierTo(
          points[i].dx,
          points[i].dy,
          points[i + 1].dx,
          points[i + 1].dy,
        );
      }
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = V3GlassSpec.edgeStroke(radius * strokeWidth)
        ..color = color;
      if (blur > 0) {
        paint.maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3GlassSpec.edgeBlur(radius * blur),
        );
      }
      canvas.drawPath(path, paint);
    }

    drawEdgeCurve(
      points: <Offset>[
        center + Offset(-radius * 0.82, -radius * 0.18),
        center + Offset(-radius * 0.88, -radius * 0.46),
        center + Offset(-radius * 0.57, -radius * 0.70),
        center + Offset(-radius * 0.36, -radius * 0.84),
        center + Offset(-radius * 0.03, -radius * 0.82),
      ],
      strokeWidth: 0.012,
      color: Colors.white.withValues(alpha: selected ? 0.54 : 0.46),
      blur: 0.007,
    );
    drawEdgeCurve(
      points: <Offset>[
        center + Offset(radius * 0.34, -radius * 0.82),
        center + Offset(radius * 0.62, -radius * 0.70),
        center + Offset(radius * 0.75, -radius * 0.44),
      ],
      strokeWidth: 0.010,
      color: Colors.white.withValues(alpha: selected ? 0.40 : 0.34),
      blur: 0.009,
    );
    drawEdgeCurve(
      points: <Offset>[
        center + Offset(-radius * 0.70, radius * 0.54),
        center + Offset(-radius * 0.38, radius * 0.82),
        center + Offset(radius * 0.04, radius * 0.84),
      ],
      strokeWidth: 0.016,
      color: Colors.black.withValues(alpha: 0.024),
      blur: 0.014,
    );
    drawEdgeCurve(
      points: <Offset>[
        center + Offset(radius * 0.84, -radius * 0.40),
        center + Offset(radius * 0.94, -radius * 0.14),
        center + Offset(radius * 0.84, radius * 0.18),
      ],
      strokeWidth: 0.007,
      color: Colors.white.withValues(alpha: selected ? 0.34 : 0.29),
      blur: 0.006,
    );
    drawEdgeCurve(
      points: <Offset>[
        center + Offset(radius * 0.72, -radius * 0.34),
        center + Offset(radius * 0.82, -radius * 0.04),
        center + Offset(radius * 0.68, radius * 0.23),
      ],
      strokeWidth: 0.014,
      color: const Color(0xFF8D949B).withValues(alpha: 0.030),
      blur: 0.020,
    );
    drawEdgeCurve(
      points: <Offset>[
        center + Offset(-radius * 0.35, -radius * 0.90),
        center + Offset(-radius * 0.06, -radius * 0.94),
        center + Offset(radius * 0.18, -radius * 0.83),
      ],
      strokeWidth: 0.006,
      color: Colors.white.withValues(alpha: selected ? 0.45 : 0.38),
      blur: 0.004,
    );

    final innerWhite = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.005)
      ..color = Colors.white.withValues(alpha: 0.38);
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(0.890),
      innerWhite,
    );

    final innerTint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.0045)
      ..color = (selected ? selectedRingColor : rim).withValues(
        alpha: selected ? 0.065 : (warm ? 0.12 : 0.090),
      );
    canvas.drawCircle(
      center,
      radius * V3GlassSpec.edgeRadius(0.842),
      innerTint,
    );

    final topSpecular = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.037)
      ..color = Colors.white.withValues(alpha: selected ? 0.82 : 0.70)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.rimTopSpecular(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.925),
      ),
      math.pi * 1.08,
      math.pi * 0.62,
      false,
      topSpecular,
    );

    final glint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.018)
      ..color = (selected ? selectedRingColor : const Color(0xFFBDEBFF))
          .withValues(alpha: selected ? 0.28 : (warm ? 0.30 : 0.34))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.rimGlint(radius));
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.905),
      ),
      selected || warm ? math.pi * 0.92 : math.pi * 1.76,
      math.pi * 0.34,
      false,
      glint,
    );

    final lowerCatch = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.024)
      ..color = Colors.black.withValues(alpha: selected ? 0.014 : 0.012)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.rimLowerCatch(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.875),
      ),
      math.pi * 0.18,
      math.pi * 0.44,
      false,
      lowerCatch,
    );

    final lowerBrightLip = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = V3GlassSpec.edgeStroke(radius * 0.018)
      ..color = Colors.white.withValues(alpha: selected ? 0.40 : 0.34)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        V3Blur.rimLowerBrightLip(radius),
      );
    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius * V3GlassSpec.edgeRadius(0.930),
      ),
      math.pi * 0.24,
      math.pi * 0.42,
      false,
      lowerBrightLip,
    );
  }

  @override
  bool shouldRepaint(covariant _V3GlassRimPainter oldDelegate) {
    return oldDelegate.tone != tone ||
        oldDelegate.selected != selected ||
        oldDelegate.selectedRingColor != selectedRingColor ||
        oldDelegate.tokens != tokens;
  }
}

class _V3GlassSurfaceScope extends InheritedWidget {
  const _V3GlassSurfaceScope({required super.child});

  @override
  bool updateShouldNotify(_V3GlassSurfaceScope oldWidget) => false;
}

void _debugAssertNoInteractiveGlassSurfaceAncestor(
  BuildContext context,
  Type controlType,
) {
  assert(() {
    final surface = context
        .dependOnInheritedWidgetOfExactType<_V3GlassSurfaceScope>();
    if (surface != null) {
      throw FlutterError(
        '$controlType cannot be nested inside V3LiquidGlassSurface. '
        'Keep interactive glass controls outside decorative glass surfaces.',
      );
    }
    return true;
  }());
}
