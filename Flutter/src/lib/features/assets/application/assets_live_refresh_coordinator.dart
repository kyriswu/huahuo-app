import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';

/// Schedules live asset reads while the observing surface is active.
/// Request merging and cancellation remain owned by the refresh operation.
final class AssetsLiveRefreshCoordinator {
  AssetsLiveRefreshCoordinator({
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
    required bool Function() canRun,
    required Future<void> Function() refresh,
  }) : _canRun = canRun,
       _poller = OrchestratedPoller(
         orchestrator: orchestrator,
         // performance-rfc: unified-network-pollers
         spec: TaskSpec(
           key: 'assets.live-refresh.account',
           owner: 'assets.live-refresh',
           priority: TaskPriority.foregroundDeferred,
           resources: const <TaskResource>{TaskResource.network},
           foregroundOnly: true,
           replaceExisting: true,
           retryable: true,
           deadline: const Duration(seconds: 15),
         ),
         interval: const Duration(seconds: 10),
         maxBackoff: const Duration(seconds: 30),
         activityMetrics: activityMetrics,
         poll: (_) async {
           if (!canRun()) return false;
           await refresh();
           return canRun();
         },
       );

  final bool Function() _canRun;
  final OrchestratedPoller _poller;

  void start({bool immediate = false}) {
    if (_canRun()) _poller.start(immediate: immediate);
  }

  void stop() => _poller.stop();

  void dispose() => _poller.dispose();
}
