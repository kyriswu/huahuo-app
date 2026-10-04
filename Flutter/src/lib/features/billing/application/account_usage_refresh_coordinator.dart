import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import 'account_usage_controller.dart';

/// Owns foreground account usage refreshes independently from the profile UI.
final class AccountUsageRefreshCoordinator {
  AccountUsageRefreshCoordinator({
    required AccountUsageController Function() currentController,
    required TaskOrchestrator orchestrator,
    required RuntimeActivityMetrics activityMetrics,
    required bool Function() canRun,
  }) : _canRun = canRun,
       _poller = OrchestratedPoller(
         orchestrator: orchestrator,
         // performance-rfc: unified-network-pollers
         spec: TaskSpec(
           key: 'account:usage-refresh',
           owner: 'account-usage-page',
           priority: TaskPriority.userVisible,
           resources: const {TaskResource.network},
           foregroundOnly: true,
           replaceExisting: true,
           retryable: true,
           deadline: const Duration(seconds: 25),
         ),
         interval: const Duration(seconds: 30),
         maxBackoff: const Duration(minutes: 2),
         activityMetrics: activityMetrics,
         poll: (token) async {
           if (!canRun()) return false;
           final controller = currentController();
           await controller.load();
           token.throwIfCancelled();
           if (controller.status == AccountUsageStatus.failure ||
               controller.status == AccountUsageStatus.unavailable) {
             throw StateError('Account usage unavailable');
           }
           return canRun();
         },
       );

  final bool Function() _canRun;
  final OrchestratedPoller _poller;

  void start() {
    if (_canRun()) _poller.start();
  }

  void stop() => _poller.stop();

  void dispose() => _poller.dispose();
}
