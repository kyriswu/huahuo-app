import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the AI feed aggregation selection and generated note', (
    tester,
  ) async {
    final notes = <V3FeedItem>[
      for (var index = 0; index < 5; index++)
        V3FeedItem(
          id: 'v5-aggregation-note-$index',
          title: '聚合素材 ${index + 1}',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 24, 8, index),
          rawBody: '用于 Mobile V5 聚合截图验收的本地素材 ${index + 1}。',
        ),
      V3FeedItem(
        id: 'v5-aggregation-hotspot',
        title: 'AI 工具如何进入日常创作流程',
        source: V3MaterialSource.hotspot,
        ownership: V3NoteOwnership.hotspot,
        createdAt: DateTime.utc(2026, 8, 24, 9),
        rawBody: '今日热点素材',
      ),
    ];
    final library = KnowledgeLibraryController(
      initialNotes: notes,
      includeDemoFixtures: false,
    );
    for (final note in notes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final profileHub = ProfileHubController(
      referenceDay: DateTime.utc(2026, 8, 24),
    );
    final aggregation = FeedAggregationController(
      library: library,
      profileHub: profileHub,
      repository: const FeedAggregationMockRepository(
        delay: Duration(seconds: 6),
      ),
      foregroundDuration: const Duration(milliseconds: 2400),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          profileHubControllerProvider.overrideWith((ref) => profileHub),
          feedAggregationControllerProvider.overrideWith((ref) => aggregation),
        ],
        child: const MaterialApp(home: V3AppShell(initialFeedNotes: true)),
      ),
    );
    await tester.pump();
    await _waitWithFrames(tester, const Duration(milliseconds: 400));

    expect(find.text('思想图谱'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-notes-random-aggregation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-notes-center')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    final idle = await binding.takeScreenshot('v5_feed_1d_idle');
    expect(idle, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('feed-home-mode-3d')).hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 500));

    final graphViewport = find.byKey(
      const ValueKey('feed-graph-interactive-viewer'),
    );
    expect(graphViewport, findsOneWidget);
    expect(find.bySemanticsLabel('开始聚合'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('feed-graph-aggregate')));
    await tester.pump();
    expect(find.byKey(const ValueKey('aggregation-selection')), findsOneWidget);
    expect(find.text('已随机选中 4 篇笔记'), findsOneWidget);
    expect(find.text('将使用以下内容碰撞出一个新的观点与笔记'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('aggregation-sheet-reshuffle')),
      findsOneWidget,
    );
    expect(find.text('换一批'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.text('开始聚合'), findsOneWidget);
    for (final number in const ['1', '2', '3', '4']) {
      expect(
        find.descendant(of: graphViewport, matching: find.text(number)),
        findsNothing,
      );
    }
    await _waitWithFrames(tester, const Duration(milliseconds: 600));
    final selection = await binding.takeScreenshot(
      'v6_feed_aggregation_confirmation',
    );
    expect(selection, isNotEmpty);

    await tester.tap(find.text('开始聚合'));
    await _waitWithFrames(tester, const Duration(milliseconds: 900));
    expect(find.text('观点聚合中...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('aggregation-v5-processing')),
      findsOneWidget,
    );
    final progress = await binding.takeScreenshot(
      'v6_feed_aggregation_progress',
    );
    expect(progress, isNotEmpty);

    await _waitWithFrames(tester, const Duration(milliseconds: 1800));
    expect(
      find.byKey(const ValueKey('aggregation-v5-processing')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('aggregation-返回')).hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('feed-floating-hub')));
    await _waitWithFrames(tester, const Duration(milliseconds: 400));
    expect(find.text('聚合内容生成中'), findsWidgets);
    expect(find.text('一键清除'), findsOneWidget);
    expect(find.text('调整材料'), findsNothing);
    final pending = await binding.takeScreenshot(
      'v6_feed_aggregation_background_pending',
    );
    expect(pending, isNotEmpty);
  });
}

Future<void> _waitWithFrames(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    await Future<void>.delayed(step);
    await tester.pump();
    elapsed += step;
  }
}
