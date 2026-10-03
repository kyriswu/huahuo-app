import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'sphere_graph_layout.dart';
import 'sphere_graph_render_topology.dart';

final class SphereGraphProjectionController extends ChangeNotifier {
  SphereGraphProjectionController()
    : _topology = SphereGraphRenderTopology.empty() {
    _allocateBuffers();
  }

  static const int depthBucketCount = 64;

  SphereGraphRenderTopology _topology;
  late Float32List projectedX;
  late Float32List projectedY;
  late Float32List cameraDepths;
  late Float32List normalizedDepths;
  late Float32List sizeFactors;
  late Float32List opacities;
  late Uint32List drawOrder;
  late Uint32List visualLinkDrawOrder;
  late Uint8List _manualFlags;
  late Float32List _manualX;
  late Float32List _manualY;
  late Int32List _bucketHeads;
  late Int32List _bucketTails;
  late Int32List _bucketNext;
  late Int32List _linkBucketHeads;
  late Int32List _linkBucketTails;
  late Int32List _linkBucketNext;
  late Map<String, Offset> _positionsView;
  late Map<String, double> _depthsView;
  late Map<String, double> _sizeFactorsView;
  late Map<String, double> _opacitiesView;
  late List<String> _drawOrderIdsView;
  Size _viewport = Size.zero;
  double _rotationX = double.nan;
  double _rotationY = double.nan;
  double _zoom = double.nan;
  double _padding = double.nan;
  int _revision = 0;
  bool _active = true;

  SphereGraphRenderTopology get topology => _topology;
  Map<String, Offset> get positions => _positionsView;
  Map<String, double> get depths => _depthsView;
  Map<String, double> get projectedSizeFactors => _sizeFactorsView;
  Map<String, double> get projectedOpacities => _opacitiesView;
  List<String> get drawOrderIds => _drawOrderIdsView;
  int get revision => _revision;
  bool get active => _active;
  Size get viewport => _viewport;

  void setActive(bool value) {
    _active = value;
  }

  void updateTopology(
    SphereGraphRenderTopology topology, {
    bool notify = true,
  }) {
    if (identical(_topology, topology)) return;
    final previousManual = <String, Offset>{};
    for (var index = 0; index < _topology.nodeCount; index++) {
      if (_manualFlags[index] != 0) {
        previousManual[_topology.nodeIds[index]] = Offset(
          _manualX[index],
          _manualY[index],
        );
      }
    }
    _topology = topology;
    _allocateBuffers();
    for (final entry in previousManual.entries) {
      setManualPosition(entry.key, entry.value, notify: false);
    }
    _viewport = Size.zero;
    _rotationX = double.nan;
    _rotationY = double.nan;
    _revision++;
    if (notify && _active) notifyListeners();
  }

  bool project({
    required Size viewport,
    required double rotationX,
    required double rotationY,
    double zoom = 1,
    double padding = 12,
    bool notify = true,
  }) {
    if (!_active || _topology.nodeCount == 0 || viewport.isEmpty) return false;
    if (!rotationX.isFinite || !rotationY.isFinite) {
      throw ArgumentError('rotation values must be finite');
    }
    if (!zoom.isFinite || zoom <= 0) {
      throw RangeError.value(zoom, 'zoom', 'must be finite and positive');
    }
    if (!padding.isFinite || padding < 0) {
      throw RangeError.value(padding, 'padding', 'must be non-negative');
    }
    if (_viewport == viewport &&
        _rotationX == rotationX &&
        _rotationY == rotationY &&
        _zoom == zoom &&
        _padding == padding) {
      return false;
    }

    _viewport = viewport;
    _rotationX = rotationX;
    _rotationY = rotationY;
    _zoom = zoom;
    _padding = padding;
    _bucketHeads.fillRange(0, depthBucketCount, -1);
    _bucketTails.fillRange(0, depthBucketCount, -1);
    _bucketNext.fillRange(0, _bucketNext.length, -1);

    final centerX = viewport.width / 2;
    final centerY = viewport.height / 2;
    final availableRadius = math.max(
      0.0,
      math.min(viewport.width, viewport.height) / 2 - padding,
    );
    final canvasRadius = availableRadius * .91 * zoom;
    final sinX = math.sin(rotationX);
    final cosX = math.cos(rotationX);
    final sinY = math.sin(rotationY);
    final cosY = math.cos(rotationY);
    final coordinates = _topology.baseCoordinates;

    for (var index = 0; index < _topology.nodeCount; index++) {
      final coordinateIndex = index * 3;
      final x = coordinates[coordinateIndex];
      final y = coordinates[coordinateIndex + 1];
      final z = coordinates[coordinateIndex + 2];
      final rotatedX = x * cosY + z * sinY;
      final zAfterY = -x * sinY + z * cosY;
      final rotatedY = y * cosX - zAfterY * sinX;
      final rotatedZ = y * sinX + zAfterY * cosX;
      final depth = ((rotatedZ + 1) / 2).clamp(0.0, 1.0).toDouble();
      final perspective = 1 / (1 - rotatedZ * .32);
      final sizeFactor = _lerp(.44, 1.32, math.pow(depth, .95).toDouble());
      final depthOpacity = _lerp(.08, .98, math.pow(depth, 1.55).toDouble());
      final opacity = _topology.isSynthetic(index)
          ? (depthOpacity * .7).clamp(.055, .7).toDouble()
          : depthOpacity;
      projectedX[index] = _manualFlags[index] == 0
          ? centerX + rotatedX * canvasRadius * perspective
          : _manualX[index];
      projectedY[index] = _manualFlags[index] == 0
          ? centerY + rotatedY * canvasRadius * perspective
          : _manualY[index];
      cameraDepths[index] = rotatedZ;
      normalizedDepths[index] = depth;
      sizeFactors[index] = sizeFactor;
      opacities[index] = opacity;

      final bucket = (depth * (depthBucketCount - 1)).floor().clamp(
        0,
        depthBucketCount - 1,
      );
      final tail = _bucketTails[bucket];
      if (tail < 0) {
        _bucketHeads[bucket] = index;
      } else {
        _bucketNext[tail] = index;
      }
      _bucketTails[bucket] = index;
    }

    var orderIndex = 0;
    for (var bucket = 0; bucket < depthBucketCount; bucket++) {
      var index = _bucketHeads[bucket];
      while (index >= 0) {
        drawOrder[orderIndex++] = index;
        index = _bucketNext[index];
      }
    }
    _linkBucketHeads.fillRange(0, depthBucketCount, -1);
    _linkBucketTails.fillRange(0, depthBucketCount, -1);
    _linkBucketNext.fillRange(0, _linkBucketNext.length, -1);
    for (
      var linkIndex = 0;
      linkIndex < _topology.visualLinkSources.length;
      linkIndex++
    ) {
      final source = _topology.visualLinkSources[linkIndex];
      final target = _topology.visualLinkTargets[linkIndex];
      final depth = (normalizedDepths[source] + normalizedDepths[target]) / 2;
      final bucket = (depth * (depthBucketCount - 1)).floor().clamp(
        0,
        depthBucketCount - 1,
      );
      final tail = _linkBucketTails[bucket];
      if (tail < 0) {
        _linkBucketHeads[bucket] = linkIndex;
      } else {
        _linkBucketNext[tail] = linkIndex;
      }
      _linkBucketTails[bucket] = linkIndex;
    }
    var linkOrderIndex = 0;
    for (var bucket = 0; bucket < depthBucketCount; bucket++) {
      var linkIndex = _linkBucketHeads[bucket];
      while (linkIndex >= 0) {
        visualLinkDrawOrder[linkOrderIndex++] = linkIndex;
        linkIndex = _linkBucketNext[linkIndex];
      }
    }
    _revision++;
    if (notify) notifyListeners();
    return true;
  }

  void setManualPosition(String nodeId, Offset position, {bool notify = true}) {
    if (!position.dx.isFinite || !position.dy.isFinite) return;
    final index = _topology.nodeIndexById[nodeId];
    if (index == null || _topology.isSynthetic(index)) return;
    _manualFlags[index] = 1;
    _manualX[index] = position.dx;
    _manualY[index] = position.dy;
    projectedX[index] = position.dx;
    projectedY[index] = position.dy;
    _revision++;
    if (notify && _active) notifyListeners();
  }

  void clearManualPosition(String nodeId, {bool notify = true}) {
    final index = _topology.nodeIndexById[nodeId];
    if (index == null || _manualFlags[index] == 0) return;
    _manualFlags[index] = 0;
    final viewport = _viewport;
    final rotationX = _rotationX;
    final rotationY = _rotationY;
    final zoom = _zoom;
    final padding = _padding;
    _rotationX = double.nan;
    if (!viewport.isEmpty && rotationX.isFinite && rotationY.isFinite) {
      project(
        viewport: viewport,
        rotationX: rotationX,
        rotationY: rotationY,
        zoom: zoom.isFinite ? zoom : 1,
        padding: padding.isFinite ? padding : 12,
        notify: notify,
      );
    }
  }

  Offset? positionForId(String nodeId) {
    final index = _topology.nodeIndexById[nodeId];
    return index == null ? null : positionAt(index);
  }

  Offset positionAt(int index) => Offset(projectedX[index], projectedY[index]);

  SphereGraphLayoutPoint? commitManualPosition(String nodeId) {
    final index = _topology.nodeIndexById[nodeId];
    if (index == null || _manualFlags[index] == 0 || _viewport.isEmpty) {
      return null;
    }
    final radius =
        math.max(
          0.0,
          math.min(_viewport.width, _viewport.height) / 2 - _padding,
        ) *
        .91 *
        _zoom;
    if (radius <= .001) return null;
    final rotatedZ = cameraDepths[index].toDouble();
    final perspective = 1 / (1 - rotatedZ * .32);
    final rotatedX =
        (_manualX[index] - _viewport.width / 2) / (radius * perspective);
    final rotatedY =
        (_manualY[index] - _viewport.height / 2) / (radius * perspective);
    final modelY =
        rotatedY * math.cos(_rotationX) + rotatedZ * math.sin(_rotationX);
    final depthAfterYaw =
        -rotatedY * math.sin(_rotationX) + rotatedZ * math.cos(_rotationX);
    final modelX =
        rotatedX * math.cos(_rotationY) - depthAfterYaw * math.sin(_rotationY);
    final modelZ =
        rotatedX * math.sin(_rotationY) + depthAfterYaw * math.cos(_rotationY);
    final magnitude = math.max(
      1.0,
      math.sqrt(modelX * modelX + modelY * modelY + modelZ * modelZ),
    );
    final point = SphereGraphLayoutPoint(
      id: nodeId,
      x: modelX / magnitude,
      y: modelY / magnitude,
      z: modelZ / magnitude,
      isSynthetic: false,
    );
    _topology.baseCoordinates[index * 3] = point.x;
    _topology.baseCoordinates[index * 3 + 1] = point.y;
    _topology.baseCoordinates[index * 3 + 2] = point.z;
    clearManualPosition(nodeId);
    return point;
  }

  void _allocateBuffers() {
    final count = _topology.nodeCount;
    projectedX = Float32List(count);
    projectedY = Float32List(count);
    cameraDepths = Float32List(count);
    normalizedDepths = Float32List(count);
    sizeFactors = Float32List(count);
    opacities = Float32List(count);
    drawOrder = Uint32List(count);
    visualLinkDrawOrder = Uint32List(_topology.visualLinkSources.length);
    _manualFlags = Uint8List(count);
    _manualX = Float32List(count);
    _manualY = Float32List(count);
    _bucketHeads = Int32List(depthBucketCount);
    _bucketTails = Int32List(depthBucketCount);
    _bucketNext = Int32List(count);
    _linkBucketHeads = Int32List(depthBucketCount);
    _linkBucketTails = Int32List(depthBucketCount);
    _linkBucketNext = Int32List(_topology.visualLinkSources.length);
    _positionsView = _ProjectionOffsetMap(this);
    _depthsView = _ProjectionDoubleMap(this, _ProjectionValue.depth);
    _sizeFactorsView = _ProjectionDoubleMap(this, _ProjectionValue.size);
    _opacitiesView = _ProjectionDoubleMap(this, _ProjectionValue.opacity);
    _drawOrderIdsView = _ProjectionDrawOrderList(this);
  }
}

enum _ProjectionValue { depth, size, opacity }

final class _ProjectionOffsetMap extends MapBase<String, Offset> {
  _ProjectionOffsetMap(this.controller);

  final SphereGraphProjectionController controller;

  @override
  Offset? operator [](Object? key) {
    final index = controller.topology.nodeIndexById[key];
    if (index == null || controller.topology.isSynthetic(index)) return null;
    return controller.positionAt(index);
  }

  @override
  Iterable<String> get keys sync* {
    for (var index = 0; index < controller.topology.nodeCount; index++) {
      if (!controller.topology.isSynthetic(index)) {
        yield controller.topology.nodeIds[index];
      }
    }
  }

  @override
  void operator []=(String key, Offset value) =>
      throw UnsupportedError('projection views are read-only');

  @override
  void clear() => throw UnsupportedError('projection views are read-only');

  @override
  Offset? remove(Object? key) =>
      throw UnsupportedError('projection views are read-only');
}

final class _ProjectionDoubleMap extends MapBase<String, double> {
  _ProjectionDoubleMap(this.controller, this.value);

  final SphereGraphProjectionController controller;
  final _ProjectionValue value;

  @override
  double? operator [](Object? key) {
    final index = controller.topology.nodeIndexById[key];
    if (index == null || controller.topology.isSynthetic(index)) return null;
    return switch (value) {
      _ProjectionValue.depth => controller.normalizedDepths[index],
      _ProjectionValue.size => controller.sizeFactors[index],
      _ProjectionValue.opacity => controller.opacities[index],
    };
  }

  @override
  Iterable<String> get keys => controller.positions.keys;

  @override
  void operator []=(String key, double value) =>
      throw UnsupportedError('projection views are read-only');

  @override
  void clear() => throw UnsupportedError('projection views are read-only');

  @override
  double? remove(Object? key) =>
      throw UnsupportedError('projection views are read-only');
}

final class _ProjectionDrawOrderList extends ListBase<String> {
  _ProjectionDrawOrderList(this.controller);

  final SphereGraphProjectionController controller;

  @override
  int get length => controller.topology.nodeCount;

  @override
  set length(int value) =>
      throw UnsupportedError('projection views are read-only');

  @override
  String operator [](int index) =>
      controller.topology.nodeIds[controller.drawOrder[index]];

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('projection views are read-only');
}

double _lerp(double start, double end, double amount) =>
    start + (end - start) * amount;
