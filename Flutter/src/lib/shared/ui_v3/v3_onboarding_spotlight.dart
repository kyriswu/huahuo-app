import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/huahuo_v3_theme.dart';

class V3OnboardingSpotlight extends StatefulWidget {
  const V3OnboardingSpotlight({
    required this.visible,
    required this.step,
    required this.title,
    required this.message,
    required this.onSkip,
    required this.child,
    this.revealTarget = false,
    super.key,
  });

  final bool visible;
  final int step;
  final String title;
  final String message;
  final VoidCallback onSkip;
  final Widget child;
  final bool revealTarget;

  @override
  State<V3OnboardingSpotlight> createState() => _V3OnboardingSpotlightState();
}

class _V3OnboardingSpotlightState extends State<V3OnboardingSpotlight> {
  final _portal = OverlayPortalController();
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final visible =
        widget.visible &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    if (!_scheduled && visible != _portal.isShowing) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted) return;
        final show =
            widget.visible &&
            (ModalRoute.isCurrentOf(context) ?? true) &&
            TickerMode.valuesOf(context).enabled;
        if (show) {
          if (widget.revealTarget) {
            Scrollable.ensureVisible(context, alignment: 0.5);
          }
          _portal.show();
        } else {
          _portal.hide();
        }
      });
    }
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (overlayContext, info) {
        if (!visible) return const SizedBox.shrink();
        final media = MediaQuery.of(overlayContext);
        final bounds = Offset.zero & info.overlaySize;
        final viewport = Rect.fromLTRB(
          math.max(media.padding.left, media.viewInsets.left),
          media.padding.top,
          bounds.right - math.max(media.padding.right, media.viewInsets.right),
          bounds.bottom -
              math.max(media.padding.bottom, media.viewInsets.bottom),
        );
        final target = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        if (viewport.width <= 32 ||
            target.isEmpty ||
            !viewport.contains(target.center) ||
            target.left < viewport.left ||
            target.right > viewport.right ||
            target.top < viewport.top ||
            target.bottom > viewport.bottom) {
          return const SizedBox.shrink();
        }
        final hole = target.inflate(6).intersect(bounds);
        final above = math.max(0.0, hole.top - viewport.top - 24);
        final below = math.max(0.0, viewport.bottom - hole.bottom - 24);
        final placeAbove = above >= below;
        final available = placeAbove ? above : below;
        if (available < 80) return const SizedBox.shrink();
        final width = math.min(360.0, viewport.width - 32);
        final left = (target.center.dx - width / 2).clamp(
          viewport.left + 16,
          viewport.right - width - 16,
        );
        final colors = HuahuoV3Theme.tokensOf(overlayContext);
        return Positioned.fill(
          child: Stack(
            key: ValueKey('startup-chat-spotlight-${widget.step}'),
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: media.disableAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    builder: (_, opacity, __) => CustomPaint(
                      painter: _SpotlightPainter(hole: hole, opacity: opacity),
                    ),
                  ),
                ),
              ),
              for (final barrier in [
                Rect.fromLTRB(0, 0, bounds.right, hole.top),
                Rect.fromLTRB(0, hole.bottom, bounds.right, bounds.bottom),
                Rect.fromLTRB(0, hole.top, hole.left, hole.bottom),
                Rect.fromLTRB(hole.right, hole.top, bounds.right, hole.bottom),
              ])
                Positioned.fromRect(
                  rect: barrier,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: () {},
                  ),
                ),
              Positioned(
                left: left,
                width: width,
                bottom: placeAbove ? bounds.bottom - hole.top + 12 : null,
                top: placeAbove ? null : hole.bottom + 12,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: available),
                  child: Material(
                    color: colors.surface,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Semantics(
                        container: true,
                        liveRegion: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '新手引导 4 / 4 · ${widget.step} / 2',
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.title,
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 19,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.message,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  placeAbove
                                      ? Icons.south_rounded
                                      : Icons.north_rounded,
                                  size: 18,
                                  color: colors.accent,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '点击高亮处试试',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.accent,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  key: const ValueKey(
                                    'startup-chat-guide-skip',
                                  ),
                                  onPressed: widget.onSkip,
                                  child: const Text('跳过引导'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({required this.hole, required this.opacity});

  final Rect hole;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final cutout = RRect.fromRectAndRadius(hole, const Radius.circular(18));
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(cutout);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: .64 * opacity),
    );
    canvas.drawRRect(
      cutout,
      Paint()
        ..color = Colors.white.withValues(alpha: .95 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter oldDelegate) =>
      oldDelegate.hole != hole || oldDelegate.opacity != opacity;
}
