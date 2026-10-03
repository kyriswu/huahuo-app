import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/work_ai/application/work_ai_task_controller.dart';
import 'package:huahuoai_app/features/work_ai/data/work_ai_task_api.dart';

void main() {
  test(
    'task controller opens the replacement task returned by retry',
    () async {
      final api = _TaskApi();
      final controller = WorkAiTaskController(api: api);

      await controller.load('task-1');
      final created = await controller.retry(
        const WorkAiTaskRetryAction(
          action: 'model_generation',
          title: 'Retry generation',
          allowed: true,
        ),
      );

      expect(created?.taskId, 'task-2');
      expect(api.loadedTaskIds, <String>['task-1', 'task-2']);
      expect(controller.state.detail?.task.taskId, 'task-2');
      expect(api.retryStages, <String?>['model_generation']);
    },
  );
}

final class _TaskApi implements WorkAiTaskApiPort {
  final loadedTaskIds = <String>[];
  final retryStages = <String?>[];

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
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<WorkAiTaskInfo>> retryTask({
    required String taskId,
    String? stage,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    retryStages.add(stage);
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
}

WorkAiTaskDetail _detail(String taskId) {
  return WorkAiTaskDetail(
    task: WorkAiTaskInfo(
      taskId: taskId,
      taskType: 'topic_generation',
      status: taskId == 'task-1' ? 'failed' : 'queued',
    ),
    retryActions: const <WorkAiTaskRetryAction>[
      WorkAiTaskRetryAction(
        action: 'model_generation',
        title: 'Retry generation',
        allowed: true,
      ),
    ],
  );
}
