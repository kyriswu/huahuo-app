import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/api/idempotency.dart';
import '../data/work_ai_api.dart';
import '../data/work_ai_task_api.dart';

// resident-provider: Shares one work ai task api dependency for the full account session.
final workAiTaskApiProvider = Provider<WorkAiTaskApiPort>((ref) {
  return WorkAiTaskApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Preserves the work ai task controller state machine across route transitions.
final workAiTaskControllerProvider =
    ChangeNotifierProvider<WorkAiTaskController>((ref) {
      return WorkAiTaskController(api: ref.watch(workAiTaskApiProvider));
    });

enum WorkAiTaskControllerStatus { idle, loading, ready, submitting, failed }

final class WorkAiTaskState {
  const WorkAiTaskState({required this.status, this.detail, this.errorCode});

  const WorkAiTaskState.initial()
    : this(status: WorkAiTaskControllerStatus.idle);

  final WorkAiTaskControllerStatus status;
  final WorkAiTaskDetail? detail;
  final String? errorCode;

  bool get isLoading => status == WorkAiTaskControllerStatus.loading;
  bool get isSubmitting => status == WorkAiTaskControllerStatus.submitting;

  WorkAiTaskState copyWith({
    WorkAiTaskControllerStatus? status,
    WorkAiTaskDetail? detail,
    String? errorCode,
    bool clearError = false,
  }) {
    return WorkAiTaskState(
      status: status ?? this.status,
      detail: detail ?? this.detail,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

final class WorkAiTaskController extends ChangeNotifier {
  WorkAiTaskController({required WorkAiTaskApiPort api}) : _api = api;

  final WorkAiTaskApiPort _api;
  SubmissionKeyStore _idempotencyStore = SubmissionKeyStore.empty;
  WorkAiTaskState _state = const WorkAiTaskState.initial();
  int _requestGeneration = 0;

  WorkAiTaskState get state => _state;

  Future<void> load(String taskId) async {
    if (!isSafeWorkAiIdentifier(taskId)) {
      _fail('WORK_AI_TASK_ID_INVALID');
      return;
    }
    final generation = ++_requestGeneration;
    _update(
      _state.copyWith(
        status: WorkAiTaskControllerStatus.loading,
        clearError: true,
      ),
    );
    final result = await _api.getTask(taskId);
    if (generation != _requestGeneration) return;
    if (!result.ok || result.data == null) {
      _fail(result.error?.code ?? 'WORK_AI_TASK_LOAD_FAILED');
      return;
    }
    _update(
      _state.copyWith(
        status: WorkAiTaskControllerStatus.ready,
        detail: result.data,
        clearError: true,
      ),
    );
  }

  Future<WorkAiTaskInfo?> retry(WorkAiTaskRetryAction action) async {
    final taskId = _state.detail?.task.taskId;
    if (taskId == null || !action.allowed) {
      _fail('WORK_AI_TASK_RETRY_NOT_ALLOWED');
      return null;
    }
    _update(
      _state.copyWith(
        status: WorkAiTaskControllerStatus.submitting,
        clearError: true,
      ),
    );
    final result = await _api.retryTask(
      taskId: taskId,
      stage: _retryStage(action.action),
      idempotency: IdempotencyRequestContext(
        operation: 'work_ai.retry_task',
        businessEntityId: taskId,
        scene: 'work_ai',
      ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    if (!result.ok || result.data == null) {
      _fail(result.error?.code ?? 'WORK_AI_TASK_RETRY_FAILED');
      return null;
    }
    final nextTask = result.data!;
    await load(nextTask.taskId);
    return nextTask;
  }

  Future<WorkAiTaskInfo?> regenerate({String? supplement}) async {
    final taskId = _state.detail?.task.taskId;
    if (taskId == null) {
      _fail('WORK_AI_TASK_REQUIRED');
      return null;
    }
    _update(
      _state.copyWith(
        status: WorkAiTaskControllerStatus.submitting,
        clearError: true,
      ),
    );
    final result = await _api.regenerateTask(
      taskId: taskId,
      supplement: supplement,
      idempotency: IdempotencyRequestContext(
        operation: 'work_ai.regenerate_task',
        businessEntityId: taskId,
        scene: 'work_ai',
      ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    if (!result.ok || result.data == null) {
      _fail(result.error?.code ?? 'WORK_AI_TASK_REGENERATE_FAILED');
      return null;
    }
    final nextTask = result.data!;
    await load(nextTask.taskId);
    return nextTask;
  }

  void _fail(String code) {
    _update(
      _state.copyWith(
        status: WorkAiTaskControllerStatus.failed,
        errorCode: code,
      ),
    );
  }

  void _update(WorkAiTaskState state) {
    _state = state;
    notifyListeners();
  }
}

String? _retryStage(String action) {
  return switch (action) {
    'runtime' => 'runtime',
    'model_generation' => 'model_generation',
    'result_parse' => 'result_parse',
    'workspace_write' => 'workspace_write',
    _ => null,
  };
}
