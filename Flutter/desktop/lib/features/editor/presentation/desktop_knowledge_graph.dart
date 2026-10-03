import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../application/desktop_graph_physics_simulation.dart';
import '../application/desktop_graph_preferences.dart';
import '../application/desktop_radial_graph_layout.dart';
import '../application/desktop_sphere_graph_layout.dart';

enum DesktopGraphViewMode { flat, sphere }

final class DesktopGraphSelection {
  const DesktopGraphSelection({
    required this.id,
    required this.label,
    required this.isBrain,
  });

  final String id;
  final String label;
  final bool isBrain;
}

class DesktopKnowledgeGraph extends StatefulWidget {
  const DesktopKnowledgeGraph({
    required this.documents,
    required this.onOpenDocument,
    required this.onOpenReference,
    required this.onSelectionChanged,
    required this.onAddToContext,
    this.preferences = DesktopGraphPreferences.defaults,
    super.key,
  });

  /// A presentation floor for an empty or very small graph. It is not a
  /// document limit: every loaded document is represented by a real node.
  static const minimumVisualNodeCount = 144;

  static int graphPointCountFor(Iterable<HuahuoDocumentSnapshot> documents) =>
      math.max(minimumVisualNodeCount, documents.length + 1);

  final List<HuahuoDocumentSnapshot> documents;
  final ValueChanged<String> onOpenDocument;
  final ValueChanged<String> onOpenReference;
  final ValueChanged<DesktopGraphSelection> onSelectionChanged;
  final ValueChanged<DesktopGraphSelection> onAddToContext;
  final DesktopGraphPreferences preferences;

  @override
  State<DesktopKnowledgeGraph> createState() => _DesktopKnowledgeGraphState();
}

final class _DesktopKnowledgeGraphState extends State<DesktopKnowledgeGraph>
    with TickerProviderStateMixin {
  static const _minimumSphereVisualNodeCount =
      DesktopKnowledgeGraph.minimumVisualNodeCount;
  static const _physicsNodeLimit = 320;
  static const _denseMotionFrameInterval = Duration(milliseconds: 16);
  static const _sphereDragSensitivity = .007;
  static const _initialSphereRotationX = -.12;
  static const _initialSphereRotationY = .24;
  static const _minimumPresentationScale = .5;
  static const _maximumPresentationScale = 5;
  static const _wheelZoomFactor = 1.12;
  static const _controlZoomFactor = 1.25;
  static const _noteLabelRevealScale = 2.5;
  static const _targetSettlementSize = 65;
  static const _maximumSettlementCount = 32;

  late final DesktopGraphPhysicsSimulation _physics;
  late final DesktopDenseGraphPhysicsSimulation _densePhysics;
  late final Ticker _physicsTicker;
  late final Ticker _denseMotionTicker;
  final DesktopSphereGraphLayout _sphereLayout =
      const DesktopSphereGraphLayout();
  final DesktopRadialGraphLayout _radialLayout =
      const DesktopRadialGraphLayout();
  List<DesktopSphereGraphLayoutPoint> _spherePoints =
      const <DesktopSphereGraphLayoutPoint>[];
  List<DesktopSphereGraphVisualLink> _sphereVisualLinks =
      const <DesktopSphereGraphVisualLink>[];
  List<String> _sphereSemanticNodeIds = const <String>[];
  int? _radialTopologyRevision;
  Size? _radialViewport;
  DesktopRadialGraphLayoutResult _radialLayoutResult =
      const DesktopRadialGraphLayoutResult.empty();
  List<DesktopGraphPhysicsNode> _radialPixelPhysicsNodes =
      const <DesktopGraphPhysicsNode>[];
  List<DesktopGraphPhysicsNode> _radialNormalizedPhysicsNodes =
      const <DesktopGraphPhysicsNode>[];
  _GraphTopologySnapshot? _topology;
  int? _visibleEdgesTopologyRevision;
  DesktopGraphViewMode? _visibleEdgesViewMode;
  String? _visibleEdgesSelectedId;
  List<_GraphEdge> _visibleSemanticEdgesCache = const <_GraphEdge>[];
  final ValueNotifier<List<_ProjectedNode>> _denseProjectedNodes =
      ValueNotifier<List<_ProjectedNode>>(const <_ProjectedNode>[]);
  Size? _denseProjectionViewport;
  List<_GraphNode> _denseProjectionNodes = const <_GraphNode>[];

  String? _selectedId;
  String? _doubleTapNodeId;
  String? _draggedNodeId;
  final ValueNotifier<_GraphDragPreview?> _dragPreview =
      ValueNotifier<_GraphDragPreview?>(null);
  Offset _dragPointerOffset = Offset.zero;
  bool _dragUsesPhysics = false;
  bool _dragUsesDensePhysics = false;
  Duration? _lastDenseMotionFrame;
  double _rotationX = _initialSphereRotationX;
  double _rotationY = _initialSphereRotationY;
  double _scale = 1;
  Offset _pan = Offset.zero;
  bool _isPanning = false;
  Offset _panStartPointer = Offset.zero;
  Offset _panAtGestureStart = Offset.zero;
  bool _reduceMotion = false;
  DesktopGraphViewMode _viewMode = DesktopGraphViewMode.sphere;

  static const _fallbackDocumentLabels = <String>[
    '待整理片段',
    '创作灵感',
    '标题备选',
    '论据素材',
  ];

  static const _referenceLabels = <String>[
    '城市观察笔记',
    '用户访谈素材',
    '品牌表达手册',
    '一周访谈摘录',
    '高频观点',
    '播客选题',
    '真实场景',
    '表达方法',
    '读者问题',
    '内容定位',
    '产品思考',
    '访谈原话',
    '个人经历',
    '观点冲突',
    '待验证假设',
    '视频脚本',
    '用户反馈',
    '长期主题',
    '内容日历',
  ];

  @override
  void initState() {
    super.initState();
    _physics = DesktopGraphPhysicsSimulation()..addListener(_onPhysicsChanged);
    _densePhysics = DesktopDenseGraphPhysicsSimulation()
      ..addListener(_onDensePhysicsChanged);
    _updatePhysicsParameters(notify: false);
    _physicsTicker = createTicker(_onPhysicsTick);
    _denseMotionTicker = createTicker(_onDenseMotionTick);
  }

  @override
  void didUpdateWidget(covariant DesktopKnowledgeGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cachedTopology = _topology;
    if (cachedTopology != null &&
        cachedTopology.documentSignature !=
            _documentTopologySignature(widget.documents)) {
      _invalidateTopologyCache();
    }
    if (oldWidget.preferences.attractionScale ==
            widget.preferences.attractionScale &&
        oldWidget.preferences.repulsionScale ==
            widget.preferences.repulsionScale &&
        oldWidget.preferences.dampingScale == widget.preferences.dampingScale) {
      return;
    }
    _updatePhysicsParameters(notify: false);
    if (_viewMode == DesktopGraphViewMode.flat && !_reduceMotion) {
      if (_usesPhysicsLayout(_ensureTopology().nodes)) {
        _schedulePhysicsTicker();
      } else {
        _scheduleDenseMotionTicker();
      }
    }
  }

  void _updatePhysicsParameters({required bool notify}) {
    final preferences = widget.preferences;
    _physics.updateParameters(
      attractionScale: preferences.attractionScale,
      repulsionScale: preferences.repulsionScale,
      dampingScale: preferences.dampingScale,
      notify: notify,
    );
    _densePhysics.updateParameters(
      attractionScale: preferences.attractionScale,
      repulsionScale: preferences.repulsionScale,
      dampingScale: preferences.dampingScale,
      notify: notify,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _physics.setIdleMotionEnabled(false, notify: false);
      _physics.freeze(notify: false);
      _densePhysics.setIdleMotionEnabled(false, notify: false);
      _densePhysics.freeze(notify: false);
      _physicsTicker.stop();
      _stopDenseMotionTicker();
    } else if (_viewMode == DesktopGraphViewMode.flat) {
      if (_isDenseDocumentGraph) {
        _densePhysics
          ..setIdleMotionEnabled(true, notify: false)
          ..unfreeze(notify: false);
        _scheduleDenseMotionTicker();
      } else {
        _physics.setIdleMotionEnabled(true, notify: false);
        _physics.unfreeze(notify: false);
        _schedulePhysicsTicker();
      }
    }
  }

  @override
  void dispose() {
    _physics.setIdleMotionEnabled(false, notify: false);
    _densePhysics.setIdleMotionEnabled(false, notify: false);
    _physics
      ..removeListener(_onPhysicsChanged)
      ..dispose();
    _densePhysics
      ..removeListener(_onDensePhysicsChanged)
      ..dispose();
    _dragPreview.dispose();
    _denseProjectedNodes.dispose();
    _physicsTicker.dispose();
    _denseMotionTicker.dispose();
    super.dispose();
  }

  void _onPhysicsChanged() {
    if (mounted) setState(() {});
  }

  void _onDensePhysicsChanged() {
    final viewport = _denseProjectionViewport;
    if (!mounted || viewport == null || _denseProjectionNodes.isEmpty) return;
    _denseProjectedNodes.value = _projectDenseFlatNodes(
      viewport,
      _denseProjectionNodes,
    );
  }

  void _onPhysicsTick(Duration elapsed) {
    _physics.advanceFrame(elapsed);
    if (_physics.isFrozen) _physicsTicker.stop();
  }

  void _onDenseMotionTick(Duration elapsed) {
    if (!mounted ||
        _reduceMotion ||
        _viewMode != DesktopGraphViewMode.flat ||
        !_isDenseDocumentGraph) {
      _stopDenseMotionTicker();
      return;
    }
    final previous = _lastDenseMotionFrame;
    if (previous == null) {
      _lastDenseMotionFrame = elapsed;
      return;
    }
    final delta = elapsed - previous;
    if (delta < _denseMotionFrameInterval) return;
    _lastDenseMotionFrame = elapsed;
    _densePhysics.advanceFrame(elapsed);
  }

  void _scheduleDenseMotionTicker() {
    if (_viewMode != DesktopGraphViewMode.flat ||
        !_isDenseDocumentGraph ||
        _reduceMotion ||
        _denseMotionTicker.isActive) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _viewMode != DesktopGraphViewMode.flat ||
          !_isDenseDocumentGraph ||
          _reduceMotion ||
          _denseMotionTicker.isActive) {
        return;
      }
      _lastDenseMotionFrame = null;
      _denseMotionTicker.start();
    });
  }

  void _stopDenseMotionTicker() {
    if (_denseMotionTicker.isActive) _denseMotionTicker.stop();
    _lastDenseMotionFrame = null;
  }

  void _schedulePhysicsTicker() {
    if (_viewMode != DesktopGraphViewMode.flat ||
        !_usesPhysicsLayout(_ensureTopology().nodes) ||
        _reduceMotion ||
        _physicsTicker.isActive ||
        _physics.isFrozen) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _viewMode != DesktopGraphViewMode.flat ||
          !_usesPhysicsLayout(_ensureTopology().nodes) ||
          _reduceMotion ||
          _physicsTicker.isActive ||
          _physics.isFrozen) {
        return;
      }
      _physicsTicker.start();
    });
  }

  bool _usesPhysicsLayout(List<_GraphNode> nodes) =>
      nodes.length <= _physicsNodeLimit;

  bool get _isDenseDocumentGraph =>
      widget.documents.length + 1 > _physicsNodeLimit;

  void _invalidateTopologyCache() {
    _topology = null;
    _radialTopologyRevision = null;
    _radialViewport = null;
    _radialLayoutResult = const DesktopRadialGraphLayoutResult.empty();
    _radialPixelPhysicsNodes = const <DesktopGraphPhysicsNode>[];
    _radialNormalizedPhysicsNodes = const <DesktopGraphPhysicsNode>[];
    _visibleEdgesTopologyRevision = null;
    _visibleEdgesViewMode = null;
    _visibleEdgesSelectedId = null;
    _visibleSemanticEdgesCache = const <_GraphEdge>[];
    _denseProjectionViewport = null;
    _denseProjectionNodes = const <_GraphNode>[];
    _denseProjectedNodes.value = const <_ProjectedNode>[];
  }

  _GraphTopologySnapshot _ensureTopology() {
    final cached = _topology;
    if (cached != null) return cached;
    final nodes = List<_GraphNode>.unmodifiable(_semanticNodes);
    final edges = List<_GraphEdge>.unmodifiable(_semanticEdges(nodes));
    final snapshot = _GraphTopologySnapshot(
      nodes: nodes,
      edges: edges,
      physicsEdges: List<DesktopGraphPhysicsEdge>.unmodifiable(
        _physicsEdges(edges),
      ),
      communities: List<DesktopGraphCommunitySnapshot>.unmodifiable(
        _communities(nodes),
      ),
      revision: _topologyRevision(nodes, edges),
      documentSignature: _documentTopologySignature(widget.documents),
    );
    _topology = snapshot;
    return snapshot;
  }

  int _documentTopologySignature(List<HuahuoDocumentSnapshot> documents) {
    var hash = 0x811C9DC5;
    void addText(String value) {
      for (final unit in value.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x01000193) & 0x7fffffff;
      }
    }

    addText(documents.length.toString());
    for (final document in documents) {
      addText(document.id);
      addText(document.title);
      addText(document.revision.toString());
    }
    return hash;
  }

  List<_GraphEdge> _ensureVisibleSemanticEdges(
    _GraphTopologySnapshot topology,
  ) {
    if (_visibleEdgesTopologyRevision == topology.revision &&
        _visibleEdgesViewMode == _viewMode &&
        _visibleEdgesSelectedId == _selectedId) {
      return _visibleSemanticEdgesCache;
    }
    _visibleSemanticEdgesCache = List<_GraphEdge>.unmodifiable(
      _visibleSemanticEdges(topology.edges, topology.nodes.length),
    );
    _visibleEdgesTopologyRevision = topology.revision;
    _visibleEdgesViewMode = _viewMode;
    _visibleEdgesSelectedId = _selectedId;
    return _visibleSemanticEdgesCache;
  }

  List<_GraphNode> get _semanticNodes {
    final nodes = <_GraphNode>[
      const _GraphNode(
        id: 'brain',
        label: '我的内容',
        kind: _GraphNodeKind.brain,
        role: DesktopGraphNodeRole.center,
        community: DesktopGraphCommunity.viewpointTrend,
        settlementId: 'brain',
      ),
    ];
    final documents = widget.documents;
    if (documents.isNotEmpty) {
      final sortedDocuments = documents.toList(growable: false)
        ..sort(_compareDocumentsForSettlement);
      final settlementCount = _settlementCountFor(sortedDocuments.length);
      final settlementIds = List<String>.filled(settlementCount, '');
      for (
        var settlementIndex = 0;
        settlementIndex < settlementCount;
        settlementIndex++
      ) {
        final firstDocumentIndex =
            settlementIndex * sortedDocuments.length ~/ settlementCount;
        settlementIds[settlementIndex] =
            'settlement-${sortedDocuments[firstDocumentIndex].id}';
      }
      for (var index = 0; index < sortedDocuments.length; index++) {
        final document = sortedDocuments[index];
        // This maps to the same floor-based ranges used above to pick every
        // settlement's first real document. Multiplying the raw index would
        // assign the boundary document to the preceding settlement.
        final settlementIndex =
            ((index + 1) * settlementCount - 1) ~/ sortedDocuments.length;
        final isSettlementCore =
            index ==
            settlementIndex * sortedDocuments.length ~/ settlementCount;
        nodes.add(
          _GraphNode(
            id: 'document-${document.id}',
            label: document.title.trim().isEmpty ? '未命名文稿' : document.title,
            kind: _GraphNodeKind.document,
            role: isSettlementCore
                ? DesktopGraphNodeRole.core
                : DesktopGraphNodeRole.satellite,
            // Community remains a palette/category signal. Settlement is the
            // physical and relational grouping used by the graph engines.
            community: _communityForDocument(document.id),
            settlementId: settlementIds[settlementIndex],
            documentId: document.id,
          ),
        );
      }
      return nodes;
    }
    for (var index = 0; index < 4; index++) {
      final community = DesktopGraphCommunity.values[index];
      if (index < widget.documents.length) {
        final document = widget.documents[index];
        nodes.add(
          _GraphNode(
            id: 'document-${document.id}',
            label: document.title.trim().isEmpty ? '未命名文稿' : document.title,
            kind: _GraphNodeKind.document,
            role: DesktopGraphNodeRole.core,
            community: community,
            settlementId: 'settlement-document-${document.id}',
            documentId: document.id,
          ),
        );
      } else {
        final label = _fallbackDocumentLabels[index];
        nodes.add(
          _GraphNode(
            id: 'reference-draft-$index',
            label: label,
            kind: _GraphNodeKind.reference,
            role: DesktopGraphNodeRole.core,
            community: community,
            settlementId: 'settlement-reference-draft-$index',
            referenceTitle: label,
          ),
        );
      }
    }
    for (var index = 0; index < _referenceLabels.length; index++) {
      final label = _referenceLabels[index];
      nodes.add(
        _GraphNode(
          id: 'reference-$index',
          label: label,
          kind: _GraphNodeKind.reference,
          role: DesktopGraphNodeRole.satellite,
          community: DesktopGraphCommunity
              .values[index % DesktopGraphCommunity.values.length],
          settlementId: 'settlement-reference-draft-${index % 4}',
          referenceTitle: label,
        ),
      );
    }
    return nodes;
  }

  DesktopGraphCommunity _communityForDocument(String documentId) {
    var hash = 0x811C9DC5;
    for (final unit in documentId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    hash ^= hash >> 16;
    hash = (hash * 0x7feb352d) & 0x7fffffff;
    return DesktopGraphCommunity.values[hash %
        DesktopGraphCommunity.values.length];
  }

  int _compareDocumentsForSettlement(
    HuahuoDocumentSnapshot left,
    HuahuoDocumentSnapshot right,
  ) {
    final hashComparison = _stableGraphHash(
      left.id,
    ).compareTo(_stableGraphHash(right.id));
    if (hashComparison != 0) return hashComparison;
    return left.id.compareTo(right.id);
  }

  int _settlementCountFor(int documentCount) {
    if (documentCount <= 1) return documentCount;
    final maximum = math.min(_maximumSettlementCount, documentCount);
    var bestCount = 2;
    var bestDistance = double.infinity;
    for (var candidate = 2; candidate <= maximum; candidate++) {
      final distance = (documentCount / candidate - _targetSettlementSize)
          .abs();
      if (distance < bestDistance) {
        bestCount = candidate;
        bestDistance = distance;
      }
    }
    return bestCount;
  }

  List<_GraphEdge> _semanticEdges(List<_GraphNode> nodes) {
    final edges = <_GraphEdge>[];
    final edgeKeys = <String>{};
    void addEdge({
      required String id,
      required String sourceId,
      required String targetId,
      required DesktopGraphRelationKind kind,
      required double weight,
    }) {
      if (sourceId == targetId) return;
      final key = sourceId.compareTo(targetId) <= 0
          ? '$sourceId|$targetId'
          : '$targetId|$sourceId';
      if (!edgeKeys.add(key)) return;
      edges.add(
        _GraphEdge(
          id: id,
          sourceId: sourceId,
          targetId: targetId,
          kind: kind,
          weight: weight,
        ),
      );
    }

    final settlements = <String, List<_GraphNode>>{};
    for (final node in nodes) {
      if (node.role == DesktopGraphNodeRole.center) continue;
      settlements
          .putIfAbsent(node.settlementId, () => <_GraphNode>[])
          .add(node);
    }
    final orderedSettlements = settlements.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final bridgeEndpoints = <String, List<_GraphNode>>{};

    for (final settlement in orderedSettlements) {
      final members = settlement.value..sort(_compareNodesForSettlement);
      final core = members
          .where((node) => node.role == DesktopGraphNodeRole.core)
          .firstOrNull;
      if (core == null) continue;
      addEdge(
        id: 'membership-brain-${core.id}',
        sourceId: 'brain',
        targetId: core.id,
        kind: DesktopGraphRelationKind.membership,
        weight: .78,
      );

      final satellites =
          members
              .where((node) => node.role == DesktopGraphNodeRole.satellite)
              .toList(growable: false)
            ..sort(_compareNodesForSettlement);
      if (satellites.isEmpty) {
        bridgeEndpoints[settlement.key] = <_GraphNode>[core];
        continue;
      }

      final representativeCount = math.min(
        5,
        math.max(1, (satellites.length / 16).ceil()),
      );
      final representatives = <_GraphNode>[
        for (var index = 0; index < representativeCount; index++)
          satellites[((index + 1) *
                  satellites.length /
                  (representativeCount + 1))
              .floor()],
      ];
      final representativeIds = representatives.map((node) => node.id).toSet();
      for (final representative in representatives) {
        addEdge(
          id: 'settlement-core-${core.id}-${representative.id}',
          sourceId: core.id,
          targetId: representative.id,
          kind: DesktopGraphRelationKind.communityAffinity,
          weight: .92,
        );
      }
      for (var index = 0; index < satellites.length; index++) {
        final node = satellites[index];
        if (!representativeIds.contains(node.id)) {
          final representativeIndex =
              index * representativeCount ~/ satellites.length;
          final representative = representatives[representativeIndex];
          addEdge(
            id: 'settlement-member-${representative.id}-${node.id}',
            sourceId: representative.id,
            targetId: node.id,
            kind: DesktopGraphRelationKind.communityAffinity,
            weight: .79,
          );
        }
        if (index > 0) {
          addEdge(
            id: 'local-${satellites[index - 1].id}-${node.id}',
            sourceId: satellites[index - 1].id,
            targetId: node.id,
            kind: DesktopGraphRelationKind.linkedMaterial,
            weight: .66,
          );
        }
        if (index > 2 && index.isEven) {
          addEdge(
            id: 'woven-${satellites[index - 3].id}-${node.id}',
            sourceId: satellites[index - 3].id,
            targetId: node.id,
            kind: DesktopGraphRelationKind.sharedTopic,
            weight: .55,
          );
        }
      }
      bridgeEndpoints[settlement.key] = <_GraphNode>[
        ...representatives,
        satellites.first,
        satellites.last,
      ];
    }

    if (orderedSettlements.length > 1) {
      void addSettlementBridge(int sourceIndex, int targetIndex, int salt) {
        final source = orderedSettlements[sourceIndex];
        final target = orderedSettlements[targetIndex];
        final sourceEndpoints = bridgeEndpoints[source.key];
        final targetEndpoints = bridgeEndpoints[target.key];
        if (sourceEndpoints == null ||
            sourceEndpoints.isEmpty ||
            targetEndpoints == null ||
            targetEndpoints.isEmpty) {
          return;
        }
        final sourceNode =
            sourceEndpoints[_stableGraphHash('${source.key}:$salt') %
                sourceEndpoints.length];
        final targetNode =
            targetEndpoints[_stableGraphHash('${target.key}:$salt') %
                targetEndpoints.length];
        addEdge(
          id: 'bridge-${source.key}-${target.key}-$salt',
          sourceId: sourceNode.id,
          targetId: targetNode.id,
          kind: DesktopGraphRelationKind.sharedContentLine,
          weight: .43,
        );
      }

      for (var index = 0; index < orderedSettlements.length; index++) {
        addSettlementBridge(index, (index + 1) % orderedSettlements.length, 0);
      }
      if (orderedSettlements.length > 3) {
        final jump = math.max(2, orderedSettlements.length ~/ 3);
        for (var index = 0; index < orderedSettlements.length; index += 2) {
          addSettlementBridge(
            index,
            (index + jump) % orderedSettlements.length,
            1,
          );
        }
      }
    }
    return edges;
  }

  int _compareNodesForSettlement(_GraphNode left, _GraphNode right) {
    final hashComparison = _stableGraphHash(
      left.id,
    ).compareTo(_stableGraphHash(right.id));
    if (hashComparison != 0) return hashComparison;
    return left.id.compareTo(right.id);
  }

  List<_GraphEdge> _visibleSemanticEdges(
    List<_GraphEdge> edges,
    int semanticNodeCount,
  ) {
    if (semanticNodeCount <= _physicsNodeLimit) return edges;
    final selectedId = _selectedId;
    if (_viewMode == DesktopGraphViewMode.sphere) {
      final communityStride = math.max(1, (semanticNodeCount / 72).ceil());
      final secondaryBudget = semanticNodeCount <= 900
          ? 420
          : semanticNodeCount <= 1600
          ? 320
          : 240;
      final secondaryStride = math.max(
        1,
        (edges.length / secondaryBudget).ceil(),
      );
      return [
        for (final edge in edges)
          if (edge.kind == DesktopGraphRelationKind.communityAffinity
              ? edge.targetId == selectedId ||
                    _shouldPaintDenseEdge(
                      edge.id,
                      edge.sourceId == selectedId
                          ? semanticNodeCount <= 5000
                                ? 1
                                : math.max(1, communityStride ~/ 2)
                          : communityStride,
                    )
              : secondaryStride == 1 ||
                    edge.sourceId == selectedId ||
                    edge.targetId == selectedId ||
                    _shouldPaintDenseEdge(edge.id, secondaryStride))
            edge,
      ];
    }
    final communityStride = math.max(1, (semanticNodeCount / 220).ceil());
    final secondaryStride = math.max(1, (edges.length / 420).ceil());
    return [
      for (final edge in edges)
        if (edge.kind == DesktopGraphRelationKind.membership ||
            edge.kind == DesktopGraphRelationKind.sharedContentLine ||
            (edge.kind == DesktopGraphRelationKind.communityAffinity &&
                (edge.targetId == selectedId ||
                    _shouldPaintDenseEdge(
                      edge.id,
                      edge.sourceId == selectedId
                          ? math.max(1, communityStride ~/ 2)
                          : communityStride,
                    ))) ||
            (edge.kind != DesktopGraphRelationKind.communityAffinity &&
                (edge.sourceId == selectedId ||
                    edge.targetId == selectedId ||
                    _shouldPaintDenseEdge(edge.id, secondaryStride))))
          edge,
    ];
  }

  List<DesktopSphereGraphVisualLink> _visibleSphereLinks(
    List<DesktopSphereGraphVisualLink> links,
    int semanticNodeCount,
  ) {
    if (semanticNodeCount <= _physicsNodeLimit) {
      return links;
    }
    final meshBudget = semanticNodeCount <= 720
        ? 460
        : semanticNodeCount <= 1200
        ? 360
        : 260;
    if (links.length <= meshBudget) return links;
    final stride = (links.length / meshBudget).ceil();
    return [
      for (var index = 0; index < links.length; index++)
        if (index % stride == 0) links[index],
    ];
  }

  int _stableGraphHash(String id) {
    var hash = 0x811C9DC5;
    for (final unit in id.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  bool _shouldPaintDenseEdge(String id, int stride) =>
      _stableGraphHash(id) % stride == 0;

  List<DesktopGraphPhysicsNode> _physicsNodes(
    List<_GraphNode> nodes, {
    Map<String, Offset> seedPositions = const <String, Offset>{},
  }) => [
    for (final node in nodes)
      DesktopGraphPhysicsNode(
        id: node.id,
        role: node.role,
        community: node.community,
        settlementId: node.settlementId,
        seedPosition: seedPositions[node.id],
      ),
  ];

  List<DesktopGraphPhysicsEdge> _physicsEdges(List<_GraphEdge> edges) => [
    for (final edge in edges)
      DesktopGraphPhysicsEdge(
        id: edge.id,
        sourceId: edge.sourceId,
        targetId: edge.targetId,
        kind: edge.kind,
        weight: edge.weight,
      ),
  ];

  List<DesktopGraphCommunitySnapshot> _communities(List<_GraphNode> nodes) {
    final membersBySettlement = <String, List<_GraphNode>>{};
    for (final node in nodes) {
      if (node.role == DesktopGraphNodeRole.center) continue;
      membersBySettlement
          .putIfAbsent(node.settlementId, () => <_GraphNode>[])
          .add(node);
    }
    final settlements = membersBySettlement.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      for (final settlement in settlements)
        DesktopGraphCommunitySnapshot(
          // The legacy type carries the palette only. Its core/member values
          // now describe one real settlement, including in the small physics
          // path that still accepts this compatibility snapshot.
          community:
              settlement.value
                  .where((node) => node.role == DesktopGraphNodeRole.core)
                  .map((node) => node.community)
                  .firstOrNull ??
              settlement.value.first.community,
          coreNodeId:
              settlement.value
                  .where((node) => node.role == DesktopGraphNodeRole.core)
                  .map((node) => node.id)
                  .firstOrNull ??
              '',
          memberNodeIds: settlement.value.map((node) => node.id).toSet(),
        ),
    ];
  }

  void _ensureSphereLayout(List<_GraphNode> nodes) {
    final ids = nodes.map((node) => node.id).toList()..sort();
    if (listEquals(ids, _sphereSemanticNodeIds)) return;
    _spherePoints = _sphereLayout.build(
      realNodeIds: ids,
      minimumVisualNodeCount: _minimumSphereVisualNodeCount,
    );
    _sphereVisualLinks = _sphereLayout.buildVisualLinks(
      points: _spherePoints,
      neighborsPerPoint: 3,
    );
    _sphereSemanticNodeIds = List<String>.unmodifiable(ids);
  }

  DesktopRadialGraphLayoutResult _ensureRadialLayout({
    required int topologyRevision,
    required Size viewport,
    required List<_GraphNode> nodes,
    required List<DesktopGraphPhysicsEdge> edges,
    required List<DesktopGraphCommunitySnapshot> communities,
  }) {
    if (_radialTopologyRevision == topologyRevision &&
        _radialViewport == viewport) {
      return _radialLayoutResult;
    }
    final layoutNodes = _physicsNodes(nodes);
    _radialLayoutResult = _radialLayout.build(
      nodes: layoutNodes,
      edges: edges,
      communities: communities,
      viewport: viewport,
    );
    _radialPixelPhysicsNodes = List<DesktopGraphPhysicsNode>.unmodifiable(
      _physicsNodes(nodes, seedPositions: _radialLayoutResult.desiredPositions),
    );
    _radialNormalizedPhysicsNodes = List<DesktopGraphPhysicsNode>.unmodifiable(
      _physicsNodes(
        nodes,
        seedPositions: _radialLayoutResult.normalizedDesiredPositions,
      ),
    );
    _radialTopologyRevision = topologyRevision;
    _radialViewport = viewport;
    return _radialLayoutResult;
  }

  List<_ProjectedNode> _projectSphereNodes(
    Size size,
    List<_GraphNode> semanticNodes,
    _GraphSelectionNeighborhood selection,
  ) {
    final byId = <String, _GraphNode>{
      for (final node in semanticNodes) node.id: node,
    };
    final projected = _sphereLayout.project(
      points: _spherePoints,
      viewport: size,
      rotationX: _rotationX,
      rotationY: _rotationY,
      zoom: _scale,
      padding: 14,
      pan: _pan,
    );
    return [
      for (final point in projected)
        _ProjectedNode(
          node: byId[point.id] ?? _GraphNode.synthetic(point.id),
          position: point.position,
          cameraDepth: point.cameraDepth,
          depth: point.depth,
          sizeFactor: point.sizeFactor,
          opacity: _nodeOpacity(byId[point.id], selection) * point.opacity,
          nodeScale: widget.preferences.nodeScale,
          baseRadius: byId.containsKey(point.id)
              ? _nodeRadiusFor(byId[point.id]!, semanticNodes.length)
              : 6.8,
        ),
    ];
  }

  List<_ProjectedNode> _projectFlatNodes(Size size, List<_GraphNode> nodes) {
    final center = size.center(Offset.zero);
    return <_ProjectedNode>[
      for (final node in nodes)
        () {
          final position = _physics.positionFor(node.id);
          return _ProjectedNode(
            node: node,
            position: center + (position - center) * _scale + _pan,
            cameraDepth: 1,
            depth: 1,
            sizeFactor: _scale,
            opacity: 1,
            nodeScale: widget.preferences.nodeScale,
            baseRadius: _physics.radiusFor(node.id),
          );
        }(),
    ];
  }

  List<_ProjectedNode> _projectDenseFlatNodes(
    Size size,
    List<_GraphNode> nodes,
  ) {
    return [
      for (final node in nodes)
        () {
          final normalized = _densePhysics.positionFor(node.id);
          final position = _denseViewPosition(normalized, size);
          return _ProjectedNode(
            node: node,
            position: position,
            cameraDepth: switch (node.role) {
              DesktopGraphNodeRole.center => 2,
              DesktopGraphNodeRole.core => 1,
              DesktopGraphNodeRole.satellite => 0,
            },
            depth: 1,
            sizeFactor: _scale,
            opacity: 1,
            nodeScale: widget.preferences.nodeScale,
            baseRadius: _nodeRadiusFor(node, nodes.length),
          );
        }(),
    ];
  }

  List<_ProjectedNode> _refreshDenseProjectedNodes(
    Size viewport,
    List<_GraphNode> nodes,
  ) {
    _denseProjectionViewport = viewport;
    _denseProjectionNodes = nodes;
    final projected = _projectDenseFlatNodes(viewport, nodes);
    _denseProjectedNodes.value = projected;
    return projected;
  }

  List<_ProjectedNode> _projectedNodesForInteraction(
    List<_ProjectedNode> fallback,
  ) {
    if (_viewMode == DesktopGraphViewMode.flat && _isDenseDocumentGraph) {
      return _denseProjectedNodes.value;
    }
    return fallback;
  }

  @visibleForTesting
  Offset? debugDenseNodeViewPosition(String nodeId, Size viewport) {
    if (!_isDenseDocumentGraph ||
        !_densePhysics.positions.containsKey(nodeId)) {
      return null;
    }
    return _denseViewPosition(_densePhysics.positionFor(nodeId), viewport);
  }

  Offset _denseViewPosition(Offset normalized, Size size) {
    final center = size.center(Offset.zero);
    final unscaled = Offset(
      normalized.dx * size.width,
      normalized.dy * size.height,
    );
    return center + (unscaled - center) * _scale + _pan;
  }

  Offset _denseNormalizedPositionForView(Offset position, Size size) {
    final center = size.center(Offset.zero);
    final unscaled = center + (position - center - _pan) / _scale;
    return DesktopGraphViewportBounds.forViewport(size).clampNormalized(
      Offset(unscaled.dx / size.width, unscaled.dy / size.height),
      inset: 8,
    );
  }

  Offset _clampFlatViewPosition(Offset position, Size size) {
    final center = size.center(Offset.zero);
    final unscaled = center + (position - center - _pan) / _scale;
    final clamped = DesktopGraphViewportBounds.forViewport(
      size,
    ).clamp(unscaled, inset: 8);
    return center + (clamped - center) * _scale + _pan;
  }

  double _nodeRadiusFor(_GraphNode node, int semanticNodeCount) {
    if (node.kind == _GraphNodeKind.brain) return node.baseRadius;
    final densityScale = semanticNodeCount <= 160
        ? 1.0
        : math.sqrt(160 / semanticNodeCount).clamp(.24, 1.0).toDouble();
    final minimum = node.role == DesktopGraphNodeRole.core ? 3.4 : 1.75;
    return math.max(minimum, node.baseRadius * densityScale);
  }

  _GraphSelectionNeighborhood _selectionNeighborhood(List<_GraphEdge> edges) {
    final selectedId = _selectedId;
    if (selectedId == null) return const _GraphSelectionNeighborhood.empty();
    final firstDegree = <String>{};
    for (final edge in edges) {
      if (edge.sourceId == selectedId) firstDegree.add(edge.targetId);
      if (edge.targetId == selectedId) firstDegree.add(edge.sourceId);
    }
    final secondDegree = <String>{};
    for (final edge in edges) {
      if (firstDegree.contains(edge.sourceId)) secondDegree.add(edge.targetId);
      if (firstDegree.contains(edge.targetId)) secondDegree.add(edge.sourceId);
    }
    return _GraphSelectionNeighborhood(
      selectedId: selectedId,
      firstDegree: Set<String>.unmodifiable(firstDegree),
      secondDegree: Set<String>.unmodifiable(secondDegree),
    );
  }

  double _nodeOpacity(_GraphNode? node, _GraphSelectionNeighborhood selection) {
    if (node == null || node.kind == _GraphNodeKind.ambient) return 1;
    final selectedId = selection.selectedId;
    if (selectedId == null) return 1;
    if (node.id == selectedId) return 1;
    if (selection.firstDegree.contains(node.id)) return .86;
    return selection.secondDegree.contains(node.id) ? .52 : .18;
  }

  _ProjectedNode? _hitTest(Offset position, List<_ProjectedNode> projected) {
    _ProjectedNode? result;
    for (final node in projected) {
      if (!node.node.isSelectable ||
          (node.position - position).distance > node.hitRadius) {
        continue;
      }
      if (result == null || node.cameraDepth > result.cameraDepth) {
        result = node;
      }
    }
    return result;
  }

  _GraphNode? _selectedNode(List<_GraphNode> nodes) {
    final selectedId = _selectedId;
    if (selectedId == null) return null;
    for (final node in nodes) {
      if (node.id == selectedId) return node;
    }
    return null;
  }

  void _selectAt(Offset position, List<_ProjectedNode> projected) {
    final hit = _hitTest(position, projected);
    if (hit == null) {
      if (_selectedId != null) setState(() => _selectedId = null);
      return;
    }
    setState(() => _selectedId = hit.node.id);
    widget.onSelectionChanged(_selectionForNode(hit.node));
  }

  DesktopGraphSelection _selectionForNode(_GraphNode node) =>
      DesktopGraphSelection(
        id: node.id,
        label: node.label,
        isBrain: node.kind == _GraphNodeKind.brain,
      );

  void _openNode(_GraphNode node) {
    if (node.documentId != null) {
      widget.onOpenDocument(node.documentId!);
    } else if (node.referenceTitle != null) {
      widget.onOpenReference(node.referenceTitle!);
    }
  }

  void _zoomBy(double factor, {required Size viewport, Offset? focalPoint}) {
    final nextScale = (_scale * factor)
        .clamp(_minimumPresentationScale, _maximumPresentationScale)
        .toDouble();
    if (nextScale == _scale) return;
    final center = viewport.center(Offset.zero);
    final focal = focalPoint ?? center;
    final scaleRatio = nextScale / _scale;
    final nextPan = focal - center - (focal - center - _pan) * scaleRatio;
    setState(() {
      _scale = nextScale;
      _pan = _clampPan(nextPan, viewport, scale: nextScale);
    });
  }

  Offset _clampPan(Offset pan, Size viewport, {double? scale}) {
    final effectiveScale = scale ?? _scale;
    final maxX = math.max(0.0, viewport.width * (effectiveScale - 1) / 2);
    final maxY = math.max(0.0, viewport.height * (effectiveScale - 1) / 2);
    return Offset(
      pan.dx.clamp(-maxX, maxX).toDouble(),
      pan.dy.clamp(-maxY, maxY).toDouble(),
    );
  }

  void _beginPan(Offset pointerPosition) {
    _isPanning = true;
    _panStartPointer = pointerPosition;
    _panAtGestureStart = _pan;
  }

  void _updatePan(Offset pointerPosition, Size viewport) {
    if (!_isPanning) return;
    setState(() {
      _pan = _clampPan(
        _panAtGestureStart + pointerPosition - _panStartPointer,
        viewport,
      );
    });
  }

  void _endPan() {
    if (!_isPanning) return;
    setState(() => _isPanning = false);
  }

  void _setViewMode(DesktopGraphViewMode mode) {
    if (_viewMode == mode) return;
    if (_dragUsesPhysics) _physics.endDrag();
    if (_dragUsesDensePhysics) _densePhysics.endDrag();
    _dragPreview.value = null;
    setState(() {
      _viewMode = mode;
      _draggedNodeId = null;
      _dragPointerOffset = Offset.zero;
      _dragUsesPhysics = false;
      _dragUsesDensePhysics = false;
      _isPanning = false;
      _pan = Offset.zero;
    });
    if (mode == DesktopGraphViewMode.sphere) {
      _physics.setIdleMotionEnabled(false, notify: false);
      _physics.freeze(notify: false);
      _densePhysics.setIdleMotionEnabled(false, notify: false);
      _densePhysics.freeze(notify: false);
      _physicsTicker.stop();
      _stopDenseMotionTicker();
    } else if (_isDenseDocumentGraph) {
      _physics.setIdleMotionEnabled(false, notify: false);
      _physics.freeze(notify: false);
      _physicsTicker.stop();
      if (!_reduceMotion) {
        _densePhysics
          ..setIdleMotionEnabled(true, notify: false)
          ..unfreeze(notify: false)
          ..wake(notify: false);
        _scheduleDenseMotionTicker();
      }
    } else if (!_reduceMotion) {
      _densePhysics.setIdleMotionEnabled(false, notify: false);
      _densePhysics.freeze(notify: false);
      _physics.setIdleMotionEnabled(true, notify: false);
      _physics.unfreeze(notify: false);
      _physics.wake(notify: false);
      _schedulePhysicsTicker();
    }
  }

  void _reset() {
    if (_dragUsesPhysics) _physics.endDrag();
    if (_dragUsesDensePhysics) _densePhysics.endDrag();
    _densePhysics.reset(notify: false);
    _dragPreview.value = null;
    setState(() {
      _rotationX = _initialSphereRotationX;
      _rotationY = _initialSphereRotationY;
      _scale = 1;
      _pan = Offset.zero;
      _selectedId = null;
      _draggedNodeId = null;
      _dragPointerOffset = Offset.zero;
      _dragUsesPhysics = false;
      _dragUsesDensePhysics = false;
      _isPanning = false;
    });
    if (_viewMode == DesktopGraphViewMode.flat &&
        !_reduceMotion &&
        _usesPhysicsLayout(_semanticNodes)) {
      _physics.wake(notify: false);
      _schedulePhysicsTicker();
    } else if (_viewMode == DesktopGraphViewMode.flat && !_reduceMotion) {
      _scheduleDenseMotionTicker();
    }
  }

  Offset _toPhysicsPosition(Offset viewPosition, Size size) {
    final center = size.center(Offset.zero);
    return center + (viewPosition - center - _pan) / _scale;
  }

  bool _beginFlatDrag(
    Offset pointerPosition,
    List<_ProjectedNode> projected,
    Size size,
    bool usePhysics,
  ) {
    if (_viewMode != DesktopGraphViewMode.flat || _draggedNodeId != null) {
      return false;
    }
    final hit = _hitTest(pointerPosition, projected);
    if (hit == null || hit.node.kind == _GraphNodeKind.brain) return false;
    _dragPointerOffset = hit.position - pointerPosition;
    final viewTarget = _clampFlatViewPosition(
      pointerPosition + _dragPointerOffset,
      size,
    );
    if (usePhysics) {
      final target = _toPhysicsPosition(viewTarget, size);
      if (!_physics.beginDrag(hit.node.id, target)) return false;
      _dragUsesPhysics = true;
      _dragUsesDensePhysics = false;
      _schedulePhysicsTicker();
    } else {
      final target = _denseNormalizedPositionForView(viewTarget, size);
      if (!_densePhysics.beginDrag(hit.node.id, target)) return false;
      _dragUsesPhysics = false;
      _dragUsesDensePhysics = true;
      _scheduleDenseMotionTicker();
    }
    _dragPreview.value = _GraphDragPreview(
      nodeId: hit.node.id,
      position: hit.position,
    );
    setState(() => _draggedNodeId = hit.node.id);
    return true;
  }

  void _updateFlatDrag(Offset pointerPosition, Size size) {
    final nodeId = _draggedNodeId;
    if (nodeId == null) return;
    final target = _clampFlatViewPosition(
      pointerPosition + _dragPointerOffset,
      size,
    );
    _dragPreview.value = _GraphDragPreview(nodeId: nodeId, position: target);
    if (_dragUsesPhysics) {
      _physics.updateDrag(_toPhysicsPosition(target, size));
      // Pointer events must produce a paint before the next ticker frame. The
      // ticker still owns the remaining spring and inertia motion.
      _physics.advanceForPointerUpdate();
      return;
    }
    if (_dragUsesDensePhysics) {
      _densePhysics.updateDrag(
        _denseNormalizedPositionForView(target, size),
        notify: false,
      );
    }
  }

  void _endFlatDrag([Size? size, bool commitPreview = false]) {
    if (_draggedNodeId == null) return;
    final usedPhysics = _dragUsesPhysics;
    final usedDensePhysics = _dragUsesDensePhysics;
    final preview = _dragPreview.value;
    if (commitPreview && size != null && preview != null) {
      if (usedPhysics) {
        _physics.commitDraggedPosition(
          _toPhysicsPosition(preview.position, size),
        );
      }
      if (usedDensePhysics) {
        _densePhysics.commitDraggedPosition(
          _denseNormalizedPositionForView(preview.position, size),
        );
      }
    }
    if (usedPhysics) _physics.endDrag();
    if (usedDensePhysics) _densePhysics.endDrag();
    _dragPreview.value = null;
    setState(() {
      _draggedNodeId = null;
      _dragPointerOffset = Offset.zero;
      _dragUsesPhysics = false;
      _dragUsesDensePhysics = false;
    });
    if (usedPhysics) _schedulePhysicsTicker();
    if (usedDensePhysics) _scheduleDenseMotionTicker();
  }

  int _topologyRevision(List<_GraphNode> nodes, List<_GraphEdge> edges) {
    var hash = 0x811C9DC5;
    for (final value in <String>[
      ...nodes.map(
        (node) =>
            '${node.id}:${node.role.index}:${node.community.index}:${node.settlementId}',
      ),
      ...edges.map((edge) => '${edge.id}:${edge.weight}'),
    ]) {
      for (final unit in value.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x01000193) & 0x7fffffff;
      }
    }
    return hash;
  }

  @override
  Widget build(BuildContext context) {
    final materialColors = Theme.of(context).colorScheme;
    final palette = _DesktopGraphPalette.forBrightness(
      materialColors.brightness,
      widget.preferences.colorPreset,
    );
    final topology = _ensureTopology();
    final semanticNodes = topology.nodes;
    final edges = topology.edges;
    final visibleSemanticEdges = _ensureVisibleSemanticEdges(topology);
    final selection = _viewMode == DesktopGraphViewMode.sphere
        ? _selectionNeighborhood(edges)
        : const _GraphSelectionNeighborhood.empty();
    final usePhysics = _usesPhysicsLayout(semanticNodes);
    final topologyRevision = topology.revision;
    final graphPointCount = DesktopKnowledgeGraph.graphPointCountFor(
      widget.documents,
    );
    return Semantics(
      label:
          '知识图谱，${widget.documents.length} 篇文稿，'
          '$graphPointCount 个图谱点',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (size.isEmpty) return const SizedBox.expand();
          late final List<_ProjectedNode> projected;
          late final List<DesktopSphereGraphVisualLink> sphereMeshLinks;
          if (_viewMode == DesktopGraphViewMode.sphere) {
            _stopDenseMotionTicker();
            _physics.setIdleMotionEnabled(false, notify: false);
            _physics.freeze(notify: false);
            _densePhysics.setIdleMotionEnabled(false, notify: false);
            _densePhysics.freeze(notify: false);
            _physicsTicker.stop();
            _ensureSphereLayout(semanticNodes);
            projected = _projectSphereNodes(size, semanticNodes, selection);
            sphereMeshLinks = _visibleSphereLinks(
              _sphereVisualLinks,
              semanticNodes.length,
            );
          } else {
            final graphEdges = topology.physicsEdges;
            final graphCommunities = topology.communities;
            _ensureRadialLayout(
              topologyRevision: topologyRevision,
              viewport: size,
              nodes: semanticNodes,
              edges: graphEdges,
              communities: graphCommunities,
            );
            if (usePhysics) {
              _stopDenseMotionTicker();
              _densePhysics.setIdleMotionEnabled(false, notify: false);
              _densePhysics.freeze(notify: false);
              _physics.synchronize(
                viewport: size,
                topologyRevision: topologyRevision,
                nodes: _radialPixelPhysicsNodes,
                edges: graphEdges,
                communities: graphCommunities,
                notify: false,
              );
              if (_reduceMotion) {
                _physics.setIdleMotionEnabled(false, notify: false);
                _physics.freeze(notify: false);
              } else {
                _physics.setIdleMotionEnabled(true, notify: false);
                _physics.unfreeze(notify: false);
                _schedulePhysicsTicker();
              }
              projected = _projectFlatNodes(size, semanticNodes);
              sphereMeshLinks = const <DesktopSphereGraphVisualLink>[];
            } else {
              _physics.setIdleMotionEnabled(false, notify: false);
              _physics.freeze(notify: false);
              _physicsTicker.stop();
              _densePhysics.synchronize(
                viewport: size,
                topologyRevision: topologyRevision,
                nodes: _radialNormalizedPhysicsNodes,
                notify: false,
              );
              if (_reduceMotion) {
                _densePhysics.setIdleMotionEnabled(false, notify: false);
                _densePhysics.freeze(notify: false);
              } else {
                _densePhysics
                  ..setIdleMotionEnabled(true, notify: false)
                  ..unfreeze(notify: false);
                _scheduleDenseMotionTicker();
              }
              projected = _refreshDenseProjectedNodes(size, semanticNodes);
              sphereMeshLinks = const <DesktopSphereGraphVisualLink>[];
            }
          }
          final selected = _selectedNode(semanticNodes);
          return ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent) {
                        _zoomBy(
                          event.scrollDelta.dy > 0
                              ? 1 / _wheelZoomFactor
                              : _wheelZoomFactor,
                          viewport: size,
                          focalPoint: event.localPosition,
                        );
                      }
                    },
                    child: GestureDetector(
                      key: const ValueKey<String>('knowledge-graph'),
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onTapUp: (details) => _selectAt(
                        details.localPosition,
                        _projectedNodesForInteraction(projected),
                      ),
                      onDoubleTapDown: (details) {
                        final hit = _hitTest(
                          details.localPosition,
                          _projectedNodesForInteraction(projected),
                        );
                        _doubleTapNodeId = hit?.node.id;
                        if (hit != null) {
                          setState(() => _selectedId = hit.node.id);
                          widget.onSelectionChanged(
                            _selectionForNode(hit.node),
                          );
                        }
                      },
                      onDoubleTap: () {
                        final id = _doubleTapNodeId;
                        _doubleTapNodeId = null;
                        if (id == null) {
                          _reset();
                          return;
                        }
                        for (final node in semanticNodes) {
                          if (node.id == id) {
                            _openNode(node);
                            return;
                          }
                        }
                      },
                      onDoubleTapCancel: () => _doubleTapNodeId = null,
                      onPanStart: (details) {
                        _doubleTapNodeId = null;
                        if (_viewMode == DesktopGraphViewMode.flat) {
                          if (_draggedNodeId != null) _endFlatDrag();
                          final beganDrag = _beginFlatDrag(
                            details.localPosition,
                            _projectedNodesForInteraction(projected),
                            size,
                            usePhysics,
                          );
                          if (!beganDrag && _scale > 1) {
                            _beginPan(details.localPosition);
                          }
                        } else if (_scale > 1 &&
                            HardwareKeyboard.instance.isShiftPressed) {
                          _beginPan(details.localPosition);
                        }
                      },
                      onPanUpdate: (details) {
                        if (_viewMode == DesktopGraphViewMode.flat) {
                          if (_isPanning) {
                            _updatePan(details.localPosition, size);
                            return;
                          }
                          _updateFlatDrag(details.localPosition, size);
                          return;
                        }
                        if (_isPanning) {
                          _updatePan(details.localPosition, size);
                          return;
                        }
                        setState(() {
                          _rotationY +=
                              details.delta.dx * _sphereDragSensitivity;
                          _rotationX =
                              (_rotationX -
                                      details.delta.dy * _sphereDragSensitivity)
                                  .clamp(-math.pi / 2, math.pi / 2)
                                  .toDouble();
                        });
                      },
                      onPanEnd: (_) {
                        _endFlatDrag(size, true);
                        _endPan();
                      },
                      onPanCancel: () {
                        _endFlatDrag(size);
                        _endPan();
                      },
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _DesktopGraphPainter(
                            projectedNodes: projected,
                            semanticEdges: visibleSemanticEdges,
                            sphereMeshLinks: sphereMeshLinks,
                            selectedId: _selectedId,
                            palette: palette,
                            isSphere: _viewMode == DesktopGraphViewMode.sphere,
                            sphereScale: _scale,
                            viewPan: _pan,
                            showNoteLabels: _scale >= _noteLabelRevealScale,
                            dragPreview: _dragPreview,
                            liveProjectedNodes:
                                _viewMode == DesktopGraphViewMode.flat &&
                                    !usePhysics
                                ? _denseProjectedNodes
                                : null,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 14,
                  right: 14,
                  child: _GraphControls(
                    scale: _scale,
                    viewMode: _viewMode,
                    palette: palette,
                    onZoomIn: () => _zoomBy(_controlZoomFactor, viewport: size),
                    onZoomOut: () =>
                        _zoomBy(1 / _controlZoomFactor, viewport: size),
                    onReset: _reset,
                    onViewModeChanged: _setViewMode,
                  ),
                ),
                if (selected != null)
                  Positioned(
                    left: 18,
                    bottom: 18,
                    child: _SelectedNodeControl(
                      node: selected,
                      palette: palette,
                      onOpen: selected.kind == _GraphNodeKind.brain
                          ? null
                          : () => _openNode(selected),
                      onAddToContext: selected.kind == _GraphNodeKind.brain
                          ? null
                          : () => widget.onAddToContext(
                              _selectionForNode(selected),
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _GraphNodeKind { brain, document, reference, ambient }

final class _GraphNode {
  const _GraphNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.role,
    required this.community,
    required this.settlementId,
    this.documentId,
    this.referenceTitle,
  });

  factory _GraphNode.synthetic(String id) => _GraphNode(
    id: id,
    label: '',
    kind: _GraphNodeKind.ambient,
    role: DesktopGraphNodeRole.satellite,
    community: DesktopGraphCommunity.viewpointTrend,
    settlementId: 'ambient-$id',
  );

  final String id;
  final String label;
  final _GraphNodeKind kind;
  final DesktopGraphNodeRole role;
  final DesktopGraphCommunity community;
  final String settlementId;
  final String? documentId;
  final String? referenceTitle;

  bool get isSelectable => kind != _GraphNodeKind.ambient;

  double get baseRadius => switch (kind) {
    _GraphNodeKind.brain => 8.0,
    _GraphNodeKind.document => 8.0,
    _GraphNodeKind.reference => 7.0,
    _GraphNodeKind.ambient => 6.8,
  };
}

final class _GraphEdge {
  const _GraphEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.kind,
    required this.weight,
  });

  final String id;
  final String sourceId;
  final String targetId;
  final DesktopGraphRelationKind kind;
  final double weight;
}

final class _GraphTopologySnapshot {
  const _GraphTopologySnapshot({
    required this.nodes,
    required this.edges,
    required this.physicsEdges,
    required this.communities,
    required this.revision,
    required this.documentSignature,
  });

  final List<_GraphNode> nodes;
  final List<_GraphEdge> edges;
  final List<DesktopGraphPhysicsEdge> physicsEdges;
  final List<DesktopGraphCommunitySnapshot> communities;
  final int revision;
  final int documentSignature;
}

final class _GraphSelectionNeighborhood {
  const _GraphSelectionNeighborhood({
    required this.selectedId,
    required this.firstDegree,
    required this.secondDegree,
  });

  const _GraphSelectionNeighborhood.empty()
    : selectedId = null,
      firstDegree = const <String>{},
      secondDegree = const <String>{};

  final String? selectedId;
  final Set<String> firstDegree;
  final Set<String> secondDegree;
}

@immutable
final class _GraphDragPreview {
  const _GraphDragPreview({required this.nodeId, required this.position});

  final String nodeId;
  final Offset position;
}

final class _ProjectedNode {
  const _ProjectedNode({
    required this.node,
    required this.position,
    required this.cameraDepth,
    required this.depth,
    required this.sizeFactor,
    required this.opacity,
    required this.nodeScale,
    required this.baseRadius,
  });

  final _GraphNode node;
  final Offset position;
  final double cameraDepth;
  final double depth;
  final double sizeFactor;
  final double opacity;
  final double nodeScale;
  final double baseRadius;

  _ProjectedNode withPosition(Offset position) => _ProjectedNode(
    node: node,
    position: position,
    cameraDepth: cameraDepth,
    depth: depth,
    sizeFactor: sizeFactor,
    opacity: opacity,
    nodeScale: nodeScale,
    baseRadius: baseRadius,
  );

  double get radius => baseRadius * sizeFactor * nodeScale;

  double get hitRadius =>
      baseRadius <= 3 ? math.max(5, radius + 3) : math.max(12, radius + 6);
}

@immutable
final class _DesktopGraphPalette {
  const _DesktopGraphPalette({
    required this.canvas,
    required this.surface,
    required this.line,
    required this.text,
    required this.markers,
  });

  factory _DesktopGraphPalette.forBrightness(
    Brightness brightness,
    DesktopGraphColorPreset preset,
  ) {
    final dark = brightness == Brightness.dark;
    return switch (preset) {
      DesktopGraphColorPreset.mistSilver =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF121313),
                surface: Color(0xFF1A1B1B),
                line: Color(0xFF343838),
                text: Color(0xFFE7E9E8),
                markers: <Color>[
                  Color(0xFFE9EBEA),
                  Color(0xFF8FA6B5),
                  Color(0xFF91A695),
                  Color(0xFFB2A098),
                  Color(0xFFB9A37D),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFDFDFD),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE3E7E6),
                text: Color(0xFF292B2B),
                markers: <Color>[
                  Color(0xFF252728),
                  Color(0xFF5E7484),
                  Color(0xFF718375),
                  Color(0xFF8A7C75),
                  Color(0xFFA08862),
                ],
              ),
      DesktopGraphColorPreset.tide =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF101516),
                surface: Color(0xFF172022),
                line: Color(0xFF2D3B3E),
                text: Color(0xFFE2EAEB),
                markers: <Color>[
                  Color(0xFFDDE8EA),
                  Color(0xFF7FA8B5),
                  Color(0xFF86AD9D),
                  Color(0xFFC89489),
                  Color(0xFF94A6BA),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFBFCFC),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFDDE7E8),
                text: Color(0xFF25363B),
                markers: <Color>[
                  Color(0xFF1F3A4A),
                  Color(0xFF477687),
                  Color(0xFF5D8B7D),
                  Color(0xFFB87569),
                  Color(0xFF76879B),
                ],
              ),
      DesktopGraphColorPreset.mountainMist =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF121513),
                surface: Color(0xFF1A1F1C),
                line: Color(0xFF343D38),
                text: Color(0xFFE4E9E5),
                markers: <Color>[
                  Color(0xFFE4E9E5),
                  Color(0xFF8FA99A),
                  Color(0xFFA1A9A7),
                  Color(0xFFC3A36F),
                  Color(0xFF91A8B3),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFCFCFA),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE2E6E2),
                text: Color(0xFF29342F),
                markers: <Color>[
                  Color(0xFF294239),
                  Color(0xFF5F746A),
                  Color(0xFF788184),
                  Color(0xFFB18B52),
                  Color(0xFF78909C),
                ],
              ),
      DesktopGraphColorPreset.editorial =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF141413),
                surface: Color(0xFF1D1D1B),
                line: Color(0xFF393936),
                text: Color(0xFFEAEAE6),
                markers: <Color>[
                  Color(0xFFEAEAE6),
                  Color(0xFF8298A6),
                  Color(0xFFAAA9A2),
                  Color(0xFFB8878E),
                  Color(0xFFB9A581),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFDFDFC),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE7E5E1),
                text: Color(0xFF292927),
                markers: <Color>[
                  Color(0xFF222322),
                  Color(0xFF4F6474),
                  Color(0xFF74736D),
                  Color(0xFF865D63),
                  Color(0xFF9A8462),
                ],
              ),
      DesktopGraphColorPreset.nightVoyage =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF111318),
                surface: Color(0xFF191C22),
                line: Color(0xFF333843),
                text: Color(0xFFE6E9EC),
                markers: <Color>[
                  Color(0xFFE6E9EC),
                  Color(0xFF8FA4B7),
                  Color(0xFFA19CAF),
                  Color(0xFFC0997D),
                  Color(0xFF8EA79F),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFCFCFD),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE1E3E8),
                text: Color(0xFF2C3038),
                markers: <Color>[
                  Color(0xFF2C3743),
                  Color(0xFF586B7D),
                  Color(0xFF716E82),
                  Color(0xFFA07C62),
                  Color(0xFF69817B),
                ],
              ),
      DesktopGraphColorPreset.electricYouth =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF11131B),
                surface: Color(0xFF191C28),
                line: Color(0xFF343952),
                text: Color(0xFFF0F3FF),
                markers: <Color>[
                  Color(0xFFE8EEFF),
                  Color(0xFF6380FF),
                  Color(0xFF42C4FF),
                  Color(0xFFB5F13B),
                  Color(0xFFFF7469),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFCFCFF),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE0E4F0),
                text: Color(0xFF1E2436),
                markers: <Color>[
                  Color(0xFF1837D7),
                  Color(0xFF0AA8FF),
                  Color(0xFF8EDB21),
                  Color(0xFFFF594D),
                  Color(0xFFFBCE35),
                ],
              ),
      DesktopGraphColorPreset.candySignal =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF18121A),
                surface: Color(0xFF231827),
                line: Color(0xFF433044),
                text: Color(0xFFFFF0FA),
                markers: <Color>[
                  Color(0xFFFFD9EF),
                  Color(0xFFFF64B5),
                  Color(0xFFA78AFF),
                  Color(0xFF52CBE5),
                  Color(0xFFFFA85D),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFFFCFF),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFF0E0EC),
                text: Color(0xFF342239),
                markers: <Color>[
                  Color(0xFFEE1C85),
                  Color(0xFF8857FF),
                  Color(0xFF20B6D7),
                  Color(0xFFFF8A3D),
                  Color(0xFFF4CA22),
                ],
              ),
      DesktopGraphColorPreset.egoPulse =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF18111A),
                surface: Color(0xFF241728),
                line: Color(0xFF46334C),
                text: Color(0xFFFFF0FB),
                markers: <Color>[
                  Color(0xFFFFE0F5),
                  Color(0xFF9A6CFF),
                  Color(0xFFFF67BB),
                  Color(0xFFFF825F),
                  Color(0xFF66D5BB),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFFFCFF),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFF0E1EF),
                text: Color(0xFF342238),
                markers: <Color>[
                  Color(0xFF612CEB),
                  Color(0xFFE12D9C),
                  Color(0xFFF05D3C),
                  Color(0xFF00A98F),
                  Color(0xFFF2D44B),
                ],
              ),
      DesktopGraphColorPreset.pureInk =>
        dark
            ? const _DesktopGraphPalette(
                canvas: Color(0xFF121212),
                surface: Color(0xFF1A1A1A),
                line: Color(0xFF363839),
                text: Color(0xFFECEDEC),
                markers: <Color>[
                  Color(0xFFECEDEC),
                  Color(0xFFC7C9C8),
                  Color(0xFFA1A5A5),
                  Color(0xFF7B8081),
                  Color(0xFF5D6264),
                ],
              )
            : const _DesktopGraphPalette(
                canvas: Color(0xFFFCFCFC),
                surface: Color(0xFFFFFFFF),
                line: Color(0xFFE3E4E4),
                text: Color(0xFF242526),
                markers: <Color>[
                  Color(0xFF18191A),
                  Color(0xFF3F4244),
                  Color(0xFF63676A),
                  Color(0xFF888C8F),
                  Color(0xFFB0B4B6),
                ],
              ),
    };
  }

  final Color canvas;
  final Color surface;
  final Color line;
  final Color text;
  final List<Color> markers;

  Color markerFor(_GraphNode node) {
    if (node.kind == _GraphNodeKind.brain) return markers.first;
    return markers[(node.community.index + 1) % markers.length];
  }

  Color syntheticMarkerFor(String id) {
    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return markers[hash % markers.length];
  }
}

final class _DesktopGraphPainter extends CustomPainter {
  _DesktopGraphPainter({
    required this.projectedNodes,
    required this.semanticEdges,
    required this.sphereMeshLinks,
    required this.selectedId,
    required this.palette,
    required this.isSphere,
    required this.sphereScale,
    required this.viewPan,
    required this.showNoteLabels,
    required this.dragPreview,
    this.liveProjectedNodes,
  }) : super(
         repaint: Listenable.merge(<Listenable?>[
           dragPreview,
           liveProjectedNodes,
         ]),
       );

  final List<_ProjectedNode> projectedNodes;
  final List<_GraphEdge> semanticEdges;
  final List<DesktopSphereGraphVisualLink> sphereMeshLinks;
  final String? selectedId;
  final _DesktopGraphPalette palette;
  final bool isSphere;
  final double sphereScale;
  final Offset viewPan;
  final bool showNoteLabels;
  final ValueListenable<_GraphDragPreview?> dragPreview;
  final ValueListenable<List<_ProjectedNode>>? liveProjectedNodes;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.canvas);
    final visibleNodes = _nodesWithDragPreview();
    final denseGraph =
        visibleNodes.where((node) => node.node.isSelectable).length > 320;
    final byId = <String, _ProjectedNode>{
      for (final node in visibleNodes) node.node.id: node,
    };
    if (isSphere) {
      final sortedMeshLinks = <_SphereMeshLinkGeometry>[
        for (final link in sphereMeshLinks)
          if (byId[link.sourceId] case final source?)
            if (byId[link.targetId] case final target?)
              _SphereMeshLinkGeometry(
                link: link,
                source: source,
                target: target,
              ),
      ]..sort((left, right) => left.depth.compareTo(right.depth));
      for (final geometry in sortedMeshLinks) {
        _paintSphereMeshLink(canvas, geometry);
      }
    }
    final sortedEdges = <_SemanticEdgeGeometry>[
      for (final edge in semanticEdges)
        if (byId[edge.sourceId] case final source?)
          if (byId[edge.targetId] case final target?)
            _SemanticEdgeGeometry(edge: edge, source: source, target: target),
    ]..sort((left, right) => left.depth.compareTo(right.depth));
    for (final geometry in sortedEdges) {
      _paintSemanticEdge(
        canvas,
        geometry,
        denseGraph: denseGraph,
        viewport: size,
      );
    }

    final sortedNodes = List<_ProjectedNode>.of(visibleNodes)
      ..sort((left, right) => left.cameraDepth.compareTo(right.cameraDepth));
    for (final node in sortedNodes) {
      if (node.node.kind == _GraphNodeKind.ambient) {
        _paintSyntheticNode(canvas, node);
      }
    }
    for (final node in sortedNodes) {
      if (node.node.kind != _GraphNodeKind.ambient) {
        _paintSemanticNode(canvas, node, denseGraph: denseGraph);
      }
    }
    if (showNoteLabels) {
      _paintVisibleNoteLabels(canvas, size, sortedNodes);
    }
  }

  void _paintVisibleNoteLabels(
    Canvas canvas,
    Size size,
    List<_ProjectedNode> sortedNodes,
  ) {
    final bounds = Offset.zero & size;
    final center = size.center(Offset.zero);
    final candidates =
        <_ProjectedNode>[
          for (final node in sortedNodes)
            if (node.node.kind == _GraphNodeKind.document ||
                node.node.kind == _GraphNodeKind.reference)
              if (bounds.inflate(24).contains(node.position)) node,
        ]..sort((left, right) {
          final leftSelected = left.node.id == selectedId;
          final rightSelected = right.node.id == selectedId;
          if (leftSelected != rightSelected) return leftSelected ? -1 : 1;
          final leftCore = left.node.role == DesktopGraphNodeRole.core;
          final rightCore = right.node.role == DesktopGraphNodeRole.core;
          if (leftCore != rightCore) return leftCore ? -1 : 1;
          return (left.position - center).distanceSquared.compareTo(
            (right.position - center).distanceSquared,
          );
        });
    if (candidates.isEmpty) return;

    const labelCellWidth = 88.0;
    const labelCellHeight = 24.0;
    final occupiedCells = <(int, int), List<Rect>>{};

    Iterable<(int, int)> cellsFor(Rect rect) sync* {
      final firstColumn = (rect.left / labelCellWidth).floor();
      final lastColumn = (rect.right / labelCellWidth).floor();
      final firstRow = (rect.top / labelCellHeight).floor();
      final lastRow = (rect.bottom / labelCellHeight).floor();
      for (var row = firstRow; row <= lastRow; row++) {
        for (var column = firstColumn; column <= lastColumn; column++) {
          yield (column, row);
        }
      }
    }

    bool overlapsOccupied(Rect candidate) {
      for (final cell in cellsFor(candidate)) {
        final existing = occupiedCells[cell];
        if (existing != null &&
            existing.any((bounds) => bounds.overlaps(candidate))) {
          return true;
        }
      }
      return false;
    }

    void occupy(Rect rect) {
      for (final cell in cellsFor(rect)) {
        (occupiedCells[cell] ??= <Rect>[]).add(rect);
      }
    }

    canvas.save();
    canvas.clipRect(bounds);
    for (final node in candidates) {
      final label = node.node.label.trim();
      if (label.isEmpty) continue;
      final estimatedPosition = node.position + Offset(node.radius + 5, -8.5);
      final estimatedWidth = math.min(
        156.0,
        math.max(42.0, label.runes.length * 10.5),
      );
      final estimatedBounds = Rect.fromLTWH(
        estimatedPosition.dx - 3,
        estimatedPosition.dy - 2,
        estimatedWidth + 6,
        21,
      );
      // Most dense candidates are rejected without allocating a TextPainter.
      // This stays collision based rather than applying a hard label cap.
      if (overlapsOccupied(estimatedBounds)) continue;
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: palette.text.withValues(alpha: isSphere ? .92 : .88),
            fontSize: 10.5,
            fontWeight: node.node.role == DesktopGraphNodeRole.core
                ? FontWeight.w600
                : FontWeight.w500,
            shadows: <Shadow>[
              Shadow(
                color: palette.canvas.withValues(alpha: .94),
                blurRadius: 4,
              ),
            ],
          ),
        ),
        maxLines: 1,
        ellipsis: '...',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 156);
      final position =
          node.position + Offset(node.radius + 5, -textPainter.height / 2);
      final labelBounds = Rect.fromLTWH(
        position.dx - 3,
        position.dy - 2,
        textPainter.width + 6,
        textPainter.height + 4,
      );
      if (overlapsOccupied(labelBounds)) {
        textPainter.dispose();
        continue;
      }
      occupy(estimatedBounds.expandToInclude(labelBounds));
      canvas.drawRRect(
        RRect.fromRectAndRadius(labelBounds, const Radius.circular(3)),
        Paint()..color = palette.canvas.withValues(alpha: .82),
      );
      textPainter.paint(canvas, position);
      textPainter.dispose();
    }
    canvas.restore();
  }

  List<_ProjectedNode> _nodesWithDragPreview() {
    final preview = dragPreview.value;
    final semanticNodes = liveProjectedNodes?.value ?? projectedNodes;
    if (preview == null) return semanticNodes;
    return <_ProjectedNode>[
      for (final node in semanticNodes)
        if (node.node.id == preview.nodeId)
          node.withPosition(preview.position)
        else
          node,
    ];
  }

  double _sphereDepthFactor(double depth) =>
      math.pow(depth.clamp(0.0, 1.0), .82).toDouble();

  double _sphereDepthRadiusFactor(double depth) =>
      _lerp(.72, 1.16, _sphereDepthFactor(depth));

  double _sphereDepthColorStrength(double depth) =>
      _lerp(.30, 1, _sphereDepthFactor(depth));

  double _sphereDepthOpacityFactor(double depth) =>
      _lerp(.82, 1, _sphereDepthFactor(depth));

  Color _sphereDepthColor(Color source, double depth) =>
      Color.lerp(palette.canvas, source, _sphereDepthColorStrength(depth))!;

  Color get _graphite => palette.canvas.computeLuminance() >= .5
      ? const Color(0xFF353A40)
      : const Color(0xFFA3A8B0);

  /// The pre-surface 3D view keeps depth on the nodes and renders links as
  /// direct volume chords, rather than routing them around a sphere shell.
  void _paintSphereMeshLink(Canvas canvas, _SphereMeshLinkGeometry geometry) {
    final depth = ((geometry.depth + 1) / 2).clamp(0.0, 1.0).toDouble();
    final depthFactor = _sphereDepthFactor(depth);
    final quieting = geometry.link.touchesSyntheticPoint ? .72 : 1.0;
    final opacity = (_lerp(.018, .105, depthFactor) * quieting).clamp(
      .006,
      .11,
    );
    canvas.drawLine(
      geometry.source.position,
      geometry.target.position,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = _lerp(.34, .74, depthFactor) * quieting
        ..color = _graphite.withValues(alpha: opacity),
    );
  }

  void _paintSemanticEdge(
    Canvas canvas,
    _SemanticEdgeGeometry geometry, {
    required bool denseGraph,
    required Size viewport,
  }) {
    final selected =
        selectedId != null &&
        (geometry.edge.sourceId == selectedId ||
            geometry.edge.targetId == selectedId);
    final endpointOpacity = math.min(
      geometry.source.opacity,
      geometry.target.opacity,
    );
    final baseOpacity = selected
        ? .72
        : switch (geometry.edge.kind) {
            // Membership is structural, not the visual focus. Keeping it
            // lighter than mobile's compact canvas prevents a large desktop
            // workspace from reading as a four-quadrant mind map.
            DesktopGraphRelationKind.membership =>
              denseGraph && !isSphere ? .18 : .07,
            DesktopGraphRelationKind.communityAffinity =>
              denseGraph && !isSphere ? .32 : .24,
            DesktopGraphRelationKind.linkedMaterial => .42,
            DesktopGraphRelationKind.sharedTopic => .34,
            DesktopGraphRelationKind.sharedContentLine => .38,
            DesktopGraphRelationKind.other => .30,
          };
    final normalizedDepth = isSphere
        ? ((geometry.depth + 1) / 2).clamp(0.0, 1.0)
        : 1.0;
    final depthFactor = isSphere ? _sphereDepthFactor(normalizedDepth) : 1.0;
    final minimumOpacity = isSphere ? (selected ? .028 : .004) : .02;
    final opacity = (baseOpacity * endpointOpacity * _lerp(.72, 1, depthFactor))
        .clamp(minimumOpacity, .82);
    final baseStrokeWidth = selected ? 1.65 : .65 + geometry.edge.weight * .42;
    final strokeWidth =
        baseStrokeWidth * (isSphere ? _lerp(.56, 1.16, depthFactor) : 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth
      ..color = _graphite.withValues(alpha: opacity);
    if (isSphere) {
      canvas.drawLine(
        geometry.source.position,
        geometry.target.position,
        paint,
      );
      return;
    }
    canvas.drawPath(_semanticPath(geometry, viewport), paint);
  }

  Path _semanticPath(_SemanticEdgeGeometry geometry, Size viewport) {
    final source = geometry.source.position;
    final target = geometry.target.position;
    final delta = target - source;
    final distance = delta.distance;
    if (distance < .01) {
      return Path()..addOval(Rect.fromCircle(center: source, radius: 1));
    }

    final normal = Offset(-delta.dy / distance, delta.dx / distance);
    final midpoint = Offset(
      (source.dx + target.dx) / 2,
      (source.dy + target.dy) / 2,
    );
    final inward = viewport.center(Offset.zero) - midpoint;
    final inwardDistance = inward.distance;
    final inwardStrength = switch (geometry.edge.kind) {
      DesktopGraphRelationKind.membership => .08,
      DesktopGraphRelationKind.communityAffinity => .15,
      DesktopGraphRelationKind.linkedMaterial => .20,
      DesktopGraphRelationKind.sharedContentLine => .34,
      DesktopGraphRelationKind.sharedTopic => .24,
      DesktopGraphRelationKind.other => .21,
    };
    final inwardPull = inwardDistance <= .01
        ? Offset.zero
        : inward /
              inwardDistance *
              math.min(distance * .26, inwardDistance * inwardStrength);
    final bend = math.min(34, distance * .14) * _edgeBend(geometry.edge.id);
    final control = midpoint + inwardPull + normal * bend;
    return Path()
      ..moveTo(source.dx, source.dy)
      ..quadraticBezierTo(control.dx, control.dy, target.dx, target.dy);
  }

  double _edgeBend(String id) {
    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.isEven ? 1 : -1;
  }

  void _paintSyntheticNode(Canvas canvas, _ProjectedNode node) {
    final normalizedDepth = node.depth.clamp(0.0, 1.0);
    final radius =
        node.radius *
        (isSphere ? _sphereDepthRadiusFactor(normalizedDepth) : 1.0);
    if (!radius.isFinite || radius <= 0) return;
    final color = isSphere
        ? _sphereDepthColor(_nodeColor(node), normalizedDepth)
        : _nodeColor(node);
    final opacity =
        (node.opacity *
                (isSphere ? _sphereDepthOpacityFactor(normalizedDepth) : 1.0))
            .clamp(isSphere ? .018 : .05, .72);
    canvas.drawCircle(
      node.position,
      radius * .54,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: opacity * .66),
    );
    canvas.drawCircle(
      node.position - Offset(radius * .12, radius * .12),
      math.max(.38, radius * .18),
      Paint()
        ..style = PaintingStyle.fill
        ..color = Color.lerp(
          color,
          Colors.white,
          .68,
        )!.withValues(alpha: opacity * .86),
    );
  }

  void _paintSemanticNode(
    Canvas canvas,
    _ProjectedNode node, {
    required bool denseGraph,
  }) {
    final selected = node.node.id == selectedId;
    final color = _nodeColor(node);
    final baseRadius = node.radius;
    final opacity = node.opacity;
    if (!isSphere) {
      final radius = baseRadius;
      final displayRadius = denseGraph
          ? switch (node.node.role) {
              DesktopGraphNodeRole.center => math.max(2.2, radius * .72),
              DesktopGraphNodeRole.core => math.max(1.45, radius * .58),
              DesktopGraphNodeRole.satellite => math.max(.7, radius * .4),
            }
          : radius;
      if (!denseGraph) {
        canvas.drawCircle(
          node.position,
          displayRadius * .78,
          Paint()..color = color.withValues(alpha: .14),
        );
      }
      canvas.drawCircle(
        node.position,
        denseGraph ? displayRadius : displayRadius * .5,
        Paint()..color = color.withValues(alpha: 1),
      );
      if (!denseGraph || node.node.role != DesktopGraphNodeRole.satellite) {
        canvas.drawCircle(
          node.position - Offset(displayRadius * .12, displayRadius * .12),
          denseGraph
              ? math.max(.42, displayRadius * .24)
              : math.max(.55, displayRadius * .12),
          Paint()..color = Colors.white.withValues(alpha: .72),
        );
      }
      if (selected) {
        canvas.drawCircle(
          node.position,
          displayRadius + 4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.15
            ..color = color.withValues(alpha: .9),
        );
      }
      return;
    }
    final normalizedDepth = node.depth.clamp(0.0, 1.0);
    final depthFactor = _sphereDepthFactor(normalizedDepth);
    final radius = baseRadius * _sphereDepthRadiusFactor(normalizedDepth);
    final shadedColor = _sphereDepthColor(color, normalizedDepth);
    final visibleOpacity =
        (opacity * _sphereDepthOpacityFactor(normalizedDepth)).clamp(.018, 1.0);
    final strength = selected ? 1.0 : .78;
    if (denseGraph && !selected) {
      canvas.drawCircle(
        node.position,
        math.max(.42, radius * .52),
        Paint()
          ..style = PaintingStyle.fill
          ..color = shadedColor.withValues(
            alpha: _lerp(.5, .94, depthFactor) * strength * visibleOpacity,
          ),
      );
      return;
    }
    final bodyRadius = math.max(.72, radius * .48);
    final bodyBounds = Rect.fromCircle(
      center: node.position,
      radius: bodyRadius,
    );
    final highlight = Color.lerp(shadedColor, Colors.white, .62)!;
    final edgeShade = Color.lerp(shadedColor, palette.canvas, .42)!;
    canvas.drawCircle(
      node.position,
      bodyRadius,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = RadialGradient(
          center: const Alignment(-.34, -.38),
          radius: 1.14,
          colors: <Color>[
            highlight.withValues(alpha: .98 * strength * visibleOpacity),
            shadedColor.withValues(alpha: .98 * strength * visibleOpacity),
            edgeShade.withValues(alpha: .94 * strength * visibleOpacity),
          ],
          stops: const <double>[0, .38, 1],
        ).createShader(bodyBounds),
    );
    canvas.drawCircle(
      node.position - Offset(bodyRadius * .27, bodyRadius * .3),
      math.max(.36, bodyRadius * .13),
      Paint()
        ..color = Colors.white.withValues(
          alpha: _lerp(.26, .78, depthFactor) * visibleOpacity,
        ),
    );
    if (selected) {
      canvas.drawCircle(
        node.position,
        bodyRadius + 4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = shadedColor.withValues(alpha: .9),
      );
      canvas.drawCircle(
        node.position,
        bodyRadius + 2.1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8
          ..color = shadedColor.withValues(alpha: .48),
      );
    }
  }

  Color _nodeColor(_ProjectedNode node) =>
      node.node.kind == _GraphNodeKind.ambient
      ? palette.syntheticMarkerFor(node.node.id)
      : palette.markerFor(node.node);

  @override
  bool shouldRepaint(covariant _DesktopGraphPainter oldDelegate) =>
      oldDelegate.selectedId != selectedId ||
      oldDelegate.palette != palette ||
      oldDelegate.isSphere != isSphere ||
      oldDelegate.sphereScale != sphereScale ||
      oldDelegate.viewPan != viewPan ||
      oldDelegate.dragPreview != dragPreview ||
      oldDelegate.liveProjectedNodes != liveProjectedNodes ||
      !listEquals(oldDelegate.projectedNodes, projectedNodes) ||
      !listEquals(oldDelegate.semanticEdges, semanticEdges) ||
      !listEquals(oldDelegate.sphereMeshLinks, sphereMeshLinks);
}

final class _SemanticEdgeGeometry {
  const _SemanticEdgeGeometry({
    required this.edge,
    required this.source,
    required this.target,
  });

  final _GraphEdge edge;
  final _ProjectedNode source;
  final _ProjectedNode target;

  double get depth => (source.cameraDepth + target.cameraDepth) / 2;
}

final class _SphereMeshLinkGeometry {
  const _SphereMeshLinkGeometry({
    required this.link,
    required this.source,
    required this.target,
  });

  final DesktopSphereGraphVisualLink link;
  final _ProjectedNode source;
  final _ProjectedNode target;

  double get depth => (source.cameraDepth + target.cameraDepth) / 2;
}

double _lerp(double start, double end, double amount) =>
    start + (end - start) * amount;

final class _GraphControls extends StatelessWidget {
  const _GraphControls({
    required this.scale,
    required this.viewMode,
    required this.palette,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.onViewModeChanged,
  });

  final double scale;
  final DesktopGraphViewMode viewMode;
  final _DesktopGraphPalette palette;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final ValueChanged<DesktopGraphViewMode> onViewModeChanged;

  @override
  Widget build(BuildContext context) {
    return _GraphControlSurface(
      palette: palette,
      borderRadius: 15,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GraphModeButton(
              label: '2D',
              selected: viewMode == DesktopGraphViewMode.flat,
              palette: palette,
              onPressed: () => onViewModeChanged(DesktopGraphViewMode.flat),
            ),
            _GraphModeButton(
              label: '3D',
              selected: viewMode == DesktopGraphViewMode.sphere,
              palette: palette,
              onPressed: () => onViewModeChanged(DesktopGraphViewMode.sphere),
            ),
            _GraphToolIcon(
              key: const ValueKey<String>('graph-zoom-out'),
              tooltip: '缩小图谱',
              icon: LucideIcons.zoomOut,
              onPressed: onZoomOut,
            ),
            SizedBox(
              width: 42,
              child: Text(
                '${(scale * 100).round()}%',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.text, fontSize: 11),
              ),
            ),
            _GraphToolIcon(
              key: const ValueKey<String>('graph-zoom-in'),
              tooltip: '放大图谱',
              icon: LucideIcons.zoomIn,
              onPressed: onZoomIn,
            ),
            _GraphToolIcon(
              key: const ValueKey<String>('graph-reset'),
              tooltip: '重置图谱视图',
              icon: LucideIcons.rotateCcw,
              onPressed: onReset,
            ),
          ],
        ),
      ),
    );
  }
}

final class _GraphModeButton extends StatelessWidget {
  const _GraphModeButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final _DesktopGraphPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? palette.markers.first.withValues(alpha: .12)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 48,
        height: 34,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: palette.text,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _GraphToolIcon extends StatelessWidget {
  const _GraphToolIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      visualDensity: VisualDensity.compact,
    ),
  );
}

final class _SelectedNodeControl extends StatelessWidget {
  const _SelectedNodeControl({
    required this.node,
    required this.palette,
    required this.onOpen,
    required this.onAddToContext,
  });

  final _GraphNode node;
  final _DesktopGraphPalette palette;
  final VoidCallback? onOpen;
  final VoidCallback? onAddToContext;

  @override
  Widget build(BuildContext context) => _GraphControlSurface(
    palette: palette,
    borderRadius: 14,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            node.kind == _GraphNodeKind.document
                ? LucideIcons.fileText
                : LucideIcons.network,
            size: 15,
            color: palette.text,
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (onOpen != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onOpen, child: const Text('打开')),
          ],
          if (onAddToContext != null)
            Tooltip(
              message: '加入聊天上下文',
              child: IconButton(
                key: const ValueKey<String>('graph-add-context'),
                onPressed: onAddToContext,
                icon: const Icon(LucideIcons.plus, size: 15),
              ),
            ),
        ],
      ),
    ),
  );
}

final class _GraphControlSurface extends StatelessWidget {
  const _GraphControlSurface({
    required this.palette,
    required this.borderRadius,
    required this.child,
  });

  final _DesktopGraphPalette palette;
  final double borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: palette.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 3,
    shadowColor: Colors.black.withValues(alpha: .08),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(color: palette.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}
