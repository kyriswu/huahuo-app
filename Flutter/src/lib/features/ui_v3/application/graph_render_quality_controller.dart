import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../app/performance/performance_policy.dart';
import '../domain/graph_edge_geometry.dart';
import 'graph_render_budget.dart';

final class GraphRenderQualityController extends ChangeNotifier {
  factory GraphRenderQualityController({
    Duration settleDelay = const Duration(milliseconds: 120),
    int maximumVisualNodeCount = 120,
    int maximumOrdinaryEdgeCount = GraphRenderBudget.maximumOrdinaryEdges,
    AppVisualQuality visualQuality = AppVisualQuality.balanced,
    bool allowIdleAnimation = false,
    int automaticFrameRate = 30,
  }) => GraphRenderQualityController._(
    settleDelay: settleDelay,
    maximumVisualNodeCount: maximumVisualNodeCount,
    maximumOrdinaryEdgeCount: maximumOrdinaryEdgeCount,
    visualQuality: visualQuality,
    allowIdleAnimation: allowIdleAnimation,
    automaticFrameRate: automaticFrameRate,
  );

  GraphRenderQualityController._({
    required this.settleDelay,
    required this._maximumVisualNodeCount,
    required this._maximumOrdinaryEdgeCount,
    required this._visualQuality,
    required this._allowIdleAnimation,
    required this._automaticFrameRate,
  });

  final Duration settleDelay;
  GraphRenderQuality _quality = GraphRenderQuality.idle;
  int _maximumVisualNodeCount;
  int _maximumOrdinaryEdgeCount;
  AppVisualQuality _visualQuality;
  bool _allowIdleAnimation;
  int _automaticFrameRate;
  Timer? _settleTimer;

  GraphRenderQuality get quality => _quality;
  AppVisualQuality get visualQuality => _visualQuality;
  bool get allowIdleAnimation => _allowIdleAnimation;
  int get automaticFrameRate => _automaticFrameRate;

  GraphRenderBudget resolveBudget(GraphGeometryLod lod) =>
      GraphRenderBudget.resolve(
        lod: lod,
        quality: _quality,
        maximumVisualNodeCount: _maximumVisualNodeCount,
        maximumOrdinaryEdgeCount: _maximumOrdinaryEdgeCount,
      );

  void setPerformanceLimits({
    required int maximumVisualNodeCount,
    required int maximumOrdinaryEdgeCount,
  }) {
    assert(maximumVisualNodeCount >= 0);
    assert(maximumOrdinaryEdgeCount >= 0);
    if (_maximumVisualNodeCount == maximumVisualNodeCount &&
        _maximumOrdinaryEdgeCount == maximumOrdinaryEdgeCount) {
      return;
    }
    _maximumVisualNodeCount = maximumVisualNodeCount;
    _maximumOrdinaryEdgeCount = maximumOrdinaryEdgeCount;
    notifyListeners();
  }

  void setPerformancePolicy({
    required int maximumVisualNodeCount,
    required int maximumOrdinaryEdgeCount,
    required AppVisualQuality visualQuality,
    required bool allowIdleAnimation,
    int automaticFrameRate = 30,
  }) {
    assert(maximumVisualNodeCount >= 0);
    assert(maximumOrdinaryEdgeCount >= 0);
    if (_maximumVisualNodeCount == maximumVisualNodeCount &&
        _maximumOrdinaryEdgeCount == maximumOrdinaryEdgeCount &&
        _visualQuality == visualQuality &&
        _allowIdleAnimation == allowIdleAnimation &&
        _automaticFrameRate == automaticFrameRate) {
      return;
    }
    _maximumVisualNodeCount = maximumVisualNodeCount;
    _maximumOrdinaryEdgeCount = maximumOrdinaryEdgeCount;
    _visualQuality = visualQuality;
    _allowIdleAnimation = allowIdleAnimation;
    _automaticFrameRate = automaticFrameRate;
    notifyListeners();
  }

  void beginInteraction() {
    if (_quality == GraphRenderQuality.inactive) return;
    _settleTimer?.cancel();
    _settleTimer = null;
    _setQuality(GraphRenderQuality.interacting);
  }

  void endInteraction() {
    if (_quality == GraphRenderQuality.inactive) return;
    _setQuality(GraphRenderQuality.settling);
    _settleTimer?.cancel();
    _settleTimer = Timer(settleDelay, () {
      _settleTimer = null;
      if (_quality == GraphRenderQuality.settling) {
        _setQuality(GraphRenderQuality.idle);
      }
    });
  }

  void setActive(bool active) {
    _settleTimer?.cancel();
    _settleTimer = null;
    _setQuality(active ? GraphRenderQuality.idle : GraphRenderQuality.inactive);
  }

  void _setQuality(GraphRenderQuality value) {
    if (_quality == value) return;
    _quality = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }
}
