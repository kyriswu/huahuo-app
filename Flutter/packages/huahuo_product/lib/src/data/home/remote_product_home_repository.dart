import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/home/product_home.dart';
import '../../domain/product_result.dart';

final class RemoteProductHomeRepository implements ProductHomeRepository {
  RemoteProductHomeRepository(ApiClient apiClient)
    : _client = HomeClient(apiClient);

  final HomeClient _client;

  @override
  Future<ProductResult<ProductHome>> load(String workspaceId) async {
    if (workspaceId.trim().isEmpty) {
      return const ProductResult<ProductHome>.failure(
        code: 'PRODUCT_HOME_WORKSPACE_INVALID',
        message: 'Workspace 无效',
      );
    }
    try {
      final result = await _client.load();
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return ProductResult<ProductHome>.success(_mapHome(data));
    } on Object {
      return const ProductResult<ProductHome>.failure(
        code: 'PRODUCT_HOME_LOAD_FAILED',
        message: '首页加载失败',
        retryable: true,
      );
    }
  }

  @override
  Future<ProductResult<void>> markSuggestionViewed({
    required String workspaceId,
    required String suggestionId,
    required String idempotencyKey,
  }) async {
    if (workspaceId.trim().isEmpty) {
      return const ProductResult<void>.failure(
        code: 'PRODUCT_HOME_WORKSPACE_INVALID',
        message: 'Workspace 无效',
      );
    }
    try {
      final result = await _client.markHotspotViewed(
        suggestionId: suggestionId,
        idempotencyKey: idempotencyKey,
      );
      if (!result.ok || result.data?.suggestionId != suggestionId) {
        return _failure(result);
      }
      return const ProductResult<void>.success(null);
    } on ArgumentError {
      return const ProductResult<void>.failure(
        code: 'PRODUCT_HOME_INPUT_INVALID',
        message: '首页操作参数无效',
      );
    } on Object {
      return const ProductResult<void>.failure(
        code: 'PRODUCT_HOME_ACKNOWLEDGE_FAILED',
        message: '首页状态更新失败',
        retryable: true,
      );
    }
  }
}

ProductHome _mapHome(HomeSnapshot source) {
  final tasks = <String, HomeRunningTask>{
    for (final task in source.runningTasks) task.taskId: task,
  };
  final action = source.primaryAction;
  final actionTask = action.taskId == null ? null : tasks[action.taskId];
  final suggestion = source.hotspotSuggestion;
  final redDotCount = source.redDots.fold<int>(
    0,
    (total, item) => total + item.count,
  );
  final generationBalance = source.quotaBalances
      .where((item) => item.quotaType == 'generation')
      .firstOrNull;
  return ProductHome(
    action: ProductHomeAction(
      type: switch (action.type) {
        HomePrimaryActionType.openRunningTask =>
          ProductHomeActionType.openRunningTask,
        HomePrimaryActionType.viewHotspotSuggestion =>
          ProductHomeActionType.viewHotspotSuggestion,
        HomePrimaryActionType.uploadRecording =>
          ProductHomeActionType.uploadRecording,
      },
      label: action.label,
      taskId: action.taskId,
      threadId: actionTask?.threadId,
      suggestionId: action.suggestionId,
    ),
    suggestion: suggestion == null
        ? null
        : ProductHomeSuggestion(
            id: suggestion.suggestionId,
            title: suggestion.title,
            summary: suggestion.summary,
            eventBrief: suggestion.eventBrief,
            discussionPoints: suggestion.discussionPoints,
            topicAngles: suggestion.topicAngles,
            sourceName: suggestion.sourceName,
            acknowledged: redDotCount == 0,
          ),
    runningTaskCount: source.runningTasks.length,
    recordingCount: source.fileSummary.recordingCount,
    depositedRecordingCount: source.fileSummary.depositedRecordingCount,
    availableGenerationCredits: generationBalance?.remaining,
    redDotCount: redDotCount,
    serverTime: source.serverTime,
  );
}

ProductResult<T> _failure<T>(ApiResult<Object?> result) =>
    ProductResult<T>.failure(
      code: result.error?.code ?? 'PRODUCT_HOME_RESPONSE_INVALID',
      message: result.error?.message ?? '首页服务响应无效',
      retryable: result.error?.isRetryable ?? false,
    );
