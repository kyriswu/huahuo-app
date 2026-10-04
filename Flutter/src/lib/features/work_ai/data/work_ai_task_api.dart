import 'package:huahuo_api/huahuo_api.dart';
import '../domain/work_ai_task.dart';
import 'work_ai_api.dart';

export '../domain/work_ai_task.dart';

abstract interface class WorkAiTaskApiPort {
  Future<ApiResult<WorkAiTaskDetail>> getTask(String taskId);

  Future<ApiResult<WorkAiTaskInfo>> retryTask({
    required String taskId,
    String? stage,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });

  Future<ApiResult<WorkAiTaskInfo>> regenerateTask({
    required String taskId,
    String? supplement,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });
}

final class WorkAiTaskApi implements WorkAiTaskApiPort {
  const WorkAiTaskApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<ApiResult<WorkAiTaskDetail>> getTask(String taskId) {
    if (!isSafeWorkAiIdentifier(taskId)) {
      return Future<ApiResult<WorkAiTaskDetail>>.value(
        _invalid<WorkAiTaskDetail>('WORK_AI_TASK_ID_INVALID'),
      );
    }
    return _apiClient.request<WorkAiTaskDetail>(
      ApiRequestOptions<WorkAiTaskDetail>(
        endpointId: 'taskDetail',
        pathParams: <String, Object>{'taskId': taskId},
        parseData: parseWorkAiTaskDetail,
      ),
    );
  }

  @override
  Future<ApiResult<WorkAiTaskInfo>> retryTask({
    required String taskId,
    String? stage,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeWorkAiIdentifier(taskId) || !_isSafeRetryStage(stage)) {
      return Future<ApiResult<WorkAiTaskInfo>>.value(
        _invalid<WorkAiTaskInfo>('WORK_AI_TASK_RETRY_INPUT_INVALID'),
      );
    }
    return _apiClient.request<WorkAiTaskInfo>(
      ApiRequestOptions<WorkAiTaskInfo>(
        endpointId: 'retryTask',
        pathParams: <String, Object>{'taskId': taskId},
        body: <String, Object?>{if (stage != null) 'stage': stage},
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: parseWorkAiTaskMutation,
      ),
    );
  }

  @override
  Future<ApiResult<WorkAiTaskInfo>> regenerateTask({
    required String taskId,
    String? supplement,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeWorkAiIdentifier(taskId) || !_isSafeSupplement(supplement)) {
      return Future<ApiResult<WorkAiTaskInfo>>.value(
        _invalid<WorkAiTaskInfo>('WORK_AI_TASK_REGENERATE_INPUT_INVALID'),
      );
    }
    return _apiClient.request<WorkAiTaskInfo>(
      ApiRequestOptions<WorkAiTaskInfo>(
        endpointId: 'regenerateTask',
        pathParams: <String, Object>{'taskId': taskId},
        body: <String, Object?>{
          if (supplement != null && supplement.trim().isNotEmpty)
            'supplement': supplement.trim(),
        },
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: parseWorkAiTaskMutation,
      ),
    );
  }
}

WorkAiTaskDetail? parseWorkAiTaskDetail(Object? value) {
  final root = asObjectMap(value);
  final task = root == null ? null : _parseTask(root['task']);
  final retryActions = root == null
      ? null
      : _parseRetryActions(root['retryActions']);
  if (task == null || retryActions == null) return null;
  final hasTopicResult = root!.containsKey('topicResult');
  final topicResult = hasTopicResult
      ? _parseTopicResult(root['topicResult'])
      : null;
  if (hasTopicResult && topicResult == null) return null;
  return WorkAiTaskDetail(
    task: task,
    topicResult: topicResult,
    retryActions: List<WorkAiTaskRetryAction>.unmodifiable(retryActions),
  );
}

WorkAiTaskInfo? parseWorkAiTaskMutation(Object? value) {
  final root = asObjectMap(value);
  if (root == null) return null;
  return _parseTask(
    root['retryTask'] ?? root['regenerateTask'] ?? root['task'],
  );
}

WorkAiTaskInfo? _parseTask(Object? value) {
  final map = asObjectMap(value);
  if (map == null) return null;
  final taskId = _safeIdentifier(map['taskId']);
  final taskType = _safeText(map['taskType'], maximum: 120);
  final status = _safeStatus(map['status']);
  final error = asObjectMap(map['error']);
  final errorCode = error == null ? null : _safeIdentifier(error['code']);
  final errorMessage = error == null
      ? null
      : _safeText(error['userMessage'], maximum: 240);
  if (taskId == null ||
      taskType == null ||
      status == null ||
      (error != null && (errorCode == null || errorMessage == null))) {
    return null;
  }
  return WorkAiTaskInfo(
    taskId: taskId,
    taskType: taskType,
    status: status,
    source: _safeOptionalText(map['source'], maximum: 120),
    resultMessageId: _safeOptionalIdentifier(map['resultMessageId']),
    errorCode: errorCode,
    errorMessage: errorMessage,
    retryable: error?['retryable'] is bool
        ? error!['retryable'] as bool
        : false,
  );
}

WorkAiTopicResult? _parseTopicResult(Object? value) {
  final map = asObjectMap(value);
  final taskId = map == null ? null : _safeIdentifier(map['taskId']);
  final rawTopics = map == null ? null : map['topics'];
  if (taskId == null || rawTopics is! List) return null;
  final topics = <WorkAiTopicResultItem>[];
  for (final raw in rawTopics) {
    final topic = _parseTopicItem(raw);
    if (topic == null) return null;
    topics.add(topic);
  }
  return WorkAiTopicResult(
    taskId: taskId,
    topics: List<WorkAiTopicResultItem>.unmodifiable(topics),
  );
}

WorkAiTopicResultItem? _parseTopicItem(Object? value) {
  final map = asObjectMap(value);
  final title = map == null ? null : _safeText(map['title'], maximum: 240);
  final reason = map == null ? null : _safeText(map['reason'], maximum: 500);
  if (title == null || reason == null) return null;
  final sourceIds = map!['sourceRecordingIds'];
  if (sourceIds == null) {
    return WorkAiTopicResultItem(title: title, reason: reason);
  }
  if (sourceIds is! List) return null;
  final ids = <String>[];
  for (final raw in sourceIds) {
    final id = _safeIdentifier(raw);
    if (id == null) return null;
    ids.add(id);
  }
  return WorkAiTopicResultItem(
    title: title,
    reason: reason,
    sourceRecordingIds: List<String>.unmodifiable(ids),
  );
}

List<WorkAiTaskRetryAction>? _parseRetryActions(Object? value) {
  if (value is! List) return null;
  final output = <WorkAiTaskRetryAction>[];
  for (final raw in value) {
    final map = asObjectMap(raw);
    final action = map == null ? null : _safeIdentifier(map['action']);
    final title = map == null ? null : _safeText(map['title'], maximum: 120);
    final allowed = map == null ? null : map['allowed'];
    if (action == null || title == null || allowed is! bool) return null;
    output.add(
      WorkAiTaskRetryAction(
        action: action,
        title: title,
        allowed: allowed,
        reason: _safeOptionalText(map!['reason'], maximum: 240),
      ),
    );
  }
  return output;
}

bool _isSafeRetryStage(String? value) {
  return value == null ||
      value == 'runtime' ||
      value == 'model_generation' ||
      value == 'result_parse' ||
      value == 'workspace_write';
}

bool _isSafeSupplement(String? value) {
  return value == null ||
      value.trim().isEmpty ||
      _safeText(value, maximum: 500) != null;
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeWorkAiIdentifier(text) ? text : null;
}

String? _safeOptionalIdentifier(Object? value) {
  return value == null ? null : _safeIdentifier(value);
}

String? _safeStatus(Object? value) {
  final text = _safeText(value, maximum: 64);
  return text != null && RegExp(r'^[a-z_]{2,64}$').hasMatch(text) ? text : null;
}

String? _safeText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeText.any((pattern) => pattern.hasMatch(text)) ? null : text;
}

String? _safeOptionalText(Object? value, {required int maximum}) {
  return value == null ? null : _safeText(value, maximum: maximum);
}

ApiResult<T> _invalid<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Work AI task input is invalid',
      userMessageKey: 'work_ai.task.error.$code',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final _unsafeText = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];
