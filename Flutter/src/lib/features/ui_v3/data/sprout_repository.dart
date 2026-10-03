import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import 'faya_germination_client.dart';
import '../domain/feed_item_models.dart';
import 'note_file_agent_client.dart';

// resident-provider: Shares one account-scoped sprout repository identity across dependent controllers.
final sproutRepositoryProvider = Provider<SproutRepository>((ref) {
  try {
    final apiClient = ref.watch(apiClientProvider);
    return FayaGerminationSproutRepository(
      FayaGerminationClient(
        apiClient: apiClient,
        workspaceId: () {
          final state = ref.read(sessionStoreProvider).state;
          return state.authState == SessionAuthState.authenticated
              ? state.workspace?.workspaceId
              : null;
        },
      ),
    );
  } on StateError catch (error) {
    if (error.message != 'DEVICE_IDENTITY_NOT_RESOLVED') rethrow;
    return const UnavailableSproutRepository();
  }
});

abstract interface class SproutRepository {
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  });
}

/// Optional production capability for admission without route-bound polling.
abstract interface class AcceptedSproutRunRepository {
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
  });
}

final class SproutGenerationException implements Exception {
  const SproutGenerationException(this.code);

  final String code;
}

final class UnavailableSproutRepository implements SproutRepository {
  const UnavailableSproutRepository();

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async => throw StateError('SPROUT_BACKEND_UNAVAILABLE');
}

final class FayaGerminationSproutRepository
    implements SproutRepository, AcceptedSproutRunRepository {
  const FayaGerminationSproutRepository(this._client);

  final FayaGerminationClient _client;

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    final noteId = note.remoteNoteId?.trim();
    final partRevisionId = note.rawPartRevisionId?.trim();
    if (note.syncState != NoteSyncState.synced ||
        noteId == null ||
        noteId.isEmpty ||
        partRevisionId == null ||
        partRevisionId.isEmpty) {
      throw const SproutGenerationException(
        'AGENT_HNOTE_EXACT_REVISION_REQUIRED',
      );
    }
    try {
      final result = await _client.generate(
        FayaGerminationRequest(
          noteId: noteId,
          expectedRawPartRevisionId: partRevisionId,
          operationId: operationId,
        ),
      );
      return V3SproutReport(
        id: 'sprout-${result.agentRunId}',
        noteId: note.id,
        title: '${note.title} · 深度洞察报告',
        markdown: result.markdown,
        generatedAt: DateTime.now(),
      );
    } on FayaGerminationException catch (error) {
      throw SproutGenerationException(error.code);
    }
  }

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
  }) async {
    final noteId = note.remoteNoteId?.trim();
    final partRevisionId = note.rawPartRevisionId?.trim();
    if (note.syncState != NoteSyncState.synced ||
        noteId == null ||
        noteId.isEmpty ||
        partRevisionId == null ||
        partRevisionId.isEmpty) {
      throw const SproutGenerationException(
        'AGENT_HNOTE_EXACT_REVISION_REQUIRED',
      );
    }
    try {
      final accepted = await _client.submit(
        FayaGerminationRequest(
          noteId: noteId,
          expectedRawPartRevisionId: partRevisionId,
          operationId: operationId,
        ),
      );
      return accepted.run;
    } on FayaGerminationException catch (error) {
      throw SproutGenerationException(error.code);
    }
  }
}

final class SproutMockRepository implements SproutRepository {
  const SproutMockRepository({
    this.delay = const Duration(milliseconds: 1200),
    this.fail = false,
  });

  final Duration delay;
  final bool fail;

  @override
  Future<V3SproutReport> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('SPROUT_GENERATION_FAILED');
    final now = DateTime.now();
    final source = (note.summaryBody ?? note.rawBody).trim();
    final excerpt = source.length <= 90
        ? source
        : '${source.substring(0, 90)}...';
    return V3SproutReport(
      id: 'sprout-${note.id}-${now.microsecondsSinceEpoch}',
      noteId: note.id,
      title: '${note.title} · 深度洞察报告',
      generatedAt: now,
      markdown:
          '''# 核心洞察

围绕《${note.title}》继续延伸：$excerpt 这条材料的价值在于把已有判断转化为可持续表达的内容主线。

# 与账号定位的连接

该材料可以连接用户的身份、目标受众和核心价值，用真实判断证明“你是谁、服务谁、能解决什么问题”。

# 可继续发展的内容方向

1. 用一个真实经历解释观点如何形成。
2. 用一个客户问题展示方法的适用场景。
3. 结合当前热点给出新的表达角度。

# 建议补充的材料

可以继续追加具体案例、结果数据、失败复盘或目标受众的真实提问。''',
    );
  }
}
