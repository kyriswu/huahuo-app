import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_work_ai_task_page.dart';
import 'package:huahuoai_app/features/work_ai/application/work_ai_task_controller.dart';
import 'package:huahuoai_app/features/work_ai/data/work_ai_task_api.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

void main() {
  testWidgets(
    'V3 task page displays server topics and regenerates a new task',
    (tester) async {
      final api = _WidgetTaskApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[workAiTaskApiProvider.overrideWithValue(api)],
          child: const MaterialApp(home: V3WorkAiTaskPage(taskId: 'task-1')),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(
        tester
            .widget<V3PageScaffold>(find.byType(V3PageScaffold))
            .fallbackRoute,
        '/v3/workbench',
      );
      expect(find.text('A useful topic'), findsOneWidget);
      await tester.tap(find.byTooltip('任务操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新生成'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Use a stronger contrast');
      await tester.tap(find.text('提交'));
      await tester.pump();
      await tester.pump();

      expect(api.regenerateSupplements, <String?>['Use a stronger contrast']);
      expect(api.loadedTaskIds, <String>['task-1', 'task-2']);
    },
  );

  testWidgets('running task polling requires foreground current route', (
    tester,
  ) async {
    final api = _WidgetTaskApi();
    final activity = AppActivityCoordinator(binding: tester.binding);
    activity.updateLifecycle(AppLifecycleState.resumed);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          workAiTaskApiProvider.overrideWithValue(api),
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3WorkAiTaskPage(taskId: 'task-2'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(api.loadedTaskIds, <String>['task-2']);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(api.loadedTaskIds, <String>['task-2']);

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(api.loadedTaskIds, <String>['task-2', 'task-2']);

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 6));
    expect(api.loadedTaskIds, hasLength(2));

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.loadedTaskIds, hasLength(3));
  });

  testWidgets('a replacement running task receives a new hashed poll key', (
    tester,
  ) async {
    final api = _WidgetTaskApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[workAiTaskApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: V3WorkAiTaskPage(taskId: 'task-2')),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3WorkAiTaskPage)),
    );
    final orchestrator = container.read(taskOrchestratorProvider);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    final firstKeys = orchestrator.snapshot.projections
        .where((task) => task.spec.owner == 'work-ai.task-status')
        .map((task) => task.spec.key)
        .toSet();
    expect(firstKeys, hasLength(1));

    await container.read(workAiTaskControllerProvider).load('task-3');
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    final replacementKeys = orchestrator.snapshot.projections
        .where((task) => task.spec.owner == 'work-ai.task-status')
        .map((task) => task.spec.key)
        .toSet();
    expect(replacementKeys, hasLength(2));
    expect(replacementKeys, containsAll(firstKeys));
    expect(replacementKeys.every((key) => !key.contains('task-2')), isTrue);
    expect(replacementKeys.every((key) => !key.contains('task-3')), isTrue);
  });
}

final class _WidgetTaskApi implements WorkAiTaskApiPort {
  final loadedTaskIds = <String>[];
  final regenerateSupplements = <String?>[];

  @override
  Future<ApiResult<WorkAiTaskDetail>> getTask(String taskId) async {
    loadedTaskIds.add(taskId);
    return ApiResult<WorkAiTaskDetail>.success(
      data: _detail(taskId),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<WorkAiTaskInfo>> regenerateTask({
    required String taskId,
    String? supplement,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    regenerateSupplements.add(supplement);
    return ApiResult<WorkAiTaskInfo>.success(
      data: const WorkAiTaskInfo(
        taskId: 'task-2',
        taskType: 'topic_generation',
        status: 'queued',
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<WorkAiTaskInfo>> retryTask({
    required String taskId,
    String? stage,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    throw UnimplementedError();
  }
}

WorkAiTaskDetail _detail(String taskId) {
  return WorkAiTaskDetail(
    task: WorkAiTaskInfo(
      taskId: taskId,
      taskType: 'topic_generation',
      status: taskId == 'task-1' ? 'succeeded' : 'queued',
    ),
    topicResult: taskId == 'task-1'
        ? const WorkAiTopicResult(
            taskId: 'task-1',
            topics: <WorkAiTopicResultItem>[
              WorkAiTopicResultItem(
                title: 'A useful topic',
                reason: 'It is grounded in deposited material.',
              ),
            ],
          )
        : null,
    retryActions: const <WorkAiTaskRetryAction>[],
  );
}
