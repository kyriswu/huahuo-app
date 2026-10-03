// ignore_for_file: prefer_const_declarations
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:go_router/go_router.dart';

import '../../core/performance/runtime_activity_metrics.dart';
import '../navigation/safe_navigation.dart';
import '../theme/huahuo_v3_theme.dart';
import 'v3_liquid_glass.dart';

void showV3Snack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = V3FeedbackTimingTokens.standardSnack,
}) {
  final snackTheme = Theme.of(context).snackBarTheme;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: snackTheme.contentTextStyle),
        backgroundColor: snackTheme.backgroundColor,
        elevation: snackTheme.elevation,
        shape: snackTheme.shape,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(
                label: actionLabel,
                textColor: snackTheme.contentTextStyle?.color,
                onPressed: onAction,
              ),
        margin: const EdgeInsets.fromLTRB(
          HuahuoSpacing.md,
          0,
          HuahuoSpacing.md,
          HuahuoSpacing.sm,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: HuahuoSpacing.md,
          vertical: HuahuoSpacing.sm,
        ),
      ),
    );
}

abstract final class V3ChatComposerMetrics {
  static const double maximumWidth = 370;
  static const double height = 54;
  static const double expandedHeight = 92;
  static const int maxVisibleLines = 3;
  static const double actionSize = 40;
  static const double actionIconSize = 20;
  static const double inputHeight = 42;
  static const double gap = 8;
  static const double horizontalInset = 7;
  static const double radius = 27;
}

class V3ChatComposerShell extends StatelessWidget {
  const V3ChatComposerShell({
    required this.child,
    this.surfaceKey,
    this.embedded = false,
    super.key,
  });

  final Widget child;
  final Key? surfaceKey;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ConstrainedBox(
      key: surfaceKey,
      constraints: const BoxConstraints(
        minHeight: V3ChatComposerMetrics.height,
        maxHeight: V3ChatComposerMetrics.expandedHeight,
      ),
      child: Material(
        color: embedded
            ? Colors.transparent
            : colors.surface.withValues(alpha: .98),
        elevation: embedded ? 0 : 4,
        shadowColor: colors.ink.withValues(alpha: .11),
        shape: embedded
            ? null
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  V3ChatComposerMetrics.radius,
                ),
                side: BorderSide(color: colors.line),
              ),
        clipBehavior: embedded ? Clip.none : Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(V3ChatComposerMetrics.horizontalInset),
          child: child,
        ),
      ),
    );
  }
}

class V3AssistantResponseAction extends StatelessWidget {
  const V3AssistantResponseAction({
    required this.width,
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final double width;
  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    const actionColor = Color(0xff2e6ec7);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: width,
            height: 48,
            child: TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size(width, 48),
                foregroundColor: actionColor,
                disabledForegroundColor: actionColor.withValues(alpha: .45),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: actionColor,
                      ),
                    )
                  else
                    Icon(icon, size: 16),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 18 / 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class V3StreamingAssistantReplyText extends StatelessWidget {
  const V3StreamingAssistantReplyText({
    required this.source,
    this.bodyStyle,
    super.key,
  });

  final String source;
  final TextStyle? bodyStyle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Text(
      source,
      style: TextStyle(
        fontSize: 15,
        height: 1.52,
        fontWeight: FontWeight.w400,
        color: colors.text,
      ).merge(bodyStyle),
    );
  }
}

enum V3BackBehavior {
  popThenFallback,

  /// Retained for existing callers. A pushed parent is still always restored.
  fallbackOnly,
}

class V3PageTopBar extends StatelessWidget {
  const V3PageTopBar({
    this.title,
    this.actions = const <Widget>[],
    this.showBack = true,
    this.fallbackRoute = '/v3/feed',
    this.backBehavior = V3BackBehavior.popThenFallback,
    this.onBack,
    this.height = 56,
    super.key,
  });

  final String? title;
  final List<Widget> actions;
  final bool showBack;
  final String fallbackRoute;
  final V3BackBehavior backBehavior;
  final VoidCallback? onBack;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: NavigationToolbar(
        centerMiddle: true,
        middleSpacing: HuahuoSpacing.xs,
        leading: showBack
            ? SizedBox(
                width: 56,
                child: Center(
                  child: onBack == null
                      ? V3NavigationBackButton(
                          fallbackRoute: fallbackRoute,
                          behavior: backBehavior,
                        )
                      : V3NavigationBackButton(onPressed: onBack),
                ),
              )
            : null,
        middle: title == null
            ? null
            : _V3AdaptiveNavigationTitle(
                title: title!,
                style: HuahuoV3Theme.navigationTitle.copyWith(
                  color: scheme.onSurface,
                ),
              ),
        trailing: actions.isEmpty
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in actions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _V3ToolbarAction(child: action),
                    ),
                ],
              ),
      ),
    );
  }
}

class V3KeyboardDismissOnUpwardScroll extends StatelessWidget {
  const V3KeyboardDismissOnUpwardScroll({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis != Axis.vertical ||
            notification.direction != ScrollDirection.reverse ||
            MediaQuery.viewInsetsOf(context).bottom <= 0) {
          return false;
        }
        FocusManager.instance.primaryFocus?.unfocus();
        return false;
      },
      child: child,
    );
  }
}

class V3InteractiveScrollbar extends StatelessWidget {
  const V3InteractiveScrollbar({
    required this.controller,
    required this.child,
    super.key,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: controller,
    thumbVisibility: true,
    interactive: true,
    thickness: 4,
    radius: const Radius.circular(2),
    child: child,
  );
}

class V3PageScaffold extends StatelessWidget {
  const V3PageScaffold({
    required this.title,
    this.children = const <Widget>[],
    this.slivers,
    this.subtitle,
    this.trailing,
    this.inlineTitleLeading,
    this.centerTitle = false,
    this.inlineTitle = false,
    this.showBack = true,
    this.pinnedContent,
    this.bottomBar,
    this.bottomBarPadding = const EdgeInsets.fromLTRB(22, 6, 22, 8),
    this.bottomBarOverlaysBody = false,
    this.bottomBarUsesSafeArea = true,
    this.fallbackRoute = '/v3',
    this.backBehavior = V3BackBehavior.popThenFallback,
    this.onBack,
    this.onTitleTap,
    this.backOffset = Offset.zero,
    this.padding = const EdgeInsets.fromLTRB(
      HuahuoSpacing.pageWide,
      10,
      HuahuoSpacing.pageWide,
      28,
    ),
    this.scrollController,
    this.onRefresh,
    this.showScrollbar = false,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.topBarHeight = 52,
    this.topBarLeadingWidth = 56,
    this.titleStyle,
    this.titleSubtitleGap = 12,
    this.titleContentGap = 24,
    this.showGraphBackground = false,
    super.key,
  }) : assert(!showScrollbar || scrollController != null);

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget>? slivers;
  final Widget? trailing;
  final Widget? inlineTitleLeading;
  final bool centerTitle;
  final bool inlineTitle;
  final bool showBack;
  final Widget? pinnedContent;
  final Widget? bottomBar;
  final EdgeInsetsGeometry bottomBarPadding;
  final bool bottomBarOverlaysBody;
  final bool bottomBarUsesSafeArea;
  final String fallbackRoute;
  final V3BackBehavior backBehavior;
  final VoidCallback? onBack;
  final VoidCallback? onTitleTap;
  final Offset backOffset;
  final EdgeInsetsGeometry padding;
  final ScrollController? scrollController;
  final Future<void> Function()? onRefresh;
  final bool showScrollbar;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final double topBarHeight;
  final double topBarLeadingWidth;
  final TextStyle? titleStyle;
  final double titleSubtitleGap;
  final double titleContentGap;
  final bool showGraphBackground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = HuahuoV3Theme.tokensOf(context);
    final resolvedPadding = padding.resolve(Directionality.of(context));
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final listPadding = resolvedPadding.copyWith(
      bottom:
          resolvedPadding.bottom +
          (bottomBar != null && bottomBarOverlaysBody ? 92 + keyboardInset : 0),
    );
    Widget buildBackAction() => V3NavigationBackButton(
      fallbackRoute: fallbackRoute,
      behavior: backBehavior,
      onPressed: onBack,
    );

    Widget buildBottomBar() {
      final bar = Padding(padding: bottomBarPadding, child: bottomBar!);
      return AnimatedPadding(
        duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: bottomBarUsesSafeArea ? SafeArea(top: false, child: bar) : bar,
      );
    }

    Widget titleTapTarget(Widget child) => onTitleTap == null
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTitleTap,
            child: child,
          );

    final contentHeader = <Widget>[
      if (!centerTitle && !inlineTitle) ...[
        titleTapTarget(
          Text(
            title,
            style:
                titleStyle?.copyWith(color: scheme.onSurface) ??
                HuahuoV3Theme.h1.copyWith(color: scheme.onSurface),
          ),
        ),
        if (subtitle != null) ...[
          SizedBox(height: titleSubtitleGap),
          Text(
            subtitle!,
            style: HuahuoV3Theme.body.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
        SizedBox(height: titleContentGap),
      ],
      if (inlineTitle && subtitle != null) ...[
        Text(
          subtitle!,
          style: HuahuoV3Theme.body.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 16),
      ],
    ];

    Widget buildScrollableContent() {
      final contentSlivers = slivers;
      final Widget scrollable;
      if (contentSlivers == null) {
        scrollable = ListView(
          key: PageStorageKey<String>('v3-page-scroll-$title'),
          controller: scrollController,
          physics: onRefresh == null
              ? null
              : const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: keyboardDismissBehavior,
          padding: listPadding,
          children: <Widget>[...contentHeader, ...children],
        );
      } else {
        scrollable = CustomScrollView(
          key: PageStorageKey<String>('v3-page-scroll-$title'),
          controller: scrollController,
          physics: onRefresh == null
              ? null
              : const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: keyboardDismissBehavior,
          slivers: <Widget>[
            SliverPadding(
              padding: listPadding,
              sliver: SliverMainAxisGroup(
                slivers: <Widget>[
                  for (final child in contentHeader)
                    SliverToBoxAdapter(child: child),
                  ...contentSlivers,
                ],
              ),
            ),
          ],
        );
      }
      final refresh = onRefresh;
      final refreshable = refresh == null
          ? scrollable
          : RefreshIndicator(onRefresh: refresh, child: scrollable);
      if (!showScrollbar) return refreshable;
      return V3InteractiveScrollbar(
        controller: scrollController!,
        child: refreshable,
      );
    }

    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      resizeToAvoidBottomInset: false,
      bottomNavigationBar: bottomBar == null || bottomBarOverlaysBody
          ? null
          : buildBottomBar(),
      body: Stack(
        children: [
          if (showGraphBackground)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _V3PageNetworkBackdropPainter(isDark: isDark),
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: topBarHeight,
                  child: centerTitle
                      ? Row(
                          children: [
                            SizedBox(
                              width: topBarLeadingWidth,
                              child: showBack
                                  ? Center(child: buildBackAction())
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: titleTapTarget(
                                _V3AdaptiveNavigationTitle(
                                  title: title,
                                  style: HuahuoV3Theme.navigationTitle.copyWith(
                                    color: scheme.onSurface,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: topBarLeadingWidth,
                              child: trailing == null
                                  ? const SizedBox.shrink()
                                  : Center(
                                      child: _V3ToolbarAction(child: trailing!),
                                    ),
                            ),
                          ],
                        )
                      : inlineTitle
                      ? Row(
                          children: [
                            SizedBox(
                              width: topBarLeadingWidth,
                              child: showBack
                                  ? Center(child: buildBackAction())
                                  : const SizedBox.shrink(),
                            ),
                            if (inlineTitleLeading != null) ...[
                              SizedBox.square(
                                dimension: 34,
                                child: inlineTitleLeading!,
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: titleTapTarget(
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HuahuoV3Theme.navigationTitle
                                        .copyWith(color: scheme.onSurface),
                                  ),
                                ),
                              ),
                            ),
                            if (trailing != null)
                              _V3ToolbarAction(child: trailing!),
                          ],
                        )
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            if (showBack)
                              Positioned(
                                left: 10 + backOffset.dx,
                                top: 4,
                                bottom: 4,
                                child: Transform.translate(
                                  offset: Offset(0, backOffset.dy),
                                  child: buildBackAction(),
                                ),
                              ),
                            if (trailing != null)
                              Positioned(
                                right: 16,
                                child: _V3ToolbarAction(child: trailing!),
                              ),
                          ],
                        ),
                ),
                if (pinnedContent != null) pinnedContent!,
                Expanded(child: buildScrollableContent()),
              ],
            ),
          ),
          if (bottomBar != null && bottomBarOverlaysBody)
            Positioned(left: 0, right: 0, bottom: 0, child: buildBottomBar()),
        ],
      ),
    );
    final router = GoRouter.maybeOf(context);
    if (!showBack || router == null || onBack != null) return scaffold;
    final canPop = canReturnToPreviousRoute(context);
    return PopScope<Object?>(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || canPop) return;
        router.go(fallbackRoute);
      },
      child: scaffold,
    );
  }
}

class _V3AdaptiveNavigationTitle extends StatelessWidget {
  const _V3AdaptiveNavigationTitle({required this.title, required this.style});

  final String title;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(
      title,
      maxLines: 1,
      softWrap: false,
      textAlign: TextAlign.center,
      style: style,
    ),
  );
}

class _V3PageNetworkBackdropPainter extends CustomPainter {
  const _V3PageNetworkBackdropPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final clusters = <_BackdropCluster>[
      const _BackdropCluster(
        anchor: Offset(.52, .11),
        scale: .78,
        points: [
          Offset(-58, 16),
          Offset(-34, -38),
          Offset(20, -22),
          Offset(54, 20),
          Offset(-8, 34),
          Offset(36, 64),
        ],
      ),
      const _BackdropCluster(
        anchor: Offset(.76, .26),
        scale: 1.00,
        points: [
          Offset(-66, -8),
          Offset(-24, -44),
          Offset(24, -18),
          Offset(62, 30),
          Offset(10, 46),
          Offset(-38, 24),
          Offset(54, -52),
        ],
      ),
      const _BackdropCluster(
        anchor: Offset(.09, .57),
        scale: .90,
        points: [
          Offset(-40, -44),
          Offset(2, -10),
          Offset(44, -26),
          Offset(56, 34),
          Offset(8, 58),
          Offset(-36, 22),
        ],
      ),
      const _BackdropCluster(
        anchor: Offset(.78, .78),
        scale: 1.08,
        points: [
          Offset(-64, -42),
          Offset(-14, -66),
          Offset(38, -36),
          Offset(72, 12),
          Offset(30, 56),
          Offset(-30, 40),
          Offset(-70, 4),
        ],
      ),
      const _BackdropCluster(
        anchor: Offset(.39, .86),
        scale: .72,
        points: [
          Offset(-54, -20),
          Offset(-12, -56),
          Offset(42, -34),
          Offset(58, 22),
          Offset(4, 48),
          Offset(-44, 28),
        ],
      ),
    ];

    for (var i = 0; i < clusters.length; i++) {
      _paintCluster(canvas, size, clusters[i], i);
    }
  }

  void _paintCluster(
    Canvas canvas,
    Size size,
    _BackdropCluster cluster,
    int clusterIndex,
  ) {
    final origin = Offset(
      size.width * cluster.anchor.dx,
      size.height * cluster.anchor.dy,
    );
    final points = <Offset>[
      for (final point in cluster.points) origin + point * cluster.scale,
    ];

    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .78
      ..color = (isDark ? const Color(0xFF6A737A) : const Color(0xFFBFC3C7))
          .withValues(alpha: isDark ? .18 : .095);
    final nearEdgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .86
      ..color = (isDark ? const Color(0xFF6A737A) : const Color(0xFFBFC3C7))
          .withValues(alpha: isDark ? .12 : .060);

    for (var i = 0; i < points.length; i++) {
      final next = points[(i + 1) % points.length];
      canvas.drawLine(points[i], next, edgePaint);
      if (i.isEven && i + 2 < points.length) {
        canvas.drawLine(points[i], points[i + 2], nearEdgePaint);
      }
      if (i == 1 || i == 4) {
        canvas.drawLine(
          points[i],
          points[(i + 3) % points.length],
          nearEdgePaint,
        );
      }
    }

    for (var i = 0; i < points.length; i++) {
      final isAccent = (clusterIndex + i) % 7 == 0;
      final isCool = (clusterIndex + i) % 5 == 0;
      final color = isAccent
          ? HuahuoV3Theme.glassWarmRim.withValues(alpha: .22)
          : isCool
          ? const Color(0xFFB7DDF5).withValues(alpha: isDark ? .32 : .20)
          : (isDark ? const Color(0xFFB5BCC2) : const Color(0xFFC9CDD1))
                .withValues(alpha: isDark ? .28 : .18);
      final radius = isAccent || isCool ? 3.0 : 2.5;
      canvas.drawCircle(
        points[i],
        radius * cluster.scale,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _V3PageNetworkBackdropPainter oldDelegate) {
    return oldDelegate.isDark != isDark;
  }
}

class _BackdropCluster {
  const _BackdropCluster({
    required this.anchor,
    required this.scale,
    required this.points,
  });

  final Offset anchor;
  final double scale;
  final List<Offset> points;
}

class V3NavigationBackButton extends StatelessWidget {
  const V3NavigationBackButton({
    this.fallbackRoute = '/v3',
    this.behavior = V3BackBehavior.popThenFallback,
    this.onPressed,
    this.tooltip = '返回',
    this.color,
    super.key,
  });

  final String fallbackRoute;
  final V3BackBehavior behavior;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return _V3FlatIconAction(
      label: tooltip,
      icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: color),
      onPressed:
          onPressed ??
          () {
            switch (behavior) {
              case V3BackBehavior.popThenFallback:
              case V3BackBehavior.fallbackOnly:
                returnToPreviousRoute(context, fallbackRoute: fallbackRoute);
            }
          },
    );
  }
}

class V3CloseButton extends StatelessWidget {
  const V3CloseButton({
    this.onPressed,
    this.tooltip = '关闭',
    this.color,
    super.key,
  });

  final VoidCallback? onPressed;
  final String tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return _V3FlatIconAction(
      label: tooltip,
      icon: Icon(Icons.close_rounded, size: 20, color: color),
      onPressed: onPressed,
    );
  }
}

class V3DisclosureChevron extends StatelessWidget {
  const V3DisclosureChevron({
    required this.expanded,
    this.size = 20,
    this.color,
    super.key,
  });

  final bool expanded;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? .25 : 0,
    duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
    curve: Curves.easeOutCubic,
    child: Icon(Icons.chevron_right_rounded, size: size, color: color),
  );
}

class V3DisclosureTile extends StatefulWidget {
  const V3DisclosureTile({
    required this.title,
    required this.children,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.tilePadding = EdgeInsets.zero,
    this.childrenPadding = EdgeInsets.zero,
    super.key,
  });

  final Widget title;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry tilePadding;
  final EdgeInsetsGeometry childrenPadding;

  @override
  State<V3DisclosureTile> createState() => _V3DisclosureTileState();
}

class _V3DisclosureTileState extends State<V3DisclosureTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final duration = V3MotionTokens.resolve(context, V3MotionTokens.standard);
    return ExpansionTile(
      initiallyExpanded: widget.initiallyExpanded,
      tilePadding: widget.tilePadding,
      childrenPadding: widget.childrenPadding,
      expansionAnimationStyle: AnimationStyle(
        duration: duration,
        reverseDuration: duration,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutCubic,
      ),
      trailing: V3DisclosureChevron(expanded: _expanded),
      onExpansionChanged: (expanded) {
        setState(() => _expanded = expanded);
        widget.onExpansionChanged?.call(expanded);
      },
      title: widget.title,
      children: widget.children,
    );
  }
}

class _V3FlatIconAction extends StatelessWidget {
  const _V3FlatIconAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: HuahuoControlSize.iconComfortable,
          child: IconButton(tooltip: label, onPressed: onPressed, icon: icon),
        ),
      ),
    );
  }
}

class _V3ToolbarAction extends StatelessWidget {
  const _V3ToolbarAction({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final candidate = child;
    if (candidate is IconButton) {
      final label = _semanticLabelFor(candidate);
      return _V3FlatIconAction(
        key: candidate.key,
        label: label,
        onPressed: candidate.onPressed,
        icon: candidate.icon,
      );
    }
    return child;
  }

  String _semanticLabelFor(IconButton button) {
    final tooltip = button.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) return tooltip;

    final icon = button.icon;
    if (icon is Icon) {
      if (icon.icon == Icons.history || icon.icon == Icons.history_rounded) {
        return '历史';
      }
      if (icon.icon == Icons.more_horiz ||
          icon.icon == Icons.more_horiz_rounded) {
        return '我的';
      }
      if (icon.icon == Icons.notifications_none ||
          icon.icon == Icons.notifications_none_rounded) {
        return '通知';
      }
    }
    return '操作';
  }
}

enum V3CardVariant { flat, outlined, glass }

class V3Card extends StatelessWidget {
  const V3Card({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.radius,
    this.color,
    this.glass = true,
    this.variant,
    this.tone = V3GlassTone.neutral,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double? radius;
  final Color? color;
  final bool glass;
  final V3CardVariant? variant;
  final V3GlassTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final resolvedColor = color ?? colors.surface;
    final resolvedVariant =
        variant ?? (glass ? V3CardVariant.glass : V3CardVariant.outlined);
    final resolvedRadius =
        radius ??
        switch (resolvedVariant) {
          V3CardVariant.flat || V3CardVariant.outlined => HuahuoRadius.surface,
          V3CardVariant.glass => HuahuoV3Theme.cardRadius,
        };
    if (resolvedVariant != V3CardVariant.glass) {
      final outlined = resolvedVariant == V3CardVariant.outlined;
      return Material(
        color: resolvedColor,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(resolvedRadius),
          side: outlined ? BorderSide(color: colors.line) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
    }

    final borderRadius = BorderRadius.circular(resolvedRadius);
    return V3LiquidGlassSurface(
      tone: tone,
      borderRadius: resolvedRadius,
      color: color,
      child: Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: V3GlassSpec.rimFor(
            tone,
            tokens: colors,
          ).withValues(alpha: 0.13),
          highlightColor: colors.surface.withValues(alpha: 0.18),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class V3NoteSummaryCard extends StatelessWidget {
  const V3NoteSummaryCard({
    required this.title,
    required this.preview,
    required this.sourceLabel,
    required this.folderLabel,
    required this.timeLabel,
    required this.onTap,
    this.semanticLabel,
    super.key,
  });

  final String title;
  final String preview;
  final String sourceLabel;
  final String folderLabel;
  final String timeLabel;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: semanticLabel ?? title,
      child: Material(
        color: colors.surface.withValues(alpha: .72),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: colors.line.withValues(alpha: .58),
            width: .8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink.withValues(alpha: .92),
                    fontSize: 15,
                    height: 1.33,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text.withValues(alpha: .88),
                    fontSize: 13,
                    height: 1.38,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _V3NoteMetadataTag(
                      label: '来源 · $sourceLabel',
                      foreground: colors.muted,
                      background: colors.surfaceMuted,
                    ),
                    _V3NoteMetadataTag(
                      label: '文件夹 · $folderLabel',
                      foreground: colors.accent,
                      background: HuahuoV3Theme.semanticSurface(
                        colors.accent,
                        colors.surface,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  timeLabel,
                  style: TextStyle(
                    color: colors.muted.withValues(alpha: .86),
                    fontSize: 11,
                    height: 1.27,
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

class _V3NoteMetadataTag extends StatelessWidget {
  const _V3NoteMetadataTag({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        label,
        style: TextStyle(color: foreground, fontSize: 9.5, height: 1),
      ),
    ),
  );
}

class V3GroupedList extends StatelessWidget {
  const V3GroupedList({
    required this.children,
    this.dividerIndent = 52,
    this.radius = HuahuoRadius.surface,
    this.variant = V3CardVariant.outlined,
    super.key,
  });

  final List<Widget> children;
  final double dividerIndent;
  final double radius;
  final V3CardVariant variant;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      key: const ValueKey<String>('v3-grouped-list-surface'),
      glass: variant == V3CardVariant.glass,
      variant: variant,
      radius: radius,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              ExcludeSemantics(
                child: Divider(
                  key: ValueKey<String>('v3-grouped-list-divider-$index'),
                  height: 1,
                  indent: dividerIndent,
                  color: colors.line,
                ),
              ),
            children[index],
          ],
        ],
      ),
    );
  }
}

class V3GroupedListTile extends StatelessWidget {
  const V3GroupedListTile({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.minHeight = 68,
    this.contentPadding = const EdgeInsets.fromLTRB(14, 10, 10, 10),
    super.key,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double minHeight;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Padding(
              padding: contentPadding,
              child: Row(
                children: [
                  if (leading case final leading?) ...[
                    IconTheme.merge(
                      data: IconThemeData(size: 21, color: colors.ink),
                      child: leading,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          child: title,
                        ),
                        if (subtitle case final subtitle?) ...[
                          const SizedBox(height: 3),
                          DefaultTextStyle.merge(
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12.5,
                              height: 1.35,
                            ),
                            child: subtitle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing case final trailing?) ...[
                    const SizedBox(width: 8),
                    IconTheme.merge(
                      data: IconThemeData(size: 20, color: colors.muted),
                      child: trailing,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showV3GlassBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  double borderRadius = 30,
  bool showHandle = true,
  Widget? topAccent,
}) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return Future<T?>.value();
  FocusManager.instance.primaryFocus?.unfocus();
  final launcherTopViewPadding = MediaQuery.viewPaddingOf(context).top;
  final flutterView = View.of(context);
  final platformTopViewPadding =
      flutterView.viewPadding.top / flutterView.devicePixelRatio;
  final persistentTopViewPadding =
      platformTopViewPadding > launcherTopViewPadding
      ? platformTopViewPadding
      : launcherTopViewPadding;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    constraints: const BoxConstraints(maxWidth: double.infinity),
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    builder: (sheetContext) {
      final mediaQuery = MediaQuery.of(sheetContext);
      final restoredTop = persistentTopViewPadding > mediaQuery.viewPadding.top
          ? persistentTopViewPadding
          : mediaQuery.viewPadding.top;
      return MediaQuery(
        data: mediaQuery.copyWith(
          viewPadding: EdgeInsets.fromLTRB(
            mediaQuery.viewPadding.left,
            restoredTop,
            mediaQuery.viewPadding.right,
            mediaQuery.viewPadding.bottom,
          ),
        ),
        child: Builder(
          builder: (restoredContext) => V3GlassBottomSheet(
            borderRadius: borderRadius,
            showHandle: showHandle,
            topAccent: topAccent,
            child: builder(restoredContext),
          ),
        ),
      );
    },
  );
}

class V3GlassBottomSheet extends StatelessWidget {
  const V3GlassBottomSheet({
    required this.child,
    this.borderRadius = 30,
    this.showHandle = true,
    this.topAccent,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final bool showHandle;
  final Widget? topAccent;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final mediaQuery = MediaQuery.of(context);
    final compactKeyboard =
        mediaQuery.viewInsets.bottom > 0 &&
        mediaQuery.size.height -
                mediaQuery.viewInsets.bottom -
                mediaQuery.viewPadding.top <
            280;
    final effectiveShowHandle = showHandle && !compactKeyboard;
    final radius = BorderRadius.vertical(top: Radius.circular(borderRadius));
    final callerBody = child;
    final Widget boundedBody;
    if (callerBody is Expanded) {
      boundedBody = Expanded(
        key: callerBody.key,
        flex: callerBody.flex,
        child: SafeArea(top: false, bottom: false, child: callerBody.child),
      );
    } else if (callerBody is Flexible) {
      boundedBody = Flexible(
        key: callerBody.key,
        flex: callerBody.flex,
        fit: callerBody.fit,
        child: SafeArea(top: false, bottom: false, child: callerBody.child),
      );
    } else {
      boundedBody = Flexible(
        fit: FlexFit.loose,
        child: SafeArea(top: false, bottom: false, child: callerBody),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: V3GlassHomeScope(
        enabled: false,
        child: Material(
          color: colors.surface,
          elevation: HuahuoElevation.floating,
          shadowColor: colors.ink.withValues(alpha: .1),
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: colors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: ClipRRect(
            borderRadius: radius,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (topAccent case final accent?) accent,
                if (effectiveShowHandle)
                  Padding(
                    key: const ValueKey('v3-glass-bottom-sheet-drag-handle'),
                    padding: const EdgeInsets.only(top: 10, bottom: 6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.ink.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const SizedBox(width: 38, height: 4),
                    ),
                  ),
                boundedBody,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class V3GlassDialog extends StatelessWidget {
  const V3GlassDialog({
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.cancelLabel = '取消',
    this.onCancel,
    this.showCancel = true,
    super.key,
  });

  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String cancelLabel;
  final VoidCallback? onCancel;
  final bool showCancel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final mediaQuery = MediaQuery.of(context);
    final unobscuredHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.padding.vertical;
    final compactKeyboard =
        mediaQuery.viewInsets.bottom > 0 && unobscuredHeight < 280;
    final dialogInsetPadding = EdgeInsets.symmetric(
      horizontal: 28,
      vertical: compactKeyboard ? 4 : 16,
    );
    final maxHeight = unobscuredHeight - dialogInsetPadding.vertical;
    return SafeArea(
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: dialogInsetPadding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight.clamp(0.0, 640.0)),
          child: V3GlassHomeScope(
            enabled: false,
            child: Material(
              color: colors.surface,
              elevation: HuahuoElevation.floating,
              shadowColor: colors.ink.withValues(alpha: .1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compactKeyboard ? 12 : 20,
                  compactKeyboard ? 8 : 20,
                  compactKeyboard ? 12 : 20,
                  compactKeyboard ? 8 : 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: SingleChildScrollView(
                        key: const ValueKey('v3-glass-dialog-content-scroll'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: colors.ink,
                                letterSpacing: 0,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Text(
                              message,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.4,
                                fontWeight: FontWeight.w400,
                                color: colors.text,
                                letterSpacing: 0,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: compactKeyboard ? 4 : 18),
                    Row(
                      children: [
                        if (showCancel) ...[
                          Expanded(
                            child: V3OutlineButton(
                              label: cancelLabel,
                              onPressed:
                                  onCancel ?? () => Navigator.of(context).pop(),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: V3PrimaryButton(
                            label: primaryLabel,
                            onPressed: onPrimary,
                          ),
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
    );
  }
}

class V3GlassGlyph extends StatelessWidget {
  const V3GlassGlyph({
    required this.icon,
    required this.size,
    this.iconSize,
    this.iconColor,
    this.tone = V3GlassTone.neutral,
    super.key,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final Color? iconColor;
  final V3GlassTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3LiquidGlassSurface(
      tone: tone,
      borderRadius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: Icon(
            icon,
            size: iconSize ?? size * .5,
            color: iconColor ?? V3GlassSpec.iconColorFor(tone, tokens: colors),
          ),
        ),
      ),
    );
  }
}

class V3CompactActionTarget extends StatelessWidget {
  const V3CompactActionTarget({
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    required this.width,
    this.height = 48,
    super.key,
  });

  final String semanticLabel;
  final VoidCallback? onTap;
  final Widget child;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      onTap: onTap,
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap),
              Center(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class V3PrimaryButton extends StatelessWidget {
  const V3PrimaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.trailing,
    this.enabled = true,
    this.busy = false,
    this.weak = false,
    super.key,
  }) : assert(
         (icon == null ? 0 : 1) +
                 (leading == null ? 0 : 1) +
                 (trailing == null ? 0 : 1) <=
             1,
       );

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final bool enabled;
  final bool busy;
  final bool weak;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final radius = BorderRadius.circular(HuahuoRadius.regular);
    final foreground = weak ? colors.text : colors.onPrimary;
    final background = weak ? colors.surfaceMuted : colors.primary;
    final retainBusyTreatment = busy && !weak;
    final interactive = enabled && !busy && onPressed != null;

    return SizedBox(
      height: HuahuoControlSize.primaryButton,
      width: double.infinity,
      child: FilledButton(
        onPressed: interactive ? onPressed : null,
        style: FilledButton.styleFrom(
          elevation: interactive && !weak ? 1 : 0,
          shadowColor: colors.ink.withValues(alpha: .10),
          backgroundColor: background,
          disabledBackgroundColor: retainBusyTreatment
              ? background
              : colors.surfaceMuted,
          foregroundColor: foreground,
          disabledForegroundColor: retainBusyTreatment
              ? foreground
              : colors.muted,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
        child: icon == null && leading == null && trailing == null
            ? Center(child: _V3ButtonLabel(label))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null || leading != null) ...[
                    leading ?? Icon(icon, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: _V3ButtonLabel(label)),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
      ),
    );
  }
}

class V3OutlineButton extends StatelessWidget {
  const V3OutlineButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.enabled = true,
    super.key,
  }) : assert(icon == null || leading == null);
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? leading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final interactive = enabled && onPressed != null;
    return SizedBox(
      height: HuahuoControlSize.primaryButton,
      child: OutlinedButton(
        onPressed: interactive ? onPressed : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.text,
          disabledForegroundColor: colors.muted.withValues(alpha: .46),
          side: BorderSide(
            color: interactive
                ? colors.line
                : colors.line.withValues(alpha: .55),
          ),
          padding: const EdgeInsets.symmetric(horizontal: HuahuoSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HuahuoRadius.regular),
          ),
        ),
        child: icon == null && leading == null
            ? Center(child: _V3ButtonLabel(label))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  leading ?? Icon(icon, size: 20),
                  const SizedBox(width: HuahuoSpacing.xs),
                  Flexible(child: _V3ButtonLabel(label)),
                ],
              ),
      ),
    );
  }
}

class _V3ButtonLabel extends StatelessWidget {
  const _V3ButtonLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: HuahuoV3Theme.button,
      ),
    );
  }
}

class V3ListTileCard extends StatelessWidget {
  const V3ListTileCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          V3GlassGlyph(
            icon: icon,
            size: HuahuoV3Theme.listIconSize,
            iconSize: HuahuoV3Theme.listIconGlyphSize,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HuahuoV3Theme.listTitle),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: HuahuoV3Theme.body.copyWith(color: colors.muted),
                ),
              ],
            ),
          ),
          trailing ??
              Icon(Icons.chevron_right_rounded, size: 30, color: colors.muted),
        ],
      ),
    );
  }
}

class V3SectionTitle extends StatelessWidget {
  const V3SectionTitle(this.text, {this.subtitle, this.trailing, super.key});
  final String text;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: HuahuoV3Theme.sectionTitle.copyWith(
                    color: colors.text,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

class V3Waveform extends StatefulWidget {
  const V3Waveform({
    this.active = true,
    this.samples,
    this.color,
    this.height = 72,
    super.key,
  });
  final bool active;
  final List<double>? samples;
  final Color? color;
  final double height;

  @override
  State<V3Waveform> createState() => _V3WaveformState();
}

class _V3WaveformState extends State<V3Waveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _tickerMetrics = RuntimeTickerMetricsLease('shared_waveform');

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: V3MotionTokens.waveformLoop,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant V3Waveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.samples == null &&
        widget.active &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop(canceled: false);
    }
    _tickerMetrics.sync(context, active: shouldAnimate);
  }

  @override
  void dispose() {
    _tickerMetrics.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => CustomPaint(
        painter: _WavePainter(
          phase: _controller.value,
          color: widget.color ?? colors.accent,
          active: widget.active,
          samples: widget.samples,
        ),
        child: SizedBox(height: widget.height, width: double.infinity),
      ),
    );
  }
}

/// A compact semantic line chart for real asset-deposit buckets.
class V3AssetGrowthSparkline extends StatelessWidget {
  const V3AssetGrowthSparkline({
    required this.values,
    this.height = 30,
    this.semanticLabel,
    super.key,
  });

  final List<int> values;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final normalized = List<int>.unmodifiable(
      values.map((value) => value < 0 ? 0 : value),
    );
    return Semantics(
      label:
          semanticLabel ??
          '资产新增趋势：${normalized.isEmpty ? '暂无数据' : normalized.join('、')}',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _V3AssetGrowthSparklinePainter(
              values: normalized,
              lineColor: colors.primary,
              baseColor: colors.line,
              pointFill: colors.surface,
            ),
            child: SizedBox(height: height, width: double.infinity),
          ),
        ),
      ),
    );
  }
}

class _V3AssetGrowthSparklinePainter extends CustomPainter {
  const _V3AssetGrowthSparklinePainter({
    required this.values,
    required this.lineColor,
    required this.baseColor,
    required this.pointFill,
  });

  final List<int> values;
  final Color lineColor;
  final Color baseColor;
  final Color pointFill;

  @override
  void paint(Canvas canvas, Size size) {
    const horizontalInset = 3.0;
    const verticalInset = 3.0;
    final baseline = size.height - verticalInset;
    final contentWidth = math
        .max(0.0, size.width - horizontalInset * 2)
        .toDouble();
    final contentHeight = math
        .max(0.0, size.height - verticalInset * 2)
        .toDouble();
    final basePaint = Paint()
      ..color = baseColor.withValues(alpha: .78)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(horizontalInset, baseline),
      Offset(size.width - horizontalInset, baseline),
      basePaint,
    );

    if (values.isEmpty || contentWidth <= 0 || contentHeight <= 0) return;
    final maxValue = values.fold<int>(
      0,
      (highest, value) => value > highest ? value : highest,
    );
    final denominator = math.max(1, maxValue).toDouble();
    final divisor = math.max(1, values.length - 1).toDouble();
    final points = <Offset>[
      for (var index = 0; index < values.length; index++)
        Offset(
          horizontalInset + contentWidth * index / divisor,
          baseline - contentHeight * values[index] / denominator,
        ),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      path.lineTo(points[index].dx, points[index].dy);
    }
    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    final fillPaint = Paint()..color = pointFill;
    final strokePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35;
    for (final point in points) {
      canvas.drawCircle(point, 2.1, fillPaint);
      canvas.drawCircle(point, 2.1, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _V3AssetGrowthSparklinePainter oldDelegate) {
    return !listEquals(values, oldDelegate.values) ||
        lineColor != oldDelegate.lineColor ||
        baseColor != oldDelegate.baseColor ||
        pointFill != oldDelegate.pointFill;
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.phase,
    required this.color,
    required this.active,
    required this.samples,
  });
  final double phase;
  final Color color;
  final bool active;
  final List<double>? samples;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final centerY = size.height / 2;
    final count = 68;
    final actualSamples = samples;
    for (var i = 0; i < count; i++) {
      final x = size.width * i / (count - 1);
      if (actualSamples != null) {
        final sampleIndex = actualSamples.isEmpty
            ? 0
            : (i * (actualSamples.length - 1) / (count - 1)).round();
        final raw = actualSamples.isEmpty ? 0.0 : actualSamples[sampleIndex];
        final level = raw.isFinite ? raw.clamp(0.0, 1.0).toDouble() : 0.0;
        final maxHeight = math.max(6.0, size.height * .86);
        final h = (6 + level * (maxHeight - 6))
            .clamp(6.0, maxHeight)
            .toDouble();
        canvas.drawLine(
          Offset(x, centerY - h / 2),
          Offset(x, centerY + h / 2),
          paint,
        );
        continue;
      }
      final seed = _waveSeed(i);
      final drift = active ? phase * math.pi * 2 : 0.0;
      final wave =
          .48 * math.sin(i * .43 + drift) +
          .32 * math.sin(i * 1.17 + seed * 5.2 - drift * .62) +
          .20 * math.sin(i * 2.31 + seed * 8.4 + drift * 1.18);
      final envelope =
          .18 + .82 * math.pow(math.sin(math.pi * i / (count - 1)).abs(), .56);
      final spike = seed > .90
          ? 1.72
          : (seed > .78 ? 1.32 : (seed < .12 ? .44 : .72 + seed * .48));
      final h =
          (active
                  ? 8 + size.height * .78 * wave.abs() * envelope * spike
                  : 7 + size.height * .18 * envelope)
              .clamp(6.0, size.height * .92)
              .toDouble();
      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.active != active ||
      oldDelegate.samples != samples;
}

double _waveSeed(int index) {
  final value = math.sin(index * 12.9898 + 78.233) * 43758.5453;
  return value - value.floorToDouble();
}
