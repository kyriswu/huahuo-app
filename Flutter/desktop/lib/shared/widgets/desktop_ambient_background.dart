import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

class DesktopAmbientBackground extends StatelessWidget {
  const DesktopAmbientBackground({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: Colors.transparent, child: child);
  }
}

class DesktopGlassSurface extends StatelessWidget {
  const DesktopGlassSurface({
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(HuahuoRadii.panel),
    ),
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.16 : 0.07),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}
