import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:forge2d/forge2d.dart';

import 'desktop_graph_preferences.dart';

enum DesktopGraphNodeRole { center, core, satellite }

enum DesktopGraphCommunity { viewpointTrend, method, inspiration, caseIndustry }

enum DesktopGraphRelationKind {
  membership,
  communityAffinity,
  linkedMaterial,
  sharedContentLine,
  sharedTopic,
  other,
}

@immutable
final class DesktopGraphPhysicsNode {
  // The stored value stays private so the public getter can preserve the
  // legacy community-derived grouping for older callers.
  const DesktopGraphPhysicsNode({
    required this.id,
    required this.role,
    required this.community,
    String? settlementId,
    this.seedPosition,
  })
    // ignore: prefer_initializing_formals
    : _settlementId = settlementId;

  final String id;
  final DesktopGraphNodeRole role;
  final DesktopGraphCommunity community;

  /// The physical settlement this node belongs to. Existing callers which
  /// predate settlements keep their former community grouping automatically.
  final String? _settlementId;
  String get settlementId {
    final id = _settlementId;
    return id == null || id.isEmpty ? 'community-${community.name}' : id;
  }

  final Offset? seedPosition;
}

@immutable
final class DesktopGraphPhysicsEdge {
  const DesktopGraphPhysicsEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.kind,
    this.weight = 1,
  });

  final String id;
  final String sourceId;
  final String targetId;
  final DesktopGraphRelationKind kind;
  final double weight;

  bool get isSelfLoop => sourceId == targetId;
}

@immutable
final class DesktopGraphCommunitySnapshot {
  const DesktopGraphCommunitySnapshot({
    required this.community,
    required this.coreNodeId,
    this.memberNodeIds = const <String>{},
  });

  final DesktopGraphCommunity community;
  final String coreNodeId;
  final Set<String> memberNodeIds;
}

@immutable
final class DesktopGraphPhysicsParameters {
  const DesktopGraphPhysicsParameters({
    this.attractionScale = 1,
    this.repulsionScale = 1,
    this.dampingScale = 1,
  });

  static const double minimumAttractionScale =
      DesktopGraphPreferences.minimumAttractionScale;
  static const double maximumAttractionScale =
      DesktopGraphPreferences.maximumAttractionScale;
  static const double minimumRepulsionScale =
      DesktopGraphPreferences.minimumRepulsionScale;
  static const double maximumRepulsionScale =
      DesktopGraphPreferences.maximumRepulsionScale;
  static const double minimumDampingScale =
      DesktopGraphPreferences.minimumDampingScale;
  static const double maximumDampingScale =
      DesktopGraphPreferences.maximumDampingScale;

  final double attractionScale;
  final double repulsionScale;
  final double dampingScale;

  /// Spring tension used by both detailed and dense 2D layouts.
  double get attractionResponse =>
      DesktopGraphPreferences.attractionResponseFor(attractionScale);

  /// Local separation strength used by both detailed and dense 2D layouts.
  double get repulsionResponse =>
      DesktopGraphPreferences.repulsionResponseFor(repulsionScale);

  /// Kinetic and spring damping shared by both 2D layouts.
  double get dampingResponse =>
      DesktopGraphPreferences.dampingResponseFor(dampingScale);

  DesktopGraphPhysicsParameters normalized() => DesktopGraphPhysicsParameters(
    attractionScale: _normalizedScale(
      attractionScale,
      minimumAttractionScale,
      maximumAttractionScale,
    ),
    repulsionScale: _normalizedScale(
      repulsionScale,
      minimumRepulsionScale,
      maximumRepulsionScale,
    ),
    dampingScale: _normalizedScale(
      dampingScale,
      minimumDampingScale,
      maximumDampingScale,
    ),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopGraphPhysicsParameters &&
          attractionScale == other.attractionScale &&
          repulsionScale == other.repulsionScale &&
          dampingScale == other.dampingScale;

  @override
  int get hashCode =>
      Object.hash(attractionScale, repulsionScale, dampingScale);
}

/// Shared viewport safety containment for every desktop 2D graph path.
///
/// This prevents an invalid drag or an unstable physics frame from placing a
/// node outside the usable canvas. It deliberately does not prescribe the
/// graph's visual geometry: concentric settlements belong to the layout, not
/// to a decorative circular boundary around the canvas.
@immutable
final class DesktopGraphViewportBounds {
  const DesktopGraphViewportBounds._({required this.viewport});

  factory DesktopGraphViewportBounds.forViewport(Size viewport) {
    final width = viewport.width.isFinite && viewport.width > 0
        ? viewport.width
        : 0.0;
    final height = viewport.height.isFinite && viewport.height > 0
        ? viewport.height
        : 0.0;
    return DesktopGraphViewportBounds._(viewport: Size(width, height));
  }

  final Size viewport;

  Offset get center => viewport.center(Offset.zero);

  bool contains(Offset position, {double inset = 0}) {
    if (!position.dx.isFinite || !position.dy.isFinite) return false;
    final bounds = _insetBounds(inset);
    return position.dx >= bounds.left - 1e-9 &&
        position.dx <= bounds.right + 1e-9 &&
        position.dy >= bounds.top - 1e-9 &&
        position.dy <= bounds.bottom + 1e-9;
  }

  Offset clamp(Offset position, {double inset = 0}) {
    if (!position.dx.isFinite || !position.dy.isFinite) return center;
    final bounds = _insetBounds(inset);
    return Offset(
      position.dx.clamp(bounds.left, bounds.right).toDouble(),
      position.dy.clamp(bounds.top, bounds.bottom).toDouble(),
    );
  }

  Offset toNormalized(Offset position) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return const Offset(.5, .5);
    }
    return Offset(position.dx / viewport.width, position.dy / viewport.height);
  }

  Offset fromNormalized(Offset position) {
    final x = position.dx.isFinite ? position.dx : .5;
    final y = position.dy.isFinite ? position.dy : .5;
    return Offset(x * viewport.width, y * viewport.height);
  }

  Offset clampNormalized(Offset position, {double inset = 0}) =>
      toNormalized(clamp(fromNormalized(position), inset: inset));

  Rect _insetBounds(double inset) {
    final safeInset = math.max(0.0, inset).toDouble();
    final horizontal = math.min(viewport.width / 2, safeInset).toDouble();
    final vertical = math.min(viewport.height / 2, safeInset).toDouble();
    return Rect.fromLTRB(
      horizontal,
      vertical,
      math.max(horizontal, viewport.width - horizontal),
      math.max(vertical, viewport.height - vertical),
    );
  }
}

/// Shared compact anchor geometry for fallback 2D graph seeds.
///
/// The primary layout supplies richer per-document positions. These anchors
/// keep every fallback path aligned with that layout when a seed is absent:
/// semantic communities remain close to the content brain without resolving
/// into the fixed four-quadrant shape used by earlier desktop prototypes.
final class DesktopGraphCentripetalAnchors {
  const DesktopGraphCentripetalAnchors._();

  static Offset compactCommunityAnchor({
    required DesktopGraphCommunity community,
    required Iterable<DesktopGraphCommunity> activeCommunities,
    required Offset center,
    required double radius,
  }) {
    final active = activeCommunities.toSet().toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final safeRadius = radius.isFinite ? math.max(0.0, radius).toDouble() : 0.0;
    if (active.isEmpty || !active.contains(community) || safeRadius <= 0) {
      return center;
    }
    final raw = _rawDirection(community);
    if (active.length == 1) return center + raw * (safeRadius * .58);
    final average =
        active
            .map(_rawDirection)
            .fold(Offset.zero, (sum, direction) => sum + direction) /
        active.length.toDouble();
    final relative = raw - average;
    final maximumDistance = active
        .fold<double>(
          0,
          (maximum, candidate) =>
              math.max(maximum, (_rawDirection(candidate) - average).distance),
        )
        .toDouble();
    if (maximumDistance <= 1e-9) return center;
    return center + relative / maximumDistance * safeRadius;
  }

  static Offset _rawDirection(DesktopGraphCommunity community) {
    const goldenAngle = 2.399963229728653;
    final phase = -math.pi / 2 + community.index * goldenAngle;
    final radialLength = .86 + (community.index % 3) * .075;
    return Offset(
      math.cos(phase) * radialLength,
      math.sin(phase) * radialLength,
    );
  }
}

/// Presentation-local port of the mobile V3 force simulation.
///
/// Its geometry is transient by design: it makes the desktop graph feel alive
/// without writing a physics frame into a note or a content snapshot.
final class DesktopGraphPhysicsSimulation extends ChangeNotifier {
  static const fixedStep = 1 / 60;
  static const maxCatchUpSteps = 3;
  static const _pixelsPerUnit = 20.0;
  static const _lowVelocityThreshold = .055;
  static const _sleepStepCount = 18;
  static const _normalMaximumActiveSteps = 180;
  static const _denseMaximumActiveSteps = 120;
  static const _baseBodyDamping = 4.2;
  static const _minimumBodyDamping = .35;
  static const _maximumBodyDamping = 12.4;
  static const _baseJointDampingRatio = .88;
  static const _minimumJointDampingRatio = .06;
  static const _maximumJointDampingRatio = 1.0;
  static const _idleMotionBaseForce = .32;
  static const _idleMotionHorizontalFrequency = .62;
  static const _idleMotionVerticalFrequency = .47;
  static const _circularBoundarySafetyInset = 1.0;

  World _world = World(Vector2.zero());
  Size _viewport = Size.zero;
  final Map<String, Body> _bodies = <String, Body>{};
  final Map<String, double> _radii = <String, double>{};
  // Community remains a presentation category. Physics groups nodes by their
  // concrete settlement so separate local clusters do not collapse back into
  // four palette buckets during the Forge2D path.
  final Map<String, String> _settlementIdByNodeId = <String, String>{};
  final Map<String, String> _coreNodeIdsBySettlement = <String, String>{};
  final List<Joint> _layoutJoints = <Joint>[];
  final List<Body> _anchorBodies = <Body>[];
  Set<String> _manuallyPositionedNodeIds = const <String>{};
  Map<String, Offset> _positions = const <String, Offset>{};
  List<DesktopGraphPhysicsEdge> _edges = const <DesktopGraphPhysicsEdge>[];
  List<DesktopGraphCommunitySnapshot> _communities =
      const <DesktopGraphCommunitySnapshot>[];
  DesktopGraphPhysicsParameters _parameters =
      const DesktopGraphPhysicsParameters();
  Body? _dragGround;
  MouseJoint? _mouseJoint;
  String? _draggedNodeId;
  Duration? _lastFrameTime;
  double _accumulator = 0;
  int _lowVelocitySteps = 0;
  int _activeSteps = 0;
  int _maximumActiveSteps = _normalMaximumActiveSteps;
  int _revision = 0;
  int _physicalJointCount = 0;
  int _layoutRevision = 0;
  int _idleMotionStep = 0;
  int? _topologyRevision;
  bool _sleeping = true;
  bool _frozen = false;
  bool _idleMotionEnabled = false;

  Map<String, Offset> get positions => _positions;
  int get revision => _revision;
  bool get isSleeping => _sleeping;
  bool get isFrozen => _frozen;
  bool get isIdleMotionEnabled => _idleMotionEnabled;
  String? get draggedNodeId => _draggedNodeId;
  Size get viewport => _viewport;
  DesktopGraphPhysicsParameters get parameters => _parameters;

  @visibleForTesting
  int get maximumActiveSteps => _maximumActiveSteps;

  @visibleForTesting
  int get physicalJointCount => _physicalJointCount;

  @visibleForTesting
  int get layoutJointCount => _layoutJoints.length;

  @visibleForTesting
  int get anchorBodyCount => _anchorBodies.length;

  @visibleForTesting
  int get layoutRevision => _layoutRevision;

  @visibleForTesting
  int get worldJointCount => _world.joints.length;

  @visibleForTesting
  int get worldBodyCount => _world.bodies.length;

  @visibleForTesting
  double? bodyDampingFor(String nodeId) => _bodies[nodeId]?.linearDamping;

  @visibleForTesting
  bool? bodyIsAwakeFor(String nodeId) => _bodies[nodeId]?.isAwake;

  double radiusFor(String nodeId) => _radii[nodeId] ?? 7;

  Offset positionFor(String nodeId) =>
      _positions[nodeId] ?? Offset(_viewport.width / 2, _viewport.height / 2);

  void synchronize({
    required Size viewport,
    required int topologyRevision,
    required List<DesktopGraphPhysicsNode> nodes,
    required List<DesktopGraphPhysicsEdge> edges,
    required List<DesktopGraphCommunitySnapshot> communities,
    Set<String> manuallyPositionedNodeIds = const <String>{},
    bool notify = true,
  }) {
    if (viewport.isEmpty || nodes.isEmpty) return;
    final nodeIds = nodes.map((node) => node.id).toSet();
    final sameTopology =
        _topologyRevision == topologyRevision &&
        _viewport == viewport &&
        setEquals(nodeIds, _bodies.keys.toSet());
    if (sameTopology) return;

    final previousViewport = _viewport;
    final previousPositions = _positions;
    _world = World(Vector2.zero());
    _viewport = viewport;
    _bodies.clear();
    _radii.clear();
    _settlementIdByNodeId.clear();
    _coreNodeIdsBySettlement.clear();
    _layoutJoints.clear();
    _anchorBodies.clear();
    _edges = List<DesktopGraphPhysicsEdge>.unmodifiable(edges);
    _communities = List<DesktopGraphCommunitySnapshot>.unmodifiable(
      communities,
    );
    _manuallyPositionedNodeIds = Set<String>.unmodifiable(
      manuallyPositionedNodeIds.where(nodeIds.contains),
    );
    _mouseJoint = null;
    _draggedNodeId = null;
    _physicalJointCount = 0;
    _idleMotionStep = 0;
    _dragGround = _world.createBody(BodyDef());
    final semanticEdgeCount = edges.length;
    _maximumActiveSteps = nodes.length > 120 || semanticEdgeCount > 300
        ? _denseMaximumActiveSteps
        : _normalMaximumActiveSteps;

    for (final node in nodes) {
      final settlementId = node.settlementId;
      _settlementIdByNodeId[node.id] = settlementId;
      if (node.role == DesktopGraphNodeRole.core) {
        final existing = _coreNodeIdsBySettlement[settlementId];
        if (existing == null || node.id.compareTo(existing) < 0) {
          _coreNodeIdsBySettlement[settlementId] = node.id;
        }
      }
      final radius = switch (node.role) {
        DesktopGraphNodeRole.center => 8.0,
        DesktopGraphNodeRole.core => 9.0,
        DesktopGraphNodeRole.satellite => 7.0,
      };
      _radii[node.id] = radius;
      final previous = previousPositions[node.id];
      final initial =
          node.seedPosition ??
          (previous != null && !previousViewport.isEmpty
              ? Offset(
                  previous.dx * viewport.width / previousViewport.width,
                  previous.dy * viewport.height / previousViewport.height,
                )
              : _seedPosition(node, viewport));
      final body = _world.createBody(
        BodyDef(
          type: node.role == DesktopGraphNodeRole.center
              ? BodyType.static
              : BodyType.dynamic,
          position: _toWorld(_clampPosition(initial, math.max(radius, 15))),
          linearDamping: _bodyDamping,
          angularDamping: _bodyDamping,
          fixedRotation: true,
          userData: node.id,
        ),
      );
      body.createFixtureFromShape(
        CircleShape(radius: 15 / _pixelsPerUnit),
        density: node.role == DesktopGraphNodeRole.core ? 1.8 : 1.0,
        friction: .08,
        restitution: .12,
      );
      _bodies[node.id] = body;
    }

    _createSettlementAnchors();
    _createRelationJoints(_edges);
    _topologyRevision = topologyRevision;
    _capturePositions();
    wake(notify: false);
    if (notify) notifyListeners();
  }

  void setIdleMotionEnabled(bool enabled, {bool notify = true}) {
    if (_idleMotionEnabled == enabled) return;
    _idleMotionEnabled = enabled;
    _idleMotionStep = 0;
    if (_bodies.isNotEmpty) wake(notify: false);
    if (notify) notifyListeners();
  }

  void updateParameters({
    required double attractionScale,
    required double repulsionScale,
    required double dampingScale,
    bool notify = true,
  }) {
    final next = DesktopGraphPhysicsParameters(
      attractionScale: attractionScale,
      repulsionScale: repulsionScale,
      dampingScale: dampingScale,
    ).normalized();
    if (next == _parameters) return;

    final rebuildLayout =
        next.attractionScale != _parameters.attractionScale ||
        next.dampingScale != _parameters.dampingScale;
    _parameters = next;
    for (final body in _bodies.values) {
      body.linearDamping = _bodyDamping;
      body.angularDamping = _bodyDamping;
    }
    if (rebuildLayout && _bodies.isNotEmpty) {
      _rebuildLayoutJoints();
    }
    if (_bodies.isNotEmpty) wake(notify: false);
    if (notify) notifyListeners();
  }

  bool advanceFrame(Duration elapsed) {
    if (_sleeping || _frozen || _bodies.isEmpty) {
      _lastFrameTime = elapsed;
      return false;
    }
    final previous = _lastFrameTime;
    _lastFrameTime = elapsed;
    if (previous == null) return false;
    final frameSeconds = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      fixedStep * maxCatchUpSteps,
    );
    _accumulator += frameSeconds;
    var steps = 0;
    while (_accumulator >= fixedStep && steps < maxCatchUpSteps) {
      _stepWorld();
      _accumulator -= fixedStep;
      steps++;
    }
    if (steps == 0) return false;
    _capturePositions();
    notifyListeners();
    return true;
  }

  /// Advances a single bounded physics step synchronously for a held pointer.
  ///
  /// The frame ticker continues the normal settling work. This path exists so
  /// a mouse movement can be painted before the next scheduled frame.
  void advanceForPointerUpdate() => _advanceFixedSteps(1);

  @visibleForTesting
  void stepFixed([int count = 1]) => _advanceFixedSteps(count);

  void _advanceFixedSteps(int count) {
    if (_frozen || _sleeping) return;
    for (var index = 0; index < count && !_sleeping; index++) {
      _stepWorld();
    }
    _capturePositions();
    notifyListeners();
  }

  void freeze({bool notify = true}) {
    if (_frozen) return;
    _frozen = true;
    _lastFrameTime = null;
    if (notify) notifyListeners();
  }

  void unfreeze({bool notify = true}) {
    if (!_frozen) return;
    _frozen = false;
    wake(notify: notify);
  }

  void wake({bool notify = true}) {
    _sleeping = false;
    _lowVelocitySteps = 0;
    _activeSteps = 0;
    _accumulator = 0;
    _lastFrameTime = null;
    for (final body in _bodies.values) {
      if (body.bodyType == BodyType.dynamic) body.setAwake(true);
    }
    if (notify) notifyListeners();
  }

  bool beginDrag(String nodeId, Offset target) {
    if (_frozen || _mouseJoint != null) return false;
    final body = _bodies[nodeId];
    final ground = _dragGround;
    if (body == null || ground == null || body.bodyType != BodyType.dynamic) {
      return false;
    }
    wake(notify: false);
    final jointDefinition = MouseJointDef<Body, Body>()
      ..bodyA = ground
      ..bodyB = body
      ..target.setFrom(_toWorld(_clampPosition(target, radiusFor(nodeId))))
      ..maxForce = math.max(120, body.mass * 900)
      ..frequencyHz = 12
      ..dampingRatio = .92;
    final joint = MouseJoint(jointDefinition);
    _world.createJoint(joint);
    _mouseJoint = joint;
    _draggedNodeId = nodeId;
    notifyListeners();
    return true;
  }

  void updateDrag(Offset target) {
    final joint = _mouseJoint;
    final nodeId = _draggedNodeId;
    if (joint == null || nodeId == null) return;
    joint.setTarget(_toWorld(_clampPosition(target, radiusFor(nodeId))));
  }

  /// Aligns the final physics body position with a rendered drag preview.
  ///
  /// During a held pointer, the mouse joint intentionally trails the cursor
  /// so the surrounding force layout remains elastic. The preview is visual
  /// only; committing it at release prevents a visible return jump while the
  /// normal springs, damping, and collisions continue afterwards.
  void commitDraggedPosition(Offset target) {
    final nodeId = _draggedNodeId;
    if (nodeId == null) return;
    final body = _bodies[nodeId];
    if (body == null || body.bodyType != BodyType.dynamic) return;
    final clamped = _clampPosition(target, radiusFor(nodeId));
    body
      ..setTransform(_toWorld(clamped), 0)
      ..setAwake(true);
    wake(notify: false);
    _capturePositions();
    notifyListeners();
  }

  Offset? endDrag() {
    final joint = _mouseJoint;
    final nodeId = _draggedNodeId;
    if (joint == null || nodeId == null) return null;
    _world.destroyJoint(joint);
    _mouseJoint = null;
    _draggedNodeId = null;
    final body = _bodies[nodeId];
    if (body != null && body.linearVelocity.length > 5) {
      body.linearVelocity = body.linearVelocity.normalized()..scale(5);
    }
    wake(notify: false);
    _capturePositions();
    notifyListeners();
    return _positions[nodeId];
  }

  void _stepWorld() {
    _applyRepulsion();
    _applyIdleMotion();
    _world.stepDt(fixedStep);
    _clampBodiesToViewport();
    final dynamicBodies = _bodies.values.where(
      (body) => body.bodyType == BodyType.dynamic,
    );
    if (_idleMotionEnabled) {
      _lowVelocitySteps = 0;
      _activeSteps = 0;
      return;
    }
    _activeSteps++;
    final lowVelocity = dynamicBodies.every(
      (body) => body.linearVelocity.length < _lowVelocityThreshold,
    );
    _lowVelocitySteps = lowVelocity ? _lowVelocitySteps + 1 : 0;
    if (_mouseJoint == null &&
        (_lowVelocitySteps >= _sleepStepCount ||
            _activeSteps >= _maximumActiveSteps)) {
      _sleeping = true;
      for (final body in dynamicBodies) {
        body.setAwake(false);
      }
    }
  }

  void _applyIdleMotion() {
    if (!_idleMotionEnabled) return;
    final elapsed = _idleMotionStep * fixedStep;
    for (final entry in _bodies.entries) {
      final body = entry.value;
      if (body.bodyType != BodyType.dynamic) continue;
      final phase = _seed('${entry.key}:idle-motion-phase') * math.pi * 2;
      final amplitude =
          _idleMotionBaseForce *
          (.88 + _seed('${entry.key}:idle-motion-amplitude') * .24);
      body.applyForce(
        Vector2(
          math.cos(elapsed * _idleMotionHorizontalFrequency + phase) *
              amplitude,
          math.sin(elapsed * _idleMotionVerticalFrequency + phase * 1.37) *
              amplitude,
        ),
      );
    }
    _idleMotionStep++;
  }

  void _applyRepulsion() {
    const cellSize = 2.6;
    final buckets = <(int, int), List<Body>>{};
    final dynamicBodies = _bodies.values
        .where((body) => body.bodyType == BodyType.dynamic)
        .toList();
    for (final body in dynamicBodies) {
      final key = (
        (body.position.x / cellSize).floor(),
        (body.position.y / cellSize).floor(),
      );
      buckets.putIfAbsent(key, () => <Body>[]).add(body);
    }
    for (final body in dynamicBodies) {
      final cellX = (body.position.x / cellSize).floor();
      final cellY = (body.position.y / cellSize).floor();
      for (var x = cellX - 1; x <= cellX + 1; x++) {
        for (var y = cellY - 1; y <= cellY + 1; y++) {
          for (final other in buckets[(x, y)] ?? const <Body>[]) {
            if (identityHashCode(other) <= identityHashCode(body)) continue;
            final delta = other.position - body.position;
            var distance = delta.length;
            final sameSettlement =
                _settlementIdByNodeId['${body.userData}'] ==
                _settlementIdByNodeId['${other.userData}'];
            final maximumDistance = sameSettlement ? 2.25 : 1.55;
            if (distance > maximumDistance) continue;
            Vector2 direction;
            if (distance < .001) {
              final sign = '${body.userData}'.compareTo('${other.userData}') < 0
                  ? 1.0
                  : -1.0;
              direction = Vector2(sign, 0);
              distance = .001;
            } else {
              direction = delta / distance;
            }
            final magnitude =
                (maximumDistance - distance) *
                (sameSettlement ? 13 : 6.5) *
                _parameters.repulsionResponse;
            final force = direction * magnitude;
            body.applyForce(-force);
            other.applyForce(force);
          }
        }
      }
    }
  }

  void _createSettlementAnchors() {
    final coreNodeIds = _coreNodeIdsBySettlement.values.toSet();
    // Old callers can still supply a community snapshot without marking a
    // node as a core. New callers arrive through the settlement map above.
    if (coreNodeIds.isEmpty) {
      coreNodeIds.addAll(
        _communities
            .map((snapshot) => snapshot.coreNodeId)
            .where((nodeId) => nodeId.isNotEmpty),
      );
    }
    final orderedCoreNodeIds = coreNodeIds.toList()..sort();
    for (final coreNodeId in orderedCoreNodeIds) {
      if (_manuallyPositionedNodeIds.contains(coreNodeId)) continue;
      final core = _bodies[coreNodeId];
      if (core == null) continue;
      // A pixel seed from the radial desktop layout has already positioned
      // the core. Anchor to that same location so the live Forge2D relaxation
      // preserves the information structure instead of returning to a legacy
      // corner arrangement.
      final corePosition = _fromWorld(core.position);
      final anchor = _world.createBody(
        BodyDef(position: _toWorld(corePosition)),
      );
      final definition = DistanceJointDef<Body, Body>()
        ..initialize(anchor, core, anchor.position, core.position)
        ..length = .65
        ..frequencyHz = 1.45 * _parameters.attractionResponse
        ..dampingRatio = _jointDampingRatio;
      final joint = DistanceJoint(definition);
      _world.createJoint(joint);
      _layoutJoints.add(joint);
      _anchorBodies.add(anchor);
    }
  }

  void _createRelationJoints(List<DesktopGraphPhysicsEdge> edges) {
    final attachedPairs = <String>{};
    final backbone = <DesktopGraphPhysicsEdge>[];
    final supplemental = <DesktopGraphPhysicsEdge>[];
    for (final edge in edges) {
      if (edge.kind == DesktopGraphRelationKind.membership || edge.isSelfLoop) {
        continue;
      }
      (edge.kind == DesktopGraphRelationKind.communityAffinity
              ? backbone
              : supplemental)
          .add(edge);
    }
    int compare(DesktopGraphPhysicsEdge left, DesktopGraphPhysicsEdge right) {
      final weight = right.weight.compareTo(left.weight);
      return weight != 0 ? weight : left.id.compareTo(right.id);
    }

    backbone.sort(compare);
    supplemental.sort(compare);
    final supplementalDegree = <String, int>{};
    final maximumSupplementalDegree = _bodies.length > 120 ? 3 : 5;

    void attach(DesktopGraphPhysicsEdge edge) {
      if (_manuallyPositionedNodeIds.contains(edge.sourceId) ||
          _manuallyPositionedNodeIds.contains(edge.targetId)) {
        return;
      }
      final source = _bodies[edge.sourceId];
      final target = _bodies[edge.targetId];
      if (source == null || target == null) return;
      final low = edge.sourceId.compareTo(edge.targetId) <= 0
          ? edge.sourceId
          : edge.targetId;
      final high = low == edge.sourceId ? edge.targetId : edge.sourceId;
      if (!attachedPairs.add('$low\u0000$high')) return;
      final definition = DistanceJointDef<Body, Body>()
        ..initialize(source, target, source.position, target.position)
        ..length = switch (edge.kind) {
          DesktopGraphRelationKind.communityAffinity =>
            2.2 + _seed('${edge.sourceId}:${edge.targetId}') * .8,
          DesktopGraphRelationKind.linkedMaterial => 2.0,
          DesktopGraphRelationKind.sharedContentLine => 2.45,
          DesktopGraphRelationKind.sharedTopic => 2.35,
          DesktopGraphRelationKind.other => 2.25,
          DesktopGraphRelationKind.membership => 3.4,
        }
        ..frequencyHz = edge.kind == DesktopGraphRelationKind.communityAffinity
            ? 1.18 * _parameters.attractionResponse
            : .82 * _parameters.attractionResponse
        ..dampingRatio = _jointDampingRatio
        ..collideConnected = true;
      final joint = DistanceJoint(definition);
      _world.createJoint(joint);
      _layoutJoints.add(joint);
      _physicalJointCount++;
    }

    for (final edge in backbone) {
      attach(edge);
    }
    for (final edge in supplemental) {
      final sourceDegree = supplementalDegree[edge.sourceId] ?? 0;
      final targetDegree = supplementalDegree[edge.targetId] ?? 0;
      if (sourceDegree >= maximumSupplementalDegree ||
          targetDegree >= maximumSupplementalDegree) {
        continue;
      }
      final before = _physicalJointCount;
      attach(edge);
      if (_physicalJointCount != before) {
        supplementalDegree[edge.sourceId] = sourceDegree + 1;
        supplementalDegree[edge.targetId] = targetDegree + 1;
      }
    }
  }

  void _rebuildLayoutJoints() {
    for (final joint in _layoutJoints) {
      if (_world.joints.contains(joint)) _world.destroyJoint(joint);
    }
    _layoutJoints.clear();
    for (final anchor in _anchorBodies) {
      if (_world.bodies.contains(anchor)) _world.destroyBody(anchor);
    }
    _anchorBodies.clear();
    _physicalJointCount = 0;
    _createSettlementAnchors();
    _createRelationJoints(_edges);
    _layoutRevision++;
  }

  Offset _seedPosition(DesktopGraphPhysicsNode node, Size viewport) {
    if (node.role == DesktopGraphNodeRole.center) {
      return Offset(viewport.width / 2, viewport.height / 2);
    }
    final anchor = _settlementAnchor(node.settlementId, viewport);
    if (node.role == DesktopGraphNodeRole.core) return anchor;
    final shortestSide = math.min(viewport.width, viewport.height);
    final phase = _seed('${node.settlementId}:${node.id}:phase') * math.pi * 2;
    final radialSample = _seed('${node.settlementId}:${node.id}:radius');
    final radius = shortestSide * (.045 + .118 * math.sqrt(radialSample));
    final position =
        anchor + Offset(math.cos(phase) * radius, math.sin(phase) * radius);
    return DesktopGraphViewportBounds.forViewport(
      viewport,
    ).clamp(position, inset: 15);
  }

  Offset _settlementAnchor(String settlementId, Size viewport) {
    final legacyCommunity = _legacyCommunityForSettlement(settlementId);
    if (legacyCommunity != null) {
      return _communityAnchor(legacyCommunity, viewport);
    }
    final shortestSide = math.min(viewport.width, viewport.height);
    final phase = _seed('$settlementId:anchor-phase') * math.pi * 2;
    final radius =
        shortestSide *
        (.026 + .164 * math.sqrt(_seed('$settlementId:anchor-radius')));
    final position =
        viewport.center(Offset.zero) +
        Offset(math.cos(phase) * radius, math.sin(phase) * radius);
    return DesktopGraphViewportBounds.forViewport(
      viewport,
    ).clamp(position, inset: 15);
  }

  Offset _communityAnchor(DesktopGraphCommunity community, Size viewport) {
    return DesktopGraphCentripetalAnchors.compactCommunityAnchor(
      community: community,
      activeCommunities: DesktopGraphCommunity.values,
      center: viewport.center(Offset.zero),
      radius: math.min(viewport.width, viewport.height) * .095,
    );
  }

  DesktopGraphCommunity? _legacyCommunityForSettlement(String settlementId) {
    for (final community in DesktopGraphCommunity.values) {
      if (settlementId == 'community-${community.name}') return community;
    }
    return null;
  }

  void _clampBodiesToViewport() {
    for (final body in _bodies.values) {
      if (body.bodyType != BodyType.dynamic) continue;
      const radius = 15.0;
      final current = _fromWorld(body.position);
      final clamped = _clampPosition(current, radius);
      if (clamped == current) continue;
      body.setTransform(_toWorld(clamped), 0);
      final velocity = body.linearVelocity;
      if (clamped.dx != current.dx) velocity.x *= -.18;
      if (clamped.dy != current.dy) velocity.y *= -.18;
    }
  }

  Offset _clampPosition(Offset position, double radius) =>
      DesktopGraphViewportBounds.forViewport(_viewport).clamp(
        position,
        inset: math.max(radius, 15.0) + _circularBoundarySafetyInset,
      );

  void _capturePositions() {
    _positions = Map<String, Offset>.unmodifiable(<String, Offset>{
      for (final entry in _bodies.entries)
        entry.key: _fromWorld(entry.value.position),
    });
    _revision++;
  }

  Vector2 _toWorld(Offset position) =>
      Vector2(position.dx / _pixelsPerUnit, position.dy / _pixelsPerUnit);

  Offset _fromWorld(Vector2 position) =>
      Offset(position.x * _pixelsPerUnit, position.y * _pixelsPerUnit);

  double get _bodyDamping => (_baseBodyDamping * _parameters.dampingResponse)
      .clamp(_minimumBodyDamping, _maximumBodyDamping);

  double get _jointDampingRatio =>
      (_baseJointDampingRatio * _parameters.dampingResponse).clamp(
        _minimumJointDampingRatio,
        _maximumJointDampingRatio,
      );
}

double _normalizedScale(double value, double minimum, double maximum) {
  if (!value.isFinite) return 1;
  return value.clamp(minimum, maximum);
}

double _seed(String value) {
  var hash = 0x811C9DC5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return (hash % 10000) / 10000;
}

/// Scalable 2D force layout for large document graphs.
///
/// Forge2D gives small graphs excellent collision behavior, but thousands of
/// bodies and joints are not an appropriate desktop interaction budget. This
/// model keeps the same force semantics in O(N + nearby-pairs): each physical
/// settlement owns a dynamic core, satellites have spring targets relative to
/// that core, and a spatial grid applies only local repulsion. It intentionally
/// contains no persisted business state.
final class DesktopDenseGraphPhysicsSimulation extends ChangeNotifier {
  static const fixedStep = 1 / 60;
  static const maxCatchUpSteps = 3;
  static const _settlementSpring = 38.0;
  static const _satelliteSpring = 70.0;
  static const _dragSpring = 230.0;
  static const _baseDamping = 5.3;
  static const _settlementSpringVelocityDamping = 4.8;
  static const _satelliteSpringVelocityDamping = 7.4;
  // Physical settlements deliberately pack more tightly as their count grows.
  // A fixed four-community separation is what previously inflated a large
  // graph into the visible outer ring shown in the desktop canvas.
  static const _settlementRepulsionDistance = .155;
  static const _settlementRepulsionForce = 12.0;
  static const _neighborRepulsionDistance = .028;
  static const _crossClusterRepulsionDistance = .021;
  static const _neighborCellSize = .042;
  static const _idleForce = .055;
  static const _settleVelocity = .0007;
  static const _settleStepCount = 20;

  Size _viewport = Size.zero;
  int? _topologyRevision;
  final Map<String, _DenseSettlementBody> _settlements =
      <String, _DenseSettlementBody>{};
  final Map<String, _DenseGraphBody> _bodies = <String, _DenseGraphBody>{};
  final Map<String, DesktopGraphNodeRole> _roles =
      <String, DesktopGraphNodeRole>{};
  final Map<String, String> _settlementIdsByNodeId = <String, String>{};
  final Map<String, String> _coreNodeIdsBySettlement = <String, String>{};
  final Set<String> _centerNodeIds = <String>{};
  Map<String, Offset> _positions = const <String, Offset>{};
  DesktopGraphPhysicsParameters _parameters =
      const DesktopGraphPhysicsParameters();
  Duration? _lastFrameTime;
  double _accumulator = 0;
  double _idleTime = 0;
  int _lowVelocitySteps = 0;
  bool _frozen = false;
  bool _sleeping = true;
  bool _idleMotionEnabled = false;
  String? _draggedNodeId;
  String? _draggedSettlementId;
  bool _draggingSettlement = false;
  Offset? _dragTarget;

  Map<String, Offset> get positions => _positions;
  Size get viewport => _viewport;
  DesktopGraphPhysicsParameters get parameters => _parameters;
  bool get isFrozen => _frozen;
  bool get isSleeping => _sleeping;
  bool get isIdleMotionEnabled => _idleMotionEnabled;
  String? get draggedNodeId => _draggedNodeId;

  @visibleForTesting
  int get bodyCount => _bodies.length;

  @visibleForTesting
  int get settlementCount => _settlements.length;

  /// Kept for existing diagnostics which used the former four-community name.
  @visibleForTesting
  int get communityCount => settlementCount;

  @visibleForTesting
  int get activeNeighborPairCount => _lastNeighborPairCount;

  int _lastNeighborPairCount = 0;

  Offset positionFor(String nodeId) =>
      _positions[nodeId] ?? const Offset(.5, .5);

  @visibleForTesting
  Offset velocityFor(String nodeId) {
    final role = _roles[nodeId];
    if (role == DesktopGraphNodeRole.core) {
      final settlementId = _settlementIdsByNodeId[nodeId];
      return settlementId == null
          ? Offset.zero
          : _settlements[settlementId]?.velocity ?? Offset.zero;
    }
    return _bodies[nodeId]?.velocity ?? Offset.zero;
  }

  void synchronize({
    required Size viewport,
    required int topologyRevision,
    required List<DesktopGraphPhysicsNode> nodes,
    bool notify = true,
  }) {
    if (viewport.isEmpty || nodes.isEmpty) return;
    final nodeIds = nodes.map((node) => node.id).toSet();
    final sameTopology =
        _topologyRevision == topologyRevision &&
        _viewport == viewport &&
        setEquals(nodeIds, <String>{..._roles.keys});
    if (sameTopology) return;

    final previousSettlements = Map<String, _DenseSettlementBody>.from(
      _settlements,
    );
    final previousBodies = Map<String, _DenseGraphBody>.from(_bodies);
    _viewport = viewport;
    _settlements.clear();
    _bodies.clear();
    _roles.clear();
    _settlementIdsByNodeId.clear();
    _coreNodeIdsBySettlement.clear();
    _centerNodeIds.clear();

    final grouped = <String, List<DesktopGraphPhysicsNode>>{};
    for (final node in nodes) {
      _roles[node.id] = node.role;
      if (node.role == DesktopGraphNodeRole.center) {
        _centerNodeIds.add(node.id);
      } else {
        final settlementId = node.settlementId;
        _settlementIdsByNodeId[node.id] = settlementId;
        grouped
            .putIfAbsent(settlementId, () => <DesktopGraphPhysicsNode>[])
            .add(node);
      }
    }
    final orderedSettlements = grouped.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));

    for (final entry in orderedSettlements) {
      final settlementId = entry.key;
      final members = entry.value
        ..sort((left, right) => left.id.compareTo(right.id));
      final declaredCores = members
          .where((node) => node.role == DesktopGraphNodeRole.core)
          .toList(growable: false);
      final core = declaredCores.isEmpty ? null : declaredCores.first;
      if (core != null) _coreNodeIdsBySettlement[settlementId] = core.id;
      final home =
          _normalizedSeed(core?.seedPosition) ?? _settlementHome(settlementId);
      final previous = previousSettlements[settlementId];
      final previousOffset = previous == null
          ? Offset.zero
          : previous.anchor - previous.home;
      _settlements[settlementId] = _DenseSettlementBody(
        settlementId: settlementId,
        home: home,
        anchor: _clampPosition(home + previousOffset),
        velocity: previous?.velocity ?? Offset.zero,
        manualOffset: previous?.manualOffset ?? Offset.zero,
      );
    }

    for (final entry in orderedSettlements) {
      final settlementId = entry.key;
      final state = _settlements[settlementId];
      if (state == null) continue;
      final satellites =
          entry.value
              .where((node) => node.role == DesktopGraphNodeRole.satellite)
              .toList(growable: false)
            ..sort((left, right) => left.id.compareTo(right.id));
      for (var index = 0; index < satellites.length; index++) {
        final node = satellites[index];
        final seed = _normalizedSeed(node.seedPosition);
        final targetOffset = seed == null
            ? _satelliteBasePosition(settlementId, index, satellites.length) -
                  state.home
            : seed - state.home;
        final previous = previousBodies[node.id];
        final initial =
            previous?.position ?? seed ?? state.anchor + targetOffset;
        _bodies[node.id] = _DenseGraphBody(
          id: node.id,
          settlementId: settlementId,
          baseOffset: targetOffset,
          position: _clampPosition(initial),
          velocity: previous?.velocity ?? Offset.zero,
          manualOffset: previous?.manualOffset ?? Offset.zero,
        );
      }
    }

    _topologyRevision = topologyRevision;
    _lastFrameTime = null;
    _accumulator = 0;
    _capturePositions();
    wake(notify: false);
    if (notify) notifyListeners();
  }

  void updateParameters({
    required double attractionScale,
    required double repulsionScale,
    required double dampingScale,
    bool notify = true,
  }) {
    final next = DesktopGraphPhysicsParameters(
      attractionScale: attractionScale,
      repulsionScale: repulsionScale,
      dampingScale: dampingScale,
    ).normalized();
    if (next == _parameters) return;
    _parameters = next;
    wake(notify: false);
    if (notify) notifyListeners();
  }

  void setIdleMotionEnabled(bool enabled, {bool notify = true}) {
    if (_idleMotionEnabled == enabled) return;
    _idleMotionEnabled = enabled;
    if (enabled) wake(notify: false);
    if (notify) notifyListeners();
  }

  void freeze({bool notify = true}) {
    if (_frozen) return;
    _frozen = true;
    _lastFrameTime = null;
    if (notify) notifyListeners();
  }

  void unfreeze({bool notify = true}) {
    if (!_frozen) return;
    _frozen = false;
    wake(notify: false);
    if (notify) notifyListeners();
  }

  void wake({bool notify = true, bool resetFrameTime = true}) {
    _sleeping = false;
    _lowVelocitySteps = 0;
    if (resetFrameTime) _lastFrameTime = null;
    if (notify) notifyListeners();
  }

  void reset({bool notify = true}) {
    for (final state in _settlements.values) {
      state
        ..anchor = state.home
        ..velocity = Offset.zero
        ..manualOffset = Offset.zero
        ..force = Offset.zero;
    }
    for (final body in _bodies.values) {
      final state = _settlements[body.settlementId]!;
      body
        ..position = _clampPosition(
          state.anchor + body.baseOffset * _repulsionSpread,
        )
        ..velocity = Offset.zero
        ..manualOffset = Offset.zero
        ..force = Offset.zero;
    }
    _draggedNodeId = null;
    _draggedSettlementId = null;
    _draggingSettlement = false;
    _dragTarget = null;
    _capturePositions();
    wake(notify: false);
    if (notify) notifyListeners();
  }

  bool beginDrag(String nodeId, Offset target) {
    if (_frozen || _draggedNodeId != null) return false;
    final role = _roles[nodeId];
    final settlementId = _settlementIdsByNodeId[nodeId];
    if (role == null ||
        settlementId == null ||
        role == DesktopGraphNodeRole.center) {
      return false;
    }
    if (role == DesktopGraphNodeRole.satellite &&
        !_bodies.containsKey(nodeId)) {
      return false;
    }
    _draggedNodeId = nodeId;
    _draggedSettlementId = settlementId;
    _draggingSettlement = role == DesktopGraphNodeRole.core;
    _dragTarget = _clampPosition(target);
    wake(notify: false);
    notifyListeners();
    return true;
  }

  void updateDrag(Offset target, {bool notify = true}) {
    final nodeId = _draggedNodeId;
    final settlementId = _draggedSettlementId;
    if (nodeId == null || settlementId == null) return;
    final resolvedTarget = _clampPosition(target);
    _dragTarget = resolvedTarget;
    if (_draggingSettlement) {
      final state = _settlements[settlementId]!;
      state.manualOffset = resolvedTarget - state.home;
      final delta = resolvedTarget - state.anchor;
      state
        ..anchor = _clampPosition(state.anchor + delta * .42)
        ..velocity = state.velocity + delta * 6.4;
    } else {
      final body = _bodies[nodeId]!;
      final delta = resolvedTarget - body.position;
      body
        ..position = _clampPosition(body.position + delta * .42)
        ..velocity = body.velocity + delta * 6.4;
    }
    wake(notify: false, resetFrameTime: false);
    if (notify) notifyListeners();
  }

  /// Aligns the final force state with a pointer-position preview on release.
  ///
  /// Only the dragged core or satellite is placed at the final pointer. Its
  /// settlement members retain their independent spring state and continue
  /// settling under attraction, repulsion, and damping.
  void commitDraggedPosition(Offset target) {
    final nodeId = _draggedNodeId;
    final settlementId = _draggedSettlementId;
    if (nodeId == null || settlementId == null) return;
    final resolvedTarget = _clampPosition(target);
    _dragTarget = resolvedTarget;
    if (_draggingSettlement) {
      final state = _settlements[settlementId]!;
      final delta = resolvedTarget - state.anchor;
      state
        ..anchor = resolvedTarget
        ..manualOffset = resolvedTarget - state.home
        ..velocity = state.velocity + delta * 6.4;
    } else {
      final body = _bodies[nodeId]!;
      final delta = resolvedTarget - body.position;
      body
        ..position = resolvedTarget
        ..velocity = body.velocity + delta * 6.4;
    }
    wake(notify: false, resetFrameTime: false);
    _capturePositions();
    notifyListeners();
  }

  Offset? endDrag() {
    final nodeId = _draggedNodeId;
    if (nodeId == null) return null;
    final position = positionFor(nodeId);
    _draggedNodeId = null;
    _draggedSettlementId = null;
    _draggingSettlement = false;
    _dragTarget = null;
    wake(notify: false);
    notifyListeners();
    return position;
  }

  bool advanceFrame(Duration elapsed) {
    if (_frozen || _sleeping || _positions.isEmpty) {
      _lastFrameTime = elapsed;
      return false;
    }
    final previous = _lastFrameTime;
    _lastFrameTime = elapsed;
    if (previous == null) return false;
    final frameSeconds = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      fixedStep * maxCatchUpSteps,
    );
    _accumulator += frameSeconds;
    var steps = 0;
    while (_accumulator >= fixedStep && steps < maxCatchUpSteps) {
      _step(fixedStep);
      _accumulator -= fixedStep;
      steps++;
    }
    if (steps == 0) return false;
    _capturePositions();
    notifyListeners();
    return true;
  }

  /// Advances a single bounded physics step synchronously for a held pointer.
  ///
  /// The frame ticker continues the normal settling work. This path exists so
  /// a mouse movement can be painted before the next scheduled frame.
  void advanceForPointerUpdate() => _advanceFixedSteps(1);

  @visibleForTesting
  void stepFixed([int count = 1]) => _advanceFixedSteps(count);

  void _advanceFixedSteps(int count) {
    if (_frozen || _sleeping) return;
    for (var index = 0; index < count && !_sleeping; index++) {
      _step(fixedStep);
    }
    _capturePositions();
    notifyListeners();
  }

  void _step(double elapsedSeconds) {
    _idleTime += elapsedSeconds;
    _applySettlementForces();
    _applySettlementRepulsion();
    for (final state in _settlements.values) {
      _integrateSettlement(state, elapsedSeconds);
    }

    for (final body in _bodies.values) {
      final state = _settlements[body.settlementId]!;
      final target = state.anchor + body.baseOffset * _repulsionSpread;
      var force =
          (target - body.position) *
          (_satelliteSpring * _parameters.attractionResponse);
      if (_draggedNodeId == body.id && !_draggingSettlement) {
        force += (_dragTarget! - body.position) * _dragSpring;
      }
      force -= body.velocity * _satelliteVelocityDamping;
      if (_idleMotionEnabled) {
        force += _idleForceFor(body.id);
      }
      body.force = force;
    }
    _applyNeighborRepulsion();
    for (final body in _bodies.values) {
      _integrateSatellite(body, elapsedSeconds);
    }
    _settleIfNeeded();
  }

  void _applySettlementForces() {
    for (final state in _settlements.values) {
      final target = state.home + state.manualOffset;
      var force =
          (target - state.anchor) *
          (_settlementSpring * _parameters.attractionResponse);
      if (_draggingSettlement && _draggedSettlementId != null) {
        if (identical(state, _settlements[_draggedSettlementId])) {
          force += (_dragTarget! - state.anchor) * _dragSpring;
        }
      }
      if (_idleMotionEnabled) {
        force += _idleForceFor('settlement-${state.settlementId}');
      }
      state.force = force - state.velocity * _settlementVelocityDamping;
    }
  }

  void _applySettlementRepulsion() {
    final states = _settlements.values.toList(growable: false)
      ..sort((left, right) => left.settlementId.compareTo(right.settlementId));
    final minimumDistance = _settlementMinimumDistance(states.length);
    final forceScale = _settlementRepulsionScale(states.length);
    for (var index = 0; index < states.length; index++) {
      final current = states[index];
      for (
        var otherIndex = index + 1;
        otherIndex < states.length;
        otherIndex++
      ) {
        final other = states[otherIndex];
        final delta = _toViewSpace(other.anchor - current.anchor);
        var distance = delta.distance;
        if (distance >= minimumDistance) continue;
        Offset direction;
        if (distance < .0001) {
          direction = index.isEven ? const Offset(1, 0) : const Offset(-1, 0);
          distance = .0001;
        } else {
          direction = delta / distance;
        }
        final magnitude =
            (minimumDistance - distance) *
            _settlementRepulsionForce *
            forceScale *
            _parameters.repulsionResponse;
        final normalizedForce = _fromViewSpace(direction * magnitude);
        current.force -= normalizedForce;
        other.force += normalizedForce;
      }
    }
  }

  void _applyNeighborRepulsion() {
    final buckets = <(int, int), List<_DenseGraphBody>>{};
    for (final body in _bodies.values) {
      final view = _toViewSpace(body.position);
      final key = (
        (view.dx / _neighborCellSize).floor(),
        (view.dy / _neighborCellSize).floor(),
      );
      buckets.putIfAbsent(key, () => <_DenseGraphBody>[]).add(body);
    }
    var pairs = 0;
    for (final body in _bodies.values) {
      final view = _toViewSpace(body.position);
      final cellX = (view.dx / _neighborCellSize).floor();
      final cellY = (view.dy / _neighborCellSize).floor();
      for (var x = cellX - 1; x <= cellX + 1; x++) {
        for (var y = cellY - 1; y <= cellY + 1; y++) {
          for (final other in buckets[(x, y)] ?? const <_DenseGraphBody>[]) {
            if (other.id.compareTo(body.id) <= 0) continue;
            final delta = _toViewSpace(other.position - body.position);
            var distance = delta.distance;
            final sameSettlement = body.settlementId == other.settlementId;
            final maximumDistance = sameSettlement
                ? _neighborRepulsionDistance
                : _crossClusterRepulsionDistance;
            if (distance >= maximumDistance) continue;
            Offset direction;
            if (distance < .0001) {
              direction = _seed(body.id) < _seed(other.id)
                  ? const Offset(1, 0)
                  : const Offset(-1, 0);
              distance = .0001;
            } else {
              direction = delta / distance;
            }
            final magnitude =
                (maximumDistance - distance) *
                (sameSettlement ? 18 : 9) *
                _parameters.repulsionResponse;
            final normalizedForce = _fromViewSpace(direction * magnitude);
            body.force -= normalizedForce;
            other.force += normalizedForce;
            pairs++;
          }
        }
      }
    }
    _lastNeighborPairCount = pairs;
  }

  void _integrateSettlement(_DenseSettlementBody state, double elapsedSeconds) {
    state.velocity += state.force * elapsedSeconds;
    state.velocity *= _velocityDecay(elapsedSeconds);
    state.anchor = _clampWithBounce(
      state.anchor + state.velocity * elapsedSeconds,
      onHorizontalBounce: () =>
          state.velocity = Offset(state.velocity.dx * -.18, state.velocity.dy),
      onVerticalBounce: () =>
          state.velocity = Offset(state.velocity.dx, state.velocity.dy * -.18),
    );
  }

  void _integrateSatellite(_DenseGraphBody body, double elapsedSeconds) {
    body.velocity += body.force * elapsedSeconds;
    body.velocity *= _velocityDecay(elapsedSeconds);
    body.position = _clampWithBounce(
      body.position + body.velocity * elapsedSeconds,
      onHorizontalBounce: () =>
          body.velocity = Offset(body.velocity.dx * -.18, body.velocity.dy),
      onVerticalBounce: () =>
          body.velocity = Offset(body.velocity.dx, body.velocity.dy * -.18),
    );
  }

  void _settleIfNeeded() {
    if (_idleMotionEnabled || _draggedNodeId != null) {
      _lowVelocitySteps = 0;
      return;
    }
    final lowVelocity =
        _settlements.values.every(
          (state) => state.velocity.distance < _settleVelocity,
        ) &&
        _bodies.values.every(
          (body) => body.velocity.distance < _settleVelocity,
        );
    _lowVelocitySteps = lowVelocity ? _lowVelocitySteps + 1 : 0;
    if (_lowVelocitySteps >= _settleStepCount) _sleeping = true;
  }

  /// Provides a deterministic, irregular fallback when the presentation layer
  /// has not supplied a normalized radial seed yet. This is intentionally not
  /// a four-way compass: a missing seed must not recreate the old fan shape.
  Offset _settlementHome(String settlementId) {
    if (_viewport.isEmpty) return const Offset(.5, .5);
    final legacyCommunity = _legacyCommunityForSettlement(settlementId);
    if (legacyCommunity != null) {
      return _clampPosition(
        _fromViewSpace(
          DesktopGraphCentripetalAnchors.compactCommunityAnchor(
            community: legacyCommunity,
            activeCommunities: DesktopGraphCommunity.values,
            center: _toViewSpace(const Offset(.5, .5)),
            radius: .095,
          ),
        ),
      );
    }
    final phase = _seed('$settlementId|home-angle') * math.pi * 2;
    final radius = .028 + .112 * math.sqrt(_seed('$settlementId|home-radius'));
    final center = _toViewSpace(const Offset(.5, .5));
    return _clampPosition(
      _fromViewSpace(
        center + Offset(math.cos(phase) * radius, math.sin(phase) * radius),
      ),
    );
  }

  DesktopGraphCommunity? _legacyCommunityForSettlement(String settlementId) {
    for (final community in DesktopGraphCommunity.values) {
      if (settlementId == 'community-${community.name}') return community;
    }
    return null;
  }

  /// Dense layouts consume normalized seeds from presentation-local geometry.
  ///
  /// Detailed Forge2D layouts deliberately use pixel seeds instead, so reject
  /// out-of-range values here rather than accidentally treating pixels as a
  /// normalized graph target.
  Offset? _normalizedSeed(Offset? seed) {
    if (seed == null || !seed.dx.isFinite || !seed.dy.isFinite) return null;
    if (seed.dx < 0 || seed.dx > 1 || seed.dy < 0 || seed.dy > 1) {
      return null;
    }
    return _clampPosition(seed);
  }

  Offset _satelliteBasePosition(String settlementId, int index, int count) {
    final home = _settlementHome(settlementId);
    final shortestSide = math.min(_viewport.width, _viewport.height);
    final legacyCommunity = _legacyCommunityForSettlement(settlementId);
    if (legacyCommunity != null) {
      final inwardAngle = math.atan2(.5 - home.dy, .5 - home.dx);
      final radius =
          shortestSide *
          (.028 + .075 * math.sqrt((index + 1) / math.max(1, count)));
      final angle =
          inwardAngle +
          index * math.pi * (3 - math.sqrt(5)) +
          legacyCommunity.index * .17;
      return _clampPosition(
        Offset(
          home.dx + math.cos(angle) * radius / _viewport.width,
          home.dy + math.sin(angle) * radius / _viewport.height,
        ),
      );
    }
    final radialSample = _seed('$settlementId|satellite-radius|$index');
    final radius =
        shortestSide *
        (.021 +
            .078 *
                math.sqrt(radialSample) *
                math.sqrt(math.min(1, count / 64)));
    final angle = _seed('$settlementId|satellite-angle|$index') * math.pi * 2;
    return _clampPosition(
      Offset(
        home.dx + math.cos(angle) * radius / _viewport.width,
        home.dy + math.sin(angle) * radius / _viewport.height,
      ),
    );
  }

  Offset _idleForceFor(String id) {
    final phase = _seed(id) * math.pi * 2;
    return Offset(
      math.cos(_idleTime * .82 + phase) * _idleForce,
      math.sin(_idleTime * .67 + phase * .79) * _idleForce * .78,
    );
  }

  Offset _toViewSpace(Offset normalized) {
    final shortestSide = math.min(_viewport.width, _viewport.height);
    return Offset(
      normalized.dx * _viewport.width / shortestSide,
      normalized.dy * _viewport.height / shortestSide,
    );
  }

  Offset _fromViewSpace(Offset view) {
    final shortestSide = math.min(_viewport.width, _viewport.height);
    return Offset(
      view.dx * shortestSide / _viewport.width,
      view.dy * shortestSide / _viewport.height,
    );
  }

  Offset _clampPosition(Offset position) {
    if (_viewport.isEmpty) return const Offset(.5, .5);
    final bounds = DesktopGraphViewportBounds.forViewport(_viewport);
    return bounds.clampNormalized(position, inset: 8);
  }

  Offset _clampWithBounce(
    Offset position, {
    required VoidCallback onHorizontalBounce,
    required VoidCallback onVerticalBounce,
  }) {
    final clamped = _clampPosition(position);
    if (clamped.dx != position.dx) onHorizontalBounce();
    if (clamped.dy != position.dy) onVerticalBounce();
    return clamped;
  }

  double get _repulsionSpread => .56 + .44 * _parameters.repulsionResponse;

  double _settlementMinimumDistance(int settlementCount) {
    final packingScale = math.sqrt(4 / math.max(4, settlementCount));
    return (_settlementRepulsionDistance * packingScale)
        .clamp(.038, _settlementRepulsionDistance)
        .toDouble();
  }

  double _settlementRepulsionScale(int settlementCount) {
    final packingScale = math.sqrt(4 / math.max(4, settlementCount));
    return packingScale.clamp(.32, 1.0).toDouble();
  }

  double get _settlementVelocityDamping =>
      _settlementSpringVelocityDamping *
      math.sqrt(_parameters.attractionResponse) *
      _parameters.dampingResponse;

  double get _satelliteVelocityDamping =>
      _satelliteSpringVelocityDamping *
      math.sqrt(_parameters.attractionResponse) *
      _parameters.dampingResponse;

  double _velocityDecay(double elapsedSeconds) =>
      math.exp(-_baseDamping * _parameters.dampingResponse * elapsedSeconds);

  void _capturePositions() {
    _positions = Map<String, Offset>.unmodifiable(<String, Offset>{
      for (final nodeId in _centerNodeIds) nodeId: const Offset(.5, .5),
      for (final entry in _coreNodeIdsBySettlement.entries)
        entry.value: _settlements[entry.key]!.anchor,
      for (final entry in _bodies.entries) entry.key: entry.value.position,
    });
  }
}

final class _DenseSettlementBody {
  _DenseSettlementBody({
    required this.settlementId,
    required this.home,
    required this.anchor,
    required this.velocity,
    required this.manualOffset,
  });

  final String settlementId;
  Offset home;
  Offset anchor;
  Offset velocity;
  Offset manualOffset;
  Offset force = Offset.zero;
}

final class _DenseGraphBody {
  _DenseGraphBody({
    required this.id,
    required this.settlementId,
    required this.baseOffset,
    required this.position,
    required this.velocity,
    required this.manualOffset,
  });

  final String id;
  final String settlementId;
  Offset baseOffset;
  Offset position;
  Offset velocity;
  Offset manualOffset;
  Offset force = Offset.zero;
}
