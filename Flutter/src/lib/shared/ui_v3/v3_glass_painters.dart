import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/huahuo_v3_theme.dart';
import 'v3_glass_blur_tokens.dart';

final class V3FloatingDockRefractionPainter extends CustomPainter {
  const V3FloatingDockRefractionPainter({
    required this.borderRadius,
    required this.selection,
    required this.tokens,
  });

  final double borderRadius;
  final bool selection;
  final HuahuoV3ThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(borderRadius, size.height / 2)),
    );
    canvas.save();
    canvas.clipRRect(shape);

    final upperGlint = Path()
      ..moveTo(size.width * .075, 2.6)
      ..cubicTo(
        size.width * .17,
        .3,
        size.width * .34,
        .2,
        size.width * (selection ? .82 : .46),
        2.0,
      );
    canvas.drawPath(
      upperGlint,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = selection ? 1.05 : 1.25
        ..color = Colors.white.withValues(alpha: selection ? .80 : .74)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.dockUpperGlint),
    );

    final lowerCaustic = Path()
      ..moveTo(size.width * (selection ? .20 : .54), size.height - 2.4)
      ..cubicTo(
        size.width * .66,
        size.height + .2,
        size.width * .82,
        size.height + .1,
        size.width * .93,
        size.height - 3.0,
      );
    canvas.drawPath(
      lowerCaustic,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = selection ? 1.15 : 1.45
        ..color = tokens.coolGlass.rim.withValues(alpha: selection ? .52 : .48)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3Blur.dockLowerCaustic,
        ),
    );

    final leftCompression = Path()
      ..moveTo(2.8, size.height * .30)
      ..cubicTo(
        .5,
        size.height * .44,
        .8,
        size.height * .68,
        3.1,
        size.height * .80,
      );
    canvas.drawPath(
      leftCompression,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.0
        ..color = tokens.muted.withValues(alpha: .15)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          V3Blur.dockCompression,
        ),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .84, size.height * .78),
        width: size.width * (selection ? .26 : .16),
        height: size.height * .20,
      ),
      Paint()
        ..color = tokens.coolGlass.selectedFallback.withValues(
          alpha: selection ? .18 : .14,
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, V3Blur.dockGlow),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant V3FloatingDockRefractionPainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.selection != selection ||
        oldDelegate.tokens != tokens;
  }
}
