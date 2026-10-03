import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/application/mobile_agent_capability_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

// resident-provider: Shares one account-scoped workbench generation repository identity across dependent controllers.
final workbenchGenerationRepositoryProvider =
    Provider<WorkbenchGenerationRepository>((ref) {
      return MobileAgentWorkbenchGenerationRepository(
        ref.watch(mobileAgentCapabilityControllerProvider.notifier),
      );
    });

@immutable
final class WorkbenchGenerationResult {
  const WorkbenchGenerationResult({
    required this.markdown,
    required this.generatedAt,
  });

  final String markdown;
  final DateTime generatedAt;
}

abstract interface class WorkbenchGenerationRepository {
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  });
}

final class WorkbenchGenerationException implements Exception {
  const WorkbenchGenerationException(
    this.code, {
    this.resultPending = false,
    this.terminalFailure = false,
  });

  final String code;
  final bool resultPending;
  final bool terminalFailure;
}

final class UnavailableWorkbenchGenerationRepository
    implements WorkbenchGenerationRepository {
  const UnavailableWorkbenchGenerationRepository();

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) async => throw StateError('WORKBENCH_GENERATION_BACKEND_UNAVAILABLE');
}

final class MobileAgentWorkbenchGenerationRepository
    implements WorkbenchGenerationRepository {
  const MobileAgentWorkbenchGenerationRepository(this._agent);

  final MobileAgentCapabilityController _agent;

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) async {
    if (notes.isEmpty) {
      throw const WorkbenchGenerationException('WORKBENCH_NOTES_REQUIRED');
    }
    final references = <MobileAgentInputReference>[];
    for (final note in notes) {
      final noteId = note.remoteNoteId?.trim();
      final partRevisionId = note.rawPartRevisionId?.trim();
      if (note.syncState != NoteSyncState.synced ||
          noteId == null ||
          noteId.isEmpty ||
          partRevisionId == null ||
          partRevisionId.isEmpty) {
        throw const WorkbenchGenerationException(
          'AGENT_HNOTE_EXACT_REVISION_REQUIRED',
        );
      }
      references.add(
        MobileAgentHNoteReference(
          noteId: noteId,
          part: 'raw',
          partRevisionId: partRevisionId,
        ),
      );
    }
    final featureId = switch (purpose) {
      WorkbenchPurpose.persona => 'workbench.persona',
      WorkbenchPurpose.lead => 'workbench.lead_content',
    };
    final visibleText = switch (purpose) {
      WorkbenchPurpose.persona => '根据我选择的已同步笔记生成人设内容草稿。',
      WorkbenchPurpose.lead => '根据我选择的已同步笔记生成获客内容草稿。',
    };
    final outcome = await _agent.execute(
      MobileAgentRunCommand(
        operationId: operationId,
        featureId: featureId,
        visibleText: visibleText,
        references: references,
      ),
      pollingPolicy: const MobileAgentRunPollingPolicy(),
    );
    final markdown = outcome.outputMarkdown?.trim();
    if (!outcome.succeeded || markdown == null || markdown.isEmpty) {
      throw WorkbenchGenerationException(
        outcome.errorCode ?? 'WORKBENCH_GENERATION_FAILED',
        resultPending:
            outcome.run?.isTerminal == false ||
            outcome.status == MobileAgentRunStatus.superseded,
        terminalFailure: outcome.run?.isTerminal == true,
      );
    }
    return WorkbenchGenerationResult(
      markdown: markdown,
      generatedAt: outcome.run!.updatedAt,
    );
  }
}

final class WorkbenchGenerationMockRepository
    implements WorkbenchGenerationRepository {
  const WorkbenchGenerationMockRepository({
    this.delay = const Duration(milliseconds: 1200),
    this.fail = false,
  });

  final Duration delay;
  final bool fail;

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('WORKBENCH_GENERATION_FAILED');
    if (notes.isEmpty) throw StateError('WORKBENCH_NOTES_REQUIRED');

    final titles = notes.map((note) => '《${note.title}》').join('、');
    final first = notes.first;
    final summary = (first.summaryBody ?? first.rawBody).trim();
    final excerpt = summary.length <= 86
        ? summary
        : '${summary.substring(0, 86)}...';
    final markdown = switch (purpose) {
      WorkbenchPurpose.persona =>
        '''# 用真实经历建立可信人设

## 内容目标

通过真实经历、明确判断和专业方法，让用户理解“你是谁、你相信什么、你能解决什么问题”。

## 推荐切入

从$titles中提取一个具体经历或观点，不直接自我介绍，而是通过故事和判断展示人物特征。

## 内容结构

开场冲突 → 真实经历 → 个人判断 → 可复用方法 → 结尾态度。

## 示例文案

从$first.title切入：$excerpt 这段材料真正能建立信任的地方，不是结论本身，而是你如何经历、判断并形成自己的方法。''',
      WorkbenchPurpose.lead =>
        '''# 用客户问题激发咨询意愿

## 内容目标

让潜在客户意识到问题、看到解决路径，并产生进一步咨询意愿。

## 推荐切入

从$titles中提取客户痛点、案例或热点连接点。

## 内容结构

常见问题 → 错误做法 → 解决方法 → 结果证据 → 咨询引导。

## 示例文案

围绕$first.title提出客户常见问题：$excerpt 与其继续用旧方法反复试错，不如先确认问题发生在哪一步，再选择可以验证结果的解决路径。''',
    };
    return WorkbenchGenerationResult(
      markdown: markdown,
      generatedAt: DateTime.now(),
    );
  }
}
