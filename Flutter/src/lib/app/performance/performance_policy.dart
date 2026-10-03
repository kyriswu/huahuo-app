import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/performance/thermal_state_port.dart';
import '../lifecycle/app_activity_coordinator.dart';

enum AppVisualQuality { high, balanced, constrained }

@immutable
final class PerformanceFeatureFlags {
  const PerformanceFeatureFlags({
    this.graphIdleAnimationEnabled = const bool.fromEnvironment(
      'HUAHUO_GRAPH_IDLE_ANIMATION',
      defaultValue: true,
    ),
    this.graphDefaultMode = const String.fromEnvironment(
      'HUAHUO_GRAPH_DEFAULT_MODE',
      defaultValue: 'sphere',
    ),
    this.graphQualityTier = const String.fromEnvironment(
      'HUAHUO_GRAPH_QUALITY_TIER',
    ),
    this.adaptiveGlassEnabled = const bool.fromEnvironment(
      'HUAHUO_ADAPTIVE_GLASS',
      defaultValue: true,
    ),
    this.chatSseAuthoritative = const bool.fromEnvironment(
      'HUAHUO_CHAT_SSE_AUTHORITATIVE',
      defaultValue: true,
    ),
    this.coalescedStreamingUi = const bool.fromEnvironment(
      'HUAHUO_COALESCED_STREAMING_UI',
      defaultValue: true,
    ),
    this.databaseWorkerEnabled = const bool.fromEnvironment(
      'HUAHUO_DATABASE_WORKER',
      defaultValue: true,
    ),
    this.incrementalProjectionEnabled = const bool.fromEnvironment(
      'HUAHUO_INCREMENTAL_PROJECTION',
      defaultValue: true,
    ),
    this.homeWidgetProjectionV2 = const bool.fromEnvironment(
      'HUAHUO_HOME_WIDGET_PROJECTION_V2',
      defaultValue: true,
    ),
  });

  final bool graphIdleAnimationEnabled;
  final String graphDefaultMode;
  final String graphQualityTier;
  final bool adaptiveGlassEnabled;
  final bool chatSseAuthoritative;
  final bool coalescedStreamingUi;
  final bool databaseWorkerEnabled;
  final bool incrementalProjectionEnabled;
  final bool homeWidgetProjectionV2;

  AppVisualQuality? get graphQualityOverride =>
      switch (graphQualityTier.trim().toLowerCase()) {
        'high' => AppVisualQuality.high,
        'balanced' => AppVisualQuality.balanced,
        'constrained' => AppVisualQuality.constrained,
        _ => null,
      };
}

@immutable
final class PerformancePolicy {
  const PerformancePolicy({
    required this.visualQuality,
    required this.graphVisualQuality,
    required this.graphNodeBudget,
    required this.graphEdgeBudget,
    required this.allowIdleAnimation,
    required this.allowImagePrefetch,
    required this.maxNetworkConcurrency,
    required this.maxCpuJobs,
    required this.backgroundPollFloor,
    this.graphAutomaticFrameRate = 30,
  });

  factory PerformancePolicy.resolve({
    required AppActivityState activity,
    required bool reduceMotion,
    required double recentFrameP95Millis,
    bool memoryConstrained = false,
    int graphThermalFrameRate = 30,
    PerformanceFeatureFlags flags = const PerformanceFeatureFlags(),
  }) {
    final frameQuality = frameQualityFor(recentFrameP95Millis);
    final constrained =
        !activity.isForeground ||
        reduceMotion ||
        memoryConstrained ||
        activity.powerClass != AppPowerClass.normal ||
        frameQuality == AppVisualQuality.constrained;
    final quality = constrained ? AppVisualQuality.constrained : frameQuality;
    final requestedGraphQuality = flags.graphQualityOverride;
    var graphQuality =
        requestedGraphQuality == null ||
            requestedGraphQuality.index < quality.index
        ? quality
        : requestedGraphQuality;
    final thermalGraphQuality = graphThermalFrameRate <= 0
        ? AppVisualQuality.constrained
        : graphThermalFrameRate < 30
        ? AppVisualQuality.balanced
        : AppVisualQuality.high;
    if (thermalGraphQuality.index > graphQuality.index) {
      graphQuality = thermalGraphQuality;
    }
    final allowAutomaticMotion =
        flags.graphIdleAnimationEnabled &&
        activity.isForeground &&
        !reduceMotion &&
        !memoryConstrained &&
        activity.powerClass != AppPowerClass.thermalLimited &&
        graphThermalFrameRate > 0;
    return PerformancePolicy(
      visualQuality: quality,
      graphVisualQuality: graphQuality,
      graphNodeBudget: switch (graphQuality) {
        AppVisualQuality.high => 120,
        AppVisualQuality.balanced => 72,
        AppVisualQuality.constrained => 32,
      },
      graphEdgeBudget: switch (graphQuality) {
        AppVisualQuality.high => 220,
        AppVisualQuality.balanced => 120,
        AppVisualQuality.constrained => 48,
      },
      allowIdleAnimation: allowAutomaticMotion,
      graphAutomaticFrameRate: allowAutomaticMotion
          ? graphThermalFrameRate.clamp(1, switch (graphQuality) {
              AppVisualQuality.high => 30,
              AppVisualQuality.balanced => 15,
              AppVisualQuality.constrained => 10,
            })
          : 0,
      allowImagePrefetch:
          activity.isForeground && quality != AppVisualQuality.constrained,
      maxNetworkConcurrency: switch (quality) {
        AppVisualQuality.high => 3,
        AppVisualQuality.balanced => 2,
        AppVisualQuality.constrained => 1,
      },
      maxCpuJobs: quality == AppVisualQuality.high ? 2 : 1,
      backgroundPollFloor: activity.isForeground
          ? const Duration(seconds: 3)
          : const Duration(minutes: 15),
    );
  }

  static AppVisualQuality frameQualityFor(double recentFrameP95Millis) =>
      recentFrameP95Millis >= 24
      ? AppVisualQuality.constrained
      : recentFrameP95Millis >= 17
      ? AppVisualQuality.balanced
      : AppVisualQuality.high;

  final AppVisualQuality visualQuality;
  final AppVisualQuality graphVisualQuality;
  final int graphNodeBudget;
  final int graphEdgeBudget;
  final bool allowIdleAnimation;
  final int graphAutomaticFrameRate;
  final bool allowImagePrefetch;
  final int maxNetworkConcurrency;
  final int maxCpuJobs;
  final Duration backgroundPollFloor;
}

final class GraphThermalBudgetController extends ChangeNotifier {
  GraphThermalBudgetController({
    required ThermalStatePort thermal,
    this.recoveryDelay = const Duration(seconds: 30),
  }) {
    _maximumFrameRate = _rateFor(thermal.current);
    _targetFrameRate = _maximumFrameRate;
    _subscription = thermal.changes.listen(_accept);
  }

  final Duration recoveryDelay;
  late final StreamSubscription<ThermalStateObservation> _subscription;
  Timer? _recoveryTimer;
  int _maximumFrameRate = 30;
  int _targetFrameRate = 30;

  int get maximumFrameRate => _maximumFrameRate;

  int _rateFor(ThermalStateObservation observation) {
    if (observation.thermalLevel == ThermalLevel.serious ||
        observation.thermalLevel == ThermalLevel.critical) {
      return 0;
    }
    if (observation.thermalLevel == ThermalLevel.unknown) {
      return observation.powerClass == PowerClass.lowPower
          ? _maximumFrameRate.clamp(0, 15)
          : _maximumFrameRate;
    }
    return observation.thermalLevel == ThermalLevel.fair ||
            observation.powerClass == PowerClass.lowPower
        ? 15
        : 30;
  }

  void _accept(ThermalStateObservation observation) {
    final next = _rateFor(observation);
    if (next == _targetFrameRate) return;
    _targetFrameRate = next;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    if (next <= _maximumFrameRate) {
      _replace(next);
    } else {
      _recoveryTimer = Timer(recoveryDelay, () {
        _recoveryTimer = null;
        _replace(_targetFrameRate);
      });
    }
  }

  void _replace(int value) {
    if (value == _maximumFrameRate) return;
    _maximumFrameRate = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
