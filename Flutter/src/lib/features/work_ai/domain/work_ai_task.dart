final class WorkAiTaskInfo {
  const WorkAiTaskInfo({
    required this.taskId,
    required this.taskType,
    required this.status,
    this.source,
    this.resultMessageId,
    this.errorCode,
    this.errorMessage,
    this.retryable = false,
  });

  final String taskId;
  final String taskType;
  final String status;
  final String? source;
  final String? resultMessageId;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  bool get isTerminal => status == 'succeeded' || status == 'failed';
  bool get isRunning => status == 'queued' || status == 'running';
}

final class WorkAiTopicResultItem {
  const WorkAiTopicResultItem({
    required this.title,
    required this.reason,
    this.sourceRecordingIds = const <String>[],
  });

  final String title;
  final String reason;
  final List<String> sourceRecordingIds;
}

final class WorkAiTopicResult {
  const WorkAiTopicResult({required this.taskId, required this.topics});

  final String taskId;
  final List<WorkAiTopicResultItem> topics;
}

final class WorkAiTaskRetryAction {
  const WorkAiTaskRetryAction({
    required this.action,
    required this.title,
    required this.allowed,
    this.reason,
  });

  final String action;
  final String title;
  final bool allowed;
  final String? reason;
}

final class WorkAiTaskDetail {
  const WorkAiTaskDetail({
    required this.task,
    required this.retryActions,
    this.topicResult,
  });

  final WorkAiTaskInfo task;
  final WorkAiTopicResult? topicResult;
  final List<WorkAiTaskRetryAction> retryActions;
}
