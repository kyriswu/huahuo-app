import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

// resident-provider: Shares one account-scoped feed aggregation repository identity across dependent controllers.
final feedAggregationRepositoryProvider = Provider<FeedAggregationRepository>((
  ref,
) {
  return const UnavailableFeedAggregationRepository();
});

// resident-provider: Shares one topic collision run port dependency for the full account session.
final topicCollisionRunPortProvider = Provider<TopicCollisionRunPort>((ref) {
  return const UnavailableTopicCollisionRunPort();
});

abstract interface class TopicCollisionRunPort {
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  });

  Future<ApiResult<TopicCollisionRun>> get(String workspaceId, String runId);
}

final class RemoteTopicCollisionRunPort implements TopicCollisionRunPort {
  const RemoteTopicCollisionRunPort(this._client);

  final TopicCollisionClient _client;

  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) => _client.submit(
    workspaceId,
    noteIds: noteIds,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<ApiResult<TopicCollisionRun>> get(String workspaceId, String runId) =>
      _client.get(workspaceId, runId);
}

final class UnavailableTopicCollisionRunPort implements TopicCollisionRunPort {
  const UnavailableTopicCollisionRunPort();

  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) async => ApiResult<TopicCollisionRun>.failure(
    error: const AppFailure(
      code: 'TOPIC_COLLISION_SERVICE_UNAVAILABLE',
      category: AppFailureCategory.compatibility,
      message: 'Topic collision service is unavailable',
      userMessageKey: 'error.topicCollision.unavailable',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<TopicCollisionRun>> get(
    String workspaceId,
    String runId,
  ) async => ApiResult<TopicCollisionRun>.failure(
    error: const AppFailure(
      code: 'TOPIC_COLLISION_SERVICE_UNAVAILABLE',
      category: AppFailureCategory.compatibility,
      message: 'Topic collision service is unavailable',
      userMessageKey: 'error.topicCollision.unavailable',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

// resident-provider: Shares one aggregation agent port dependency for the full account session.
final aggregationAgentPortProvider = Provider<AggregationAgentPort>((ref) {
  return const UnavailableAggregationAgentPort();
});

abstract interface class FeedAggregationRepository {
  Future<V3FeedItem> aggregate({
    required List<V3FeedItem> normalNotes,
    required V3FeedItem hotspotNote,
  });
}

abstract interface class AggregationAgentPort {
  Future<AggregationAgentSession> prepare(
    AggregationAgentLaunchRequest request,
  );

  Future<String> reply({
    required AggregationAgentSession session,
    required String message,
  });
}

final class UnavailableFeedAggregationRepository
    implements FeedAggregationRepository {
  const UnavailableFeedAggregationRepository();

  @override
  Future<V3FeedItem> aggregate({
    required List<V3FeedItem> normalNotes,
    required V3FeedItem hotspotNote,
  }) async => throw StateError('FEED_AGGREGATION_BACKEND_UNAVAILABLE');
}

final class UnavailableAggregationAgentPort implements AggregationAgentPort {
  const UnavailableAggregationAgentPort();

  @override
  Future<AggregationAgentSession> prepare(
    AggregationAgentLaunchRequest request,
  ) async => throw StateError('AGGREGATION_AGENT_BACKEND_UNAVAILABLE');

  @override
  Future<String> reply({
    required AggregationAgentSession session,
    required String message,
  }) async => throw StateError('AGGREGATION_AGENT_BACKEND_UNAVAILABLE');
}

final class SessionAggregationAgentMockPort implements AggregationAgentPort {
  const SessionAggregationAgentMockPort({
    this.delay = const Duration(milliseconds: 320),
    this.fail = false,
  });

  final Duration delay;
  final bool fail;

  @override
  Future<AggregationAgentSession> prepare(
    AggregationAgentLaunchRequest request,
  ) async {
    if (!request.isValid) {
      throw StateError('AGGREGATION_AGENT_CONTEXT_INVALID');
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('AGGREGATION_AGENT_PREPARE_FAILED');
    return AggregationAgentSession(
      id: 'aggregation-agent-${DateTime.now().microsecondsSinceEpoch}',
      kind: request.kind,
      materialIds: List<String>.unmodifiable(<String>[
        ...request.noteIds,
        request.hotspotId,
      ]),
      openingMessage: switch (request.kind) {
        AggregationAgentKind.persona => '我们先提炼最能形成个人识别度的观点。',
        AggregationAgentKind.lead => '我们从受众需求和行动路径开始梳理。',
        AggregationAgentKind.visual => '我们先确定内容的视觉主线和画面重点。',
      },
    );
  }

  @override
  Future<String> reply({
    required AggregationAgentSession session,
    required String message,
  }) async {
    final prompt = message.trim();
    if (prompt.isEmpty) throw StateError('AGGREGATION_AGENT_MESSAGE_EMPTY');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('AGGREGATION_AGENT_REPLY_FAILED');
    return switch (session.kind) {
      AggregationAgentKind.persona =>
        '可以把“$prompt”收束为一个稳定的人设承诺：明确你持续解决的问题、坚持的方法和可验证的经历。',
      AggregationAgentKind.lead =>
        '围绕“$prompt”，建议先指出具体困境，再给出可执行的一步，最后用低门槛问题承接咨询。',
      AggregationAgentKind.visual =>
        '围绕“$prompt”，可以采用一个主视觉、两层信息层级和统一色彩线索，避免画面同时表达过多重点。',
    };
  }
}

final class FeedAggregationMockRepository implements FeedAggregationRepository {
  const FeedAggregationMockRepository({
    this.delay = const Duration(seconds: 6),
    this.fail = false,
  });

  final Duration delay;
  final bool fail;

  @override
  Future<V3FeedItem> aggregate({
    required List<V3FeedItem> normalNotes,
    required V3FeedItem hotspotNote,
  }) async {
    if (normalNotes.length != 4 || !hotspotNote.isHotspot) {
      throw StateError('FEED_AGGREGATION_INPUT_INVALID');
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('FEED_AGGREGATION_FAILED');

    final now = DateTime.now();
    final titles = normalNotes.map((note) => '《${note.title}》').join('、');
    return V3FeedItem(
      id: 'aggregation-${now.microsecondsSinceEpoch}',
      title: '内容聚合 · ${hotspotNote.title}',
      source: V3MaterialSource.note,
      ownership: V3NoteOwnership.mine,
      createdAt: now,
      updatedAt: now,
      rawBody:
          '''# 结合热点

把《${hotspotNote.title}》与$titles中的核心观点连接，生成一段适合当前账号定位的内容方向。

# 排列组合

重新组合$titles中的观点、案例和方法，生成一段新的表达角度。

# 大师升级

用更高阶的结构和表达方式重新解释这些材料，生成一段更完整的内容建议。''',
      summaryBody: '已将《${hotspotNote.title}》与四条沉淀笔记组合为可继续编辑的内容草稿。',
      linkedMaterials: <V3LinkedMaterialRef>[
        for (final note in normalNotes)
          V3LinkedMaterialRef(
            id: note.id,
            source: note.source,
            title: note.title,
            summary: note.summaryBody,
          ),
        V3LinkedMaterialRef(
          id: hotspotNote.id,
          source: hotspotNote.source,
          title: hotspotNote.title,
          summary: hotspotNote.summaryBody,
        ),
      ],
      sproutStatus: V3SproutTaskStatus.notStarted,
      topics: <String>[
        hotspotNote.title,
        ...normalNotes.map((note) => note.title),
      ],
    );
  }
}
