import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/performance/database_metrics.dart';
import '../../core/performance/frame_metrics_collector.dart';
import '../../core/performance/memory_pressure_port.dart';
import '../../core/performance/network_metrics.dart';
import '../../core/performance/platform_thermal_state_port.dart';
import '../../core/performance/performance_snapshot.dart';
import '../../core/performance/runtime_activity_metrics.dart';
import '../../core/performance/task_metrics.dart';
import '../../core/performance/thermal_state_port.dart';
import '../../core/tasking/task_orchestrator.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../performance/performance_policy.dart';

// resident-provider: Preserves the frame metrics collector dependency identity across route changes.
final frameMetricsCollectorProvider =
    ChangeNotifierProvider<FrameMetricsCollector>((ref) {
      return FrameMetricsCollector()..start();
    });

// resident-provider: Preserves the runtime activity metrics dependency identity across route changes.
final runtimeActivityMetricsProvider = Provider<RuntimeActivityMetrics>((ref) {
  final metrics = RuntimeActivityMetrics();
  ref.onDispose(metrics.dispose);
  return metrics;
});

// resident-provider: Preserves the task metrics dependency identity across route changes.
final taskMetricsProvider = Provider<TaskMetrics>((_) => TaskMetrics());

// resident-provider: Preserves the database metrics dependency identity across route changes.
final databaseMetricsProvider = Provider<DatabaseMetrics>(
  (_) => DatabaseMetrics(),
);

// resident-provider: Preserves the network metrics dependency identity across route changes.
final networkMetricsProvider = Provider<NetworkMetrics>(
  (_) => NetworkMetrics(),
);

// resident-provider: Shares one memory pressure port dependency for the full account session.
final memoryPressurePortProvider = Provider<InMemoryMemoryPressurePort>((ref) {
  final port = InMemoryMemoryPressurePort();
  ref.onDispose(port.dispose);
  return port;
});

// resident-provider: Shares one thermal state port dependency for the full account session.
final thermalStatePortProvider = Provider<ThermalStatePort>((ref) {
  final port = PlatformThermalStatePort();
  final activity = ref.read(appActivityCoordinatorProvider);
  void apply(ThermalStateObservation observation) {
    activity.updatePowerClass(appPowerClassForThermalObservation(observation));
  }

  final subscription = port.changes.listen(apply);
  apply(port.current);
  ref.onDispose(() {
    unawaited(subscription.cancel());
    port.dispose();
  });
  return port;
});

AppPowerClass appPowerClassForThermalObservation(
  ThermalStateObservation observation,
) {
  if (observation.thermalLevel == ThermalLevel.serious ||
      observation.thermalLevel == ThermalLevel.critical) {
    return AppPowerClass.thermalLimited;
  }
  if (observation.powerClass == PowerClass.lowPower) {
    return AppPowerClass.lowPower;
  }
  return AppPowerClass.normal;
}

// resident-provider: Preserves the task orchestrator dependency identity across route changes.
final taskOrchestratorProvider = Provider<TaskOrchestrator>((ref) {
  final activity = ref.read(appActivityCoordinatorProvider);
  final orchestrator = TaskOrchestrator(metrics: ref.watch(taskMetricsProvider))
    ..setForeground(activity.state.canRunForegroundWork);
  void followActivity() {
    orchestrator.setForeground(activity.state.canRunForegroundWork);
  }

  activity.addListener(followActivity);
  ref.listen<PerformancePolicy>(performancePolicyProvider, (_, policy) {
    orchestrator.setResourceBudgets(<TaskResource, int>{
      TaskResource.network: policy.maxNetworkConcurrency,
      TaskResource.cpu: policy.maxCpuJobs,
    });
  }, fireImmediately: true);
  ref.onDispose(() {
    activity.removeListener(followActivity);
    orchestrator.dispose();
  });
  return orchestrator;
});

// resident-provider: Keeps the performance feature flags value consistent across sibling route consumers.
final performanceFeatureFlagsProvider = Provider<PerformanceFeatureFlags>(
  (_) => const PerformanceFeatureFlags(),
);

// resident-provider: Keeps the performance policy value consistent across sibling route consumers.
final performancePolicyProvider = Provider<PerformancePolicy>((ref) {
  ref.watch(
    appActivityCoordinatorProvider.select(
      (coordinator) => (
        isForeground: coordinator.state.isForeground,
        powerClass: coordinator.state.powerClass,
        reduceMotion: coordinator.state.reduceMotion,
        memoryConstrained: coordinator.state.memoryPressureRevision > 0,
      ),
    ),
  );
  ref.watch(
    frameMetricsCollectorProvider.select(
      (collector) => PerformancePolicy.frameQualityFor(
        collector.totalPercentiles.p95Ms ?? 0,
      ),
    ),
  );
  final activity = ref.read(appActivityCoordinatorProvider).state;
  return PerformancePolicy.resolve(
    activity: activity,
    reduceMotion: activity.reduceMotion,
    recentFrameP95Millis:
        ref.read(frameMetricsCollectorProvider).totalPercentiles.p95Ms ?? 0,
    memoryConstrained: activity.memoryPressureRevision > 0,
    graphThermalFrameRate: ref.watch(
      graphThermalBudgetProvider.select((budget) => budget.maximumFrameRate),
    ),
    flags: ref.watch(performanceFeatureFlagsProvider),
  );
});

final graphThermalBudgetProvider =
    ChangeNotifierProvider.autoDispose<GraphThermalBudgetController>((ref) {
      return GraphThermalBudgetController(
        thermal: ref.watch(thermalStatePortProvider),
      );
    });

// resident-provider: Preserves the app performance runtime dependency identity across route changes.
final appPerformanceRuntimeProvider = Provider<AppPerformanceRuntime>((ref) {
  final runtime = AppPerformanceRuntime(
    frames: ref.watch(frameMetricsCollectorProvider.notifier),
    activity: ref.watch(runtimeActivityMetricsProvider),
    tasks: ref.watch(taskMetricsProvider),
    database: ref.watch(databaseMetricsProvider),
    network: ref.watch(networkMetricsProvider),
    memoryPressure: ref.watch(memoryPressurePortProvider),
    thermal: ref.watch(thermalStatePortProvider),
  );
  final activityCoordinator = ref.read(appActivityCoordinatorProvider);
  final orchestrator = ref.read(taskOrchestratorProvider);
  var observedMemoryRevision = activityCoordinator.state.memoryPressureRevision;

  void syncActivity() {
    final state = activityCoordinator.state;
    runtime.activity.update(
      route: state.route,
      tab: state.activeTab,
      lifecycle: switch (state.visibility) {
        AppVisibility.foreground => AppLifecycleState.resumed,
        AppVisibility.inactive => AppLifecycleState.inactive,
        AppVisibility.background => AppLifecycleState.paused,
      },
      activeTasks: orchestrator.snapshot.running,
    );
    if (state.memoryPressureRevision != observedMemoryRevision) {
      observedMemoryRevision = state.memoryPressureRevision;
      runtime.memoryPressure.update(MemoryPressureLevel.critical);
    }
  }

  void syncTasks() {
    runtime.activity.update(activeTasks: orchestrator.snapshot.running);
  }

  activityCoordinator.addListener(syncActivity);
  orchestrator.addListener(syncTasks);
  ref.listen<PerformancePolicy>(performancePolicyProvider, (_, policy) {
    runtime.activity.update(
      visualQuality: switch (policy.visualQuality) {
        AppVisualQuality.high => RuntimeVisualQuality.high,
        AppVisualQuality.balanced => RuntimeVisualQuality.balanced,
        AppVisualQuality.constrained => RuntimeVisualQuality.constrained,
      },
    );
  }, fireImmediately: true);
  syncActivity();
  ref.onDispose(() {
    activityCoordinator.removeListener(syncActivity);
    orchestrator.removeListener(syncTasks);
  });
  return runtime;
});

final class AppPerformanceRuntime {
  AppPerformanceRuntime({
    required this.frames,
    required this.activity,
    required this.tasks,
    required this.database,
    required this.network,
    required this.memoryPressure,
    required this.thermal,
  }) : _bootClock = Stopwatch()..start();

  final FrameMetricsCollector frames;
  final RuntimeActivityMetrics activity;
  final TaskMetrics tasks;
  final DatabaseMetrics database;
  final NetworkMetrics network;
  final InMemoryMemoryPressurePort memoryPressure;
  final ThermalStatePort thermal;
  final Stopwatch _bootClock;
  Duration? _firstFrame;
  Duration? _firstInteractive;

  void markFirstFrame() {
    _firstFrame ??= _bootClock.elapsed;
  }

  void markFirstInteractive() {
    _firstInteractive ??= _bootClock.elapsed;
  }

  PerformanceSnapshot capture({
    DateTime? capturedAt,
    Map<String, Object?>? compressedImageCache,
  }) {
    final activitySnapshot = activity.snapshot();
    final runtime = <String, Object?>{
      ...activitySnapshot.toJson(),
      'firstFrameMs': _firstFrame == null
          ? null
          : _firstFrame!.inMicroseconds / 1000,
      'firstInteractiveMs': _firstInteractive == null
          ? null
          : _firstInteractive!.inMicroseconds / 1000,
    };
    final frame = <String, Object?>{
      ...frames.snapshot().toJson(),
      'windowContext': activitySnapshot.current.toJson(),
    };
    final decodedImages = PaintingBinding.instance.imageCache;
    return PerformanceSnapshot(
      capturedAt: capturedAt ?? DateTime.now(),
      frame: frame,
      runtime: runtime,
      tasks: tasks.snapshot().toJson(),
      database: database.snapshot().toJson(),
      network: network.snapshot().toJson(),
      imageCaches: <String, Object?>{
        'decoded': <String, Object?>{
          'available': true,
          'currentEntries': decodedImages.currentSize,
          'maximumEntries': decodedImages.maximumSize,
          'currentBytes': decodedImages.currentSizeBytes,
          'maximumBytes': decodedImages.maximumSizeBytes,
          'liveEntries': decodedImages.liveImageCount,
          'pendingEntries': decodedImages.pendingImageCount,
        },
        'compressed':
            compressedImageCache ?? const <String, Object?>{'available': false},
      },
      memoryPressure: memoryPressure.current.toJson(),
      thermal: thermal.current.toJson(),
    );
  }
}
