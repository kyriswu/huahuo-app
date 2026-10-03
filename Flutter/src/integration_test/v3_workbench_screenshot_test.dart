import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart'
    show dailyTopicControllerProvider;
import 'package:huahuoai_app/app/navigation/app_router.dart'
    show appRouterProvider;
import 'package:huahuoai_app/features/ui_v3/domain/canvas_image_embed_data.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _workbenchScreenshotName = '10_workbench_liquid_glass_iphone15pro_actual';
const _feedScreenshotName = 'v5_ai_feed_remote_glass_actual';
const _graphOverviewScreenshotName = 'v8_graph_morandi_50_overview_actual';
const _graphMiddleScreenshotName = 'v8_graph_morandi_lod_middle_actual';
const _graphFocusScreenshotName = 'v8_graph_morandi_local_focus_actual';
const _chatHeaderScreenshotName = 'v18_chat_lucide_header_actions_actual';
const _canvasScreenshotName = 'v15_creation_canvas_wysiwyg_default_actual';
const _canvasRichTextScreenshotName = 'v15_creation_canvas_rich_text_actual';
const _canvasImageScreenshotName = 'v15_creation_canvas_image_resize_actual';
const _canvasNoteImportScreenshotName =
    'v15_creation_canvas_note_import_actual';
const _canvasChatScreenshotName = 'v15_creation_canvas_chat_actual';
const _profileScreenshotName = 'v16_profile_workspace_actual';
const _assetsScreenshotName = 'v16_my_assets_created_actual';
const _subscriptionsScreenshotName = 'v16_knowledge_subscriptions_actual';
const _squareScreenshotName = 'v16_knowledge_square_actual';
const _dailyTopicLiveSmokeEnabled = bool.fromEnvironment(
  'HUAHUO_DAILY_TOPIC_LIVE_SMOKE',
  defaultValue: false,
);
const _dailyTopicLiveBusinessDate = String.fromEnvironment(
  'HUAHUO_DAILY_TOPIC_BUSINESS_DATE',
  defaultValue: '2026-09-08',
);
const _dailyTopicLiveRecommendationId = String.fromEnvironment(
  'HUAHUO_DAILY_TOPIC_RECOMMENDATION_ID',
  defaultValue: '',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the graph-free full-screen workbench', (tester) async {
    expect(
      huahuoV3UiEnabled,
      isTrue,
      reason: 'Run with --dart-define=HUAHUO_V3_UI=true.',
    );

    await app.main();
    await tester.pump();
    await _waitForFeed(tester);
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('思想图谱'), findsOneWidget);
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    final graphNoteTargets = find.bySemanticsLabel(RegExp(r'^知识笔记：'));
    final feedScreenshot = await _capture(binding, _feedScreenshotName);
    expect(feedScreenshot, isNotEmpty);
    final overviewScreenshot = await _capture(
      binding,
      _graphOverviewScreenshotName,
    );
    expect(overviewScreenshot, isNotEmpty);

    await tester.tap(find.bySemanticsLabel('聊一聊').hitTestable().first);
    await _pumpAnimationFrames(tester, frames: 8);
    expect(find.byTooltip('会话列表'), findsOneWidget);
    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(find.text('内容由 AI 生成，仅供参考'), findsOneWidget);
    expect(await _capture(binding, _chatHeaderScreenshotName), isNotEmpty);
    await tester.tap(find.bySemanticsLabel('返回').hitTestable());
    await _pumpAnimationFrames(tester, frames: 8);
    expect(find.text('思想图谱'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('feed-home-mode-3d')).hitTestable(),
    );
    await _pumpAnimationFrames(tester, frames: 8);

    final viewerFinder = find.byKey(
      const ValueKey('feed-graph-interactive-viewer'),
    );
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    final viewportSize = tester.getSize(viewerFinder);
    final viewportCenter = Offset(
      viewportSize.width / 2,
      viewportSize.height / 2,
    );
    const middleScale = 1.25;
    final sceneCenter = viewportCenter + const Offset(240, 240);
    final middleTranslation = viewportCenter - sceneCenter * middleScale;
    viewer.transformationController?.value = Matrix4.identity()
      ..setEntry(0, 0, middleScale)
      ..setEntry(1, 1, middleScale)
      ..setEntry(0, 3, middleTranslation.dx)
      ..setEntry(1, 3, middleTranslation.dy);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final middleScreenshot = await _capture(
      binding,
      _graphMiddleScreenshotName,
    );
    expect(middleScreenshot, isNotEmpty);

    viewer.transformationController?.value = Matrix4.identity();
    await tester.pump(const Duration(milliseconds: 400));
    if (graphNoteTargets.hitTestable().evaluate().isNotEmpty) {
      await tester.tap(graphNoteTargets.hitTestable().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 420));
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_graphTitleTexts().evaluate().length, lessThanOrEqualTo(14));
      expect(find.text('查看'), findsOneWidget);
      expect(find.text('聊一聊'), findsOneWidget);
    }
    final focusScreenshot = await _capture(binding, _graphFocusScreenshotName);
    expect(focusScreenshot, isNotEmpty);

    viewer.transformationController?.value = Matrix4.identity();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(
      find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
    );
    await _pumpAnimationFrames(tester, frames: 6);
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );
    expect(await _capture(binding, _profileScreenshotName), isNotEmpty);

    await tester.tap(find.text('我的资产').hitTestable());
    await _pumpAnimationFrames(tester, frames: 8);
    expect(find.text('我的资产'), findsOneWidget);
    expect(await _capture(binding, _assetsScreenshotName), isNotEmpty);
    await tester.tap(find.byTooltip('返回').hitTestable().first);
    await _pumpAnimationFrames(tester, frames: 8);
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );

    await tester.tap(find.text('外部世界').hitTestable());
    await _pumpAnimationFrames(tester, frames: 8);
    expect(
      find.byKey(const ValueKey('knowledge-tab-subscribed')),
      findsOneWidget,
    );
    expect(await _capture(binding, _subscriptionsScreenshotName), isNotEmpty);
    await tester.tap(
      find.byKey(const ValueKey('knowledge-tab-square')).hitTestable(),
    );
    await _pumpAnimationFrames(tester, frames: 6);
    expect(await _capture(binding, _squareScreenshotName), isNotEmpty);
    await tester.tap(find.byTooltip('返回').hitTestable().first);
    await _pumpAnimationFrames(tester, frames: 8);
    final profilePanel = find.byKey(
      const ValueKey<String>('v3-profile-side-panel'),
    );
    expect(profilePanel, findsOneWidget);
    Navigator.of(tester.element(profilePanel), rootNavigator: true).pop();
    await _pumpAnimationFrames(tester, frames: 5);
    expect(find.text('思想图谱'), findsOneWidget);

    final edgeGesture = find.byKey(
      const ValueKey<String>('feed-right-edge-workbench-gesture'),
    );
    expect(edgeGesture, findsOneWidget);
    final edgeRect = tester.getRect(edgeGesture);
    await tester.dragFrom(edgeRect.center, const Offset(-72, 0));
    for (var frame = 0; frame < 9; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('创作空间'), findsOneWidget);
    expect(find.text('今日推送'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('workbench-free-creation')),
      findsOneWidget,
    );
    final workbenchScroll = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    expect(workbenchScroll, findsOneWidget);
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
    expect(find.bySemanticsLabel('知识笔记：AI 落地客户访谈'), findsNothing);
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
    await _pumpAnimationFrames(tester, frames: 22);

    if (defaultTargetPlatform == TargetPlatform.android) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    final screenshot = await _capture(binding, _workbenchScreenshotName);
    expect(screenshot, isNotEmpty);

    await tester.fling(workbenchScroll, const Offset(0, 900), 1800);
    await _pumpAnimationFrames(tester, frames: 6);

    final freeCreation = find.byKey(
      const ValueKey<String>('workbench-free-creation'),
    );
    await tester.ensureVisible(freeCreation);
    await tester.tap(freeCreation.hitTestable());
    await _waitForCanvas(tester);
    await _pumpAnimationFrames(tester, frames: 12);

    expect(find.text('自由创作'), findsNothing);
    for (final key in const <String>[
      'canvas-title-field',
      'canvas-body-field',
      'canvas-markdown-toolbar',
      'canvas-top-undo',
      'canvas-top-redo',
      'canvas-save',
      'canvas-text-style',
      'canvas-block-style',
      'canvas-alignment',
      'canvas-import-notes',
      'canvas-chat-entry',
      'canvas-ai-tools',
      'canvas-keyboard-toggle',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
    }
    final canvasEditor = tester.widget<QuillEditor>(
      find.byKey(const ValueKey<String>('canvas-body-field')),
    );
    expect(canvasEditor.config.placeholder, '开始写点什么...');
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );

    final canvasScreenshot = await _capture(binding, _canvasScreenshotName);
    expect(canvasScreenshot, isNotEmpty);

    final controller = canvasEditor.controller;
    const richText = '加粗格式会直接显示在正文中';
    controller.replaceText(
      0,
      controller.document.length - 1,
      richText,
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('加粗').hitTestable());
    await _pumpAnimationFrames(tester, frames: 10);
    expect(
      controller.document
          .collectStyle(0, 4)
          .attributes[Attribute.bold.key]
          ?.value,
      isTrue,
    );
    final richTextScreenshot = await _capture(
      binding,
      _canvasRichTextScreenshotName,
    );
    expect(richTextScreenshot, isNotEmpty);

    final imageFile = await _writeCanvasAcceptanceImage();
    addTearDown(() async {
      if (await imageFile.exists()) await imageFile.delete();
    });
    final imageData = CanvasImageEmbedData(
      resourceId: imageFile.uri.pathSegments.last,
      alt: '自由创作配图验收',
      widthRatio: .62,
      aspectRatio: 12 / 7,
    );
    final imageOffset = controller.document.length - 1;
    controller.replaceText(
      imageOffset,
      0,
      Embeddable(CanvasImageEmbedData.deltaEmbedType, imageData.toJson()),
      TextSelection.collapsed(offset: imageOffset + 1),
    );
    await _pumpAnimationFrames(tester, frames: 4);
    final imageFinder = find.byKey(
      ValueKey<String>('canvas-image-${imageData.resourceId}'),
    );
    await tester.ensureVisible(imageFinder);
    await _pumpAnimationFrames(tester, frames: 4);
    expect(imageFinder, findsOneWidget);
    expect(
      find.byKey(
        ValueKey<String>(
          'canvas-image-handle-top-left-${imageData.resourceId}',
        ),
      ),
      findsNothing,
    );
    expect(find.byType(Slider), findsNothing);
    final imageScreenshot = await _capture(binding, _canvasImageScreenshotName);
    expect(imageScreenshot, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-import-notes')).hitTestable(),
    );
    await _pumpAnimationFrames(tester, frames: 8);
    final notePickerSearch = find.byKey(
      const ValueKey('knowledge-note-picker-search'),
    );
    expect(notePickerSearch, findsOneWidget);
    expect(find.text('导入笔记'), findsOneWidget);
    final noteImportScreenshot = await _capture(
      binding,
      _canvasNoteImportScreenshotName,
    );
    expect(noteImportScreenshot, isNotEmpty);
    Navigator.of(tester.element(notePickerSearch)).pop();
    await _pumpAnimationFrames(tester, frames: 6);

    await tester.tap(find.bySemanticsLabel('聊一聊').hitTestable());
    await _pumpAnimationFrames(tester, frames: 8);
    expect(find.text('创作聊天'), findsOneWidget);
    final topGlow = find.byKey(const ValueKey('canvas-chat-top-glow'));
    final dragHandle = find.byKey(
      const ValueKey('v3-glass-bottom-sheet-drag-handle'),
    );
    expect(topGlow, findsOneWidget);
    expect(dragHandle, findsOneWidget);
    expect(
      tester.getTopLeft(topGlow).dy,
      lessThan(tester.getTopLeft(dragHandle).dy),
    );
    final chatScreenshot = await _capture(binding, _canvasChatScreenshotName);
    expect(chatScreenshot, isNotEmpty);
  });

  testWidgets(
    'validates the production daily topic and opens a workspace note source',
    (tester) async {
      await app.main();
      await tester.pump();
      await _waitForAuthenticatedHome(tester);

      final appSurface = find.byType(MaterialApp).first;
      final container = ProviderScope.containerOf(tester.element(appSurface));
      final dailyTopics = container.read(dailyTopicControllerProvider);
      await dailyTopics.load(force: true);
      await tester.pump();

      final requestedRecommendationId = _dailyTopicLiveRecommendationId.trim();
      if (requestedRecommendationId.isNotEmpty) {
        await dailyTopics.open(requestedRecommendationId);
        await tester.pump();
      }

      final state = dailyTopics.state;
      expect(
        state.errorCode,
        isNull,
        reason: 'Production daily topic refresh failed: ${state.errorCode}',
      );
      final recommendation = state.recommendation;
      expect(
        recommendation,
        isNotNull,
        reason: 'No ready production daily topic was returned.',
      );
      expect(recommendation!.status, 'ready');
      expect(recommendation.businessDate, _dailyTopicLiveBusinessDate);
      expect(recommendation.title.trim(), isNotEmpty);
      expect(recommendation.summaryMarkdown.trim(), isNotEmpty);
      final recommendationReport = <String, Object?>{
        'recommendationId': recommendation.recommendationId,
        'businessDate': recommendation.businessDate,
        'status': recommendation.status,
        'title': recommendation.title,
        'summaryMarkdown': recommendation.summaryMarkdown,
        'topicCount': recommendation.topics.length,
      };
      debugPrint(
        '[DailyTopicLiveSmokeRecommendation] '
        '${jsonEncode(recommendationReport)}',
      );

      container.read(appRouterProvider).go('/v3/workbench');
      await _waitForFinder(
        tester,
        find.byKey(const ValueKey<String>('home-workbench-surface')),
        reason: 'The production Workbench did not open.',
      );
      expect(
        await _capture(
          binding,
          'daily_topic_live_${_dailyTopicLiveBusinessDate.replaceAll('-', '')}_list',
        ),
        isNotEmpty,
      );
      expect(
        recommendation.topics,
        isNotEmpty,
        reason: 'Delivery succeeded, but the production content is empty.',
      );
      expect(recommendation.topics.length, lessThanOrEqualTo(12));

      DailyTopicItem selectedTopic = recommendation.topics.first;
      DailyTopicWorkspaceNoteSourceRef? workspaceNoteSource;
      for (final topic in recommendation.topics) {
        for (final source in topic.sourceRefs) {
          if (source is DailyTopicWorkspaceNoteSourceRef) {
            selectedTopic = topic;
            workspaceNoteSource = source;
            break;
          }
        }
        if (workspaceNoteSource != null) break;
      }

      if (requestedRecommendationId.isEmpty) {
        final topicCard = find.byKey(
          ValueKey<String>('workbench-today-topic-${selectedTopic.topicId}'),
        );
        await _waitForFinder(
          tester,
          topicCard,
          reason: 'The production daily topic card is not visible.',
        );
        await tester.ensureVisible(topicCard);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(topicCard.hitTestable());
      } else {
        container
            .read(appRouterProvider)
            .go(
              '/v3/workbench/recommendations/'
              '${Uri.encodeComponent(recommendation.recommendationId)}'
              '?topicId=${Uri.encodeQueryComponent(selectedTopic.topicId)}',
            );
        await tester.pump();
      }
      final topicContent = find.byKey(
        const ValueKey<String>('workbench-recommendation-topic-content'),
      );
      await _waitForFinder(
        tester,
        topicContent,
        reason: 'The production daily topic detail did not open.',
      );
      expect(find.text(selectedTopic.title), findsOneWidget);
      for (final source in selectedTopic.sourceRefs) {
        final label = source.label?.trim().isNotEmpty == true
            ? source.label!.trim()
            : '来源笔记';
        expect(find.text(label), findsWidgets);
      }
      expect(
        await _capture(
          binding,
          'daily_topic_live_${_dailyTopicLiveBusinessDate.replaceAll('-', '')}_detail',
        ),
        isNotEmpty,
      );

      final smokeReport = <String, Object?>{
        'recommendationId': recommendation.recommendationId,
        'businessDate': recommendation.businessDate,
        'status': recommendation.status,
        'title': recommendation.title,
        'summaryMarkdown': recommendation.summaryMarkdown,
        'topicCount': recommendation.topics.length,
        'selectedTopic': <String, Object?>{
          'topicId': selectedTopic.topicId,
          'title': selectedTopic.title,
          'briefMarkdown': selectedTopic.briefMarkdown,
          'sourceRefs': selectedTopic.sourceRefs
              .map((source) => source.toJson())
              .toList(growable: false),
        },
        'workspaceNoteFound': workspaceNoteSource != null,
      };
      debugPrint('[DailyTopicLiveSmoke] ${jsonEncode(smokeReport)}');

      if (workspaceNoteSource != null) {
        final sourceLabel = workspaceNoteSource.label?.trim().isNotEmpty == true
            ? workspaceNoteSource.label!.trim()
            : '来源笔记';
        final sourceLink = find.byKey(
          ValueKey<String>('workbench-recommendation-source-$sourceLabel'),
        );
        await tester.ensureVisible(sourceLink.first);
        await tester.tap(sourceLink.hitTestable().first);
        await _waitForFinder(
          tester,
          find.byKey(const ValueKey<String>('note-detail-surface')),
          reason: 'The workspace note source did not open its local asset.',
        );
        expect(
          await _capture(
            binding,
            'daily_topic_live_${_dailyTopicLiveBusinessDate.replaceAll('-', '')}_workspace_note',
          ),
          isNotEmpty,
        );
      }
    },
    skip: !_dailyTopicLiveSmokeEnabled,
  );
}

Future<List<int>> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final bytes = await binding.takeScreenshot(name);
  final root = await getTemporaryDirectory();
  final directory = Directory('${root.path}/huahuo-v5-visual-probe');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes, flush: true);
  debugPrint('[V5VisualProbe] ${directory.path}/$name.png');
  return bytes;
}

Finder _graphTitleTexts() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return widget is Text &&
      key is ValueKey<String> &&
      key.value.startsWith('feed-graph-node-label-');
});

Future<void> _waitForFeed(WidgetTester tester) async {
  final feedTitle = find.text('思想图谱');
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 40; attempt++) {
    if (feedTitle.hitTestable().evaluate().isNotEmpty) return;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(feedTitle.hitTestable(), findsOneWidget);
}

Future<void> _waitForAuthenticatedHome(WidgetTester tester) async {
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 600; attempt++) {
    if (find.text('思想图谱').evaluate().isNotEmpty ||
        find.text('创作空间').evaluate().isNotEmpty) {
      return;
    }
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  fail('The authenticated production home did not become available.');
}

Future<void> _waitForFinder(
  WidgetTester tester,
  Finder finder, {
  required String reason,
}) async {
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 600; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(finder, findsWidgets, reason: reason);
}

Future<void> _waitForCanvas(WidgetTester tester) async {
  final canvasBody = find.byKey(const ValueKey<String>('canvas-body-field'));
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 40; attempt++) {
    if (canvasBody.evaluate().isNotEmpty) return;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(canvasBody, findsOneWidget);
}

Future<void> _pumpAnimationFrames(
  WidgetTester tester, {
  required int frames,
}) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<File> _writeCanvasAcceptanceImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  const size = ui.Size(720, 420);
  canvas.drawRect(
    const ui.Offset(0, 0) & size,
    ui.Paint()..color = const Color(0xFFF1F4F2),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 250, 720, 170),
    ui.Paint()..color = const Color(0xFFBFCBC4),
  );
  canvas.drawCircle(
    const ui.Offset(560, 116),
    62,
    ui.Paint()..color = const Color(0xFFE15D45),
  );
  final accent = ui.Paint()
    ..color = const Color(0xFF1F4540)
    ..strokeWidth = 18
    ..strokeCap = ui.StrokeCap.round;
  canvas.drawLine(const ui.Offset(82, 104), const ui.Offset(360, 104), accent);
  canvas.drawLine(const ui.Offset(82, 158), const ui.Offset(286, 158), accent);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (png == null) throw StateError('Unable to encode canvas test image');

  final root = await getApplicationSupportDirectory();
  final directory = Directory(
    '${root.path}${Platform.pathSeparator}HuahuoAI'
    '${Platform.pathSeparator}CanvasImages',
  );
  await directory.create(recursive: true);
  final file = File(
    '${directory.path}${Platform.pathSeparator}integration-canvas.png',
  );
  await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
  return file;
}
