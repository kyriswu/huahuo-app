import '../product_result.dart';

enum ProductHomeActionType {
  openRunningTask,
  viewHotspotSuggestion,
  uploadRecording,
}

final class ProductHomeAction {
  const ProductHomeAction({
    required this.type,
    required this.label,
    this.taskId,
    this.threadId,
    this.suggestionId,
  });

  final ProductHomeActionType type;
  final String label;
  final String? taskId;
  final String? threadId;
  final String? suggestionId;
}

final class ProductHomeSuggestion {
  ProductHomeSuggestion({
    required this.id,
    required this.title,
    required this.summary,
    required this.eventBrief,
    required List<String> discussionPoints,
    required List<String> topicAngles,
    required this.sourceName,
    required this.acknowledged,
  }) : discussionPoints = List<String>.unmodifiable(discussionPoints),
       topicAngles = List<String>.unmodifiable(topicAngles);

  final String id;
  final String title;
  final String? summary;
  final String? eventBrief;
  final List<String> discussionPoints;
  final List<String> topicAngles;
  final String? sourceName;
  final bool acknowledged;

  ProductHomeSuggestion copyWith({bool? acknowledged}) => ProductHomeSuggestion(
    id: id,
    title: title,
    summary: summary,
    eventBrief: eventBrief,
    discussionPoints: discussionPoints,
    topicAngles: topicAngles,
    sourceName: sourceName,
    acknowledged: acknowledged ?? this.acknowledged,
  );
}

final class ProductHome {
  ProductHome({
    required this.action,
    required this.suggestion,
    required this.runningTaskCount,
    required this.recordingCount,
    required this.depositedRecordingCount,
    required this.availableGenerationCredits,
    required this.redDotCount,
    required this.serverTime,
  });

  final ProductHomeAction action;
  final ProductHomeSuggestion? suggestion;
  final int runningTaskCount;
  final int recordingCount;
  final int depositedRecordingCount;
  final num? availableGenerationCredits;
  final int redDotCount;
  final DateTime serverTime;

  bool get hasContent =>
      suggestion != null ||
      runningTaskCount > 0 ||
      recordingCount > 0 ||
      redDotCount > 0;

  ProductHome acknowledgeSuggestion(String suggestionId) => ProductHome(
    action: action,
    suggestion: suggestion?.id == suggestionId
        ? suggestion!.copyWith(acknowledged: true)
        : suggestion,
    runningTaskCount: runningTaskCount,
    recordingCount: recordingCount,
    depositedRecordingCount: depositedRecordingCount,
    availableGenerationCredits: availableGenerationCredits,
    redDotCount: 0,
    serverTime: serverTime,
  );
}

abstract interface class ProductHomeRepository {
  Future<ProductResult<ProductHome>> load(String workspaceId);

  Future<ProductResult<void>> markSuggestionViewed({
    required String workspaceId,
    required String suggestionId,
    required String idempotencyKey,
  });
}

final class UnavailableProductHomeRepository implements ProductHomeRepository {
  const UnavailableProductHomeRepository();

  @override
  Future<ProductResult<ProductHome>> load(String workspaceId) async =>
      const ProductResult<ProductHome>.failure(
        code: 'PRODUCT_HOME_UNAVAILABLE',
        message: '首页服务尚未配置',
      );

  @override
  Future<ProductResult<void>> markSuggestionViewed({
    required String workspaceId,
    required String suggestionId,
    required String idempotencyKey,
  }) async => const ProductResult<void>.failure(
    code: 'PRODUCT_HOME_UNAVAILABLE',
    message: '首页服务尚未配置',
  );
}
