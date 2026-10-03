import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const _requestedFlow = String.fromEnvironment(
  'HUAHUO_V6_FLOW',
  defaultValue: 'all',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  _flowTest('persona', 'personal IP opens the direct renshe expert chat', (
    tester,
  ) async {
    await _launchWorkbench(tester);
    await _waitWithFrames(tester, const Duration(milliseconds: 600));
    await binding.takeScreenshot('v6_workbench');
    await tester.tap(
      find
          .byKey(const ValueKey<String>('workbench-inline-tool-persona'))
          .hitTestable(),
    );
    await _pumpRoute(tester);
    expect(
      find.byKey(
        const ValueKey<String>('chat-local-agent-opening-renshe_content'),
      ),
      findsOneWidget,
    );
    expect(find.text('选择你的资产'), findsNothing);
    expect(find.text('开始创作'), findsNothing);
    await binding.takeScreenshot('v6_persona_chat');
  });

  _flowTest('lead', 'lead marketing opens the direct huoke expert chat', (
    tester,
  ) async {
    await _launchWorkbench(tester);
    await tester.tap(
      find
          .byKey(const ValueKey<String>('workbench-inline-tool-lead'))
          .hitTestable(),
    );
    await _pumpRoute(tester);
    expect(
      find.byKey(
        const ValueKey<String>('chat-local-agent-opening-huoke_content'),
      ),
      findsOneWidget,
    );
    expect(find.text('选择你的资产'), findsNothing);
    expect(find.text('开始创作'), findsNothing);
  });

  _flowTest(
    'video',
    'installed video analysis opens without fabricating a report',
    (tester) async {
      await _launchWorkbench(tester);
      await tester.tap(
        find
            .byKey(const ValueKey<String>('workbench-inline-tool-video'))
            .hitTestable(),
      );
      await _pumpRoute(tester);
      expect(find.text('已启用视频分析能力。'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(find.text('视频分析报告'), findsNothing);
      await binding.takeScreenshot('v6_video_ready');
    },
  );

  _flowTest(
    'positioning',
    'missing report exposes initial positioning recovery',
    (tester) async {
      await _launchFeed(tester);
      await tester.tap(find.byKey(const ValueKey<String>('home-profile-menu')));
      await tester.pumpAndSettle();
      expect(find.text('深度定位'), findsOneWidget);
      await tester.tap(find.text('深度定位'));
      await _pumpRoute(tester);
      expect(find.text('深度定位'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('deep-positioning-initial-entry')),
        findsOneWidget,
      );
      expect(find.text('先完成卡片问卷，生成第一份定位报告，再通过深度对话持续校准方向。'), findsOneWidget);
    },
  );

  _flowTest('graph', 'interactive graph search opens note-context chat', (
    tester,
  ) async {
    final library = await _launchFeed(tester);
    final target = library.myCreatedNotes.first;
    await tester.tap(
      find.byKey(const ValueKey<String>('feed-home-mode-3d')).hitTestable(),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('思想图谱'), findsOneWidget);
    await _selectGraphNoteBySearch(tester, target.title);
    expect(find.byTooltip('关闭搜索'), findsNothing);
    await _waitWithFrames(tester, const Duration(milliseconds: 600));
    await binding.takeScreenshot('v6_feed_node_card');
    await tester.tap(find.text('聊一聊'));
    await _pumpRoute(tester);
    expect(find.text('已引用资产「${target.title}」'), findsOneWidget);
    await binding.takeScreenshot('v6_graph_chat');
  });
}

void _flowTest(String flow, String description, WidgetTesterCallback callback) {
  if (_requestedFlow == 'all' || _requestedFlow == flow) {
    testWidgets(description, callback);
  }
}

Future<void> _launchWorkbench(WidgetTester tester) async {
  await _launchFeed(tester);
  final edgeGesture = find.byKey(
    const ValueKey<String>('feed-right-edge-workbench-gesture'),
  );
  expect(edgeGesture, findsOneWidget);
  await tester.dragFrom(
    tester.getRect(edgeGesture).center,
    const Offset(-72, 0),
  );
  await tester.pump(const Duration(milliseconds: 450));
  expect(find.text('创作空间'), findsOneWidget);
  expect(find.text('大曝光'), findsNothing);
}

Future<KnowledgeLibraryController> _launchFeed(WidgetTester tester) async {
  await app.main();
  await tester.pump();
  final feedTitle = find.text('思想图谱');
  for (var attempt = 0; attempt < 40; attempt++) {
    if (feedTitle.hitTestable().evaluate().isNotEmpty) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  expect(feedTitle.hitTestable(), findsOneWidget);
  final container = ProviderScope.containerOf(tester.element(feedTitle.first));
  final library = container.read(knowledgeLibraryControllerProvider);
  await library.initialize();
  for (var index = library.myCreatedNotes.length; index < 4; index++) {
    library.createManualNote(
      title: '产品流笔记 ${index + 1}',
      rawBody: '用于验证产品流图谱搜索与上下文聊天 ${index + 1}。',
      createdAt: DateTime.utc(2026, 8, 24, 9, index),
    );
  }
  for (final note in library.myCreatedNotes.take(4)) {
    library.depositContent(note.id);
  }
  await tester.pump();
  return library;
}

Future<void> _selectGraphNoteBySearch(WidgetTester tester, String title) async {
  final searchButton = find.byKey(const ValueKey('feed-graph-search-open'));
  expect(searchButton, findsOneWidget);
  await tester.tap(searchButton);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.enterText(
    find.byKey(const ValueKey('feed-graph-search-input')),
    title,
  );
  await tester.pump(const Duration(milliseconds: 250));
  final resultTitle = find.descendant(
    of: find.byKey(const ValueKey('feed-graph-search-results')),
    matching: find.text(title),
  );
  expect(resultTitle, findsOneWidget);
  final resultTile = find.ancestor(
    of: resultTitle,
    matching: find.byType(InkWell),
  );
  expect(resultTile, findsOneWidget);
  tester.widget<InkWell>(resultTile).onTap!();
  await tester.pump(const Duration(milliseconds: 450));
  expect(find.text('查看'), findsOneWidget);
  expect(find.text('聊一聊'), findsOneWidget);
}

Future<void> _pumpRoute(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 450));

Future<void> _waitWithFrames(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    await Future<void>.delayed(step);
    await tester.pump();
    elapsed += step;
  }
}
