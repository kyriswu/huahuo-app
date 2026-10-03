import 'dart:math';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_topics_port.dart';

export '../domain/desktop_topics_port.dart' show UnavailableDesktopTopicsPort;

final class RemoteDesktopTopicsPort implements DesktopTopicsPort {
  RemoteDesktopTopicsPort(ApiClient client)
    : _dailyTopics = DailyTopicRecommendationClient(client),
      _collisions = TopicCollisionClient(client),
      _workspace = WorkspaceContentClient(client);

  final DailyTopicRecommendationClient _dailyTopics;
  final TopicCollisionClient _collisions;
  final WorkspaceContentClient _workspace;
  final Map<String, Future<List<String>>> _collisionSelections = {};

  @override
  Future<DesktopServiceResult<DailyTopicRecommendationPage>> listDailyTopics(
    String workspaceId,
  ) => _map(
    () => _dailyTopics.list(workspaceId),
    unavailableCode: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
    unavailableMessage: '每日推荐服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> getDailyTopic(
    String workspaceId,
    String recommendationId,
  ) => _map(
    () => _dailyTopics.get(workspaceId, recommendationId),
    unavailableCode: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
    unavailableMessage: '每日推荐服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> markDailyTopicRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _map(
    () => _dailyTopics.markRead(
      workspaceId,
      recommendationId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
    unavailableCode: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
    unavailableMessage: '每日推荐服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> dismissDailyTopic(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _map(
    () => _dailyTopics.dismiss(
      workspaceId,
      recommendationId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
    unavailableCode: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
    unavailableMessage: '每日推荐服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<DailyTopicUseResult>> useDailyTopic(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => _map(
    () => _dailyTopics.use(
      workspaceId,
      recommendationId,
      topicId: topicId,
      idempotencyKey: idempotencyKey,
    ),
    unavailableCode: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
    unavailableMessage: '每日推荐服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> createTopicCollision(
    String workspaceId, {
    required String idempotencyKey,
  }) => _map(
    () async {
      final selectionKey = '$workspaceId|$idempotencyKey';
      final selection = _collisionSelections.putIfAbsent(
        selectionKey,
        () => _selectCollisionNotes(workspaceId),
      );
      late final List<String> noteIds;
      try {
        noteIds = await selection.timeout(const Duration(seconds: 30));
      } catch (_) {
        _collisionSelections.remove(selectionKey);
        rethrow;
      }
      return _collisions.submit(
        workspaceId,
        noteIds: noteIds,
        idempotencyKey: idempotencyKey,
      );
    },
    unavailableCode: 'TOPIC_COLLISION_SERVICE_UNAVAILABLE',
    unavailableMessage: '聚合服务暂不可用',
  );

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> getTopicCollision(
    String workspaceId,
    String runId,
  ) => _map(
    () => _collisions.get(workspaceId, runId),
    unavailableCode: 'TOPIC_COLLISION_SERVICE_UNAVAILABLE',
    unavailableMessage: '聚合服务暂不可用',
  );

  Future<List<String>> _selectCollisionNotes(String workspaceId) async {
    final selected = <String>{};
    final seen = <String>{};
    final tokens = <String>{};
    String? pageToken;
    String? snapshotId;
    var inspected = 0;
    for (var pageIndex = 0; pageIndex < 5 && inspected < 40; pageIndex++) {
      final response = await _workspace.contentSnapshot(
        workspaceId,
        pageToken: pageToken,
      );
      final page = response.data;
      if (!response.ok || page == null) {
        throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
      }
      snapshotId ??= page.snapshotId;
      if (snapshotId != page.snapshotId) {
        throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
      }
      final candidates =
          page.objects
              .where((item) => item.ownerRef.kind == 'hnote' && !item.tombstone)
              .toList()
            ..shuffle(Random());
      for (final candidate in candidates) {
        if (!seen.add(candidate.ownerRef.id)) continue;
        if (++inspected > 40) break;
        final response = await _workspace.note(
          workspaceId,
          candidate.ownerRef.id,
          revisionId: candidate.revisionId,
        );
        final note = response.data;
        if (!response.ok || note == null) {
          throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
        }
        if (note.noteId != candidate.ownerRef.id ||
            (note.workspaceId != null && note.workspaceId != workspaceId)) {
          throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
        }
        if (note.state != 'live' ||
            note.sourceKind == null ||
            note.sourceKind == 'topic_collision') {
          continue;
        }
        final raw = await _workspace.notePart(
          workspaceId,
          note.noteId,
          'raw',
          partRevisionId: note.raw.partRevisionId,
        );
        if (!raw.ok || raw.data == null) {
          throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
        }
        if (raw.data!.noteId != note.noteId ||
            raw.data!.partRevisionId != note.raw.partRevisionId) {
          throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
        }
        if (raw.data!.markdown.trim().isEmpty) continue;
        selected.add(note.noteId);
        if (selected.length == 4) return List.unmodifiable(selected);
      }
      if (!page.hasMore) break;
      pageToken = page.nextPageToken;
      if (pageToken == null || !tokens.add(pageToken)) {
        throw StateError('AGGREGATION_SOURCE_SYNC_FAILED');
      }
    }
    throw StateError('NOTE_TOPIC_SOURCE_INSUFFICIENT');
  }
}

Future<DesktopServiceResult<T>> _map<T>(
  Future<ApiResult<T>> Function() request, {
  required String unavailableCode,
  required String unavailableMessage,
}) async {
  try {
    final result = await request();
    if (result.ok && result.data != null) {
      return DesktopServiceResult<T>.success(result.data!);
    }
    final code = result.error?.code ?? 'DESKTOP_TOPICS_REQUEST_FAILED';
    if (result.status == 404 ||
        code == 'NOT_FOUND' ||
        code == 'ROUTE_NOT_FOUND') {
      return DesktopServiceResult<T>.failure(
        code: unavailableCode,
        message: unavailableMessage,
        retryable: true,
      );
    }
    return DesktopServiceResult<T>.failure(
      code: code,
      message: result.error?.message ?? '服务请求失败',
      retryable: result.error?.isRetryable ?? false,
    );
  } on StateError catch (error) {
    return DesktopServiceResult<T>.failure(
      code:
          const {
            'NOTE_TOPIC_SOURCE_INSUFFICIENT',
            'AGGREGATION_SOURCE_SYNC_FAILED',
          }.contains(error.message)
          ? error.message.toString()
          : unavailableCode,
      message: error.message == 'NOTE_TOPIC_SOURCE_INSUFFICIENT'
          ? '至少需要四篇正文非空且不是聚合结果的云端笔记。'
          : '未能核对聚合来源，尚未提交任务，请稍后重试。',
    );
  } on ArgumentError {
    return DesktopServiceResult<T>.failure(
      code: 'DESKTOP_TOPICS_INPUT_INVALID',
      message: '每日推荐请求参数无效',
    );
  } on Object {
    return DesktopServiceResult<T>.failure(
      code: unavailableCode,
      message: unavailableMessage,
      retryable: true,
    );
  }
}
