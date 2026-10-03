import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_item_detail_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  for (final fixture in _fixtures) {
    testWidgets('M02 ${fixture.name} uses the production detail state', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final note = _noteFor(fixture);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final tracker = _DerivedFixtureTracker(
        outlinePending:
            fixture.stage == V3ContentStage.summary &&
            (fixture.loading || fixture.failed),
        sproutPending:
            fixture.stage == V3ContentStage.sprout &&
            (fixture.loading || fixture.failed),
      );
      final controller = FeedItemDetailController.withDependencies(
        itemId: note.id,
        library: library,
        runTracker: tracker,
      );
      controller.refreshFromTaskTracker();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            resolvedDeviceIdProvider.overrideWithValue('m02-golden-device'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedItemDetailControllerProvider.overrideWith(
              (ref, itemId) => controller,
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(402, 874),
                padding: EdgeInsets.only(top: 54, bottom: 24),
                viewPadding: EdgeInsets.only(top: 54, bottom: 24),
              ),
              child: V3FeedItemDetailPage(
                itemId: note.id,
                initialStage: fixture.stage,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      if (fixture.failed) {
        tracker
          ..outlinePending = false
          ..sproutPending = false
          ..lastDerivedCompletion = DerivedPartRunCompletion(
            fileAgentRunId: 'failed-${fixture.stage.name}',
            localNoteId: note.id,
            remoteNoteId: note.remoteNoteId!,
            targetPart: fixture.stage == V3ContentStage.summary
                ? NoteFileAgentPart.outline
                : NoteFileAgentPart.germination,
            status: 'failed',
            failureCode: fixture.stage == V3ContentStage.summary
                ? 'OUTLINE_RUN_POLL_FAILED'
                : 'FAYA_RUN_POLL_FAILED',
          );
        controller.refreshFromTaskTracker();
        await tester.pump();
      }
      if (fixture.loading) {
        await tester.pump(const Duration(milliseconds: 240));
      }

      expect(
        find.byKey(const ValueKey<String>('note-detail-surface')),
        findsOneWidget,
      );
      expect(find.text(fixture.stage.label), findsOneWidget);
      await expectLater(
        find.byKey(const ValueKey<String>('note-detail-surface')),
        matchesGoldenFile('goldens/${fixture.golden}'),
      );
    });
  }
}

enum _DerivedFixturePhase { empty, loading, failed, succeeded }

final class _DetailFixture {
  const _DetailFixture(this.name, this.stage, this.phase, this.golden);

  final String name;
  final V3ContentStage stage;
  final _DerivedFixturePhase phase;
  final String golden;

  bool get loading => phase == _DerivedFixturePhase.loading;
  bool get failed => phase == _DerivedFixturePhase.failed;
}

const _fixtures = <_DetailFixture>[
  _DetailFixture(
    'outline empty',
    V3ContentStage.summary,
    _DerivedFixturePhase.empty,
    'note_detail_outline_empty.png',
  ),
  _DetailFixture(
    'outline loading',
    V3ContentStage.summary,
    _DerivedFixturePhase.loading,
    'note_detail_outline_loading.png',
  ),
  _DetailFixture(
    'outline error',
    V3ContentStage.summary,
    _DerivedFixturePhase.failed,
    'note_detail_outline_error.png',
  ),
  _DetailFixture(
    'outline success',
    V3ContentStage.summary,
    _DerivedFixturePhase.succeeded,
    'note_detail_outline_success.png',
  ),
  _DetailFixture(
    'ignite empty',
    V3ContentStage.sprout,
    _DerivedFixturePhase.empty,
    'note_detail_ignite_empty.png',
  ),
  _DetailFixture(
    'ignite loading',
    V3ContentStage.sprout,
    _DerivedFixturePhase.loading,
    'note_detail_ignite_loading.png',
  ),
  _DetailFixture(
    'ignite error',
    V3ContentStage.sprout,
    _DerivedFixturePhase.failed,
    'note_detail_ignite_error.png',
  ),
  _DetailFixture(
    'ignite success',
    V3ContentStage.sprout,
    _DerivedFixturePhase.succeeded,
    'note_detail_ignite_success.png',
  ),
];

V3FeedItem _noteFor(_DetailFixture fixture) {
  final success = fixture.phase == _DerivedFixturePhase.succeeded;
  const title = '内容不是堆数量，而是形成判断';
  const outline = '''## 核心判断

内容的价值不在数量，而在能否形成稳定、可调用的判断。

## 判断路径

### 01 整理

先保留原始上下文，去掉重复与噪声。

### 02 比较

把相近观点放在一起，看见差异与联系。

### 03 提炼

将信息收束为能支持选择和行动的结论。''';
  const ignite = '''## 值得继续追问

当记录不再追求更多，而是追求更准，我们该如何重新设计日常的信息输入？

## 可以继续创作的方向

### 01 从收藏到判断

把“记下来”变成“想清楚”的过程。

### 02 建立筛选标准

用价值、相关性与行动性判断什么值得留下。

### 03 让笔记进入下一步

让每条记录落到一个问题、决定或行动。''';
  return V3FeedItem(
    id: 'm02-${fixture.stage.name}-${fixture.phase.name}',
    title: title,
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 8, 19),
    rawBody:
        '内容不是靠堆砌数量产生价值，而是通过整理、比较和提炼，形成自己的判断。\n\n'
        '这条笔记保留原始上下文，纲要和深度洞察会基于此内容继续生成。',
    summaryBody: fixture.stage == V3ContentStage.summary && success
        ? outline
        : null,
    sproutStatus: fixture.stage == V3ContentStage.sprout && success
        ? V3SproutTaskStatus.succeeded
        : V3SproutTaskStatus.notStarted,
    sproutReport: fixture.stage == V3ContentStage.sprout && success
        ? V3SproutReport(
            id: 'm02-sprout-report',
            noteId: 'm02-${fixture.stage.name}-${fixture.phase.name}',
            title: '深度洞察报告',
            markdown: ignite,
            generatedAt: DateTime(2026, 8, 19),
          )
        : null,
    remoteNoteId: 'remote-m02-note',
    noteRevisionId: 'note-revision-m02',
    rawPartRevisionId: 'raw-revision-m02',
    etag: '"m02"',
    contentCursor: 'm02-cursor',
    syncState: NoteSyncState.synced,
  );
}

final class _DerivedFixtureTracker implements DerivedPartRunTrackingPort {
  _DerivedFixtureTracker({
    required this.outlinePending,
    required this.sproutPending,
  });

  bool outlinePending;
  bool sproutPending;

  @override
  DerivedPartRunCompletion? lastDerivedCompletion;

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) =>
      isDerivedPartPending(localNoteId, targetPart) ? 'running' : null;

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) => const <AgentRunToolTrace>[];

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      switch (targetPart) {
        NoteFileAgentPart.outline => outlinePending,
        NoteFileAgentPart.germination => sproutPending,
        NoteFileAgentPart.raw => false,
      };

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {}
}
