import 'package:flutter/material.dart';

import 'v3_liquid_glass.dart';

class V3ChatMark extends StatelessWidget {
  const V3ChatMark({this.size = 44, this.showSurface = true, super.key});

  final double size;
  final bool showSurface;

  @override
  Widget build(BuildContext context) {
    final safeSize = size.isFinite && size > 0 ? size : 44.0;
    final inset = (safeSize * .11).clamp(2.0, 7.0);
    final mark = Padding(
      padding: EdgeInsets.all(inset),
      child: Image.asset(
        'assets/images/chat_firework_mark.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      ),
    );
    return Semantics(
      image: true,
      label: 'Infinite Spark AI',
      child: SizedBox.square(
        dimension: safeSize,
        child: showSurface
            ? V3LiquidGlassSurface(borderRadius: safeSize / 2, child: mark)
            : mark,
      ),
    );
  }
}
