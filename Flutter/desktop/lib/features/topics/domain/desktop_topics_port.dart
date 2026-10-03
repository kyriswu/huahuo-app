import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';

abstract interface class DesktopTopicsPort {
  Future<DesktopServiceResult<DailyTopicRecommendationPage>> listDailyTopics(
    String workspaceId,
  );

  Future<DesktopServiceResult<DailyTopicRecommendation>> getDailyTopic(
    String workspaceId,
    String recommendationId,
  );

  Future<DesktopServiceResult<DailyTopicRecommendation>> markDailyTopicRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<DailyTopicRecommendation>> dismissDailyTopic(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<DailyTopicUseResult>> useDailyTopic(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<TopicCollisionRun>> createTopicCollision(
    String workspaceId, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<TopicCollisionRun>> getTopicCollision(
    String workspaceId,
    String runId,
  );
}

final class UnavailableDesktopTopicsPort implements DesktopTopicsPort {
  const UnavailableDesktopTopicsPort();

  DesktopServiceResult<T> _dailyUnavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
        message: '每日推荐服务暂不可用',
      );

  DesktopServiceResult<T> _collisionUnavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'TOPIC_COLLISION_SERVICE_UNAVAILABLE',
        message: '聚合服务暂不可用',
      );

  @override
  Future<DesktopServiceResult<DailyTopicRecommendationPage>> listDailyTopics(
    String workspaceId,
  ) async => _dailyUnavailable<DailyTopicRecommendationPage>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> getDailyTopic(
    String workspaceId,
    String recommendationId,
  ) async => _dailyUnavailable<DailyTopicRecommendation>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> markDailyTopicRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _dailyUnavailable<DailyTopicRecommendation>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> dismissDailyTopic(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _dailyUnavailable<DailyTopicRecommendation>();

  @override
  Future<DesktopServiceResult<DailyTopicUseResult>> useDailyTopic(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) async => _dailyUnavailable<DailyTopicUseResult>();

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> createTopicCollision(
    String workspaceId, {
    required String idempotencyKey,
  }) async => _collisionUnavailable<TopicCollisionRun>();

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> getTopicCollision(
    String workspaceId,
    String runId,
  ) async => _collisionUnavailable<TopicCollisionRun>();
}

final class DesktopTopicsCacheSnapshot {
  const DesktopTopicsCacheSnapshot({
    this.dailyRecommendation,
    this.dailyExpiresAt,
    this.dailyTopicContextsByThread = const <String, String>{},
    this.topicCollisionRun,
    this.topicCollisionCreatedAt,
  });

  final DailyTopicRecommendation? dailyRecommendation;
  final DateTime? dailyExpiresAt;
  final Map<String, String> dailyTopicContextsByThread;
  final TopicCollisionRun? topicCollisionRun;
  final DateTime? topicCollisionCreatedAt;

  String? get topicCollisionRunId => topicCollisionRun?.topicCollisionRunId;
}

abstract interface class DesktopTopicsCache {
  Future<DesktopTopicsCacheSnapshot> load({
    required String userId,
    required String workspaceId,
  });

  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopTopicsCacheSnapshot snapshot,
  });

  Future<void> clear({required String userId, required String workspaceId});
}

final class UnavailableDesktopTopicsCache implements DesktopTopicsCache {
  const UnavailableDesktopTopicsCache();

  @override
  Future<void> clear({required String userId, required String workspaceId}) =>
      Future<void>.value();

  @override
  Future<DesktopTopicsCacheSnapshot> load({
    required String userId,
    required String workspaceId,
  }) => Future<DesktopTopicsCacheSnapshot>.value(
    const DesktopTopicsCacheSnapshot(),
  );

  @override
  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopTopicsCacheSnapshot snapshot,
  }) => Future<void>.value();
}
