import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens in 1D and keeps the selected graph across mode changes', (
    tester,
  ) async {
    final library = await _launchFeed(tester);
    final primaryNote = library.myCreatedNotes.first;
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('feed-notes-center')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-home-mode-1d')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    await _openGraph3d(tester);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    expect(find.byType(V3GraphSearchIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-right-edge-workbench-gesture')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);

    await tester.dragFrom(const Offset(196, 360), const Offset(-160, 0));
    await _settle(tester);
    expect(find.text('思想图谱'), findsOneWidget);

    await _openWorkbenchFromFeed(tester);
    await _settle(tester);
    expect(find.text('创作空间'), findsOneWidget);
    expect(find.text('今日推送'), findsOneWidget);
    final workbenchScroll = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    expect(workbenchScroll, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('workbench-free-creation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-workbench-dock-frame')),
      findsNothing,
    );
    for (final id in const ['persona', 'lead', 'influence', 'video']) {
      expect(
        find.byKey(ValueKey<String>('workbench-inline-tool-$id')),
        findsOneWidget,
      );
    }
    expect(find.byKey(ValueKey(primaryNote.id)), findsNothing);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    expect(find.byType(V3GraphSearchIcon), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('聊一聊'), findsNothing);

    await tester.drag(workbenchScroll, const Offset(0, -260));
    await _settle(tester);
    expect(find.text('创作空间'), findsOneWidget);

    final contentPager = find.byKey(
      const ValueKey<String>('home-content-mode-pager'),
    );
    await tester.drag(contentPager, const Offset(280, 0));
    await _settle(tester);
    expect(find.text('思想图谱'), findsOneWidget);
    expect(find.byKey(ValueKey(primaryNote.id)), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    expect(find.byType(V3GraphSearchIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-right-edge-workbench-gesture')),
      findsOneWidget,
    );
  });

  testWidgets('remote graph search selects a note without navigating', (
    tester,
  ) async {
    final library = await _launchFeed(tester);
    final expected = library.myCreatedNotes.first;
    await _openGraph3d(tester);
    expect(find.byKey(const ValueKey('feed-graph-search-input')), findsNothing);
    await tester.tap(find.byType(V3GraphSearchIcon).hitTestable());
    await _settle(tester);
    final search = find.byKey(const ValueKey('feed-graph-search-input'));
    expect(search, findsOneWidget);
    await tester.enterText(search, expected.title);
    await tester.pump();
    final result = find.descendant(
      of: find.byKey(const ValueKey('feed-graph-search-results')),
      matching: find.text(expected.title),
    );
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pump(const Duration(milliseconds: 120));
    expect(search, findsNothing);
    expect(find.text('思想图谱'), findsOneWidget);
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('原始'), findsNothing);
  });

  testWidgets('secondary pages return to their immediate visible parent', (
    tester,
  ) async {
    await _launchFeed(tester);
    await _openWorkbenchFromFeed(tester);
    await _settle(tester);
    final workbenchScroll = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    expect(find.text('创作空间'), findsOneWidget);
    expect(workbenchScroll, findsOneWidget);

    final freeCreation = find.byKey(
      const ValueKey<String>('workbench-free-creation'),
    );
    await tester.ensureVisible(freeCreation);
    await tester.tap(freeCreation);
    await _settle(tester);
    expect(find.byKey(const ValueKey('canvas-title-field')), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回'));
    await _settle(tester);
    expect(find.text('创作空间'), findsOneWidget);

    final visualDesign = find.byKey(
      const ValueKey<String>('workbench-inline-tool-influence'),
    );
    await tester.ensureVisible(visualDesign);
    await tester.tap(visualDesign);
    await _settle(tester);
    expect(find.text('已启用视觉设计能力。'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回'));
    await _settle(tester);
    expect(find.text('创作空间'), findsOneWidget);

    final persona = find.byKey(
      const ValueKey<String>('workbench-inline-tool-persona'),
    );
    await tester.ensureVisible(persona);
    await tester.tap(persona);
    await _settle(tester);
    expect(
      find.byKey(
        const ValueKey<String>('chat-local-agent-opening-renshe_content'),
      ),
      findsOneWidget,
    );
    expect(find.text('选择你的资产'), findsNothing);
    await tester.tap(find.bySemanticsLabel('返回').hitTestable().first);
    await _settle(tester);
    expect(find.text('创作空间'), findsOneWidget);
  });

  testWidgets('aggregation fails closed without an authenticated workspace', (
    tester,
  ) async {
    await _launchFeed(tester);
    await _openGraph3d(tester);
    final feedTitle = find.text('思想图谱').hitTestable();
    final container = ProviderScope.containerOf(tester.element(feedTitle));
    final aggregation = container.read(feedAggregationControllerProvider);
    await tester.tap(
      find.byKey(const ValueKey('feed-graph-aggregate')).hitTestable(),
    );
    await tester.pump();
    expect(aggregation.usesProductionRun, isTrue);
    expect(aggregation.status, FeedAggregationStatus.failed);
    expect(aggregation.errorCode, 'WORKSPACE_NOT_READY');
    expect(find.text('工作区准备完成后即可开始聚合'), findsOneWidget);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
    expect(find.byKey(const ValueKey('aggregation-progress')), findsNothing);
  });

  testWidgets('opens the canonical creation sheet', (tester) async {
    await _launchFeed(tester);
    await tester.tap(find.bySemanticsLabel('新建').hitTestable());
    await _settle(tester);
    for (final label in const ['独白', '文字']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in const ['外录', '内录', '链接', '导入']) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('shows the remote profile menu without retired entries', (
    tester,
  ) async {
    await _launchFeed(tester);
    await _openProfile(tester);
    expect(
      find.byKey(const ValueKey('profile-recording-card-control-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-recording-card-menu-entry')),
      findsNothing,
    );
    expect(find.text('录音卡设备管理'), findsNothing);
    for (final label in const ['数字孪生', '外部世界', '我的资产', '花火商学院', '设置']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('会员与额度'), findsNothing);
    expect(find.text('帮助与反馈'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-recording-card-voiceprint')),
      findsNothing,
    );
    for (final label in const [
      '社媒定位',
      '查看报告',
      '账号与安全',
      '日历',
      '沉淀',
      '声纹识别',
      '花火 Spark',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.text('自媒体日报'), findsNothing);
    expect(find.text('深度洞察报告'), findsNothing);
    expect(find.text('本地录音库'), findsNothing);
    expect(find.text('本地存储'), findsNothing);
  });

  testWidgets('all visible profile destinations return to the side panel', (
    tester,
  ) async {
    await _launchFeed(tester);
    await _openProfile(tester);
    final branches = <(String, Finder)>[
      ('数字孪生', find.byKey(const ValueKey('digital-twin-compact-header'))),
      ('外部世界', find.byKey(const ValueKey('knowledge-tab-subscribed'))),
      ('我的资产', find.byKey(const ValueKey('my-assets-page-view'))),
      ('花火商学院', find.text('功能尚未开发')),
      ('设置', find.byKey(const ValueKey('settings-account-group'))),
    ];
    for (final branch in branches) {
      await tester.tap(find.text(branch.$1).hitTestable());
      await _settle(tester);
      expect(branch.$2, findsWidgets, reason: branch.$1);
      await tester.tap(find.bySemanticsLabel('返回').hitTestable().first);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('v3-profile-side-panel')),
        findsOneWidget,
        reason: branch.$1,
      );
    }
  });
}

Future<KnowledgeLibraryController> _launchFeed(WidgetTester tester) async {
  await app.main();
  await tester.pump();
  final feedTitle = find.text('思想图谱');
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 40; attempt++) {
    if (feedTitle.hitTestable().evaluate().isNotEmpty) break;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(feedTitle.hitTestable(), findsOneWidget);
  final container = ProviderScope.containerOf(tester.element(feedTitle.first));
  final library = container.read(knowledgeLibraryControllerProvider);
  await library.initialize();
  for (var index = library.myCreatedNotes.length; index < 4; index++) {
    library.createManualNote(
      title: '设备集成笔记 ${index + 1}',
      rawBody: '用于验证 Mobile V5 图谱、搜索和页面切换的本地内容 ${index + 1}。',
      createdAt: DateTime.utc(2026, 8, 24, 8, index),
    );
  }
  for (final note in library.myCreatedNotes.take(4)) {
    library.depositContent(note.id);
  }
  await tester.pump();
  return library;
}

Future<void> _openProfile(WidgetTester tester) async {
  final profileMenu = find.byKey(const ValueKey<String>('home-profile-menu'));
  await tester.tap(profileMenu.hitTestable());
  await _settle(tester);
  final panel = find.byKey(const ValueKey<String>('v3-profile-side-panel'));
  expect(panel, findsOneWidget);
  expect(tester.getRect(panel).left, 0);
}

Future<void> _openGraph3d(WidgetTester tester) async {
  final mode = find.byKey(const ValueKey<String>('feed-home-mode-3d'));
  expect(mode, findsOneWidget);
  await tester.tap(mode.hitTestable());
  await _settle(tester);
  expect(
    find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    findsOneWidget,
  );
}

Future<void> _openWorkbenchFromFeed(WidgetTester tester) async {
  final edgeGesture = find.byKey(
    const ValueKey<String>('feed-right-edge-workbench-gesture'),
  );
  expect(edgeGesture, findsOneWidget);
  final edgeRect = tester.getRect(edgeGesture);
  await tester.dragFrom(edgeRect.center, const Offset(-72, 0));
}

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 450));
