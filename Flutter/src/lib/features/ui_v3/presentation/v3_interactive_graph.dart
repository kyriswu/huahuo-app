// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/lifecycle/page_activity_lease.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../app/performance/performance_policy.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../application/feed_graph_controller.dart';
import '../application/graph_render_budget.dart';
import '../application/graph_render_quality_controller.dart';
import '../application/sphere_graph_layout.dart';
import '../application/sphere_graph_slots.dart';
import '../application/sphere_graph_motion_controller.dart';
import '../application/sphere_graph_projection_controller.dart';
import '../application/sphere_graph_render_topology.dart';
import '../domain/graph_edge_geometry.dart';
import '../domain/graph_snapshot.dart';
import '../domain/ui_v3_models.dart';
import 'v3_graph_node_painter.dart';
import 'v3_graph_sphere_mesh_painter.dart';
import 'v3_graph_status_overlay.dart';

class V3InteractiveGraph extends ConsumerStatefulWidget {
  const V3InteractiveGraph({
    required this.aggregated,
    this.active = true,
    this.aggregating = false,
    this.aggregationProgress = 0,
    this.interactionsEnabled = true,
    this.height = 520,
    this.onNodeTap,
    this.onSelectedNodeTap,
    this.onNodeLongPress,
    this.onCanvasTap,
    this.onCreateContent,
    this.showAggregationAction = false,
    this.onStartAggregation,
    this.fullscreen = false,
    this.aggregationSelectedNoteIds = const <String>[],
    this.aggregationHotspotNoteId,
    super.key,
  });

  final bool aggregated;
  final bool active;
  final bool aggregating;
  final double aggregationProgress;
  final bool interactionsEnabled;
  final double height;
  final ValueChanged<V3GraphNode>? onNodeTap;
  final ValueChanged<V3GraphNode>? onSelectedNodeTap;
  final ValueChanged<V3GraphNode>? onNodeLongPress;
  final VoidCallback? onCanvasTap;
  final VoidCallback? onCreateContent;
  final bool showAggregationAction;
  final VoidCallback? onStartAggregation;
  final bool fullscreen;
  final List<String> aggregationSelectedNoteIds;
  final String? aggregationHotspotNoteId;

  @override
  ConsumerState<V3InteractiveGraph> createState() => _V3InteractiveGraphState();
}

class _V3InteractiveGraphState extends ConsumerState<V3InteractiveGraph>
    with TickerProviderStateMixin, AppActivityRouteAware<V3InteractiveGraph> {
  static const _scenePadding = 240.0;
  static const _sphereDragSensitivity = .007;
  static const _initialSphereRotationX = -.7853981633974483;
  static const _initialSphereRotationY = .7853981633974483;
  late final TransformationController _transformationController;
  late final AnimationController _zoomPulseController;
  late final GraphRenderQualityController _renderQuality;
  _GraphLod _lod = _GraphLod.far;
  late final Listenable _graphRepaint;
  final SphereGraphLayout _sphereLayout = const SphereGraphLayout();
  late final SphereGraphProjectionController _sphereProjection;
  final SphereGraphSlots _sphereSlots = SphereGraphSlots();
  late final SphereGraphMotionController _motion;
  final _rotationMetrics = RuntimeTickerMetricsLease('graph_sphere_rotation');
  bool _tickerModeEnabled = true;
  bool _sphereTopologyReady = false;
  List<SphereGraphLayoutPoint> _spherePoints = const [];
  List<SphereGraphVisualLink> _sphereVisualLinks = const [];
  List<String> _sphereRealNodeIds = const [];
  final Map<String, Offset> _sphereManualPositions = <String, Offset>{};
  double _sphereRotationX = _initialSphereRotationX;
  double _sphereRotationY = _initialSphereRotationY;
  Iterable<Offset> _sphereFitPositions = const <Offset>[];
  Map<String, Offset> _displayPositions = const <String, Offset>{};
  bool _rotatingSphere = false;
  bool _reduceMotion = false;
  Timer? _completedStatusTimer;
  bool _showBuildCompleted = false;
  late final PageActivityLease _activityLease;
  bool _doubleTapWasBlank = true, _pendingHomeCameraFit = false;
  bool _homeFitScheduled = false, _hasUserTransformed = false;
  String? _canvasDraggedNodeId;
  Offset? _canvasDragOrigin;
  Offset? _canvasDragPointerOffset;
  Offset? _canvasDragPosition;
  bool _canvasDragMoved = false;
  bool _canvasDragHadSphereManualPosition = false;
  Offset? _canvasDragOriginalSphereManualPosition;
  FeedGraphController? _remoteLoadController;
  Matrix4? _resolvedHomeTransformation;
  Size? _lastGraphSize;
  Rect? _lastHomeTargetRect;
  Offset _lastSceneOrigin = Offset.zero;
  double _lastHomeNodePadding = 18;
  @override
  void initState() {
    super.initState();
    _activityLease = PageActivityLease(
      activity: ref.read(appActivityCoordinatorProvider),
      tabActive: widget.active,
    )..addListener(_handleActivityLeaseChanged);
    _transformationController = TransformationController(_homeTransformation());
    _transformationController.addListener(_handleTransformationChanged);
    _zoomPulseController = AnimationController(
      value: 1,
      duration: V3MotionTokens.graphPulse,
      vsync: this,
    );
    _sphereProjection = SphereGraphProjectionController();
    final performancePolicy = ref.read(performancePolicyProvider);
    _renderQuality = GraphRenderQualityController(
      maximumVisualNodeCount: performancePolicy.graphNodeBudget,
      maximumOrdinaryEdgeCount: performancePolicy.graphEdgeBudget,
      visualQuality: performancePolicy.graphVisualQuality,
      allowIdleAnimation: performancePolicy.allowIdleAnimation,
      automaticFrameRate: performancePolicy.graphAutomaticFrameRate,
    )..addListener(_handleRenderQualityChanged);
    _graphRepaint = _sphereProjection;
    _motion = SphereGraphMotionController(onRotate: _rotateAutomatically)
      ..addListener(_handleMotionStateChanged);
    ref.listenManual<PerformancePolicy>(performancePolicyProvider, (_, next) {
      _renderQuality.setPerformancePolicy(
        maximumVisualNodeCount: next.graphNodeBudget,
        maximumOrdinaryEdgeCount: next.graphEdgeBudget,
        visualQuality: next.graphVisualQuality,
        allowIdleAnimation: next.allowIdleAnimation,
        automaticFrameRate: next.graphAutomaticFrameRate,
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (_reduceMotion) _zoomPulseController.stop(canceled: false);
    _syncVisualActivity();
  }

  @override
  void didUpdateWidget(covariant V3InteractiveGraph old) {
    super.didUpdateWidget(old);
    final wasTransitioning = _isAggregating(old);
    final isTransitioning = _isAggregating(widget);
    if (!wasTransitioning && isTransitioning) {
    } else if (wasTransitioning && !isTransitioning) {
      _completedStatusTimer?.cancel();
      _showBuildCompleted = widget.aggregated;
      if (_showBuildCompleted) {
        _completedStatusTimer = Timer(
          V3FeedbackTimingTokens.graphCompletion,
          () {
            if (mounted) setState(() => _showBuildCompleted = false);
          },
        );
      }
    }
    if (old.active != widget.active) _activityLease.setTabActive(widget.active);
    _syncVisualActivity();
  }

  @override
  void onActivityRouteBecameActive() => _handleActivityLeaseChanged();

  @override
  void onActivityRouteBecameInactive() => _handleActivityLeaseChanged();

  void _handleActivityLeaseChanged() {
    if (!mounted) return;
    _syncVisualActivity();
    setState(() {});
  }

  void _syncVisualActivity() {
    if (_visualActive) {
      _requestRemoteGraphLoad();
      if (!_sphereProjection.active) _resumeVisualWork();
    } else {
      _pauseVisualWork();
    }
    _motion.configure(
      active: _visualActive,
      suspended:
          !_renderQuality.allowIdleAnimation ||
          _reduceMotion ||
          _isAggregating(widget) ||
          !widget.interactionsEnabled,
      nodeCount: _sphereProjection.topology.nodeCount,
      maximumFrameRate: _renderQuality.automaticFrameRate,
    );
  }

  void _handleMotionStateChanged() =>
      _rotationMetrics.sync(context, active: _motion.isTicking);

  void _rotateAutomatically(double radians) {
    if (!_visualActive) return;
    _sphereRotationY = (_sphereRotationY + radians) % (math.pi * 2);
    _projectSphere();
  }

  @override
  void dispose() {
    _completedStatusTimer?.cancel();
    _activityLease
      ..removeListener(_handleActivityLeaseChanged)
      ..dispose();
    _motion
      ..removeListener(_handleMotionStateChanged)
      ..dispose();
    _rotationMetrics.dispose();
    _transformationController.removeListener(_handleTransformationChanged);
    _transformationController.dispose();
    _zoomPulseController.dispose();
    _renderQuality
      ..removeListener(_handleRenderQualityChanged)
      ..dispose();
    _sphereProjection.dispose();
    super.dispose();
  }

  bool _isAggregating(V3InteractiveGraph value) =>
      !value.aggregated &&
      (value.aggregating ||
          (value.aggregationProgress > 0 && value.aggregationProgress < 1));
  bool get _visualActive =>
      _activityLease.active && activityRouteCanRun && _tickerModeEnabled;
  GraphRenderBudget get _currentRenderBudget {
    if (_visualActive) return _renderQuality.resolveBudget(_geometryLod(_lod));
    return GraphRenderBudget.resolve(
      lod: _geometryLod(_lod),
      quality: GraphRenderQuality.inactive,
    );
  }

  void _handleRenderQualityChanged() {
    _syncVisualActivity();
    setState(() {});
  }

  void _pauseVisualWork() {
    _sphereProjection.setActive(false);
    _cancelCanvasNodeDrag(rebuild: false);
    for (final id in _sphereManualPositions.keys) {
      _sphereProjection.clearManualPosition(id, notify: false);
    }
    _sphereManualPositions.clear();
    _zoomPulseController.stop(canceled: false);
    _renderQuality.setActive(false);
    _rotatingSphere = false;
  }

  void _resumeVisualWork() {
    _renderQuality.setActive(true);
    _sphereProjection.setActive(true);
  }

  void _projectSphere({Size? viewport, bool notify = true}) {
    final targetViewport = viewport ?? _sphereProjection.viewport;
    if (targetViewport.isEmpty) return;
    _sphereProjection.project(
      viewport: targetViewport,
      rotationX: _sphereRotationX,
      rotationY: _sphereRotationY,
      padding: 14,
      notify: notify,
    );
  }

  void _handleTransformationChanged() {
    final next = _lodForScale(
      v3GraphViewportScale(_transformationController.value),
    );
    if (next == _lod || !mounted) return;
    setState(() => _lod = next);
  }

  void _handleInteractionStart(ScaleStartDetails details) {
    if (!_visualActive) return;
    _renderQuality.beginInteraction();
    _hasUserTransformed = true;
    _rotatingSphere = details.pointerCount == 1;
  }

  void _handleInteractionUpdate(ScaleUpdateDetails details) {
    if (!_visualActive) return;
    if (details.pointerCount == 1 && _rotatingSphere) {
      final delta = details.focalPointDelta;
      if (delta.distanceSquared > .01) {
        _sphereRotationY += delta.dx * _sphereDragSensitivity;
        _sphereRotationX =
            (_sphereRotationX - delta.dy * _sphereDragSensitivity)
                .clamp(-math.pi / 2, math.pi / 2)
                .toDouble();
        final viewport = _sphereProjection.viewport;
        if (!viewport.isEmpty) {
          _projectSphere(viewport: viewport);
        }
      }
      return;
    }
    if (details.pointerCount >= 2) _rotatingSphere = false;
  }

  void _handleInteractionEnd(ScaleEndDetails details) {
    if (!_visualActive) return;
    _rotatingSphere = false;
    _renderQuality.endInteraction();
  }

  void _replayNodePulse() {
    if (_reduceMotion || !_visualActive) return;
    _zoomPulseController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      appActivityCoordinatorProvider.select(
        (activity) => activity.state.memoryPressureRevision,
      ),
      (previous, next) {
        if (previous == null || previous == next) return;
        _sphereTopologyReady = false;
        _spherePoints = const [];
        _sphereVisualLinks = const [];
        _displayPositions = const {};
        _sphereProjection.updateTopology(
          SphereGraphRenderTopology.empty(),
          notify: false,
        );
        if (mounted) setState(() {});
      },
    );
    if (!_visualActive) return SizedBox(height: widget.height);
    _requestRemoteGraphLoad();
    final colors = HuahuoV3Theme.tokensOf(context);
    final graphPalette = HuahuoV3Theme.graphPaletteOf(context);
    ref.listen<int>(
      feedGraphControllerProvider.select(
        (controller) => controller.filterApplicationRevision,
      ),
      (previous, next) {
        if (previous != null && previous != next) _replayNodePulse();
      },
    );
    final controller = ref.watch(feedGraphControllerProvider);
    final transitionProgress = widget.aggregated
        ? 1.0
        : widget.aggregationProgress.clamp(0.0, 1.0).toDouble();
    final transitioning =
        !widget.aggregated &&
        (widget.aggregating ||
            (transitionProgress > 0 && transitionProgress < 1));
    final nodes = controller.nodes;
    final selectedNodeId = controller.selectedNodeId;
    const V3GraphEdge? selectedEdge = null;
    final firstDegreeNodeIds = controller.firstDegreeNodeIds;
    final secondDegreeNodeIds = controller.secondDegreeNodeIds;
    final searchQuery = controller.appliedSearchQuery;
    final searchResults = controller.searchResults;
    final renderBudget = _currentRenderBudget;
    return TickerMode(
      enabled: _visualActive,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: widget.height,
          color: colors.canvas,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final graphSize = Size(
                constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : MediaQuery.sizeOf(context).width,
                constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : widget.height,
              );
              final viewportToolsTop = widget.fullscreen
                  ? MediaQuery.paddingOf(context).top + 68
                  : 78.0;
              final compactStatusTop =
                  viewportToolsTop + (widget.showAggregationAction ? 56 : 0);
              final compactViewport = graphSize.height < 680;
              final homeTop = compactViewport
                  ? (widget.showAggregationAction
                        ? viewportToolsTop + 56.0
                        : 24.0)
                  : viewportToolsTop +
                        (widget.showAggregationAction ? 56.0 : 16.0);
              const sceneOrigin = Offset(_scenePadding, _scenePadding);
              final sceneSize = Size(
                graphSize.width + _scenePadding * 2,
                graphSize.height + _scenePadding * 2,
              );
              final usableBottom = math.min(
                graphSize.height,
                math.max(180.0, graphSize.height - 128),
              );
              final logicalScale = Offset(
                graphSize.width / _graphLogicalSize.width,
                usableBottom / _graphLogicalSize.height,
              );
              final layoutViewport = Size(
                graphSize.width,
                compactViewport
                    ? usableBottom
                    : math.max(180, usableBottom - homeTop),
              );
              final renderedNodes = nodes
                  .where((node) => !node.center)
                  .toList(growable: false);
              final denseMode = renderedNodes.length > 120;
              late List<V3GraphNode> orderedNodes;
              late Map<String, Offset> idlePositions;
              late Map<String, double> nodeDepths;
              late Map<String, double> nodeRadii;
              _ensureSphereLayout(renderedNodes);
              _projectSphere(viewport: layoutViewport, notify: false);
              orderedNodes = renderedNodes;
              idlePositions = _sphereProjection.positions;
              nodeDepths = _sphereProjection.depths;
              nodeRadii = V3SphereNodeRadiusMap(_sphereProjection);
              final sphereCenter = Offset(
                layoutViewport.width / 2,
                layoutViewport.height / 2,
              );
              final sphereRadius =
                  math.max(0.0, layoutViewport.shortestSide / 2 - 14) * .97;
              _sphereFitPositions = [
                sphereCenter - Offset(sphereRadius, sphereRadius),
                sphereCenter + Offset(sphereRadius, sphereRadius),
              ];
              final importantNodeIds = _importantNodeIds(orderedNodes);
              final labeledNodeIds = _labeledNodeIds(
                nodes: orderedNodes,
                nodeDepths: nodeDepths,
                selectedNodeId: selectedNodeId,
                firstDegreeNodeIds: firstDegreeNodeIds,
                searchQuery: searchQuery,
                searchResults: searchResults,
                ordinaryLimit: renderBudget.ordinaryLabelCount,
                priorityLimit: renderBudget.priorityLabelCount,
              );
              final visualKinds = <String, _GraphNodeVisualKind>{
                for (final node in orderedNodes.where((node) => !node.center))
                  node.id: _visualKindFor(
                    node: node,
                    labeledNodeIds: labeledNodeIds,
                    importantNodeIds: importantNodeIds,
                    selectedNodeId: selectedNodeId,
                    firstDegreeNodeIds: firstDegreeNodeIds,
                    secondDegreeNodeIds: secondDegreeNodeIds,
                  ),
              };
              final aggregationPositions = <String, Offset>{
                for (final node in orderedNodes)
                  node.id: _positionForTransition(
                    node: node,
                    start: idlePositions[node.id] ?? Offset.zero,
                    hub: Offset(
                      layoutViewport.width / 2,
                      layoutViewport.height / 2,
                    ),
                    end: idlePositions[node.id] ?? Offset.zero,
                    progress: transitionProgress,
                  ),
              };
              final noteOpacity = _noteTagOpacity(transitionProgress);
              final displayPositions = transitioning
                  ? aggregationPositions
                  : idlePositions;
              _displayPositions = displayPositions;
              final focusedCluster = controller.focusedCluster;
              final searchActive = searchQuery.trim().isNotEmpty;
              final aggregationHighlightsActive =
                  widget.aggregationSelectedNoteIds.isNotEmpty &&
                  widget.aggregationProgress < 1 &&
                  (widget.aggregating || widget.aggregationProgress <= 0);
              final aggregationParticipantIds = <String>{
                if (aggregationHighlightsActive) ...[
                  ...widget.aggregationSelectedNoteIds,
                  if (widget.aggregationHotspotNoteId case final hotspotId?)
                    hotspotId,
                ],
              };
              final aggregationSelecting =
                  aggregationParticipantIds.isNotEmpty && !transitioning;
              final semanticNodeOpacities = <String, double>{
                for (final node in orderedNodes)
                  node.id: _aggregationSelectionOpacity(
                    nodeId: node.id,
                    baseOpacity: _nodeOpacity(
                      node: node,
                      selectedNodeId: selectedNodeId,
                      firstDegreeNodeIds: firstDegreeNodeIds,
                      secondDegreeNodeIds: secondDegreeNodeIds,
                      focusedCluster: focusedCluster,
                      matchesFilter: controller.nodeMatchesFilter(node),
                      matchesEntityType: controller.nodeMatchesEntityType(node),
                      searchActive: searchActive,
                      matchesSearch: controller.matchesSearch(node),
                      selectedEdge: selectedEdge,
                      aggregationOpacity: noteOpacity,
                    ),
                    selecting: aggregationSelecting,
                    participantIds: aggregationParticipantIds,
                  ),
              };
              final emphasizedNodeIds = <String>{
                if (selectedNodeId != null) selectedNodeId,
                if (selectedEdge != null) ...<String>{
                  selectedEdge.sourceId,
                  selectedEdge.targetId,
                },
                if (searchActive)
                  for (final node in searchResults) node.id,
              };
              final nodeOpacities = V3SphereNodeOpacityMap(
                projection: _sphereProjection,
                semanticOpacities: semanticNodeOpacities,
                emphasizedNodeIds: emphasizedNodeIds,
              );
              final nodeColors = <String, Color>{
                for (final node in orderedNodes)
                  node.id: _graphMarkerColorFor(node, graphPalette),
              };
              final homeTargetRect = Rect.fromLTRB(
                18,
                homeTop,
                math.max(114, graphSize.width - 18),
                math.max(homeTop + 120, usableBottom - 18),
              ).intersect(Offset.zero & graphSize);
              final viewportChanged = _lastGraphSize != graphSize;
              _lastGraphSize = graphSize;
              _lastHomeTargetRect = homeTargetRect;
              _lastSceneOrigin = sceneOrigin;
              _lastHomeNodePadding =
                  (nodeRadii.values.isEmpty
                          ? 18.0
                          : nodeRadii.values.reduce(math.max) + 10)
                      .clamp(18.0, 30.0)
                      .toDouble();
              if (_resolvedHomeTransformation == null ||
                  (viewportChanged && !_hasUserTransformed)) {
                _scheduleHomeFit();
              }
              final nodeRoles = <String, V3GraphNodeRole>{
                for (final node in orderedNodes)
                  node.id: controller.roleForNode(node.id),
              };
              final baseOverlayNodeIds = denseMode
                  ? v3GraphDenseOverlayNodeIds(
                      nodes: orderedNodes,
                      roles: nodeRoles,
                      searchMatchNodeIds: searchResults.map((node) => node.id),
                      maximum: renderBudget.widgetNodeCount,
                    )
                  : orderedNodes.map((node) => node.id).toSet();
              final overlayNodeIds = <String>{
                ...baseOverlayNodeIds,
                if (_canvasDraggedNodeId case final draggedId?) draggedId,
              };
              final flowItems = <_GraphFlowItem>[
                for (final node in orderedNodes)
                  if (overlayNodeIds.contains(node.id))
                    _GraphFlowItem(node.id, const Size.square(30)),
              ];
              if (_pendingHomeCameraFit) {
                _pendingHomeCameraFit = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _resetTransformation();
                });
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: AbsorbPointer(
                      absorbing:
                          !_visualActive ||
                          !widget.interactionsEnabled ||
                          transitioning,
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (event) =>
                            _motion.pointerDown(event.pointer),
                        onPointerUp: (event) =>
                            _motion.pointerUp(event.pointer),
                        onPointerCancel: (event) =>
                            _motion.pointerUp(event.pointer),
                        child: InteractiveViewer(
                          key: const ValueKey('feed-graph-interactive-viewer'),
                          transformationController: _transformationController,
                          panEnabled: false,
                          minScale: .82,
                          maxScale: 3,
                          boundaryMargin: EdgeInsets.zero,
                          constrained: false,
                          alignment: Alignment.topLeft,
                          clipBehavior: Clip.none,
                          onInteractionStart: _handleInteractionStart,
                          onInteractionUpdate: _handleInteractionUpdate,
                          onInteractionEnd: _handleInteractionEnd,
                          child: SizedBox(
                            key: const ValueKey('feed-graph-scene'),
                            width: sceneSize.width,
                            height: sceneSize.height,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: RepaintBoundary(
                                    child: _CanvasLongPressGestureLayer(
                                      enabled: denseMode,
                                      onStart: (details) =>
                                          _beginCanvasNodeDrag(
                                            details.localPosition - sceneOrigin,
                                            nodes: orderedNodes,
                                            overlayNodeIds: baseOverlayNodeIds,
                                            nodeRadii: nodeRadii,
                                            nodeOpacities: nodeOpacities,
                                            nodeDepths: nodeDepths,
                                          ),
                                      onUpdate: (details) =>
                                          _updateCanvasNodeDrag(
                                            details.localPosition - sceneOrigin,
                                          ),
                                      onEnd: (_) => _endCanvasNodeDrag(
                                        logicalScale: logicalScale,
                                      ),
                                      onCancel: _cancelCanvasNodeDrag,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTapUp: (details) {
                                          _handleCanvasTap(
                                            details.localPosition - sceneOrigin,
                                            nodes: orderedNodes,
                                            overlayNodeIds: overlayNodeIds,
                                            nodeRadii: nodeRadii,
                                            nodeOpacities: nodeOpacities,
                                            nodeDepths: nodeDepths,
                                          );
                                        },
                                        onDoubleTapDown: (details) {
                                          _doubleTapWasBlank =
                                              !_hasCanvasTarget(
                                                details.localPosition -
                                                    sceneOrigin,
                                                nodes: orderedNodes,
                                                overlayNodeIds: overlayNodeIds,
                                                nodeRadii: nodeRadii,
                                                nodeOpacities: nodeOpacities,
                                                nodeDepths: nodeDepths,
                                              );
                                        },
                                        onDoubleTap: () {
                                          if (_doubleTapWasBlank) {
                                            _resetGraph(replayPulse: false);
                                          }
                                        },
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            CustomPaint(
                                              key: const ValueKey(
                                                'feed-graph-sphere-mesh',
                                              ),
                                              painter: V3GraphSphereMeshPainter(
                                                projection: _sphereProjection,
                                                nodeColors: nodeColors,
                                                syntheticPalette: graphPalette,
                                                sceneOrigin: sceneOrigin,
                                                canvasColor: colors.canvas,
                                                baseNodeRadius: 7,
                                                useEdgeGradients:
                                                    _renderQuality
                                                        .visualQuality ==
                                                    AppVisualQuality.high,
                                              ),
                                            ),
                                            if (denseMode)
                                              CustomPaint(
                                                key: const ValueKey(
                                                  'feed-graph-dense-node-canvas',
                                                ),
                                                painter: V3GraphNodePainter(
                                                  repaint: _graphRepaint,
                                                  resolvePositions:
                                                      _currentPositions,
                                                  resolvePaintOrderIds: () =>
                                                      _sphereProjection
                                                          .drawOrderIds,
                                                  resolveZoom: _currentZoom,
                                                  sceneOrigin: sceneOrigin,
                                                  nodes: orderedNodes,
                                                  nodeRadii: nodeRadii,
                                                  nodeColors: nodeColors,
                                                  nodeOpacities: nodeOpacities,
                                                  nodeDepths: nodeDepths,
                                                  overlayNodeIds:
                                                      overlayNodeIds,
                                                  showAllLabels:
                                                      labeledNodeIds.isNotEmpty,
                                                  selectedNodeId:
                                                      selectedNodeId,
                                                  labelNodeIds: labeledNodeIds,
                                                  labelColor: colors.text,
                                                  labelHaloColor: colors.canvas,
                                                  onSemanticNodeTap:
                                                      _handleSemanticNodeTap,
                                                  maximumSemanticNodes:
                                                      renderBudget
                                                          .semanticNodeCount,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned.fill(
                                  child: CustomMultiChildLayout(
                                    delegate: _GraphPositionDelegate(
                                      sceneOrigin: sceneOrigin,
                                      positions: displayPositions,
                                      resolvePositions: !transitioning
                                          ? _currentPositions
                                          : null,
                                      relayout: !transitioning
                                          ? _sphereProjection
                                          : null,
                                      items: flowItems,
                                    ),
                                    children: [
                                      for (final node in orderedNodes)
                                        if (overlayNodeIds.contains(node.id))
                                          LayoutId(
                                            key: ValueKey(
                                              'feed-graph-layout-${node.id}',
                                            ),
                                            id: node.id,
                                            child: node.center
                                                ? _CenterAnchor(
                                                    key: const ValueKey(
                                                      'feed-graph-center-anchor',
                                                    ),
                                                    diameter:
                                                        (nodeRadii[node.id] ??
                                                            7) *
                                                        2,
                                                    color: nodeColors[node.id]!,
                                                    opacity:
                                                        nodeOpacities[node.id]!,
                                                  )
                                                : _NodeHit(
                                                    key: ValueKey(node.id),
                                                    node: node,
                                                    position:
                                                        displayPositions[node
                                                            .id]!,
                                                    resolvePosition: () =>
                                                        _currentPositions()[node
                                                            .id] ??
                                                        displayPositions[node
                                                            .id]!,
                                                    transformationController:
                                                        _transformationController,
                                                    resolveCameraRevision: () =>
                                                        _sphereProjection
                                                            .revision,
                                                    visualRepaint:
                                                        _sphereProjection,
                                                    resolveVisualSize: () =>
                                                        Size.square(
                                                          (nodeRadii[node.id] ??
                                                                  7) *
                                                              2,
                                                        ),
                                                    resolveOpacity: () =>
                                                        nodeOpacities[node
                                                            .id] ??
                                                        1,
                                                    zoomPulse:
                                                        _zoomPulseController,
                                                    visualKind:
                                                        visualKinds[node.id]!,
                                                    labelMaxLines:
                                                        switch (_lod) {
                                                          _GraphLod.far => 1,
                                                          _GraphLod.middle => 3,
                                                          _GraphLod.near => 4,
                                                        },
                                                    visualSize: Size.square(
                                                      (nodeRadii[node.id] ??
                                                              7) *
                                                          2,
                                                    ),
                                                    color: nodeColors[node.id]!,
                                                    opacity:
                                                        nodeOpacities[node.id]!,
                                                    selected:
                                                        node.id ==
                                                        selectedNodeId,
                                                    aggregationBadge:
                                                        aggregationHighlightsActive &&
                                                            node.id ==
                                                                widget
                                                                    .aggregationHotspotNoteId
                                                        ? '热点'
                                                        : null,
                                                    onDragStart: (_) {},
                                                    onDragUpdate: (position) =>
                                                        _updateSphereNodePosition(
                                                          node.id,
                                                          position,
                                                        ),
                                                    onDragEnd: (position) =>
                                                        _commitSphereNodePosition(
                                                          node.id,
                                                          position,
                                                          logicalScale,
                                                        ),
                                                    onDragCancel: (_) {
                                                      _sphereManualPositions
                                                          .remove(node.id);
                                                      _sphereProjection
                                                          .clearManualPosition(
                                                            node.id,
                                                          );
                                                    },
                                                    onTap: widget.onNodeTap,
                                                    onSelectedTap: widget
                                                        .onSelectedNodeTap,
                                                    onLongPress:
                                                        widget.onNodeLongPress,
                                                  ),
                                          ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.showAggregationAction)
                    Positioned(
                      top: viewportToolsTop + 8,
                      right: 20,
                      child: _GraphAggregationTool(
                        enabled:
                            _visualActive &&
                            widget.interactionsEnabled &&
                            !transitioning,
                        onStartAggregation: widget.onStartAggregation,
                      ),
                    ),
                  Positioned.fill(
                    child: V3GraphStatusOverlay(
                      state: transitioning
                          ? GraphLoadingState.building
                          : controller.loadingState,
                      progress: transitioning ? transitionProgress : null,
                      refreshing: controller.isRefreshing,
                      showCompleted: _showBuildCompleted,
                      compactTopInset: compactStatusTop,
                      errorMessage: _graphErrorMessage(
                        controller.graphErrorCode,
                      ),
                      onRetry: controller.retryGraphLoad,
                      onCreate: widget.onCreateContent,
                      onDismissCompleted: () {
                        _completedStatusTimer?.cancel();
                        setState(() => _showBuildCompleted = false);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _requestRemoteGraphLoad() {
    if (!_visualActive) return;
    final controller = ref.read(feedGraphControllerProvider);
    if (identical(_remoteLoadController, controller)) return;
    _remoteLoadController = controller;
    unawaited(
      Future<void>.microtask(() async {
        if (!mounted ||
            !_visualActive ||
            !identical(controller, ref.read(feedGraphControllerProvider))) {
          if (identical(_remoteLoadController, controller)) {
            _remoteLoadController = null;
          }
          return;
        }
        await controller.ensureRemoteGraphLoaded();
      }),
    );
  }

  void _ensureSphereLayout(List<V3GraphNode> nodes) {
    final ids = nodes.map((node) => node.id).toList()..sort();
    if (_sphereTopologyReady && _stringListsEqual(_sphereRealNodeIds, ids))
      return;
    _spherePoints = _sphereSlots.synchronize(ids);
    _sphereVisualLinks = _sphereLayout.buildVisualLinks(points: _spherePoints);
    _sphereProjection.updateTopology(
      SphereGraphRenderTopology.build(
        points: _spherePoints,
        visualLinks: _sphereVisualLinks,
        semanticEdges: const [],
      ),
      notify: false,
    );
    _sphereRealNodeIds = List.unmodifiable(ids);
    _sphereTopologyReady = true;
    final validIds = ids.toSet();
    _sphereManualPositions.removeWhere((id, _) => !validIds.contains(id));
    _motion.configure(
      active: _visualActive,
      suspended:
          !_renderQuality.allowIdleAnimation ||
          _reduceMotion ||
          _isAggregating(widget) ||
          !widget.interactionsEnabled,
      nodeCount: _spherePoints.length,
      maximumFrameRate: _renderQuality.automaticFrameRate,
    );
  }

  void _updateSphereNodePosition(String nodeId, Offset position) {
    if (!position.dx.isFinite || !position.dy.isFinite) return;
    if (_sphereManualPositions[nodeId] == position) return;
    _sphereManualPositions[nodeId] = position;
    _sphereProjection.setManualPosition(nodeId, position);
  }

  void _commitSphereNodePosition(
    String nodeId,
    Offset position,
    Offset logicalScale,
  ) {
    _updateSphereNodePosition(nodeId, position);
    final point = _sphereProjection.commitManualPosition(nodeId);
    if (point != null) _sphereSlots.updatePosition(nodeId, point);
    _sphereManualPositions.remove(nodeId);
    final safeScaleX = logicalScale.dx.abs() > .001 ? logicalScale.dx : 1.0;
    final safeScaleY = logicalScale.dy.abs() > .001 ? logicalScale.dy : 1.0;
    ref
        .read(feedGraphControllerProvider)
        .setNodePosition(
          nodeId,
          Offset(position.dx / safeScaleX, position.dy / safeScaleY),
        );
  }

  void _beginCanvasNodeDrag(
    Offset scenePosition, {
    required List<V3GraphNode> nodes,
    required Set<String> overlayNodeIds,
    required Map<String, double> nodeRadii,
    required Map<String, double> nodeOpacities,
    required Map<String, double> nodeDepths,
  }) {
    if (!_visualActive || _canvasDraggedNodeId != null) return;
    final node = hitTestV3GraphCanvasNode(
      scenePosition: scenePosition,
      nodes: nodes,
      positions: _currentPositions(),
      radii: nodeRadii,
      opacities: nodeOpacities,
      zoom: _currentZoom(),
      depths: nodeDepths,
      excludedNodeIds: overlayNodeIds,
    );
    if (node == null) return;
    final origin = _currentPositions()[node.id];
    if (origin == null) return;
    _canvasDraggedNodeId = node.id;
    _canvasDragOrigin = origin;
    _canvasDragPosition = origin;
    _canvasDragPointerOffset = origin - scenePosition;
    _canvasDragMoved = false;
    _canvasDragHadSphereManualPosition = _sphereManualPositions.containsKey(
      node.id,
    );
    _canvasDragOriginalSphereManualPosition = _sphereManualPositions[node.id];
    setState(() {});
  }

  void _updateCanvasNodeDrag(Offset scenePosition) {
    final nodeId = _canvasDraggedNodeId;
    final origin = _canvasDragOrigin;
    final pointerOffset = _canvasDragPointerOffset;
    if (nodeId == null || origin == null || pointerOffset == null) return;
    final position = scenePosition + pointerOffset;
    if ((position - origin).distance > 4) _canvasDragMoved = true;
    _canvasDragPosition = position;
    _updateSphereNodePosition(nodeId, position);
  }

  void _endCanvasNodeDrag({required Offset logicalScale}) {
    final nodeId = _canvasDraggedNodeId;
    final position = _canvasDragPosition;
    final moved = _canvasDragMoved;
    if (nodeId == null || position == null) return;
    if (!moved) {
      _cancelCanvasNodeDrag();
      final controller = ref.read(feedGraphControllerProvider);
      controller.selectNode(nodeId);
      final node = controller.nodeForId(nodeId);
      if (node != null) widget.onNodeLongPress?.call(node);
      return;
    }
    _commitSphereNodePosition(nodeId, position, logicalScale);
    _clearCanvasDragState(rebuild: true);
  }

  void _cancelCanvasNodeDrag({bool rebuild = true}) {
    final nodeId = _canvasDraggedNodeId;
    if (nodeId == null) return;
    final original = _canvasDragOriginalSphereManualPosition;
    if (_canvasDragHadSphereManualPosition && original != null) {
      _sphereManualPositions[nodeId] = original;
      _sphereProjection.setManualPosition(nodeId, original, notify: rebuild);
    } else {
      _sphereManualPositions.remove(nodeId);
      _sphereProjection.clearManualPosition(nodeId, notify: rebuild);
    }
    _clearCanvasDragState(rebuild: rebuild);
  }

  void _clearCanvasDragState({required bool rebuild}) {
    _canvasDraggedNodeId = null;
    _canvasDragOrigin = null;
    _canvasDragPointerOffset = null;
    _canvasDragPosition = null;
    _canvasDragMoved = false;
    _canvasDragHadSphereManualPosition = false;
    _canvasDragOriginalSphereManualPosition = null;
    if (rebuild && mounted) setState(() {});
  }

  Matrix4 _homeTransformation() =>
      Matrix4.translationValues(-_scenePadding, -_scenePadding, 0);

  void _resetTransformation() {
    _hasUserTransformed = false;
    final graphSize = _lastGraphSize;
    final targetRect = _lastHomeTargetRect;
    if (graphSize == null || targetRect == null) {
      _transformationController.value = _homeTransformation();
      return;
    }
    final next = v3GraphFitTransformation(
      viewportSize: graphSize,
      positions: _fitPositionsForActiveMode(),
      sceneOrigin: _lastSceneOrigin,
      targetRect: targetRect,
      nodePadding: _lastHomeNodePadding,
    );
    _resolvedHomeTransformation = next;
    _transformationController.value = next;
  }

  void _scheduleHomeFit() {
    if (_homeFitScheduled || _hasUserTransformed) return;
    final graphSize = _lastGraphSize;
    final targetRect = _lastHomeTargetRect;
    if (graphSize == null || targetRect == null) return;
    _homeFitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeFitScheduled = false;
      if (!mounted || _hasUserTransformed) return;
      final next = v3GraphFitTransformation(
        viewportSize: graphSize,
        positions: _fitPositionsForActiveMode(),
        sceneOrigin: _lastSceneOrigin,
        targetRect: targetRect,
        nodePadding: _lastHomeNodePadding,
      );
      _resolvedHomeTransformation = next;
      _transformationController.value = next;
    });
  }

  void _resetGraph({bool replayPulse = true}) {
    ref.read(feedGraphControllerProvider).resetView();
    setState(() {
      _hasUserTransformed = false;
      _pendingHomeCameraFit = true;
      _sphereRotationX = _initialSphereRotationX;
      _sphereRotationY = _initialSphereRotationY;
    });
    if (!_sphereProjection.viewport.isEmpty) {
      _projectSphere(viewport: _sphereProjection.viewport);
    }
    if (replayPulse) _replayNodePulse();
  }

  Iterable<Offset> _fitPositionsForActiveMode() => _sphereFitPositions;

  double _currentZoom() {
    final scale = v3GraphViewportScale(_transformationController.value);
    return scale.isFinite && scale > .001 ? scale : 1.0;
  }

  Map<String, Offset> _currentPositions() => _displayPositions;

  void _handleCanvasTap(
    Offset scenePosition, {
    required List<V3GraphNode> nodes,
    required Set<String> overlayNodeIds,
    required Map<String, double> nodeRadii,
    required Map<String, double> nodeOpacities,
    required Map<String, double> nodeDepths,
  }) {
    final canvasNode = hitTestV3GraphCanvasNode(
      scenePosition: scenePosition,
      nodes: nodes,
      positions: _currentPositions(),
      radii: nodeRadii,
      opacities: nodeOpacities,
      zoom: _currentZoom(),
      depths: nodeDepths,
      excludedNodeIds: overlayNodeIds,
    );
    if (canvasNode != null) {
      _handleSemanticNodeTap(canvasNode.id);
      return;
    }
    ref.read(feedGraphControllerProvider).clearSelection();
    widget.onCanvasTap?.call();
  }

  void _handleSemanticNodeTap(String nodeId) {
    final controller = ref.read(feedGraphControllerProvider);
    final node = controller.nodeForId(nodeId);
    if (node == null) return;
    final alreadySelected = controller.selectedNodeId == node.id;
    controller.selectNode(node.id);
    if (alreadySelected) {
      (widget.onSelectedNodeTap ?? widget.onNodeTap)?.call(node);
    } else {
      widget.onNodeTap?.call(node);
    }
  }

  bool _hasCanvasTarget(
    Offset scenePosition, {
    required List<V3GraphNode> nodes,
    required Set<String> overlayNodeIds,
    required Map<String, double> nodeRadii,
    required Map<String, double> nodeOpacities,
    required Map<String, double> nodeDepths,
  }) {
    return hitTestV3GraphCanvasNode(
          scenePosition: scenePosition,
          nodes: nodes,
          positions: _currentPositions(),
          radii: nodeRadii,
          opacities: nodeOpacities,
          zoom: _currentZoom(),
          depths: nodeDepths,
          excludedNodeIds: overlayNodeIds,
        ) !=
        null;
  }

  Set<String> _importantNodeIds(List<V3GraphNode> nodes) {
    final ranked = nodes.where((node) => !node.center).toList()
      ..sort((left, right) {
        final weight = right.weight.compareTo(left.weight);
        if (weight != 0) return weight;
        final updated = (right.updatedAt?.millisecondsSinceEpoch ?? 0)
            .compareTo(left.updatedAt?.millisecondsSinceEpoch ?? 0);
        if (updated != 0) return updated;
        return left.id.compareTo(right.id);
      });
    final count = math.min(
      25,
      math.min(ranked.length, math.max(15, (ranked.length * .4).round())),
    );
    return ranked.take(count).map((node) => node.id).toSet();
  }

  Set<String> _labeledNodeIds({
    required List<V3GraphNode> nodes,
    required Map<String, double> nodeDepths,
    required String? selectedNodeId,
    required Set<String> firstDegreeNodeIds,
    required String searchQuery,
    required List<V3GraphNode> searchResults,
    required int ordinaryLimit,
    required int priorityLimit,
  }) {
    final result = <String>{};
    bool frontFacing(V3GraphNode node) => (nodeDepths[node.id] ?? .5) >= .54;
    if (_lod == _GraphLod.far) {
      final ranked =
          nodes.where((node) => !node.center && frontFacing(node)).toList()
            ..sort((left, right) {
              final weight = right.weight.compareTo(left.weight);
              if (weight != 0) return weight;
              final updated = (right.updatedAt?.millisecondsSinceEpoch ?? 0)
                  .compareTo(left.updatedAt?.millisecondsSinceEpoch ?? 0);
              if (updated != 0) return updated;
              return left.id.compareTo(right.id);
            });
      result.addAll(ranked.take(ordinaryLimit).map((node) => node.id));
    } else if (_lod == _GraphLod.near) {
      if (ordinaryLimit > 0) {
        result.addAll(
          nodes
              .where((node) => !node.center && frontFacing(node))
              .map((node) => node.id),
        );
      }
    } else if (_lod == _GraphLod.middle) {
      for (final cluster in V3GraphCluster.values) {
        final ranked =
            nodes
                .where(
                  (node) =>
                      !node.center &&
                      node.cluster == cluster &&
                      frontFacing(node),
                )
                .toList()
              ..sort((left, right) {
                final weight = right.weight.compareTo(left.weight);
                if (weight != 0) return weight;
                final updated = (right.updatedAt?.millisecondsSinceEpoch ?? 0)
                    .compareTo(left.updatedAt?.millisecondsSinceEpoch ?? 0);
                if (updated != 0) return updated;
                return left.id.compareTo(right.id);
              });
        if (ranked.isNotEmpty && result.length < ordinaryLimit) {
          result.add(ranked.first.id);
        }
      }
    }

    final priority = <String>[];
    void addPriority(String id) {
      if (!priority.contains(id)) priority.add(id);
    }

    if (selectedNodeId != null) {
      addPriority(selectedNodeId);
      final stableFirstDegree = firstDegreeNodeIds.toList()..sort();
      for (final id in stableFirstDegree) {
        addPriority(id);
      }
    }
    if (searchQuery.trim().isNotEmpty) {
      for (final node in searchResults) {
        addPriority(node.id);
      }
    }
    result.addAll(priority.take(priorityLimit));
    return result;
  }

  Offset _positionForTransition({
    required V3GraphNode node,
    required Offset start,
    required Offset hub,
    required Offset end,
    required double progress,
  }) {
    if (node.center) {
      return Offset.lerp(
            start,
            end,
            Curves.easeInOutCubic.transform(progress),
          ) ??
          end;
    }
    return _aggregationPath(
      start: start,
      hub: hub,
      end: end,
      progress: progress,
      seed: _seed(node.id),
    );
  }
}

Matrix4 v3GraphFitTransformation({
  required Size viewportSize,
  required Iterable<Offset> positions,
  required Offset sceneOrigin,
  required Rect targetRect,
  double nodePadding = 18,
  double minScale = .82,
  double maxScale = 1,
}) {
  final finitePositions = positions
      .where((position) => position.dx.isFinite && position.dy.isFinite)
      .toList(growable: false);
  final usableTarget = targetRect.intersect(Offset.zero & viewportSize);
  if (finitePositions.isEmpty ||
      usableTarget.width <= 0 ||
      usableTarget.height <= 0) {
    return Matrix4.translationValues(-sceneOrigin.dx, -sceneOrigin.dy, 0);
  }
  var left = finitePositions.first.dx;
  var right = left;
  var top = finitePositions.first.dy;
  var bottom = top;
  for (final position in finitePositions.skip(1)) {
    left = math.min(left, position.dx);
    right = math.max(right, position.dx);
    top = math.min(top, position.dy);
    bottom = math.max(bottom, position.dy);
  }
  final safePadding = nodePadding.isFinite
      ? nodePadding.clamp(0.0, 80.0).toDouble()
      : 18.0;
  final bounds = Rect.fromLTRB(left, top, right, bottom).inflate(safePadding);
  final width = math.max(bounds.width, 1.0);
  final height = math.max(bounds.height, 1.0);
  final lowerScale = minScale.isFinite && minScale > 0 ? minScale : .82;
  final upperScale = maxScale.isFinite && maxScale >= lowerScale
      ? maxScale
      : lowerScale;
  final scale = math
      .min(usableTarget.width / width, usableTarget.height / height)
      .clamp(lowerScale, upperScale)
      .toDouble();
  final sceneCenter = bounds.center + sceneOrigin;
  final translation = usableTarget.center - sceneCenter * scale;
  return Matrix4.diagonal3Values(scale, scale, 1)
    ..setTranslationRaw(translation.dx, translation.dy, 0);
}

enum _GraphLod { far, middle, near }

enum _GraphNodeVisualKind { dot, importantDot, contextDot, label }

GraphGeometryLod _geometryLod(_GraphLod lod) => switch (lod) {
  _GraphLod.far => GraphGeometryLod.far,
  _GraphLod.middle => GraphGeometryLod.middle,
  _GraphLod.near => GraphGeometryLod.near,
};

String? _graphErrorMessage(String? code) => switch (code) {
  null => null,
  'GRAPH_ID_INVALID' => '图谱标识无效',
  'GRAPH_SNAPSHOT_MALFORMED' => '图谱数据暂时无法解析',
  'GRAPH_SNAPSHOT_LOAD_FAILED' => '图谱加载失败，请稍后重试',
  _ => '图谱暂时无法加载',
};

_GraphLod _lodForScale(double scale) {
  if (scale < 1.12) return _GraphLod.far;
  if (scale < 1.78) return _GraphLod.middle;
  return _GraphLod.near;
}

Color _graphMarkerColorFor(V3GraphNode node, List<Color> palette) {
  final effectivePalette = palette.isEmpty
      ? HuahuoV3Theme.graphPaletteFor(HuahuoV3Theme.lightTokens)
      : palette;
  if (node.center) return effectivePalette.first;
  if (node.isHotspot || node.isAggregated) {
    return effectivePalette[math.min(3, effectivePalette.length - 1)];
  }
  return v3GraphEntityColorFor(node.entityType, effectivePalette);
}

Color v3GraphEntityColorFor(String entityType, [List<Color>? colors]) {
  final palette = colors == null || colors.isEmpty
      ? HuahuoV3Theme.graphPaletteFor(HuahuoV3Theme.lightTokens)
      : colors;
  final normalized = canonicalGraphEntityType(entityType);
  final localIndex = switch (normalized) {
    '观点' || 'Viewpoint' || '人物' || 'Person' => 0,
    '行业' || 'Industry' || '组织' || 'Organization' => 1,
    '方法' || '趋势' || '主题' || 'Method' || 'Trend' || 'Topic' => 2,
    '案例' || '项目' || '产品' || 'Case' || 'Project' || 'Product' => 3,
    '灵感' || 'Inspiration' => 4,
    _ => null,
  };
  if (localIndex != null) return palette[localIndex];
  var hash = 0x811C9DC5;
  for (final unit in normalized.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return palette[hash % palette.length];
}

double _nodeOpacity({
  required V3GraphNode node,
  required String? selectedNodeId,
  required Set<String> firstDegreeNodeIds,
  required Set<String> secondDegreeNodeIds,
  required V3GraphCluster? focusedCluster,
  required bool matchesFilter,
  required bool matchesEntityType,
  required bool searchActive,
  required bool matchesSearch,
  required V3GraphEdge? selectedEdge,
  required double aggregationOpacity,
}) {
  var opacity = aggregationOpacity;
  if (selectedNodeId != null) {
    if (firstDegreeNodeIds.contains(node.id)) {
      opacity = math.min(opacity, .86);
    } else if (secondDegreeNodeIds.contains(node.id)) {
      opacity = math.min(opacity, .52);
    } else if (node.id != selectedNodeId) {
      opacity = math.min(opacity, .18);
    }
  }
  if (selectedEdge != null) {
    final endpoint =
        node.id == selectedEdge.sourceId || node.id == selectedEdge.targetId;
    if (!endpoint) opacity = math.min(opacity, .18);
  }
  if (focusedCluster != null &&
      !node.center &&
      node.cluster != focusedCluster) {
    opacity = math.min(opacity, .24);
  }
  if (!matchesFilter || !matchesEntityType) {
    opacity = math.min(opacity, .24);
  }
  if (searchActive && !node.center && !matchesSearch) {
    opacity = math.min(opacity, .20);
  }
  if (node.id == selectedNodeId ||
      selectedEdge != null &&
          (node.id == selectedEdge.sourceId ||
              node.id == selectedEdge.targetId)) {
    opacity = 1;
  }
  return opacity.clamp(0.0, 1.0).toDouble();
}

_GraphNodeVisualKind _visualKindFor({
  required V3GraphNode node,
  required Set<String> labeledNodeIds,
  required Set<String> importantNodeIds,
  required String? selectedNodeId,
  required Set<String> firstDegreeNodeIds,
  required Set<String> secondDegreeNodeIds,
}) {
  if (node.id == selectedNodeId || labeledNodeIds.contains(node.id)) {
    return _GraphNodeVisualKind.label;
  }
  if (firstDegreeNodeIds.contains(node.id) ||
      secondDegreeNodeIds.contains(node.id)) {
    return _GraphNodeVisualKind.contextDot;
  }
  if (importantNodeIds.contains(node.id)) {
    return _GraphNodeVisualKind.importantDot;
  }
  return _GraphNodeVisualKind.dot;
}

const _graphLogicalSize = Size(900, 860);

Offset _aggregationPath({
  required Offset start,
  required Offset hub,
  required Offset end,
  required double progress,
  required double seed,
}) {
  const rotationPhaseEnd = .35;
  const collapsePhaseEnd = .60;
  final value = progress.clamp(0.0, 1.0).toDouble();
  if (value <= rotationPhaseEnd) {
    final turn = Curves.easeInOutCubic.transform(value / rotationPhaseEnd);
    return hub + _rotateVector(start - hub, math.pi * (2.75 + seed) * turn);
  }
  if (value <= collapsePhaseEnd) {
    final collapse = Curves.easeInCubic.transform(
      (value - rotationPhaseEnd) / (collapsePhaseEnd - rotationPhaseEnd),
    );
    final rotated = _rotateVector(start - hub, math.pi * (2.75 + seed));
    return hub + _rotateVector(rotated, math.pi * collapse) * (1 - collapse);
  }
  final expand = Curves.easeOutCubic.transform(
    (value - collapsePhaseEnd) / (1 - collapsePhaseEnd),
  );
  return Offset.lerp(hub, end, expand) ?? end;
}

Offset _rotateVector(Offset vector, double angle) {
  final cosAngle = math.cos(angle);
  final sinAngle = math.sin(angle);
  return Offset(
    vector.dx * cosAngle - vector.dy * sinAngle,
    vector.dx * sinAngle + vector.dy * cosAngle,
  );
}

double _noteTagOpacity(double progress) {
  if (progress <= .28) return 1;
  if (progress < .56) {
    return 1 - Curves.easeInCubic.transform((progress - .28) / .28);
  }
  if (progress < .72) return 0;
  return Curves.easeOutCubic.transform((progress - .72) / .28);
}

double _seed(String value) {
  var hash = 0x811C9DC5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return (hash % 10000) / 10000;
}

final class _GraphFlowItem {
  const _GraphFlowItem(this.nodeId, this.size);

  final String nodeId;
  final Size size;
}

final class _GraphPositionDelegate extends MultiChildLayoutDelegate {
  _GraphPositionDelegate({
    required this.sceneOrigin,
    required this.positions,
    required this.resolvePositions,
    required super.relayout,
    required this.items,
  });

  final Offset sceneOrigin;
  final Map<String, Offset> positions;
  final Map<String, Offset> Function()? resolvePositions;
  final List<_GraphFlowItem> items;

  @override
  void performLayout(Size size) {
    final resolvedPositions = resolvePositions?.call() ?? positions;
    for (final item in items) {
      if (!hasChild(item.nodeId)) continue;
      layoutChild(item.nodeId, BoxConstraints.tight(item.size));
      final position =
          (resolvedPositions[item.nodeId] ?? Offset.zero) + sceneOrigin;
      positionChild(
        item.nodeId,
        Offset(
          position.dx - item.size.width / 2,
          position.dy - item.size.height / 2,
        ),
      );
    }
  }

  @override
  bool shouldRelayout(covariant _GraphPositionDelegate oldDelegate) =>
      oldDelegate.sceneOrigin != sceneOrigin ||
      !_mapEquals(oldDelegate.positions, positions) ||
      !_flowItemsEqual(oldDelegate.items, items);
}

bool _flowItemsEqual(List<_GraphFlowItem> left, List<_GraphFlowItem> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index].nodeId != right[index].nodeId ||
        left[index].size != right[index].size) {
      return false;
    }
  }
  return true;
}

class _CanvasLongPressGestureLayer extends StatelessWidget {
  const _CanvasLongPressGestureLayer({
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<LongPressStartDetails> onStart;
  final ValueChanged<LongPressMoveUpdateDetails> onUpdate;
  final ValueChanged<LongPressEndDetails> onEnd;
  final VoidCallback onCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: V3InteractionTimingTokens.graphLongPress,
              ),
              (recognizer) => recognizer
                ..onLongPressStart = onStart
                ..onLongPressMoveUpdate = onUpdate
                ..onLongPressEnd = onEnd
                ..onLongPressCancel = onCancel,
            ),
      },
      child: child,
    );
  }
}

class _NodeHit extends ConsumerStatefulWidget {
  const _NodeHit({
    required this.node,
    required this.position,
    required this.resolvePosition,
    required this.transformationController,
    required this.resolveCameraRevision,
    required this.zoomPulse,
    required this.visualKind,
    required this.labelMaxLines,
    required this.visualSize,
    required this.color,
    required this.opacity,
    required this.selected,
    required this.aggregationBadge,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required this.onTap,
    required this.onSelectedTap,
    required this.onLongPress,
    this.visualRepaint,
    this.resolveVisualSize,
    this.resolveOpacity,
    super.key,
  });

  final V3GraphNode node;
  final Offset position;
  final Offset Function() resolvePosition;
  final TransformationController transformationController;
  final int Function() resolveCameraRevision;
  final Animation<double> zoomPulse;
  final _GraphNodeVisualKind visualKind;
  final int labelMaxLines;
  final Size visualSize;
  final Color color;
  final double opacity;
  final bool selected;
  final String? aggregationBadge;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<Offset> onDragEnd;
  final ValueChanged<Offset> onDragCancel;
  final ValueChanged<V3GraphNode>? onTap;
  final ValueChanged<V3GraphNode>? onSelectedTap;
  final ValueChanged<V3GraphNode>? onLongPress;
  final Listenable? visualRepaint;
  final Size Function()? resolveVisualSize;
  final double Function()? resolveOpacity;

  @override
  ConsumerState<_NodeHit> createState() => _NodeHitState();
}

class _NodeHitState extends ConsumerState<_NodeHit> {
  static const _tapSlop = 8.0;

  Offset? _longPressOrigin;
  Offset? _longPressPosition;
  bool _longPressMoved = false;
  int? _tapPointer;
  Offset? _tapDownPosition;
  Matrix4? _tapDownTransform;
  int? _tapDownCameraRevision;
  bool _tapMoved = false;
  bool _suppressTap = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    const hitSize = Size.square(30);
    return Semantics(
      container: true,
      button: true,
      excludeSemantics: true,
      label: '知识笔记：${node.label}',
      hint: '${node.cluster.label}，${node.summary}',
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: V3InteractionTimingTokens.graphLongPress,
                  ),
                  (recognizer) => recognizer
                    ..onLongPressStart = _beginLongPressDrag
                    ..onLongPressMoveUpdate = _updateLongPressDrag
                    ..onLongPressEnd = _endLongPressDrag
                    ..onLongPressCancel = _cancelLongPressDrag,
                ),
          },
          child: SizedBox.fromSize(
            size: hitSize,
            child: Center(
              child: widget.visualRepaint == null
                  ? _buildVisual(node)
                  : AnimatedBuilder(
                      animation: widget.visualRepaint!,
                      builder: (context, _) => _buildVisual(node),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVisual(V3GraphNode node) => _GraphNodeVisual(
    node: node,
    kind: widget.visualKind,
    labelMaxLines: widget.labelMaxLines,
    size: widget.resolveVisualSize?.call() ?? widget.visualSize,
    color: widget.color,
    selected: widget.selected,
    opacity: widget.resolveOpacity?.call() ?? widget.opacity,
    aggregationBadge: widget.aggregationBadge,
    transformationController: widget.transformationController,
    zoomPulse: widget.zoomPulse,
  );

  void _openFromTap() {
    final controller = ref.read(feedGraphControllerProvider);
    final alreadySelected = controller.selectedNodeId == widget.node.id;
    controller.selectNode(widget.node.id);
    if (alreadySelected) {
      (widget.onSelectedTap ?? widget.onTap)?.call(widget.node);
    } else {
      widget.onTap?.call(widget.node);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_tapPointer != null) {
      _suppressTap = true;
      return;
    }
    _tapPointer = event.pointer;
    _tapDownPosition = event.position;
    _tapDownTransform = widget.transformationController.value.clone();
    _tapDownCameraRevision = widget.resolveCameraRevision();
    _tapMoved = false;
    _suppressTap = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _tapPointer || _tapDownPosition == null) return;
    if ((event.position - _tapDownPosition!).distance > _tapSlop) {
      _tapMoved = true;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _tapPointer) {
      return;
    }
    final shouldOpen =
        !_tapMoved &&
        !_suppressTap &&
        _tapDownCameraRevision == widget.resolveCameraRevision() &&
        _matrixNear(_tapDownTransform, widget.transformationController.value);
    _clearTapPointer();
    if (shouldOpen) _openFromTap();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _tapPointer) {
      return;
    }
    _clearTapPointer();
  }

  void _clearTapPointer() {
    _tapPointer = null;
    _tapDownPosition = null;
    _tapDownTransform = null;
    _tapDownCameraRevision = null;
    _tapMoved = false;
    _suppressTap = false;
  }

  void _beginLongPressDrag(LongPressStartDetails details) {
    _suppressTap = true;
    final currentPosition = widget.resolvePosition();
    _longPressOrigin = currentPosition;
    _longPressPosition = currentPosition;
    _longPressMoved = false;
    widget.onDragStart(currentPosition);
  }

  void _updateLongPressDrag(LongPressMoveUpdateDetails details) {
    final origin = _longPressOrigin;
    if (origin == null) return;
    final viewportScale = v3GraphViewportScale(
      widget.transformationController.value,
    );
    final safeViewportScale = viewportScale.isFinite && viewportScale > .001
        ? viewportScale
        : 1.0;
    final canvasDelta = details.offsetFromOrigin / safeViewportScale;
    if (canvasDelta.distance > 4) _longPressMoved = true;
    final position = origin + canvasDelta;
    _longPressPosition = position;
    widget.onDragUpdate(position);
  }

  void _endLongPressDrag(LongPressEndDetails details) {
    final moved = _longPressMoved;
    final finalPosition = _longPressPosition;
    _longPressOrigin = null;
    _longPressPosition = null;
    _longPressMoved = false;
    if (!moved || finalPosition == null) {
      if (finalPosition != null) widget.onDragCancel(finalPosition);
      ref.read(feedGraphControllerProvider).selectNode(widget.node.id);
      widget.onLongPress?.call(widget.node);
      return;
    }
    widget.onDragEnd(finalPosition);
  }

  void _cancelLongPressDrag() {
    _suppressTap = true;
    final origin = _longPressOrigin;
    _longPressOrigin = null;
    _longPressPosition = null;
    _longPressMoved = false;
    if (origin != null) widget.onDragCancel(origin);
  }
}

bool _matrixNear(Matrix4? left, Matrix4 right) {
  if (left == null) return false;
  for (var index = 0; index < 16; index++) {
    if ((left.storage[index] - right.storage[index]).abs() > .001) return false;
  }
  return true;
}

class _GraphNodeVisual extends StatelessWidget {
  const _GraphNodeVisual({
    required this.node,
    required this.kind,
    required this.labelMaxLines,
    required this.size,
    required this.color,
    required this.selected,
    required this.opacity,
    required this.aggregationBadge,
    required this.transformationController,
    required this.zoomPulse,
  });

  final V3GraphNode node;
  final _GraphNodeVisualKind kind;
  final int labelMaxLines;
  final Size size;
  final Color color;
  final bool selected;
  final double opacity;
  final String? aggregationBadge;
  final TransformationController transformationController;
  final Animation<double> zoomPulse;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final showLabel = kind == _GraphNodeVisualKind.label;
    final labelWidth = switch (labelMaxLines) {
      1 => selected ? 88.0 : 76.0,
      3 => selected ? 160.0 : 144.0,
      _ => selected ? 196.0 : 180.0,
    };
    final badge = aggregationBadge;
    final angle = math.pi * 2 * _seed('${node.id}:entrance');
    final outward = Offset(math.cos(angle), math.sin(angle)) * 10;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: V3MotionTokens.graphEntrance,
      curve: Curves.easeOutCubic,
      builder: (context, entrance, child) => Opacity(
        opacity: entrance,
        child: Transform.translate(
          offset: outward * (1 - entrance),
          child: Transform.scale(scale: .88 + .12 * entrance, child: child),
        ),
      ),
      child: AnimatedBuilder(
        animation: zoomPulse,
        builder: (context, child) {
          final pulse = Curves.easeOutCubic.transform(zoomPulse.value);
          return Opacity(
            key: ValueKey('feed-graph-node-zoom-effect-${node.id}'),
            opacity: .62 + .38 * pulse,
            child: Transform.translate(
              key: ValueKey('feed-graph-node-pulse-offset-${node.id}'),
              offset: outward * .8 * (1 - pulse),
              child: Transform.scale(
                key: ValueKey('feed-graph-node-pulse-scale-${node.id}'),
                scale: .86 + .14 * pulse,
                child: child,
              ),
            ),
          );
        },
        child: Opacity(
          key: ValueKey('feed-graph-node-opacity-${node.id}'),
          opacity: opacity.clamp(0.0, 1.0).toDouble(),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                painter: _NodeStateRingPainter(
                  color: color,
                  selected: selected,
                  hotspot: node.isHotspot,
                  aggregated: node.isAggregated,
                  label: false,
                ),
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          key: ValueKey('feed-graph-node-marker-${node.id}'),
                          painter: _LuminousNodePainter(
                            color: color,
                            selected: selected,
                          ),
                        ),
                      ),
                      if (showLabel)
                        Positioned(
                          left: (size.width - labelWidth) / 2,
                          top: size.height + 3,
                          child: _ScaleStableNodeLabel(
                            node: node,
                            width: labelWidth,
                            maxLines: labelMaxLines,
                            transformationController: transformationController,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  right: -7,
                  top: -9,
                  child: Builder(
                    builder: (context) {
                      final background = badge == '热点'
                          ? colors.warmGlass.rim
                          : colors.ink;
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: colors.surface, width: 1.5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(
                              color: HuahuoV3Theme.contrastingForeground(
                                colors.ink,
                                background: background,
                              ),
                              fontSize: 8,
                              height: 1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScaleStableNodeLabel extends StatelessWidget {
  const _ScaleStableNodeLabel({
    required this.node,
    required this.width,
    required this.maxLines,
    required this.transformationController,
  });

  final V3GraphNode node;
  final double width;
  final int maxLines;
  final TransformationController transformationController;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: transformationController,
        child: SizedBox(
          key: ValueKey('feed-graph-label-bounds-${node.id}'),
          width: width,
          height: switch (maxLines) {
            1 => 14,
            2 => 24,
            3 => 34,
            _ => 44,
          },
          child: Text(
            node.label,
            key: ValueKey('feed-graph-node-label-${node.id}'),
            textAlign: TextAlign.center,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontSize: 9,
              height: 1.15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              shadows: [Shadow(color: colors.canvas, blurRadius: 3)],
            ),
          ),
        ),
        builder: (context, child) {
          final scale = v3GraphViewportScale(transformationController.value);
          final safeScale = scale.isFinite && scale > .001 ? scale : 1.0;
          return Transform.scale(
            key: ValueKey('feed-graph-node-label-scale-${node.id}'),
            scale: 1 / safeScale,
            alignment: Alignment.topCenter,
            child: child,
          );
        },
      ),
    );
  }
}

double v3GraphViewportScale(Matrix4 transform) {
  final values = transform.storage;
  final horizontal = math.sqrt(values[0] * values[0] + values[1] * values[1]);
  final vertical = math.sqrt(values[4] * values[4] + values[5] * values[5]);
  return math.max(horizontal, vertical);
}

final class _LuminousNodePainter extends CustomPainter {
  const _LuminousNodePainter({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final strength = selected ? 1.0 : .78;
    canvas.drawCircle(
      center,
      radius * .76,
      Paint()
        ..style = PaintingStyle.fill
        ..maskFilter = ui.MaskFilter.blur(
          BlurStyle.normal,
          math.max(
            V3GraphEffectTokens.outerNodeHaloMinimumSigma,
            radius * V3GraphEffectTokens.outerNodeHaloRadiusFactor,
          ),
        )
        ..color = color.withValues(alpha: .44 * strength),
    );
    canvas.drawCircle(
      center,
      radius * .48,
      Paint()
        ..style = PaintingStyle.fill
        ..maskFilter = ui.MaskFilter.blur(
          BlurStyle.normal,
          math.max(
            V3GraphEffectTokens.innerNodeHaloMinimumSigma,
            radius * V3GraphEffectTokens.innerNodeHaloRadiusFactor,
          ),
        )
        ..color = color.withValues(alpha: .9 * strength),
    );
    canvas.drawCircle(
      center,
      radius * .33,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
    canvas.drawCircle(
      center,
      radius * .17,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Color.lerp(color, Colors.white, .78)!,
    );
    canvas.drawCircle(
      center - Offset(radius * .06, radius * .06),
      math.max(.45, radius * .055),
      Paint()..color = Colors.white.withValues(alpha: .92),
    );
  }

  @override
  bool shouldRepaint(covariant _LuminousNodePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.selected != selected;
}

class _NodeStateRingPainter extends CustomPainter {
  const _NodeStateRingPainter({
    required this.color,
    required this.selected,
    required this.hotspot,
    required this.aggregated,
    required this.label,
  });

  final Color color;
  final bool selected;
  final bool hotspot;
  final bool aggregated;
  final bool label;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    RRect ring(double inset) => RRect.fromRectAndRadius(
      outer.deflate(inset),
      Radius.circular(label ? 9 : size.shortestSide / 2),
    );
    if (selected || hotspot) {
      canvas.drawRRect(
        ring(.6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: selected ? .90 : .68),
      );
      canvas.drawRRect(
        ring(3.2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8
          ..color = color.withValues(alpha: selected ? .48 : .34),
      );
    }
    if (aggregated) {
      final path = Path()..addRRect(ring(1.8));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .9
        ..color = color.withValues(alpha: .72);
      for (final metric in path.computeMetrics()) {
        for (var distance = 0.0; distance < metric.length; distance += 5) {
          canvas.drawPath(
            metric.extractPath(
              distance,
              math.min(distance + 2.8, metric.length),
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NodeStateRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.hotspot != hotspot ||
      oldDelegate.aggregated != aggregated ||
      oldDelegate.label != label;
}

class _CenterAnchor extends StatelessWidget {
  const _CenterAnchor({
    required this.diameter,
    required this.color,
    required this.opacity,
    super.key,
  });

  final double diameter;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: Center(
          child: Container(
            key: const ValueKey('feed-graph-center-dot'),
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.surface.withValues(alpha: .52),
                width: .7,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: .5),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            foregroundDecoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  Colors.white.withValues(alpha: .88),
                  Color.lerp(color, Colors.white, .45)!.withValues(alpha: .54),
                  Colors.transparent,
                ],
                stops: const <double>[0, .26, .72],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GraphAggregationTool extends StatelessWidget {
  const _GraphAggregationTool({
    required this.enabled,
    required this.onStartAggregation,
  });

  final bool enabled;
  final VoidCallback? onStartAggregation;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '开始聚合',
    enabled: enabled,
    child: Tooltip(
      message: '开始聚合',
      child: V3LiquidGlassSurface(
        key: const ValueKey('feed-graph-aggregate'),
        style: V3GlassSurfaceStyle.subtle,
        borderRadius: 14,
        opacity: .68,
        padding: EdgeInsets.zero,
        child: SizedBox.square(
          dimension: 44,
          child: IconButton(
            onPressed: enabled ? onStartAggregation : null,
            tooltip: null,
            padding: EdgeInsets.zero,
            icon: const Icon(
              LucideIcons.blend,
              key: ValueKey('feed-graph-aggregation-glyph'),
              size: 21,
            ),
          ),
        ),
      ),
    ),
  );
}

double _aggregationSelectionOpacity({
  required String nodeId,
  required double baseOpacity,
  required bool selecting,
  required Set<String> participantIds,
}) {
  if (!selecting) return baseOpacity;
  if (participantIds.contains(nodeId)) return 1;
  return math.min(baseOpacity, .18);
}

@visibleForTesting
double v3GraphEdgeOpacity({
  required V3GraphEdge edge,
  required String? selectedNodeId,
}) {
  if (selectedNodeId == edge.sourceId || selectedNodeId == edge.targetId) {
    return .60;
  }
  if (selectedNodeId != null) return .11;
  return switch (edge.kind) {
    V3GraphRelationKind.membership => .09,
    V3GraphRelationKind.communityAffinity => .19,
    V3GraphRelationKind.linkedMaterial => .28,
    V3GraphRelationKind.sharedTopic ||
    V3GraphRelationKind.sharedContentLine ||
    V3GraphRelationKind.other => .24,
  };
}

bool _mapEquals<T>(Map<String, T> left, Map<String, T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

@visibleForTesting
Offset v3GraphEdgeControlPoint({
  required Offset from,
  required Offset to,
  required V3GraphEdge edge,
}) {
  final vector = to - from;
  final distance = vector.distance;
  if (distance < .1) return Offset.lerp(from, to, .5) ?? from;
  final bend = _edgeBend(from: from, to: to, edge: edge);
  final normal = Offset(-vector.dy / distance, vector.dx / distance);
  return (from + to) / 2 + normal * bend;
}

double _edgeBend({
  required Offset from,
  required Offset to,
  required V3GraphEdge edge,
}) {
  final distance = (to - from).distance;
  if (distance < .1) return 0;
  final seed = _seed('${edge.sourceId}:${edge.targetId}:${edge.kind.name}');
  final direction = seed >= .5 ? 1.0 : -1.0;
  final variation = .78 + seed * .22;
  final magnitude = (distance * .052 * variation).clamp(4.0, 16.0);
  return magnitude * direction;
}
