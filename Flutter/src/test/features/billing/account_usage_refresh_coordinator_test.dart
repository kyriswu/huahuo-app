import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/billing/application/account_usage_controller.dart';
import 'package:huahuoai_app/features/billing/application/account_usage_refresh_coordinator.dart';
import 'package:huahuoai_app/features/billing/domain/account_usage_repository.dart';

void main() {
  testWidgets('each poll resolves the current account controller', (
    tester,
  ) async {
    final first = _UnavailableUsage();
    final second = _UnavailableUsage();
    final oldController = AccountUsageController(repository: first);
    final newController = AccountUsageController(repository: second);
    var controller = oldController;
    var active = false;
    final tasks = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    final refresh = AccountUsageRefreshCoordinator(
      currentController: () => controller,
      orchestrator: tasks,
      activityMetrics: metrics,
      canRun: () => active,
    );
    refresh.start();
    await tester.pump(const Duration(minutes: 1));
    expect(first.reads, 0);
    active = true;
    refresh.start();
    refresh.start();
    await tester.pump();
    expect(first.reads, 1);
    controller = newController;
    oldController.dispose();
    await tester.pump(const Duration(seconds: 35));
    expect(first.reads, 1);
    expect(second.reads, 1);
    refresh.stop();
    await tester.pump(const Duration(minutes: 3));
    expect(second.reads, 1);
    expect(metrics.current.activePollers, 0);
    refresh.dispose();
    newController.dispose();
    tasks.dispose();
    metrics.dispose();
  });
}

class _UnavailableUsage implements AccountUsageRepository {
  int reads = 0;

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>> membership() async {
    reads++;
    return const MobileAccountUsageResult.failure('UNAVAILABLE');
  }

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) async => const MobileAccountUsageResult.failure('UNAVAILABLE');

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async => const MobileAccountUsageResult.failure('UNAVAILABLE');

  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async =>
      const MobileAccountUsageResult.failure('UNAVAILABLE');

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async => const MobileAccountUsageResult.failure('UNAVAILABLE');
}
