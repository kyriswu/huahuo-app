import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/assets/application/assets_live_refresh_coordinator.dart';

void main() {
  testWidgets(
    'inactive surface does not read and repeated start stays single',
    (tester) async {
      final tasks = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      var active = false;
      var reads = 0;
      final refresh = AssetsLiveRefreshCoordinator(
        orchestrator: tasks,
        activityMetrics: metrics,
        canRun: () => active,
        refresh: () async => reads++,
      );
      addTearDown(() {
        refresh.dispose();
        tasks.dispose();
        metrics.dispose();
      });

      refresh.start();
      await tester.pump(const Duration(seconds: 12));
      expect(reads, 0);
      active = true;
      refresh.start();
      refresh.start();
      await tester.pump();
      expect(reads, 0); // Initial live work keeps the delayed first poll.
      await tester.pump(const Duration(seconds: 12));
      expect(reads, 1);
      expect(metrics.current.activePollers, 1);
      active = false;
      refresh.stop();
      await tester.pump(const Duration(minutes: 1));
      expect(reads, 1);
      expect(metrics.current.activePollers, 0);
    },
  );

  testWidgets('stop discards a late completion without rearming a timer', (
    tester,
  ) async {
    final tasks = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    final pending = Completer<void>();
    var reads = 0;
    final refresh = AssetsLiveRefreshCoordinator(
      orchestrator: tasks,
      activityMetrics: metrics,
      canRun: () => true,
      refresh: () {
        reads++;
        return pending.future;
      },
    );
    refresh.start(immediate: true);
    await tester.pump();
    expect(reads, 1);
    refresh.stop();
    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 1);
    expect(metrics.current.activePollers, 0);
    refresh.dispose();
    tasks.dispose();
    metrics.dispose();
  });

  testWidgets('background suspension resumes only eligible live work', (
    tester,
  ) async {
    final tasks = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    var reads = 0;
    var active = true;
    final refresh = AssetsLiveRefreshCoordinator(
      orchestrator: tasks,
      activityMetrics: metrics,
      canRun: () => active,
      refresh: () async => reads++,
    );
    refresh.start(immediate: true);
    await tester.pump();
    expect(reads, 1);
    tasks.setForeground(false);
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 1);
    tasks.setForeground(true);
    await tester.pump();
    expect(reads, 2);
    active = false;
    await tester.pump(const Duration(seconds: 12));
    expect(reads, 2);
    expect(metrics.current.activePollers, 0);
    refresh.dispose();
    tasks.dispose();
    metrics.dispose();
  });
}
