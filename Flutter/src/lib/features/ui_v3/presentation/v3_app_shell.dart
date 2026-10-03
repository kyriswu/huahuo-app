// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../notifications/application/notification_center_state_machine.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_onboarding_spotlight.dart';
import '../../chat/domain/chat_models.dart';
import '../application/feed_composer_controller.dart';
import '../application/feed_graph_controller.dart';
import '../application/feed_view_mode_controller.dart';
import '../application/profile_workspace_controller.dart';
import '../application/user_profile_controller.dart';
import 'v3_feed_page.dart';
import 'v3_account_profile_page.dart';
import 'v3_feed_quick_dock.dart';
import 'v3_masterpiece_page.dart';
import 'v3_profile_side_panel.dart';
import 'v3_workbench_page.dart';

const _openProfilePanelForScreenshot = bool.fromEnvironment(
  'HUAHUO_V3_OPEN_PROFILE_PANEL',
  defaultValue: false,
);
const _homeModeForScreenshot = String.fromEnvironment('HUAHUO_V3_HOME_MODE');
const _closedBottomPagerHeight = 76.0;
const _expandedBottomPagerHeight = 292.0;
const _bottomPagerPhysicalOverlap = 8.0;
const _bottomControlInset = 20.0;
const _modeIndicatorBottom = 76.0;
const _modeIndicatorHeight = 5.0;
const _feedOverlayGap = 12.0;

abstract final class _ModeSwipePolicy {
  static const _viewportFraction = 0.12;
  static const _minimumTravel = 48.0;
  static const _maximumTravel = 64.0;
  static const _minimumFlingTravel = 24.0;
  static const _minimumFlingVelocity = 500.0;
  static const _directionalDominance = 1.25;

  static double travelThreshold(double viewportWidth) {
    return (viewportWidth * _viewportFraction)
        .clamp(_minimumTravel, _maximumTravel)
        .toDouble();
  }

  static bool shouldCommit({
    required Offset displacement,
    required Velocity velocity,
    required double viewportWidth,
    required bool validateCrossAxis,
  }) {
    final horizontalTravel = displacement.dx.abs();
    if (horizontalTravel + precisionErrorTolerance < kTouchSlop) return false;
    if (validateCrossAxis &&
        horizontalTravel < displacement.dy.abs() * _directionalDominance) {
      return false;
    }
    final pixelsPerSecond = velocity.pixelsPerSecond;
    final isFastRelease = pixelsPerSecond.distance >= _minimumFlingVelocity;
    final hasHorizontalFlingSpeed =
        pixelsPerSecond.dx.abs() >= _minimumFlingVelocity;
    final velocityMatchesTravel =
        pixelsPerSecond.dx.sign == displacement.dx.sign;
    final velocityIsHorizontal =
        !validateCrossAxis ||
        pixelsPerSecond.dx.abs() >=
            pixelsPerSecond.dy.abs() * _directionalDominance;
    if (horizontalTravel + precisionErrorTolerance >=
        travelThreshold(viewportWidth)) {
      return !isFastRelease ||
          (hasHorizontalFlingSpeed &&
              velocityMatchesTravel &&
              velocityIsHorizontal);
    }
    if (horizontalTravel + precisionErrorTolerance < _minimumFlingTravel ||
        !hasHorizontalFlingSpeed ||
        !velocityMatchesTravel ||
        !velocityIsHorizontal) {
      return false;
    }
    return true;
  }
}

/// The order is intentionally the visual swipe order of the bounded pager.
enum V3HomeMode { feed, workbench, masterpiece }

enum _FeedSwipeOrigin { idle, dock, notes, cancelled }

class _DirectionalHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _DirectionalHorizontalDragGestureRecognizer()
    : super(
        supportedDevices: const <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        },
      );

  int? _primaryPointer;
  Offset? _globalStart;
  Offset _globalDisplacement = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _beginTracking(event.pointer, event.position);
    super.addAllowedPointer(event);
  }

  void _beginTracking(int pointer, Offset position) {
    if (_primaryPointer != null) return;
    _primaryPointer = pointer;
    _globalStart = position;
    _globalDisplacement = Offset.zero;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == _primaryPointer) {
      final start = _globalStart;
      if (start != null && event is PointerMoveEvent) {
        _globalDisplacement = event.position - start;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return super.hasSufficientGlobalDistanceToAccept(
          pointerDeviceKind,
          deviceTouchSlop,
        ) &&
        _globalDisplacement.dx.abs() >=
            _globalDisplacement.dy.abs() *
                _ModeSwipePolicy._directionalDominance;
  }

  @override
  DragEndDetails? considerFling(
    VelocityEstimate estimate,
    PointerDeviceKind kind,
  ) {
    final maxVelocity = maxFlingVelocity ?? kMaxFlingVelocity;
    final estimatedVelocity = estimate.pixelsPerSecond;
    return DragEndDetails(
      velocity: Velocity(
        pixelsPerSecond: Offset(
          estimatedVelocity.dx.clamp(-maxVelocity, maxVelocity).toDouble(),
          estimatedVelocity.dy.clamp(-maxVelocity, maxVelocity).toDouble(),
        ),
      ),
    );
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _primaryPointer = null;
    _globalStart = null;
    _globalDisplacement = Offset.zero;
  }
}

class _DirectionalHorizontalDragArea extends StatelessWidget {
  const _DirectionalHorizontalDragArea({
    required this.child,
    required this.behavior,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    super.key,
  });

  final Widget child;
  final HitTestBehavior behavior;
  final GestureDragStartCallback? onStart;
  final GestureDragUpdateCallback? onUpdate;
  final GestureDragEndCallback? onEnd;
  final GestureDragCancelCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
    final multitouchDragStrategy = ScrollConfiguration.of(
      context,
    ).getMultitouchDragStrategy(context);
    final gestures =
        onStart == null && onUpdate == null && onEnd == null && onCancel == null
        ? <Type, GestureRecognizerFactory>{}
        : <Type, GestureRecognizerFactory>{
            _DirectionalHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _DirectionalHorizontalDragGestureRecognizer
                >(_DirectionalHorizontalDragGestureRecognizer.new, (
                  recognizer,
                ) {
                  recognizer
                    ..onStart = onStart
                    ..onUpdate = onUpdate
                    ..onEnd = onEnd
                    ..onCancel = onCancel
                    ..dragStartBehavior = DragStartBehavior.down
                    ..multitouchDragStrategy = multitouchDragStrategy
                    ..gestureSettings = gestureSettings;
                }),
          };
    return RawGestureDetector(
      behavior: behavior,
      excludeFromSemantics: true,
      gestures: gestures,
      child: child,
    );
  }
}

/// Settles from the page where the drag began instead of requiring half a page.
class _ComfortablePageScrollPhysics extends ScrollPhysics {
  const _ComfortablePageScrollPhysics({
    required this.dragStartPage,
    required this.dragBasePage,
    required this.dragCanCommit,
    super.parent,
  });

  final double Function() dragStartPage;
  final int Function() dragBasePage;
  final bool Function() dragCanCommit;

  @override
  _ComfortablePageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ComfortablePageScrollPhysics(
      dragStartPage: dragStartPage,
      dragBasePage: dragBasePage,
      dragCanCommit: dragCanCommit,
      parent: buildParent(ancestor),
    );
  }

  @override
  double? get dragStartDistanceMotionThreshold => null;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position is! PageMetrics) {
      return super.createBallisticSimulation(position, velocity);
    }

    final currentPage = position.page;
    if (currentPage == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final pageExtent = position.viewportDimension * position.viewportFraction;
    final startPage = dragStartPage();
    final basePage = dragBasePage();
    final displacement = _commitDisplacement(
      startPage: startPage,
      currentPage: currentPage,
      basePage: basePage,
      pageExtent: pageExtent,
    );
    final shouldCommit =
        dragCanCommit() &&
        _ModeSwipePolicy.shouldCommit(
          displacement: Offset(displacement, 0),
          velocity: Velocity(pixelsPerSecond: Offset(velocity, 0)),
          viewportWidth: position.viewportDimension,
          validateCrossAxis: false,
        );
    final targetPage =
        basePage + (shouldCommit ? displacement.sign.toInt() : 0);
    final inRangePixels = position.pixels
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final targetPixels =
        (inRangePixels + (targetPage - currentPage) * pageExtent)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    final tolerance = toleranceFor(position);
    if ((targetPixels - position.pixels).abs() <= tolerance.distance) {
      return null;
    }
    final targetDirection = (targetPixels - position.pixels).sign;
    final settlingVelocity = shouldCommit && velocity.sign == targetDirection
        ? velocity
        : 0.0;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      targetPixels,
      settlingVelocity,
      tolerance: tolerance,
    );
  }

  double _commitDisplacement({
    required double startPage,
    required double currentPage,
    required int basePage,
    required double pageExtent,
  }) {
    final startSide = (startPage - basePage).sign;
    final currentSide = (currentPage - basePage).sign;
    final gestureDisplacement = (currentPage - startPage) * pageExtent;
    if (startSide == 0) return gestureDisplacement;
    if (currentSide == startSide) {
      return gestureDisplacement.sign == startSide ? gestureDisplacement : 0;
    }
    return (currentPage - basePage) * pageExtent;
  }
}

extension V3HomeModeX on V3HomeMode {
  String get title => switch (this) {
    V3HomeMode.feed => '思想图谱',
    V3HomeMode.workbench => '创作空间',
    V3HomeMode.masterpiece => '代表作',
  };
}

class V3AppShell extends ConsumerStatefulWidget {
  const V3AppShell({
    this.initialMode,
    this.initialFeedNotes = false,
    super.key,
  });

  /// Used by the V5 router. The graph canvas is visible only for feed mode.
  final V3HomeMode? initialMode;

  final bool initialFeedNotes;

  V3HomeMode get resolvedInitialMode {
    for (final mode in V3HomeMode.values) {
      if (_homeModeForScreenshot == mode.name) return mode;
    }
    if (initialMode != null) return initialMode!;
    return V3HomeMode.feed;
  }

  @override
  ConsumerState<V3AppShell> createState() => _V3AppShellState();
}

class _V3AppShellState extends ConsumerState<V3AppShell>
    with AppActivityRouteAware<V3AppShell> {
  late final PageController _modePageController;
  late V3HomeMode _mode;
  late int _physicalPage;
  late bool _hasVisitedWorkbench;
  final _feedModePointers = <int>{};
  _FeedSwipeOrigin _feedSwipeOrigin = _FeedSwipeOrigin.idle;
  bool _feedModeGestureInvalidated = false;
  bool _suppressDockActions = false;
  Offset? _feedModeDragStart;
  Offset _feedModePointerDelta = Offset.zero;
  double? _modePageDragStartPage;
  int? _modePageDragBasePage;
  bool _modePageGestureInvalidated = false;
  bool _profilePanelOpen = false;

  @override
  void initState() {
    super.initState();
    final requestedMode = widget.resolvedInitialMode;
    final masterpieceVisible = ref
        .read(profileWorkspaceControllerProvider)
        .masterpiece
        .isVisible;
    _mode = !masterpieceVisible && requestedMode == V3HomeMode.masterpiece
        ? V3HomeMode.workbench
        : requestedMode;
    _physicalPage = _mode.index;
    _hasVisitedWorkbench = _mode == V3HomeMode.workbench;
    ref
        .read(feedViewModeControllerProvider)
        .initialize(initiallyShowNotes: widget.initialFeedNotes);
    _modePageController = PageController(initialPage: _physicalPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_openProfilePanelForScreenshot) showV3ProfileSidePanel(context);
    });
  }

  @override
  void didUpdateWidget(covariant V3AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFeedNotes != oldWidget.initialFeedNotes ||
        widget.resolvedInitialMode != oldWidget.resolvedInitialMode) {
      _cancelFeedModePointer();
    }
    final nextMode = widget.resolvedInitialMode;
    if (nextMode == oldWidget.resolvedInitialMode) return;
    _mode = nextMode;
    _physicalPage = nextMode.index;
    _hasVisitedWorkbench |= nextMode == V3HomeMode.workbench;
    if (_modePageController.hasClients) {
      _animateToMode(nextMode);
    }
  }

  @override
  void dispose() {
    _modePageController.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() {}

  @override
  void onActivityRouteBecameInactive() {
    _suppressDockActions = true;
    _feedModePointers.clear();
    _cancelFeedModePointer();
  }

  @override
  Widget build(BuildContext context) {
    final feedNotesVisible = ref.watch(
      feedViewModeControllerProvider.select(
        (controller) => controller.mode == FeedViewMode.notes,
      ),
    );
    ref.listen<FeedViewMode>(
      feedViewModeControllerProvider.select((controller) => controller.mode),
      (previous, next) => _cancelFeedModePointer(),
    );
    final addMenuOpen = ref.watch(
      feedComposerControllerProvider.select(
        (controller) => controller.addMenuOpen,
      ),
    );
    final modeSwitchLocked = addMenuOpen;
    final colors = HuahuoV3Theme.tokensOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomSafeArea = MediaQuery.paddingOf(context).bottom;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final masterpieceVisible = ref.watch(
      profileWorkspaceControllerProvider.select(
        (controller) => controller.masterpiece.isVisible,
      ),
    );
    if (!masterpieceVisible && _mode == V3HomeMode.masterpiece) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            ref
                .read(profileWorkspaceControllerProvider)
                .masterpiece
                .isVisible) {
          return;
        }
        _animateToMode(V3HomeMode.workbench);
      });
    }
    final dockHeight = _mode == V3HomeMode.feed && addMenuOpen
        ? _expandedBottomPagerHeight
        : _closedBottomPagerHeight;
    final feedOverlayBottomInset = keyboardVisible
        ? 0.0
        : bottomSafeArea +
              (addMenuOpen
                  ? dockHeight - _bottomPagerPhysicalOverlap
                  : _mode != V3HomeMode.feed
                  ? dockHeight - _bottomPagerPhysicalOverlap
                  : _modeIndicatorBottom + _modeIndicatorHeight) +
              _feedOverlayGap;
    if (modeSwitchLocked ||
        keyboardVisible ||
        !activityRouteCanRun ||
        (_feedSwipeOrigin == _FeedSwipeOrigin.notes && !feedNotesVisible)) {
      _cancelFeedModePointer();
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: colors.canvas,
          ),
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: V3GlassHomeScope(
          child: SafeArea(
            bottom: false,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleFeedModePointerDown,
              onPointerUp: _handleFeedModePointerUp,
              onPointerCancel: _handleFeedModePointerCancel,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleModePageScrollNotification,
                      child: PageView(
                        key: const ValueKey<String>('home-content-mode-pager'),
                        controller: _modePageController,
                        pageSnapping: false,
                        dragStartBehavior: DragStartBehavior.down,
                        physics: modeSwitchLocked || _mode == V3HomeMode.feed
                            ? const NeverScrollableScrollPhysics()
                            : _ComfortablePageScrollPhysics(
                                dragStartPage: () =>
                                    _modePageDragStartPage ??
                                    _physicalPage.toDouble(),
                                dragBasePage: () =>
                                    _modePageDragBasePage ?? _physicalPage,
                                dragCanCommit: () =>
                                    !_modePageGestureInvalidated,
                                parent: const BouncingScrollPhysics(),
                              ),
                        children: [
                          _DirectionalHorizontalDragArea(
                            behavior: HitTestBehavior.translucent,
                            onStart: feedNotesVisible
                                ? (details) => _handleFeedModeDragStart(
                                    details,
                                    _FeedSwipeOrigin.notes,
                                  )
                                : null,
                            onUpdate: feedNotesVisible
                                ? _handleFeedModeDragUpdate
                                : null,
                            onEnd: feedNotesVisible
                                ? _handleFeedModeDragEnd
                                : null,
                            onCancel: feedNotesVisible
                                ? _handleFeedModeDragCancel
                                : null,
                            child: V3FeedPage(
                              active: _mode == V3HomeMode.feed,
                              isFeedMode: true,
                              initiallyShowNotes: widget.initialFeedNotes,
                              bottomOverlayInset: feedOverlayBottomInset,
                            ),
                          ),
                          const V3WorkbenchHomeSurface(bottomContentInset: 18),
                          if (masterpieceVisible)
                            V3MasterpiecePage(
                              active: _mode == V3HomeMode.masterpiece,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_mode == V3HomeMode.feed && addMenuOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: ref
                            .read(feedComposerControllerProvider)
                            .closeAddMenu,
                      ),
                    ),
                  Positioned(
                    top: 12,
                    left: 22,
                    right: 20,
                    child: _HomeHeaderConnector(
                      mode: _mode,
                      animateFeedReturn:
                          _hasVisitedWorkbench && _mode == V3HomeMode.feed,
                      searchEnabled: true,
                      onOpenProfile: _openProfilePanel,
                      onOpenNotifications: () =>
                          context.push(AppRoutePaths.notifications),
                    ),
                  ),
                  if (!keyboardVisible)
                    if (!masterpieceVisible && _mode == V3HomeMode.workbench)
                      Positioned(
                        top: 68,
                        right: 18,
                        child: TextButton.icon(
                          onPressed: () {
                            final restored = ref
                                .read(profileWorkspaceControllerProvider)
                                .setMasterpieceVisible(true);
                            if (!restored) return;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _animateToMode(V3HomeMode.masterpiece);
                              }
                            });
                          },
                          icon: const Icon(Icons.menu_book_outlined),
                          label: const Text('显示代表作'),
                        ),
                      ),
                  if (!keyboardVisible)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: bottomSafeArea + 10,
                      child: IgnorePointer(
                        child: AnimatedSlide(
                          duration: V3MotionTokens.resolve(
                            context,
                            V3MotionTokens.standard,
                          ),
                          curve: Curves.easeOutCubic,
                          offset: Offset(
                            0,
                            _mode == V3HomeMode.feed
                                ? -(_modeIndicatorBottom - 10) /
                                      _modeIndicatorHeight
                                : 0,
                          ),
                          child: Center(
                            child: _HomeModeIndicator(
                              mode: _mode,
                              masterpieceVisible: masterpieceVisible,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_mode == V3HomeMode.feed && !keyboardVisible)
                    Positioned(
                      left: 22,
                      right: 22,
                      bottom: bottomSafeArea - _bottomPagerPhysicalOverlap,
                      child: SizedBox(
                        height: dockHeight,
                        child: _HomeBottomModePage(
                          key: const ValueKey<String>('home-bottom-mode-feed'),
                          active: true,
                          chatKey: const ValueKey<String>('home-chat-feed'),
                          preferredDockWidth: V3FeedQuickDock.preferredWidth,
                          dockKey: const ValueKey<String>(
                            'home-feed-dock-frame',
                          ),
                          dock: Semantics(
                            hint: '左滑进入创作空间，右滑打开我的',
                            child: _DirectionalHorizontalDragArea(
                              key: const ValueKey('feed-dock-mode-gesture'),
                              behavior: HitTestBehavior.opaque,
                              onStart: (details) => _handleFeedModeDragStart(
                                details,
                                _FeedSwipeOrigin.dock,
                              ),
                              onUpdate: _handleFeedModeDragUpdate,
                              onEnd: _handleFeedModeDragEnd,
                              onCancel: _handleFeedModeDragCancel,
                              child: V3FeedQuickDock(
                                enabled: true,
                                canActivate: () =>
                                    !_suppressDockActions &&
                                    _feedNavigationAllowed,
                                onOpenWorkbench: _openWorkbench,
                              ),
                            ),
                          ),
                        ),
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

  void _commitSettledContentPage(int settledPage) {
    final index = settledPage.clamp(0, V3HomeMode.values.length - 1).toInt();
    final nextMode = index >= V3HomeMode.masterpiece.index
        ? V3HomeMode.masterpiece
        : V3HomeMode.values[index];
    if (_physicalPage == index && _mode == nextMode) return;
    setState(() {
      _physicalPage = index;
      _mode = nextMode;
      _hasVisitedWorkbench |= nextMode == V3HomeMode.workbench;
    });
  }

  void _captureModePageDragStart() {
    if (!_modePageController.hasClients) return;
    final page = _modePageController.page ?? _physicalPage.toDouble();
    _modePageDragStartPage = page;
    _modePageDragBasePage = page.round();
  }

  bool get _feedUsesNotesGestures {
    return ref.read(feedViewModeControllerProvider).mode == FeedViewMode.notes;
  }

  bool get _feedNavigationAllowed {
    return _mode == V3HomeMode.feed &&
        activityRouteCanRun &&
        !_profilePanelOpen &&
        !ref.read(feedComposerControllerProvider).addMenuOpen &&
        MediaQuery.viewInsetsOf(context).bottom == 0 &&
        _modePageController.hasClients &&
        !_modePageController.position.isScrollingNotifier.value;
  }

  bool _handleModePageScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      if (_feedModePointers.isEmpty) {
        _modePageGestureInvalidated = false;
        _captureModePageDragStart();
      }
    } else if (notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      if (metrics is! PageMetrics) return false;
      final page = metrics.page;
      if (page == null) return false;
      final settledPage = page.round();
      final pageExtent = metrics.viewportDimension * metrics.viewportFraction;
      final distanceFromSettledPage = (page - settledPage).abs() * pageExtent;
      final settleTolerance =
          (1 / metrics.devicePixelRatio) + precisionErrorTolerance;
      if (distanceFromSettledPage <= settleTolerance) {
        _modePageDragStartPage = null;
        _modePageDragBasePage = null;
        _commitSettledContentPage(settledPage);
      }
    }
    return false;
  }

  void _handleFeedModePointerDown(PointerDownEvent event) {
    final firstPointer = _feedModePointers.isEmpty;
    _feedModePointers.add(event.pointer);
    if (!firstPointer) {
      _modePageGestureInvalidated = true;
      _cancelFeedModePointer();
      return;
    }
    _modePageGestureInvalidated = false;
    if (_mode != V3HomeMode.feed && _modePageController.hasClients) {
      _captureModePageDragStart();
    }
    _feedModeGestureInvalidated = false;
    _feedSwipeOrigin = _FeedSwipeOrigin.idle;
    _feedModeDragStart = null;
    _feedModePointerDelta = Offset.zero;
    _suppressDockActions = !_feedNavigationAllowed;
  }

  void _handleFeedModePointerUp(PointerUpEvent event) {
    _feedModePointers.remove(event.pointer);
  }

  void _handleFeedModePointerCancel(PointerCancelEvent event) {
    _modePageGestureInvalidated = true;
    _cancelFeedModePointer();
    _feedModePointers.remove(event.pointer);
  }

  void _handleFeedModeDragStart(
    DragStartDetails details,
    _FeedSwipeOrigin origin,
  ) {
    final originMatchesViewport =
        origin == _FeedSwipeOrigin.dock ||
        (origin == _FeedSwipeOrigin.notes && _feedUsesNotesGestures);
    if (_feedModeGestureInvalidated ||
        _feedModePointers.length != 1 ||
        !_feedNavigationAllowed ||
        !originMatchesViewport) {
      _cancelFeedModePointer();
      return;
    }
    _suppressDockActions = true;
    _feedSwipeOrigin = origin;
    _feedModeDragStart = details.globalPosition;
    _feedModePointerDelta = Offset.zero;
  }

  void _handleFeedModeDragUpdate(DragUpdateDetails details) {
    final dragStart = _feedModeDragStart;
    if (_feedModeGestureInvalidated ||
        dragStart == null ||
        !_feedNavigationAllowed) {
      _cancelFeedModePointer();
      return;
    }
    _feedModePointerDelta = details.globalPosition - dragStart;
  }

  void _handleFeedModeDragEnd(DragEndDetails details) {
    final origin = _feedSwipeOrigin;
    final displacement = _feedModePointerDelta;
    final canCommit =
        !_feedModeGestureInvalidated &&
        _feedModeDragStart != null &&
        _feedNavigationAllowed &&
        (origin == _FeedSwipeOrigin.dock || origin == _FeedSwipeOrigin.notes);
    _feedSwipeOrigin = _FeedSwipeOrigin.idle;
    _feedModeDragStart = null;
    _feedModePointerDelta = Offset.zero;
    if (!canCommit ||
        !_ModeSwipePolicy.shouldCommit(
          displacement: displacement,
          velocity: details.velocity,
          viewportWidth: MediaQuery.sizeOf(context).width,
          validateCrossAxis: true,
        )) {
      return;
    }
    if (displacement.dx > 0) {
      _openProfilePanel();
    } else {
      _openWorkbench();
    }
  }

  void _handleFeedModeDragCancel() {
    if (_feedModeDragStart == null) return;
    _cancelFeedModePointer();
  }

  void _cancelFeedModePointer() {
    _suppressDockActions = true;
    _feedModeGestureInvalidated = true;
    _modePageGestureInvalidated = true;
    _feedSwipeOrigin = _FeedSwipeOrigin.cancelled;
    _feedModeDragStart = null;
    _feedModePointerDelta = Offset.zero;
  }

  void _openWorkbench() => _animateToMode(V3HomeMode.workbench);

  void _animateToMode(V3HomeMode mode) {
    if (!_modePageController.hasClients) return;
    _cancelFeedModePointer();
    _modePageDragStartPage = null;
    _modePageDragBasePage = null;
    _modePageGestureInvalidated = false;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _modePageController.jumpToPage(mode.index);
      _commitSettledContentPage(mode.index);
      return;
    }
    _modePageController.animateToPage(
      mode.index,
      duration: V3MotionTokens.resolve(context, V3MotionTokens.pageTravel),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _openProfilePanel() async {
    if (_profilePanelOpen) return;
    _cancelFeedModePointer();
    _profilePanelOpen = true;
    ref.read(feedComposerControllerProvider).closeAddMenu();
    try {
      await showV3ProfileSidePanel(context);
    } finally {
      _profilePanelOpen = false;
    }
  }
}

class _HomeHeaderConnector extends ConsumerWidget {
  const _HomeHeaderConnector({
    required this.mode,
    required this.animateFeedReturn,
    required this.searchEnabled,
    required this.onOpenProfile,
    required this.onOpenNotifications,
  });

  final V3HomeMode mode;
  final bool animateFeedReturn;
  final bool searchEnabled;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenNotifications;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatar = ref.watch(
      userProfileControllerProvider.select(
        (controller) => controller.state.profile.avatar,
      ),
    );
    if (mode != V3HomeMode.feed) {
      return _HomeHeader(
        mode: mode,
        animateFeedReturn: false,
        searchOpen: false,
        query: '',
        searchEnabled: false,
        onToggleSearch: _ignoreTap,
        onSearchQueryChanged: _ignoreQuery,
        onOpenProfile: onOpenProfile,
        onOpenNotifications: onOpenNotifications,
        avatar: avatar,
      );
    }
    final state = ref.watch(
      feedGraphControllerProvider.select(
        (controller) => (
          searchOpen: controller.searchOpen,
          searchQuery: controller.searchQuery,
        ),
      ),
    );
    return _HomeHeader(
      mode: mode,
      animateFeedReturn: animateFeedReturn,
      searchOpen: state.searchOpen,
      query: state.searchQuery,
      searchEnabled: searchEnabled,
      onToggleSearch: () =>
          ref.read(feedGraphControllerProvider).toggleSearch(),
      onSearchQueryChanged: (value) =>
          ref.read(feedGraphControllerProvider).setSearchQuery(value),
      onOpenProfile: onOpenProfile,
      onOpenNotifications: onOpenNotifications,
      avatar: avatar,
    );
  }

  static void _ignoreTap() {}

  static void _ignoreQuery(String _) {}
}

class _HomeBottomModePage extends ConsumerWidget {
  const _HomeBottomModePage({
    required this.active,
    required this.chatKey,
    this.preferredDockWidth = 0,
    this.dockKey,
    this.dock,
    super.key,
  });

  static const _chatWidth = 48.0;
  static const _minimumGap = 12.0;

  final bool active;
  final Key chatKey;
  final double preferredDockWidth;
  final Key? dockKey;
  final Widget? dock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journey = ref.watch(firstLaunchDeviceSetupControllerProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableDockWidth =
            (constraints.maxWidth - _chatWidth - _minimumGap)
                .clamp(0.0, preferredDockWidth)
                .toDouble();
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 8,
              bottom: _bottomControlInset,
              child: V3OnboardingSpotlight(
                visible: active && journey.requiresChatGuide,
                step: 1,
                title: '点这里，和花火聊一聊',
                message: '这个花火图标就是「聊一聊」入口。想选题、写文案或脚本、润色修改内容，都可以从这里开始。',
                onSkip: () {
                  if (!journey.skipChatGuide()) {
                    showV3Snack(context, '进度暂未保存，请再试一次');
                  }
                },
                child: V3ChatEntry(
                  key: chatKey,
                  interactive: active,
                  onTap: journey.requiresChatGuide
                      ? () => context.push(
                          '/v3/feed/chat?entry=$thoughtGraphChatEntryRouteValue&startupGuide=1',
                        )
                      : null,
                ),
              ),
            ),
            if (dock case final dock?)
              Positioned(
                right: 0,
                bottom: _bottomControlInset,
                width: availableDockWidth,
                child: SizedBox(key: dockKey, child: dock),
              ),
          ],
        );
      },
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.mode,
    required this.animateFeedReturn,
    required this.searchOpen,
    required this.query,
    required this.searchEnabled,
    required this.onToggleSearch,
    required this.onSearchQueryChanged,
    required this.onOpenProfile,
    required this.onOpenNotifications,
    required this.avatar,
  });

  final V3HomeMode mode;
  final bool animateFeedReturn;
  final bool searchOpen;
  final String query;
  final bool searchEnabled;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchQueryChanged;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenNotifications;
  final UserProfileAvatar? avatar;

  @override
  Widget build(BuildContext context) {
    final graphSearchVisible = mode == V3HomeMode.feed;
    if (mode == V3HomeMode.workbench) {
      return Row(
        children: [
          _HomeProfileAction(
            key: const ValueKey<String>('home-profile-menu'),
            onTap: onOpenProfile,
            avatar: avatar,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _AnimatedModeTitle(
              key: const ValueKey<String>('home-workbench-title'),
              text: mode.title,
              fontSize: HuahuoV3Theme.pageTitleSize,
              revealColor: true,
            ),
          ),
          _HomeNotificationConnector(
            actionKey: const ValueKey<String>('home-workbench-notifications'),
            onTap: onOpenNotifications,
          ),
        ],
      );
    }
    return Row(
      children: [
        _HomeProfileAction(
          key: const ValueKey<String>('home-profile-menu'),
          onTap: onOpenProfile,
          avatar: avatar,
        ),
        SizedBox(width: mode == V3HomeMode.feed ? 16 : 8),
        Expanded(
          child: graphSearchVisible && searchOpen
              ? V3GraphSearchControl(
                  query: query,
                  enabled: searchEnabled,
                  onToggle: onToggleSearch,
                  onQueryChanged: onSearchQueryChanged,
                )
              : mode != V3HomeMode.feed
              ? _AnimatedModeTitle(
                  key: ValueKey<String>(
                    mode == V3HomeMode.workbench
                        ? 'home-workbench-title'
                        : 'home-masterpiece-title',
                  ),
                  text: mode.title,
                  fontSize: HuahuoV3Theme.pageTitleSize,
                  revealColor: true,
                )
              : animateFeedReturn
              ? const _AnimatedModeTitle(
                  key: ValueKey<String>('home-feed-title'),
                  text: '思想图谱',
                  fontSize: HuahuoV3Theme.pageTitleSize,
                  revealColor: false,
                )
              : Text(
                  mode.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: HuahuoV3Theme.pageTitleSize,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
        ),
        if (graphSearchVisible && !searchOpen) ...[
          V3GraphSearchIcon(
            key: const ValueKey<String>('home-feed-search'),
            enabled: searchEnabled,
            onTap: onToggleSearch,
          ),
          const SizedBox(width: 8),
          _HomeNotificationConnector(
            actionKey: const ValueKey<String>('home-feed-notifications'),
            onTap: onOpenNotifications,
          ),
        ],
      ],
    );
  }
}

class _HomeNotificationConnector extends ConsumerWidget {
  const _HomeNotificationConnector({
    required this.actionKey,
    required this.onTap,
  });

  final Key actionKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attention = ref.watch(notificationCenterAttentionProvider);
    return _HomeNotificationAction(
      actionKey: actionKey,
      attention: attention,
      onTap: onTap,
    );
  }
}

class _HomeNotificationAction extends StatelessWidget {
  const _HomeNotificationAction({
    required this.actionKey,
    required this.attention,
    required this.onTap,
  });

  final Key actionKey;
  final NotificationCenterAttention attention;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final unreadCount = attention.unreadCount;
    final hasProcessing = attention.hasProcessing;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        V3LiquidGlassIconAction(
          key: actionKey,
          tooltip: '通知',
          semanticLabel: unreadCount > 0
              ? '打开通知，$unreadCount 条未读${hasProcessing ? '，有任务进行中' : ''}'
              : hasProcessing
              ? '打开通知，有任务进行中'
              : '打开通知',
          icon: const Icon(LucideIcons.bell, size: 22),
          onTap: onTap,
        ),
        if (unreadCount > 0)
          Positioned(
            right: -2,
            top: -2,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Container(
                  key: const ValueKey('home-notification-unread-count'),
                  height: 18,
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.danger,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.canvas, width: 1.5),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 9,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                if (hasProcessing)
                  Positioned(
                    key: const ValueKey('home-notification-processing-dot'),
                    left: -3,
                    bottom: -3,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: colors.danger,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.canvas, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          )
        else if (hasProcessing)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              key: const ValueKey('home-notification-processing-dot'),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: colors.danger,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _AnimatedModeTitle extends StatefulWidget {
  const _AnimatedModeTitle({
    required this.text,
    required this.fontSize,
    required this.revealColor,
    super.key,
  });

  final String text;
  final double fontSize;
  final bool revealColor;

  @override
  State<_AnimatedModeTitle> createState() => _AnimatedModeTitleState();
}

class _AnimatedModeTitleState extends State<_AnimatedModeTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: V3MotionTokens.brandReveal,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion || Platform.environment['FLUTTER_TEST'] == 'true') {
      _controller.value = 1;
    } else if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      header: true,
      label: widget.text,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final phase = Curves.easeInOutCubic.transform(
                  _controller.value,
                );
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) => _titleSweepShader(
                    bounds,
                    phase: phase,
                    revealColor: widget.revealColor,
                    baseInk: colors.ink,
                  ),
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: HuahuoV3Theme.fontFamily,
                      fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
                      fontSize: widget.fontSize,
                      height: 1,
                      fontWeight: widget.revealColor
                          ? FontWeight.w600
                          : FontWeight.w500,
                      letterSpacing: 0,
                      color: colors.ink,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeProfileAction extends StatelessWidget {
  const _HomeProfileAction({
    required this.avatar,
    required this.onTap,
    super.key,
  });

  final UserProfileAvatar? avatar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '我的',
      child: Semantics(
        button: true,
        label: '打开我的面板',
        child: SizedBox.square(
          dimension: V3GlassSpec.iconActionDiameter,
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: V3ProfileAvatarPreview(
                avatar: avatar,
                size: V3GlassSpec.iconActionDiameter,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _titleGradientColors = <Color>[
  Color(0xFF7795EB),
  Color(0xFFA47DDE),
  Color(0xFFE18FC2),
  Color(0xFFF2A28E),
];
const _titleGradientStops = <double>[0, .34, .68, 1];

Shader _titleSweepShader(
  Rect bounds, {
  required double phase,
  required bool revealColor,
  required Color baseInk,
}) {
  final progress = phase.clamp(0.0, 1.0);
  if (progress <= .001) {
    return LinearGradient(
      colors: revealColor ? [baseInk, baseInk] : _titleGradientColors,
      stops: revealColor ? const [0, 1] : _titleGradientStops,
    ).createShader(bounds);
  }
  if (progress >= .999) {
    return LinearGradient(
      colors: revealColor ? _titleGradientColors : [baseInk, baseInk],
      stops: revealColor ? _titleGradientStops : const [0, 1],
    ).createShader(bounds);
  }

  const feather = .055;
  final edge = (progress + feather).clamp(0.0, 1.0);
  final colors = <Color>[];
  final stops = <double>[];
  if (revealColor) {
    for (var index = 0; index < _titleGradientStops.length; index++) {
      final stop = _titleGradientStops[index];
      if (stop >= progress) break;
      stops.add(stop);
      colors.add(_titleGradientColors[index]);
    }
    stops
      ..add(progress)
      ..add(edge);
    colors
      ..add(_titleGradientColorAt(progress))
      ..add(baseInk);
    if (edge < 1) {
      stops.add(1);
      colors.add(baseInk);
    }
  } else {
    stops
      ..add(0)
      ..add(progress)
      ..add(edge);
    colors
      ..add(baseInk)
      ..add(baseInk)
      ..add(_titleGradientColorAt(edge));
    for (var index = 1; index < _titleGradientStops.length; index++) {
      final stop = _titleGradientStops[index];
      if (stop <= edge) continue;
      stops.add(stop);
      colors.add(_titleGradientColors[index]);
    }
    if (stops.last < 1) {
      stops.add(1);
      colors.add(_titleGradientColors.last);
    }
  }
  return LinearGradient(colors: colors, stops: stops).createShader(bounds);
}

Color _titleGradientColorAt(double position) {
  for (var index = 1; index < _titleGradientStops.length; index++) {
    final end = _titleGradientStops[index];
    if (position > end) continue;
    final start = _titleGradientStops[index - 1];
    final local = (position - start) / (end - start);
    return Color.lerp(
      _titleGradientColors[index - 1],
      _titleGradientColors[index],
      local,
    )!;
  }
  return _titleGradientColors.last;
}

class _HomeModeIndicator extends StatelessWidget {
  const _HomeModeIndicator({
    required this.mode,
    required this.masterpieceVisible,
  });

  final V3HomeMode mode;
  final bool masterpieceVisible;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey<String>('home-mode-indicator'),
      label: '当前首页模式：${mode.title}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (
            var index = 0;
            index < (masterpieceVisible ? V3HomeMode.values.length : 2);
            index++
          ) ...[
            if (index > 0) const SizedBox(width: 5),
            _ModeDot(active: mode == V3HomeMode.values[index]),
          ],
        ],
      ),
    );
  }
}

class _ModeDot extends StatelessWidget {
  const _ModeDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: active ? 16 : 5,
      height: _modeIndicatorHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          color: colors.ink.withValues(alpha: active ? .48 : .16),
        ),
      ),
    );
  }
}
