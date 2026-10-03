import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/performance/performance_policy.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/performance/frame_metrics_collector.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/core/performance/thermal_state_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const foreground = AppActivityState(
    visibility: AppVisibility.foreground,
    route: '/',
    activeTab: 'feed',
    powerClass: AppPowerClass.normal,
    networkAvailable: true,
    foregroundGeneration: 1,
    memoryPressureRevision: 0,
    viewMetricsRevision: 0,
    reduceMotion: false,
  );

  test('frame quality preserves the exact existing thresholds', () {
    for (final entry in <double, AppVisualQuality>{
      0: AppVisualQuality.high,
      16.999: AppVisualQuality.high,
      17: AppVisualQuality.balanced,
      23.999: AppVisualQuality.balanced,
      24: AppVisualQuality.constrained,
      50: AppVisualQuality.constrained,
    }.entries) {
      expect(PerformancePolicy.frameQualityFor(entry.key), entry.value);
      expect(
        PerformancePolicy.resolve(
          activity: foreground,
          reduceMotion: false,
          recentFrameP95Millis: entry.key,
        ).visualQuality,
        entry.value,
      );
    }
  });

  test('frame updates preserve runtime identity and startup markers', () {
    final frames = FrameMetricsCollector(notificationBatchSize: 1);
    final thermal = InMemoryThermalStatePort(
      initialThermalLevel: ThermalLevel.nominal,
    );
    final container = ProviderContainer(
      overrides: [
        frameMetricsCollectorProvider.overrideWith((ref) => frames),
        thermalStatePortProvider.overrideWithValue(thermal),
      ],
    );
    addTearDown(() {
      container.dispose();
      thermal.dispose();
    });
    final runtime = container.read(appPerformanceRuntimeProvider)
      ..markFirstFrame()
      ..markFirstInteractive();
    final firstSnapshot = runtime.capture().runtime;
    expect(firstSnapshot['firstFrameMs'], isNotNull);
    expect(firstSnapshot['firstInteractiveMs'], isNotNull);

    for (final milliseconds in <int>[8, 19, 40]) {
      frames.recordFrame(
        build: const Duration(milliseconds: 2),
        raster: const Duration(milliseconds: 3),
        total: Duration(milliseconds: milliseconds),
      );
      final current = container.read(appPerformanceRuntimeProvider);
      expect(current, same(runtime));
      expect(current.frames, same(frames));
      final snapshot = current.capture().runtime;
      expect(snapshot['firstFrameMs'], firstSnapshot['firstFrameMs']);
      expect(
        snapshot['firstInteractiveMs'],
        firstSnapshot['firstInteractiveMs'],
      );
    }
  });

  test('policy ignores navigation and frame jitter within a quality band', () {
    final frames = FrameMetricsCollector(capacity: 1, notificationBatchSize: 1);
    final thermal = InMemoryThermalStatePort(
      initialThermalLevel: ThermalLevel.nominal,
    );
    final container = ProviderContainer(
      overrides: [
        frameMetricsCollectorProvider.overrideWith((ref) => frames),
        thermalStatePortProvider.overrideWithValue(thermal),
      ],
    );
    addTearDown(() {
      container.dispose();
      thermal.dispose();
    });
    final activity = container.read(appActivityCoordinatorProvider)
      ..updateLifecycle(AppLifecycleState.resumed);
    final observed = <PerformancePolicy>[];
    container.listen<PerformancePolicy>(
      performancePolicyProvider,
      (_, policy) => observed.add(policy),
      fireImmediately: true,
    );
    final initial = container.read(performancePolicyProvider);
    activity
      ..updateRoute('/v3/chat')
      ..updateActiveTab('profile')
      ..updateNetworkAvailability(false)
      ..didChangeMetrics();
    expect(container.read(performancePolicyProvider), same(initial));
    for (final milliseconds in <int>[8, 16]) {
      frames.recordFrame(
        build: const Duration(milliseconds: 2),
        raster: const Duration(milliseconds: 3),
        total: Duration(milliseconds: milliseconds),
      );
      expect(container.read(performancePolicyProvider), same(initial));
    }
    expect(observed, hasLength(1));

    frames.recordFrame(
      build: const Duration(milliseconds: 2),
      raster: const Duration(milliseconds: 3),
      total: const Duration(milliseconds: 17),
    );
    final balanced = container.read(performancePolicyProvider);
    expect(balanced.visualQuality, AppVisualQuality.balanced);
    expect(observed, hasLength(2));
    frames.recordFrame(
      build: const Duration(milliseconds: 2),
      raster: const Duration(milliseconds: 3),
      total: const Duration(milliseconds: 23),
    );
    expect(container.read(performancePolicyProvider), same(balanced));
    activity.updateLifecycle(AppLifecycleState.paused);
    expect(
      container.read(performancePolicyProvider).allowIdleAnimation,
      isFalse,
    );
    activity.updateLifecycle(AppLifecycleState.resumed);
    expect(
      container.read(performancePolicyProvider).visualQuality,
      AppVisualQuality.balanced,
    );
    thermal.update(thermalLevel: ThermalLevel.fair);
    expect(
      container.read(performancePolicyProvider).graphAutomaticFrameRate,
      15,
    );
    activity.updateReduceMotion(true);
    expect(
      container.read(performancePolicyProvider).allowIdleAnimation,
      isFalse,
    );
    activity.updateReduceMotion(false);
    activity.didHaveMemoryPressure();
    final constrained = container.read(performancePolicyProvider);
    expect(constrained.visualQuality, AppVisualQuality.constrained);
    expect(constrained.allowIdleAnimation, isFalse);
    activity.didHaveMemoryPressure();
    expect(container.read(performancePolicyProvider), same(constrained));
  });

  test('healthy foreground retains policy-controlled sphere rotation', () {
    const flags = PerformanceFeatureFlags();
    final policy = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: false,
      recentFrameP95Millis: 12,
      flags: flags,
    );

    expect(flags.graphIdleAnimationEnabled, isTrue);
    expect(flags.graphQualityTier, isEmpty);
    expect(flags.adaptiveGlassEnabled, isTrue);
    expect(policy.visualQuality, AppVisualQuality.high);
    expect(policy.graphVisualQuality, AppVisualQuality.high);
    expect(policy.allowIdleAnimation, isTrue);
    expect(policy.graphAutomaticFrameRate, 30);
    expect(policy.maxNetworkConcurrency, 3);
  });

  test('frame pressure selects balanced without disabling all prefetch', () {
    final policy = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: false,
      recentFrameP95Millis: 19,
    );

    expect(policy.visualQuality, AppVisualQuality.balanced);
    expect(policy.allowImagePrefetch, isTrue);
  });

  test('background, accessibility, power, heat and memory constrain work', () {
    final conditions = <PerformancePolicy>[
      PerformancePolicy.resolve(
        activity: foreground.copyWith(visibility: AppVisibility.background),
        reduceMotion: false,
        recentFrameP95Millis: 8,
      ),
      PerformancePolicy.resolve(
        activity: foreground,
        reduceMotion: true,
        recentFrameP95Millis: 8,
      ),
      PerformancePolicy.resolve(
        activity: foreground.copyWith(powerClass: AppPowerClass.lowPower),
        reduceMotion: false,
        recentFrameP95Millis: 8,
      ),
      PerformancePolicy.resolve(
        activity: foreground.copyWith(powerClass: AppPowerClass.thermalLimited),
        reduceMotion: false,
        recentFrameP95Millis: 8,
      ),
      PerformancePolicy.resolve(
        activity: foreground,
        reduceMotion: false,
        recentFrameP95Millis: 8,
        memoryConstrained: true,
      ),
    ];

    for (final policy in conditions) {
      expect(policy.visualQuality, AppVisualQuality.constrained);
      expect(policy.graphNodeBudget, inInclusiveRange(24, 36));
      expect(policy.allowIdleAnimation, identical(policy, conditions[2]));
      expect(policy.maxCpuJobs, 1);
    }
    expect(conditions.first.backgroundPollFloor, const Duration(minutes: 15));
    expect(conditions[2].graphAutomaticFrameRate, 10);
  });

  test('graph thermal cadence does not constrain unrelated healthy work', () {
    final warm = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: false,
      recentFrameP95Millis: 8,
      graphThermalFrameRate: 15,
    );
    expect(warm.visualQuality, AppVisualQuality.high);
    expect(warm.graphVisualQuality, AppVisualQuality.balanced);
    expect(warm.graphAutomaticFrameRate, 15);
    expect(warm.maxNetworkConcurrency, 3);
    final disabled = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: false,
      recentFrameP95Millis: 8,
      flags: const PerformanceFeatureFlags(graphIdleAnimationEnabled: false),
    );
    expect(disabled.allowIdleAnimation, isFalse);
    expect(disabled.graphAutomaticFrameRate, 0);
  });

  testWidgets(
    'graph thermal recovery is delayed, conservative and cancellable',
    (tester) async {
      final thermal = InMemoryThermalStatePort(
        initialThermalLevel: ThermalLevel.nominal,
      );
      final budget = GraphThermalBudgetController(thermal: thermal);
      addTearDown(thermal.dispose);
      expect(budget.maximumFrameRate, 30);
      thermal.update(thermalLevel: ThermalLevel.fair);
      expect(budget.maximumFrameRate, 15);
      thermal.update(thermalLevel: ThermalLevel.serious);
      expect(budget.maximumFrameRate, 0);
      thermal.update(thermalLevel: ThermalLevel.nominal);
      await tester.pump(const Duration(seconds: 29));
      expect(budget.maximumFrameRate, 0);
      thermal.update(thermalLevel: ThermalLevel.unknown);
      await tester.pump(const Duration(seconds: 2));
      expect(budget.maximumFrameRate, 0);
      thermal.update(thermalLevel: ThermalLevel.nominal);
      await tester.pump(const Duration(seconds: 30));
      expect(budget.maximumFrameRate, 30);
      thermal.update(thermalLevel: ThermalLevel.fair);
      thermal.update(thermalLevel: ThermalLevel.nominal);
      budget.dispose();
      await tester.pump(const Duration(seconds: 31));
      expect(tester.takeException(), isNull);
    },
  );

  test('graph tier override is a safe rollback quality cap', () {
    final healthy = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: false,
      recentFrameP95Millis: 8,
      flags: const PerformanceFeatureFlags(graphQualityTier: 'constrained'),
    );
    final thermal = PerformancePolicy.resolve(
      activity: foreground.copyWith(powerClass: AppPowerClass.thermalLimited),
      reduceMotion: false,
      recentFrameP95Millis: 8,
      flags: const PerformanceFeatureFlags(graphQualityTier: 'high'),
    );

    expect(healthy.visualQuality, AppVisualQuality.high);
    expect(healthy.graphVisualQuality, AppVisualQuality.constrained);
    expect(healthy.graphNodeBudget, 32);
    expect(healthy.maxNetworkConcurrency, 3);
    expect(thermal.visualQuality, AppVisualQuality.constrained);
    expect(thermal.graphVisualQuality, AppVisualQuality.constrained);
    expect(thermal.graphNodeBudget, 32);
  });

  test('constrained policy lowers shared scheduler admission budgets', () {
    final constrained = PerformancePolicy.resolve(
      activity: foreground,
      reduceMotion: true,
      recentFrameP95Millis: 8,
    );
    final container = ProviderContainer(
      overrides: <Override>[
        performancePolicyProvider.overrideWithValue(constrained),
      ],
    );
    addTearDown(container.dispose);

    final orchestrator = container.read(taskOrchestratorProvider);
    expect(orchestrator.resourceBudgets[TaskResource.network], 1);
    expect(orchestrator.resourceBudgets[TaskResource.cpu], 1);
  });

  test(
    'shared scheduler keeps work through inactive and cancels on background',
    () async {
      final activity = AppActivityCoordinator()
        ..updateLifecycle(AppLifecycleState.resumed);
      final constrained = PerformancePolicy.resolve(
        activity: activity.state,
        reduceMotion: true,
        recentFrameP95Millis: 8,
      );
      final container = ProviderContainer(
        overrides: <Override>[
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
          performancePolicyProvider.overrideWithValue(constrained),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(activity.dispose);
      final orchestrator = container.read(taskOrchestratorProvider);
      final releaseBlocker = Completer<void>();
      addTearDown(() {
        if (!releaseBlocker.isCompleted) releaseBlocker.complete();
      });
      final blocker = orchestrator.schedule<void>(
        TaskSpec(
          key: 'activity-provider-blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => releaseBlocker.future,
      );
      final foregroundOnly = orchestrator.schedule<void>(
        TaskSpec(
          key: 'activity-provider-foreground-only',
          owner: 'test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
        ),
        (_) async {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        orchestrator.projectionFor('activity-provider-foreground-only')?.state,
        isA<AppTaskQueued>(),
      );

      activity.updateLifecycle(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(
        orchestrator.projectionFor('activity-provider-foreground-only')?.state,
        isA<AppTaskQueued>(),
      );

      activity.updateLifecycle(AppLifecycleState.paused);
      await expectLater(
        foregroundOnly,
        throwsA(isA<AppTaskCancelledException>()),
      );
      releaseBlocker.complete();
      await blocker;
    },
  );
}
