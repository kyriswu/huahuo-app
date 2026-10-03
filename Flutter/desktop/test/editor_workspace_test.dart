import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/app/desktop_app.dart';
import 'package:huahuo_desktop/app/desktop_services.dart';
import 'package:huahuo_desktop/features/editor/data/local_document_store.dart';
import 'package:huahuo_desktop/features/editor/presentation/desktop_knowledge_graph.dart';
import 'package:huahuo_desktop/features/assets/data/desktop_assets_adapters.dart';
import 'package:huahuo_desktop/features/auth/data/desktop_auth_adapters.dart';
import 'package:huahuo_desktop/features/auth/domain/desktop_auth_port.dart';
import 'package:huahuo_desktop/features/calendar/domain/desktop_activity_calendar_port.dart';
import 'package:huahuo_desktop/features/chat/data/desktop_chat_adapters.dart';
import 'package:huahuo_desktop/features/chat/domain/desktop_chat_port.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_raw_note_creator.dart';
import 'package:huahuo_desktop/features/topics/domain/desktop_topics_port.dart';
import 'package:huahuo_desktop/shared/services/desktop_service_result.dart';
import 'package:huahuo_desktop/shared/widgets/desktop_window_frame.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:huahuo_product/huahuo_product.dart';

import 'support/desktop_port_fakes.dart';

const _incomingDocumentTestChannel = MethodChannel(
  'huahuo_desktop/incoming_documents',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _incomingDocumentTestChannel,
          (_) async => null,
        );
    final textFont = FontLoader('NotoSansSC')
      ..addFont(
        _loadPackageFile(
          'huahuo_desktop',
          'assets/fonts/NotoSansSC-Variable.ttf',
        ),
      );
    final iconFont = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(_loadPackageFile('lucide_icons_flutter', 'assets/lucide.ttf'));
    await Future.wait([textFont.load(), iconFont.load()]);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_incomingDocumentTestChannel, null);
  });

  Future<void> pumpDesktop(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.light,
    DocumentStore? documentStore,
    DesktopWindowController? windowController,
    Size viewport = const Size(1440, 900),
    bool reduceMotion = true,
    bool muteTickers = false,
    DesktopServices? services,
    DesktopRawNoteCreator? rawNoteCreator,
    List<String> incomingDocumentPaths = const <String>[],
  }) async {
    final activeWindowController = windowController ?? _FakeWindowController();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(
          disableAnimations: reduceMotion,
          reduceMotion: reduceMotion,
        );
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(activeWindowController.dispose);
    await tester.pumpWidget(
      TickerMode(
        enabled: !muteTickers,
        child: HuahuoDesktopApp(
          documentStore: documentStore ?? _MemoryDocumentStore(),
          themeMode: themeMode,
          windowController: activeWindowController,
          services:
              services ??
              DesktopServices(
                auth: FakeDesktopAuthPort(),
                assets: const FakeDesktopAssetsPort(),
                documents: FakeDesktopDocumentSyncPort(),
                rawNoteCreator: rawNoteCreator ?? FakeDesktopRawNoteCreator(),
                chat: FakeDesktopChatPort(),
                subscription: FakeDesktopSubscriptionPort(),
                demoMode: false,
              ),
          incomingDocumentPaths: incomingDocumentPaths,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }

  Future<void> openCreationWorkspace(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('creation-mode')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('note-explorer')), findsOneWidget);
  }

  DesktopKnowledgeGraph graphWidget(WidgetTester tester) =>
      tester.widget<DesktopKnowledgeGraph>(find.byType(DesktopKnowledgeGraph));

  Future<Uint8List> graphPixels(WidgetTester tester) async {
    final boundaryFinder = find.descendant(
      of: find.byKey(const ValueKey<String>('knowledge-graph')),
      matching: find.byType(RepaintBoundary),
    );
    expect(boundaryFinder, findsOneWidget);
    final boundary = tester.renderObject<RenderRepaintBoundary>(boundaryFinder);
    final pixels = await tester.runAsync<Uint8List>(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null) {
          throw StateError(
            'The graph repaint boundary did not produce pixels.',
          );
        }
        return Uint8List.fromList(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
        );
      } finally {
        image.dispose();
      }
    });
    if (pixels == null) {
      throw StateError('Timed out while capturing the graph repaint boundary.');
    }
    return pixels;
  }

  int changedPixelByteCount(Uint8List before, Uint8List after) {
    expect(after.length, before.length);
    var changed = 0;
    for (var index = 0; index < before.length; index++) {
      if (before[index] != after[index]) changed++;
    }
    return changed;
  }

  testWidgets('opens directly into the interactive idea-graph workspace', (
    tester,
  ) async {
    await pumpDesktop(tester);

    expect(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('knowledge-graph')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('note-explorer')), findsNothing);
    expect(find.text('思想图谱'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('knowledge-graph-node-count')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fixed-chat-panel')),
      findsOneWidget,
    );
  });

  testWidgets('waits for Workspace ready before binding desktop chat', (
    tester,
  ) async {
    final auth = FakeDesktopAuthPort(
      account: const DesktopAuthAccount(
        userId: 'workspace-pending-user',
        displayName: '准备中的用户',
        workspaceStatus: 'creating',
        workspaceId: 'workspace-pending',
      ),
    );
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: auth,
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        subscription: FakeDesktopSubscriptionPort(),
        demoMode: false,
      ),
    );

    expect(find.text('正在准备你的 Workspace'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey<String>('chat-input')))
          .enabled,
      isFalse,
    );

    auth.account = const DesktopAuthAccount(
      userId: 'workspace-pending-user',
      displayName: '准备中的用户',
      workspaceStatus: 'ready',
      workspaceId: 'workspace-pending',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('正在准备你的 Workspace'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey<String>('chat-input')))
          .enabled,
      isTrue,
    );
  });

  testWidgets('imports a startup document through the formal document port', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'desktop-startup-document-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final source = File('${directory.path}${Platform.pathSeparator}启动资料.txt')
      ..writeAsStringSync('供正式导入链路读取。');
    final importer = FakeDesktopDocumentImportPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        documentImporter: importer,
        chat: FakeDesktopChatPort(),
        subscription: FakeDesktopSubscriptionPort(),
        demoMode: false,
      ),
      incomingDocumentPaths: <String>[source.path],
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(importer.requests, hasLength(1));
    expect(importer.requests.single.filePath, source.path);
    expect(importer.requests.single.fileName, '启动资料.txt');
    expect(importer.requests.single.workspaceId, 'workspace-test');
  });

  testWidgets('running topic collision shows server-frozen sources', (
    tester,
  ) async {
    final topics = _FixedDesktopTopicsPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        subscription: FakeDesktopSubscriptionPort(),
        topics: topics,
        demoMode: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('desktop-topic-collision')),
    );
    await tester.pump();

    expect(topics.createCalls, 1);
    expect(find.text('聚合生成中'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-topic-collision-sources')),
      findsOneWidget,
    );
    expect(find.textContaining('来源笔记 1'), findsOneWidget);
    expect(find.textContaining('来源笔记 4'), findsOneWidget);
  });

  testWidgets('failed topic collision stays visible and can be retried', (
    tester,
  ) async {
    final topics = _FixedDesktopTopicsPort(_failedTopicCollisionRun);
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        subscription: FakeDesktopSubscriptionPort(),
        topics: topics,
        demoMode: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('desktop-topic-collision')),
    );
    await tester.pumpAndSettle();

    expect(topics.createCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('desktop-topic-collision-failed')),
      findsOneWidget,
    );
    expect(find.text('聚合失败，可重试'), findsOneWidget);
    expect(find.textContaining('TOPIC_COLLISION'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('desktop-topic-collision')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('self-drawn title bar wires every native window command', (
    tester,
  ) async {
    final controller = _FakeWindowController();
    await pumpDesktop(tester, windowController: controller);

    expect(
      find.byKey(const ValueKey<String>('desktop-title-bar')),
      findsOneWidget,
    );
    final dragRegion = tester.widget<GestureDetector>(
      find.byKey(const ValueKey<String>('desktop-title-drag-region')),
    );
    dragRegion.onPanStart!(DragStartDetails());
    await tester.tap(find.byKey(const ValueKey<String>('window-minimize')));
    dragRegion.onDoubleTap!();
    await tester.pump();
    expect(controller.dragCount, 1);
    expect(controller.minimizeCount, 1);
    expect(controller.maximizeCount, 1);

    await tester.tap(find.byKey(const ValueKey<String>('window-maximize')));
    await tester.pump();
    expect(controller.unmaximizeCount, 1);
    await tester.tap(find.byKey(const ValueKey<String>('window-maximize')));
    await tester.pump();
    expect(controller.maximizeCount, 2);
    await tester.tap(find.byKey(const ValueKey<String>('window-maximize')));
    await tester.tap(find.byKey(const ValueKey<String>('window-close')));
    await tester.pump();
    expect(controller.unmaximizeCount, 2);
    expect(controller.closeCount, 1);
  });

  testWidgets('title bar workspace picker and command menus are usable', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(find.byKey(const ValueKey<String>('workspace-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('七月内容计划').last);
    await tester.pump();
    expect(find.text('七月内容计划'), findsWidgets);

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('最小化窗口'), findsOneWidget);
  });

  testWidgets('Explorer and fixed chat rail are independently collapsible', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await openCreationWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey<String>('sidebar-toggle')));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byKey(const ValueKey<String>('note-explorer')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('sidebar-toggle')));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byKey(const ValueKey<String>('note-explorer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('chat-rail-collapse')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fixed-chat-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('collapsed-chat-rail')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('chat-rail-expand')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fixed-chat-panel')),
      findsOneWidget,
    );
  });

  testWidgets('Explorer contains only notes and folders, not asset sources', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await openCreationWorkspace(tester);
    expect(find.text('短视频脚本：城市夜跑'), findsNWidgets(2));
    expect(find.text('知识素材'), findsNothing);
    expect(find.text('已沉淀'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('folder-我的创作')));
    await tester.pump();
    expect(find.text('短视频脚本：城市夜跑'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('folder-我的创作')));
    await tester.pump();
    expect(find.text('短视频脚本：城市夜跑'), findsNWidgets(2));
    expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);
  });

  testWidgets('graph controls zoom and reset the interactive viewport', (
    tester,
  ) async {
    await pumpDesktop(tester);

    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.text('2D'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('knowledge-graph')),
      findsOneWidget,
    );
    await tester.tap(find.text('3D'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('graph-zoom-in')));
    await tester.pump();
    expect(find.text('125%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('graph-reset')));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('graph indexes every document in a dense collection', (
    tester,
  ) async {
    final documents = List<HuahuoDocumentSnapshot>.generate(
      2004,
      (index) => HuahuoDocumentSnapshot(
        id: 'stress-20260728-${index.toString().padLeft(4, '0')}',
        title: '压力测试文稿 ${index + 1}',
        deltaJson: '[{"insert":"压力测试内容\\n"}]',
        revision: 1,
        createdAt: DateTime.utc(2026, 7, 28),
        modifiedAt: DateTime.utc(2026, 7, 28),
      ),
    );
    await pumpDesktop(tester, documentStore: _MemoryDocumentStore(documents));

    expect(graphWidget(tester).documents, hasLength(2004));
    expect(find.text('2004 篇文稿 · 2005 个图谱点'), findsOneWidget);
    await tester.tap(find.text('2D'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('knowledge-graph')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dense 2D mouse pan visibly repaints before pointer release', (
    tester,
  ) async {
    final documents = List<HuahuoDocumentSnapshot>.generate(
      321,
      (index) => HuahuoDocumentSnapshot(
        id: 'dense-drag-${index.toString().padLeft(4, '0')}',
        title: 'Dense drag note ${index + 1}',
        deltaJson: '[{"insert":"Dense graph content\\n"}]',
        revision: 1,
        createdAt: DateTime.utc(2026, 7, 29),
        modifiedAt: DateTime.utc(2026, 7, 29),
      ),
    );
    await pumpDesktop(
      tester,
      documentStore: _MemoryDocumentStore(documents),
      reduceMotion: false,
      // The gesture itself must cause the bitmap change. Muting tickers keeps
      // idle motion from creating a false-positive pixel difference.
      muteTickers: true,
    );
    await tester.tap(find.text('2D'));
    await tester.pump();

    final graph = find.byKey(const ValueKey<String>('knowledge-graph'));
    final graphSize = tester.getSize(graph);
    final graphOrigin = tester.getTopLeft(graph);
    final graphState =
        tester.state(find.byType(DesktopKnowledgeGraph)) as dynamic;
    final documentPosition =
        graphState.debugDenseNodeViewPosition(
              'document-dense-drag-0000',
              graphSize,
            )
            as Offset?;
    expect(documentPosition, isNotNull);
    final documentGlobal = graphOrigin + documentPosition!;
    const dragDelta = Offset(84, 52);

    final drag = await tester.startGesture(
      documentGlobal,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    // This first move claims the pan recognizer. The second move below is the
    // held-pointer update whose paint is asserted before mouse-up.
    await drag.moveBy(const Offset(16, 10));
    await tester.pump();
    final pixelsBeforeLiveMove = await graphPixels(tester);
    await drag.moveBy(dragDelta);
    await tester.pump();
    final pixelsDuringDrag = await graphPixels(tester);

    expect(
      changedPixelByteCount(pixelsBeforeLiveMove, pixelsDuringDrag),
      greaterThan(100),
      reason:
          'A held mouse move must synchronously repaint the dragged graph, '
          'not wait for pointer release.',
    );

    await drag.up();
    await tester.pump(const Duration(milliseconds: 360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('2D graph matches the mobile-aligned visual baseline', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(find.text('2D'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('knowledge-graph')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('graph-add-context')),
      findsNothing,
    );
    await expectLater(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      matchesGoldenFile('goldens/editor_workspace_graph_2d_1440x900.png'),
    );
  });

  testWidgets('mobile-equivalent features open as functional editor tabs', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('assets-workspace')),
      findsOneWidget,
    );
    expect(find.text('我的资产'), findsWidgets);

    final captureMode = find.byKey(const ValueKey<String>('capture-mode'));
    final settingsMode = find.byKey(const ValueKey<String>('settings-mode'));
    expect(
      tester.getTopLeft(captureMode).dy,
      lessThan(tester.getTopLeft(settingsMode).dy),
    );

    await tester.tap(captureMode);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('feature-capture')),
      findsOneWidget,
    );
    expect(find.text('导入独白音频'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('tab-graph')), findsOneWidget);
  });

  testWidgets('feature command palette opens a real routed workspace', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final query = find.byKey(const ValueKey<String>('feature-command-query'));
    expect(query, findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('feature-command-native.recordingCard'),
      ),
      findsNothing,
    );

    await tester.enterText(query, '通知');
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-notifications.inbox')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktop-notifications-workspace')),
      findsOneWidget,
    );
  });

  testWidgets('activity calendar command loads the authenticated Workspace', (
    tester,
  ) async {
    final calendar = _FakeActivityCalendarPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        activityCalendar: calendar,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '活动日历',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-content.calendar')),
    );
    await tester.pumpAndSettle();

    expect(calendar.workspaceIds, <String>['workspace-test']);
    expect(
      find.byKey(const ValueKey<String>('desktop-activity-calendar')),
      findsOneWidget,
    );
    expect(find.text('2026-09-03 新增 6 条笔记'), findsOneWidget);
  });

  testWidgets('Workspace command opens the shared management surface', (
    tester,
  ) async {
    final workspaces = _EditorWorkspaceManagementRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        workspaceManagement: workspaces,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      'Workspace',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-account.workspace')),
    );
    await tester.pumpAndSettle();

    expect(workspaces.listCalls, greaterThanOrEqualTo(1));
    expect(
      find.byKey(const ValueKey<String>('desktop-workspace-management')),
      findsOneWidget,
    );
    expect(find.text('桌面工作空间'), findsOneWidget);
  });

  testWidgets('Home command opens aggregation and executes primary action', (
    tester,
  ) async {
    final home = _EditorHomeRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        home: home,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '首页',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-content.home')),
    );
    await tester.pumpAndSettle();

    expect(home.workspaceIds, contains('workspace-test'));
    expect(
      find.byKey(const ValueKey<String>('desktop-home-workspace')),
      findsOneWidget,
    );
    expect(find.text('6'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('home-primary-action')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('capture-workspace')),
      findsOneWidget,
    );
  });

  testWidgets('recording command opens cloud library and upload handoff', (
    tester,
  ) async {
    final recordings = _EditorRecordingRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        recordingLibrary: recordings,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '录音文件库',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-recordings.library')),
    );
    await tester.pumpAndSettle();

    expect(recordings.workspaceIds, ['workspace-test']);
    expect(
      find.byKey(const ValueKey<String>('desktop-recording-library')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('recordings-upload')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('capture-workspace')),
      findsOneWidget,
    );
  });

  testWidgets('creation command opens the server-backed Workspace editor', (
    tester,
  ) async {
    final creations = _EditorCreationRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        creations: creations,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '自由创作',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-creation.workspace')),
    );
    await tester.pumpAndSettle();

    expect(creations.workspaceIds, ['workspace-test']);
    expect(
      find.byKey(const ValueKey<String>('desktop-creation-workspace')),
      findsOneWidget,
    );
    expect(find.text('云端创作'), findsWidgets);
  });

  testWidgets('proposal command opens Workspace-wide server history', (
    tester,
  ) async {
    final proposals = _EditorProposalRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        proposals: proposals,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '文档提案',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-creation.proposals')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>('desktop-document-proposals-workspace'),
      ),
      findsOneWidget,
    );
    expect(proposals.workspaceIds, ['workspace-test']);
    expect(proposals.ownerIds, [null]);
  });

  testWidgets('Creation handoff preserves Proposal owner revision', (
    tester,
  ) async {
    final creations = _EditorCreationRepository();
    final proposals = _EditorProposalRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        creations: creations,
        proposals: proposals,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '自由创作',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-creation.workspace')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('creation-item-creation-desktop')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('creation-proposals')));
    await tester.pumpAndSettle();

    expect(proposals.ownerIds, ['creation-desktop']);
    await tester.tap(
      find.byKey(const ValueKey<String>('proposal-empty-create')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('proposal-instruction')),
      '优化正文',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('proposal-instruction-confirm')),
    );
    await tester.pumpAndSettle();
    expect(proposals.rawPartRevisionIds, ['raw-revision-1']);
  });

  testWidgets('Digital Twin command opens its dedicated account workspace', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await tester.pump(const Duration(milliseconds: 120));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '数字分身',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('feature-command-digitalTwin.workspace'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('desktop-digital-twin-workspace')),
      findsOneWidget,
    );
    expect(find.text('数字分身加载失败'), findsOneWidget);
  });

  testWidgets('support command opens injected help workspace', (tester) async {
    final support = _EditorSupportRepository();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        support: support,
        demoMode: false,
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '帮助中心',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-account.support')),
    );
    await tester.pumpAndSettle();

    expect(support.catalogLoads, 1);
    expect(
      find.byKey(const ValueKey<String>('desktop-support-workspace')),
      findsOneWidget,
    );
    expect(find.text('桌面帮助'), findsOneWidget);
  });

  testWidgets('creation-tool Agent entries start profile-bound chat', (
    tester,
  ) async {
    final chat = FakeDesktopChatPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: chat,
        demoMode: false,
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('tools-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('人设').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-agent-profile-label')),
      findsOneWidget,
    );
    expect(find.text('人设内容'), findsWidgets);
    expect(find.textContaining('这里不是让你填表，也不是让你从零想选题。'), findsOneWidget);
    expect(chat.lastAgentProfileId, isNull);
    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-input')),
      '帮我梳理个人表达方向',
    );
    await tester.tap(find.byKey(const ValueKey<String>('chat-send')));
    await tester.pumpAndSettle();

    expect(chat.lastAgentProfileId, 'renshe_content');
  });

  testWidgets('video-analysis history restores its local opening', (
    tester,
  ) async {
    final chat = FakeDesktopChatPort(
      thread: const DesktopChatThread(
        threadId: 'video-thread',
        title: '视频拆解',
        agentProfileId: 'video_analysis',
      ),
      messages: const <DesktopChatMessage>[
        DesktopChatMessage(
          messageId: 'video-user-1',
          threadId: 'video-thread',
          role: 'user',
          text: '请帮我拆解这个视频',
        ),
        DesktopChatMessage(
          messageId: 'video-assistant-1',
          threadId: 'video-thread',
          role: 'assistant',
          text: '可以，请先提供视频。',
        ),
      ],
    );
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: chat,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('视频分析'), findsOneWidget);
    expect(find.textContaining('你好，我可以陪你一起看视频'), findsOneWidget);
    expect(find.text('请帮我拆解这个视频'), findsOneWidget);
    expect(find.text('可以，请先提供视频。'), findsOneWidget);
    expect(chat.lastAgentProfileId, isNull);
  });

  testWidgets('subscribed external knowledge collects into a visible asset', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-mode')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('external-knowledge-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('knowledge-square-workspace')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('knowledge-square-subscribe-industry-weekly'),
      ),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('knowledge-square-workspace')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('knowledge-square-actions-industry-weekly'),
      ),
    );
    await tester.pumpAndSettle();
    final collectAction = find.ancestor(
      of: find.text('收录到我的资产'),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
    );
    final dynamic collectMenuItem = tester.widget(collectAction);
    final dynamic actionsMenu = tester.widget(
      find.byKey(
        const ValueKey<String>('knowledge-square-actions-industry-weekly'),
      ),
    );
    actionsMenu.onSelected(collectMenuItem.value);
    Navigator.of(tester.element(collectAction)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
    await tester.pump();
    expect(find.text('行业研究周报'), findsWidgets);
  });

  testWidgets('my assets includes every Flutter-UI asset section', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
    await tester.pump();

    for (var index = 0; index < 8; index++) {
      await tester.tap(find.byKey(ValueKey<String>('asset-section-$index')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('assets-workspace')),
        findsOneWidget,
      );
    }
  });

  testWidgets('remote asset Markdown opens in the native preview', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('测试云端资产').last);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('remote-asset-markdown-preview')),
      findsOneWidget,
    );
    expect(find.text('测试云端资产'), findsWidgets);
  });

  testWidgets('external knowledge supports subscriptions, square, and import', (
    tester,
  ) async {
    final rawNotes = FakeDesktopRawNoteCreator();
    await pumpDesktop(tester, rawNoteCreator: rawNotes);
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-mode')),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-subscriptions')),
    );
    await tester.pump();
    expect(find.text('客户访谈原文'), findsOneWidget);

    expect(
      find.byKey(const ValueKey<String>('external-knowledge-sources')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-square')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('knowledge-square-workspace')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-import')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('external-knowledge-import-input')),
      'https://example.com/research',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsWidgets);
    expect(rawNotes.requests, hasLength(1));
    expect(
      rawNotes.requests.single.rawMarkdown,
      contains('<https://example.com/research>'),
    );
  });

  testWidgets(
    'knowledge square exposes discovery, categories, context, and subscriptions',
    (tester) async {
      await pumpDesktop(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-mode')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-square')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('knowledge-square-workspace')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-featured')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-banner-pages')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-categories')),
        findsOneWidget,
      );
      for (final category in <String>['all', 'treasure', 'history']) {
        expect(
          find.byKey(ValueKey<String>('knowledge-square-category-$category')),
          findsOneWidget,
        );
      }
      expect(find.text('最近更新'), findsOneWidget);

      final contextAction = find.byKey(
        const ValueKey<String>('knowledge-square-context-industry-weekly'),
      );
      final subscribeAction = find.byKey(
        const ValueKey<String>('knowledge-square-subscribe-industry-weekly'),
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-square-more')),
        findsOneWidget,
      );
      expect(contextAction, findsOneWidget);
      expect(subscribeAction, findsOneWidget);

      final squareWorkspace = find.byKey(
        const ValueKey<String>('knowledge-square-workspace'),
      );
      await tester.drag(squareWorkspace, const Offset(0, -360));
      await tester.pumpAndSettle();
      await tester.tap(contextAction);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'remove-chat-context-external-industry-weekly',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(subscribeAction);
      await tester.pump();
      expect(
        find.descendant(of: subscribeAction, matching: find.text('已订阅')),
        findsOneWidget,
      );

      final more = find.byKey(const ValueKey<String>('knowledge-square-more'));
      await tester.tap(more);
      await tester.pump();
      expect(find.text('收起'), findsOneWidget);

      final history = find.byKey(
        const ValueKey<String>('knowledge-square-category-history'),
      );
      await tester.tap(history);
      await tester.pump();
      expect(find.text('历史 · 最近更新'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('knowledge-square-category-treasure'),
        ),
      );
      await tester.pump();
      expect(find.text('一件器物如何讲述历史'), findsOneWidget);
    },
  );

  testWidgets(
    'opening external content updates the dynamic selection slot without opening the middle panel',
    (tester) async {
      await pumpDesktop(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-mode')),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-subscriptions')),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(
          const ValueKey<String>('external-knowledge-row-customer-interview'),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-focus-selection')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('chat-context-focus-selection'),
          ),
          matching: find.text('客户访谈原文'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('context-panel')), findsNothing);
    },
  );

  testWidgets(
    'remote Subscription replaces seeds, opens immutable content, and rotates action keys',
    (tester) async {
      final subscription = FakeDesktopSubscriptionPort();
      subscription.publications
        ..clear()
        ..add(
          SharedSubscriptionPublication(
            publicationId: 'publication-remote',
            title: '远端专栏',
            summary: '远端目录',
            sectionCount: 0,
            articleCount: 1,
            updatedAt: DateTime.utc(2026, 8, 7),
          ),
        );
      subscription.articles
        ..clear()
        ..add(
          SharedSubscriptionArticle(
            articleId: 'remote-only',
            publicationId: 'publication-remote',
            currentArticleRevisionId: 'revision-remote-1',
            title: '远端唯一文章',
            summary: '这条内容只来自 API 25',
            author: '远端作者',
            publishedAt: DateTime.utc(2026, 8, 7),
          ),
        );
      subscription.followedPublicationIds.clear();
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(),
          subscription: subscription,
          demoMode: false,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-mode')),
      );
      await tester.pumpAndSettle();

      expect(find.text('远端唯一文章'), findsWidgets);
      expect(find.text('行业研究周报'), findsNothing);
      await tester.tap(find.text('远端唯一文章').last);
      await tester.pumpAndSettle();
      expect(subscription.operations, contains('article:remote-only'));
      expect(
        find.byKey(const ValueKey<String>('remote-asset-markdown-preview')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-mode')),
      );
      await tester.pumpAndSettle();
      final subscribe = find.byKey(
        const ValueKey<String>('knowledge-square-subscribe-remote-only'),
      );
      subscription.failNextMutation = true;
      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: subscribe, matching: find.text('+ 订阅')),
        findsOneWidget,
      );
      final failedKey = subscription.idempotencyKeys.last;

      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      expect(subscription.idempotencyKeys.last, failedKey);
      expect(
        find.descendant(of: subscribe, matching: find.text('已订阅')),
        findsOneWidget,
      );

      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      final unfollowKey = subscription.idempotencyKeys.last;
      expect(unfollowKey, isNot(failedKey));
      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      expect(subscription.idempotencyKeys.last, isNot(failedKey));
      expect(subscription.idempotencyKeys.last, isNot(unfollowKey));
    },
  );

  testWidgets(
    'saving a Subscription revision pulls its HNote and rotates the next save key',
    (tester) async {
      final subscription = FakeDesktopSubscriptionPort();
      subscription.followedPublicationIds.add('publication-industry');
      final documents = FakeDesktopDocumentSyncPort();
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: documents,
          chat: FakeDesktopChatPort(),
          subscription: subscription,
          demoMode: false,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('external-knowledge-mode')),
      );
      await tester.pumpAndSettle();
      final actions = find.byKey(
        const ValueKey<String>('knowledge-square-actions-industry-weekly'),
      );
      final initialPullCount = documents.operations
          .where((operation) => operation == 'pull')
          .length;
      await tester.ensureVisible(actions);
      await tester.pumpAndSettle();
      await tester.tap(actions);
      await tester.pumpAndSettle();
      for (var index = 0; index < 5; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final firstSaveKey = subscription.idempotencyKeys
          .where((key) => key.contains('-save-'))
          .single;
      expect(subscription.operations, contains('save:industry-weekly'));
      expect(
        documents.operations.where((operation) => operation == 'pull').length,
        initialPullCount + 1,
      );

      final index = subscription.articles.indexWhere(
        (article) => article.articleId == 'industry-weekly',
      );
      final previous = subscription.articles[index];
      subscription.articles[index] = SharedSubscriptionArticle(
        articleId: previous.articleId,
        publicationId: previous.publicationId,
        currentArticleRevisionId: 'revision-customer-interview-2',
        title: previous.title,
        summary: '第二版访谈内容',
        author: previous.author,
        publishedAt: DateTime.utc(2026, 8, 8),
      );
      final subscribe = find.byKey(
        const ValueKey<String>('knowledge-square-subscribe-industry-weekly'),
      );
      await tester.ensureVisible(subscribe);
      await tester.pumpAndSettle();
      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      await tester.ensureVisible(subscribe);
      await tester.pumpAndSettle();
      await tester.tap(subscribe);
      await tester.pumpAndSettle();
      await tester.ensureVisible(actions);
      await tester.pumpAndSettle();
      await tester.tap(actions);
      await tester.pumpAndSettle();
      for (var index = 0; index < 5; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final saveKeys = subscription.idempotencyKeys
          .where((key) => key.contains('-save-'))
          .toList(growable: false);
      expect(saveKeys, hasLength(2));
      expect(saveKeys.last, isNot(firstSaveKey));
    },
  );

  testWidgets('remote Subscription failure never exposes production seeds', (
    tester,
  ) async {
    final subscription = FakeDesktopSubscriptionPort()
      ..readFailureCode = 'SUBSCRIPTION_CATALOG_UNAVAILABLE';
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        subscription: subscription,
        demoMode: false,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-mode')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('subscription-remote-error')),
      findsOneWidget,
    );
    expect(find.text('行业研究周报'), findsNothing);
  });

  testWidgets(
    'Workspace Search debounces races and opens the exact owner revision',
    (tester) async {
      final workspace = FakeDesktopWorkspacePort();
      final first =
          Completer<DesktopServiceResult<SharedWorkspaceSearchOutput>>();
      final second =
          Completer<DesktopServiceResult<SharedWorkspaceSearchOutput>>();
      workspace.searchResponder = (query, _) =>
          query == '旧查询' ? first.future : second.future;
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(),
          workspace: workspace,
          subscription: FakeDesktopSubscriptionPort(),
          accountUsage: FakeDesktopAccountUsagePort(),
          demoMode: false,
        ),
      );
      await openCreationWorkspace(tester);
      final input = find.byKey(const ValueKey<String>('explorer-search'));

      await tester.enterText(input, '旧查询');
      await tester.pump(const Duration(milliseconds: 340));
      expect(workspace.searchQueries, <String>['旧查询']);
      expect(
        find.byKey(const ValueKey<String>('workspace-search-loading')),
        findsOneWidget,
      );

      await tester.enterText(input, '新查询');
      await tester.pump(const Duration(milliseconds: 340));
      expect(workspace.searchQueries, <String>['旧查询', '新查询']);
      second.complete(
        DesktopServiceResult<SharedWorkspaceSearchOutput>.success(
          _workspaceSearchOutput(
            title: '新响应笔记',
            noteId: 'note-new',
            revisionId: 'note-revision-new',
          ),
        ),
      );
      await tester.pump();
      first.complete(
        DesktopServiceResult<SharedWorkspaceSearchOutput>.success(
          _workspaceSearchOutput(
            title: '旧响应笔记',
            noteId: 'note-old',
            revisionId: 'note-revision-old',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('新响应笔记'), findsOneWidget);
      expect(find.text('旧响应笔记'), findsNothing);
      await tester.tap(find.text('新响应笔记'));
      await tester.pumpAndSettle();
      expect(workspace.loadedNoteRevisionIds, <String>['note-revision-new']);
      expect(workspace.loadedPartRevisionIds, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('remote-asset-markdown-preview')),
        findsOneWidget,
      );
      expect(
        workspace.operations.where(
          (operation) => operation.startsWith('navigation:'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('Workspace Search exposes an explicit local-only state', (
    tester,
  ) async {
    final localOnlyWorkspace = FakeDesktopWorkspacePort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(signedIn: false),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        workspace: localOnlyWorkspace,
        accountUsage: FakeDesktopAccountUsagePort(),
        demoMode: false,
      ),
    );
    await openCreationWorkspace(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('explorer-search')),
      '本机',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('workspace-search-local-only')),
      findsOneWidget,
    );
    expect(localOnlyWorkspace.searchQueries, isEmpty);
  });

  testWidgets('Workspace Search failure keeps local Explorer results', (
    tester,
  ) async {
    final failingWorkspace = FakeDesktopWorkspacePort()
      ..searchResult =
          const DesktopServiceResult<SharedWorkspaceSearchOutput>.failure(
            code: 'WORKSPACE_KEYWORD_SEARCH_UNAVAILABLE',
            message: '关键字索引暂不可用',
          );
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        workspace: failingWorkspace,
        subscription: FakeDesktopSubscriptionPort(),
        accountUsage: FakeDesktopAccountUsagePort(),
        demoMode: false,
      ),
    );
    await openCreationWorkspace(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('explorer-search')),
      '云端失败',
    );
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('workspace-search-error')),
      findsOneWidget,
    );
    expect(find.text('我的创作'), findsWidgets);
  });

  testWidgets('explicit Note Relation reuses failed keys and rotates success', (
    tester,
  ) async {
    final workspace = FakeDesktopWorkspacePort();
    final relation = _explicitNoteRelation();
    workspace.relationItems.add(relation);
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        workspace: workspace,
        subscription: FakeDesktopSubscriptionPort(),
        accountUsage: FakeDesktopAccountUsagePort(),
        demoMode: false,
      ),
    );
    await openCreationWorkspace(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('relations-panel-toggle')),
    );
    await tester.pumpAndSettle();
    final delete = find.byKey(
      const ValueKey<String>('note-relation-delete-relation-test'),
    );
    expect(delete, findsOneWidget);
    workspace.failNextRelationMutation = true;
    await tester.tap(delete);
    await tester.pumpAndSettle();
    final failedKey = workspace.relationIdempotencyKeys.single;
    expect(workspace.relationEtags.single, '"relation-test-v1"');

    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(workspace.relationIdempotencyKeys.last, failedKey);
    expect(
      find.byKey(const ValueKey<String>('note-relations-list')),
      findsOneWidget,
    );

    workspace.relationItems.add(relation);
    final relationToggle = find.byKey(
      const ValueKey<String>('relations-panel-toggle'),
    );
    tester.widget<IconButton>(relationToggle).onPressed!();
    await tester.pump();
    tester.widget<IconButton>(relationToggle).onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(workspace.relationIdempotencyKeys.last, isNot(failedKey));

    workspace.relationItems.add(relation);
    tester.widget<IconButton>(relationToggle).onPressed!();
    await tester.pump();
    tester.widget<IconButton>(relationToggle).onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('note-relation-relation-test')),
    );
    await tester.pumpAndSettle();
    expect(workspace.loadedPartRevisionIds, <String>['part-target-exact']);
    expect(
      workspace.operations.where(
        (operation) => operation.startsWith('navigation:'),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'API27 membership credits and Chat Run Usage remain independent',
    (tester) async {
      final workspace = FakeDesktopWorkspacePort();
      final account = FakeDesktopAccountUsagePort();
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(agentRunId: 'run-usage-1'),
          workspace: workspace,
          subscription: FakeDesktopSubscriptionPort(),
          accountUsage: account,
          demoMode: false,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('chat-input')),
        '记录本次用量',
      );
      await tester.tap(find.byKey(const ValueKey<String>('chat-send')));
      await tester.pumpAndSettle();
      expect(account.operations, contains('usage:run-usage-1'));

      await tester.tap(find.byKey(const ValueKey<String>('account-mode')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('pilot_paid · 可用 9000800 credits'),
        findsOneWidget,
      );
      expect(find.text('360 credits · settled'), findsOneWidget);
      expect(account.operations, contains('membership'));
      expect(
        account.operations.where(
          (operation) => operation.startsWith('credits:'),
        ),
        isNotEmpty,
      );
      expect(
        account.operations.where((operation) => operation.contains('billing')),
        isEmpty,
      );
      expect(
        workspace.operations.where(
          (operation) => operation.startsWith('navigation:'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('Knowledge Square matches the desktop visual baseline', (
    tester,
  ) async {
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        demoMode: true,
      ),
    );
    final imageContext = tester.element(
      find.byKey(const ValueKey<String>('desktop-workspace')),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/images/knowledge_square_banner.png'),
        imageContext,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-mode')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('external-knowledge-square')),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      matchesGoldenFile(
        'goldens/editor_workspace_knowledge_square_1440x900.png',
      ),
    );
  });

  testWidgets('new folders are created inside the Explorer', (tester) async {
    await pumpDesktop(tester);

    await openCreationWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey<String>('new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('new-folder-input')),
      '播客脚本',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('folder-播客脚本')), findsOneWidget);
  });

  testWidgets('desktop monologue exposes truthful audio import guidance', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(find.byKey(const ValueKey<String>('capture-mode')));
    await tester.pump();
    expect(find.text('导入独白音频'), findsOneWidget);
    expect(find.text('选择已有独白音频后会上传并开始转写；实时麦克风采集请使用移动端。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('monologue-import')),
      findsOneWidget,
    );
  });

  testWidgets('media import command opens the working audio picker surface', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('feature-command-query')),
      '媒体导入',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('feature-command-ingestion.media')),
    );
    await tester.pumpAndSettle();

    expect(find.text('导入录音音频'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('capture-media-import')),
      findsOneWidget,
    );
    expect(find.textContaining('图片和视频上传等待'), findsNothing);
  });

  testWidgets('desktop text capture creates a raw HNote asset', (tester) async {
    final rawNotes = FakeDesktopRawNoteCreator();
    await pumpDesktop(tester, rawNoteCreator: rawNotes);

    await tester.tap(find.byKey(const ValueKey<String>('capture-mode')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('capture-mode-text')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('capture-text-input')),
      '记录一个可以继续验证的表达判断。',
    );
    await tester.tap(find.byKey(const ValueKey<String>('capture-text-save')));
    await tester.pumpAndSettle();

    expect(rawNotes.requests, hasLength(1));
    expect(rawNotes.requests.single.rawMarkdown, '记录一个可以继续验证的表达判断。');
    expect(find.text('已保存为原始资产'), findsOneWidget);
  });

  testWidgets('new document title is editable', (tester) async {
    await pumpDesktop(tester);

    await openCreationWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey<String>('new-document')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(
      find.byKey(const ValueKey<String>('editor-title')),
      '桌面端创作草稿',
    );
    await tester.pump();

    expect(find.text('桌面端创作草稿'), findsWidgets);
  });

  testWidgets(
    'fixed chat submits without replacing the active creation document',
    (tester) async {
      await pumpDesktop(tester);

      await openCreationWorkspace(tester);

      await tester.enterText(
        find.byKey(const ValueKey<String>('chat-input')),
        '写一个有画面感的开头',
      );
      await tester.tap(find.byKey(const ValueKey<String>('chat-send')));
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.byKey(const ValueKey<String>('chat-to-creation')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);
    },
  );

  testWidgets(
    'note version switcher exposes only materialized derived stages',
    (tester) async {
      await pumpDesktop(tester);
      await openCreationWorkspace(tester);

      expect(
        find.byKey(
          const ValueKey<String>('note-version-switcher-city-running-script'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey<String>('note-expand-city-running-script')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('note-stage-city-running-script-summary'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(
          const ValueKey<String>('note-stage-city-running-script-sprout'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(
          const ValueKey<String>('note-stage-interview-outline-summary'),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(
          const ValueKey<String>('note-stage-interview-outline-sprout'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('note-version-switcher-welcome-draft'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('note-stage-welcome-draft-summary')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('note-stage-welcome-draft-sprout')),
        findsNothing,
      );
    },
  );

  testWidgets('opening a derived note stage preserves an independent raw tab', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await openCreationWorkspace(tester);

    await tester.tap(
      find
          .byKey(const ValueKey<String>('note-document-city-running-script'))
          .first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      find.byKey(
        const ValueKey<String>('tab-document-city-running-script-raw'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find
          .byKey(
            const ValueKey<String>(
              'add-note-stage-context-city-running-script-summary',
            ),
          )
          .first,
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('chat-context-tags')),
      const Offset(-480, 0),
    );
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>(
          'remove-chat-context-document-city-running-script-summary',
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find
          .byKey(
            const ValueKey<String>('note-stage-city-running-script-summary'),
          )
          .first,
    );
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>('tab-document-city-running-script-raw'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('tab-document-city-running-script-summary'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('note-stage-reader-summary')),
      findsOneWidget,
    );
  });

  testWidgets('wide document editor keeps a live Markdown companion', (
    tester,
  ) async {
    await pumpDesktop(tester, viewport: const Size(2100, 900));
    await openCreationWorkspace(tester);

    expect(
      find.byKey(const ValueKey<String>('markdown-live-writing-split')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-live-companion')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('markdown-native-companion'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('markdown-preview-toggle')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('markdown-preview-workspace-raw')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('markdown-live-companion')),
      findsNothing,
    );
  });

  testWidgets('document toolbar enters reading focus and AI annotations', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await openCreationWorkspace(tester);

    expect(
      find.byKey(const ValueKey<String>('markdown-live-companion')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('markdown-preview-toggle')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('markdown-preview-workspace-raw')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('markdown-preview-toggle')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('ai-annotations-toggle')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('ai-annotations-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('generate-sprout-insight')),
      findsOneWidget,
    );
    final unavailableButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('generate-sprout-insight')),
    );
    expect(unavailableButton.onPressed, isNull);
    expect(
      find.byKey(const ValueKey<String>('sprout-feature-status')),
      findsOneWidget,
    );
  });

  testWidgets(
    'editor Sprout uses File-Agent and reads its exact server revision',
    (tester) async {
      final catalog = FakeDesktopCatalogPort();
      final documents = FakeDesktopDocumentSyncPort();
      final workspace = FakeDesktopWorkspacePort();
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: documents,
          chat: FakeDesktopChatPort(),
          workspace: workspace,
          catalog: catalog,
          subscription: FakeDesktopSubscriptionPort(),
          demoMode: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      await openCreationWorkspace(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-annotations-toggle')),
      );
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey<String>('generate-sprout-insight')),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(
        find.byKey(const ValueKey<String>('generate-sprout-insight')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(catalog.createdFileAgentRuns, hasLength(1));
      final request = catalog.createdFileAgentRuns.single;
      expect(request.agentProfileId, 'faya_germination');
      expect(request.skillProfileIds, <String>['viewpoint_germination']);
      expect(request.noteId, 'note-welcome-draft');
      expect(request.inputPart, 'raw');
      expect(request.inputPartRevisionId, 'raw-revision');
      expect(request.targetPart, 'germination');
      expect(request.targetPartRevisionId, 'germination-revision');
      expect(request.instruction, isNot(contains('/Users/')));
      expect(
        workspace.loadedPartRevisionIds,
        contains('germination-revision-output'),
      );
      expect(
        documents.snapshots.last.sproutMarkdown,
        '# 云端精确版本\n\ngermination-revision-output',
      );
      expect(
        find.byKey(const ValueKey<String>('note-stage-reader-sprout')),
        findsOneWidget,
      );
      expect(find.text('发芽洞见已生成'), findsOneWidget);
    },
  );

  testWidgets(
    'editor Agent action leaves Skill installation admission to the server',
    (tester) async {
      final catalog = FakeDesktopCatalogPort(installationState: 'disabled');
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(),
          catalog: catalog,
          subscription: FakeDesktopSubscriptionPort(),
          demoMode: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      await openCreationWorkspace(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('ai-annotations-toggle')),
      );
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey<String>('generate-sprout-insight')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('所需 Skill 当前未启用'), findsNothing);
      expect(catalog.createdRequests, isEmpty);
      expect(catalog.createdFileAgentRuns, isEmpty);
    },
  );

  testWidgets('editor Agent rejects a stale remote document binding', (
    tester,
  ) async {
    final catalog = FakeDesktopCatalogPort();
    final documents = FakeDesktopDocumentSyncPort()..remoteLocalRevision = 7;
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: documents,
        chat: FakeDesktopChatPort(),
        catalog: catalog,
        subscription: FakeDesktopSubscriptionPort(),
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await openCreationWorkspace(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('ai-annotations-toggle')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('generate-sprout-insight')),
    );
    await tester.pump();

    expect(find.text('当前文稿还有未同步修改'), findsOneWidget);
    expect(catalog.createdRequests, isEmpty);
    expect(catalog.createdFileAgentRuns, isEmpty);
  });

  testWidgets('document views stay single-line and expose writing tools', (
    tester,
  ) async {
    await pumpDesktop(tester);
    await openCreationWorkspace(tester);

    expect(
      find.byKey(const ValueKey<String>('document-workspace-tabs')),
      findsOneWidget,
    );
    for (final key in <String>[
      'editor-format-heading',
      'editor-format-bold',
      'editor-format-underline',
      'editor-format-ordered-list',
      'editor-format-quote',
      'editor-format-code-block',
      'editor-format-link',
      'editor-format-image',
    ]) {
      expect(find.byKey(ValueKey<String>(key)), findsOneWidget);
    }

    final writingLabel = tester.widget<Text>(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('document-workspace-tab-writing'),
        ),
        matching: find.text('写作'),
      ),
    );
    expect(writingLabel.maxLines, 1);
    expect(writingLabel.softWrap, isFalse);

    await tester.tap(
      find.byKey(const ValueKey<String>('document-workspace-tab-outline')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('document-outline-workspace')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('document-workspace-tab-references')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('document-references-workspace')),
      findsOneWidget,
    );
  });

  testWidgets('document toolbar adapts to a constrained editor canvas', (
    tester,
  ) async {
    await pumpDesktop(tester, viewport: const Size(1304, 754));
    await openCreationWorkspace(tester);

    final tabs = tester.widget<SizedBox>(
      find.byKey(const ValueKey<String>('document-workspace-tabs')),
    );
    expect(tabs.width, 138);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fixed chat rail keeps dynamic focus separate from removable manual context tags',
    (tester) async {
      await pumpDesktop(tester);

      expect(find.byKey(const ValueKey<String>('chat-mode')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('fixed-chat-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('knowledge-graph')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-add')),
        findsOneWidget,
      );
      await openCreationWorkspace(tester);
      await tester.pump();

      final focusDocument = find.byKey(
        const ValueKey<String>('chat-context-focus-document'),
      );
      expect(focusDocument, findsOneWidget);
      expect(
        find.descendant(of: focusDocument, matching: find.text('未命名文稿 · 原始内容')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('chat-context-add')));
      await tester.pumpAndSettle();
      final cityRawCandidate = find.descendant(
        of: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
      );
      expect(cityRawCandidate, findsOneWidget);
      await tester.tap(cityRawCandidate);
      await tester.pump();

      final removeCity = find.byKey(
        const ValueKey<String>(
          'remove-chat-context-document-city-running-script-raw',
        ),
      );
      expect(removeCity, findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      tester.widget<IconButton>(removeCity).onPressed!();
      await tester.pump();
      expect(removeCity, findsNothing);
      expect(focusDocument, findsOneWidget);
    },
  );

  testWidgets(
    'chat rail can collapse and reopen without losing dynamic focus',
    (tester) async {
      await pumpDesktop(tester);
      await openCreationWorkspace(tester);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-rail-collapse')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('fixed-chat-panel')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('collapsed-chat-rail')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('chat-rail-expand')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('fixed-chat-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-focus-document')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'opening a note from the Explorer replaces the dynamic document context slot',
    (tester) async {
      await pumpDesktop(tester);

      await openCreationWorkspace(tester);
      await tester.tap(find.text('短视频脚本：城市夜跑').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-focus-document')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('chat-context-focus-document')),
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'graph selection replaces the dynamic document slot without a confirmation toast',
    (tester) async {
      await pumpDesktop(tester);
      const cityNode = DesktopGraphSelection(
        id: 'document-city-running-script',
        label: '短视频脚本：城市夜跑',
        isBrain: false,
      );
      const interviewNode = DesktopGraphSelection(
        id: 'document-interview-outline',
        label: '产品访谈提纲',
        isBrain: false,
      );
      final graph = graphWidget(tester);
      final focusDocument = find.byKey(
        const ValueKey<String>('chat-context-focus-document'),
      );

      graph.onSelectionChanged(cityNode);
      await tester.pump();
      expect(
        find.descendant(
          of: focusDocument,
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );

      graph.onSelectionChanged(interviewNode);
      await tester.pump();
      expect(
        find.descendant(
          of: focusDocument,
          matching: find.text('产品访谈提纲 · 原始内容'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('clear-chat-context-focus-document')),
      );
      await tester.pump();
      expect(
        find.descendant(of: focusDocument, matching: find.text('当前文稿')),
        findsOneWidget,
      );

      graph.onSelectionChanged(cityNode);
      await tester.pump();
      expect(
        find.descendant(
          of: focusDocument,
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>(
            'remove-chat-context-document-city-running-script-raw',
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'graph and document selections share the same dynamic document slot',
    (tester) async {
      await pumpDesktop(tester);
      const cityNode = DesktopGraphSelection(
        id: 'document-city-running-script',
        label: '短视频脚本：城市夜跑',
        isBrain: false,
      );
      final graph = graphWidget(tester);

      graph.onSelectionChanged(cityNode);
      await tester.pump();
      graph.onOpenDocument('city-running-script');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-context-focus-document')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('chat-context-focus-document')),
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );
      final contextRemoveButtons = find.descendant(
        of: find.byKey(const ValueKey<String>('chat-context-tags')),
        matching: find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '移除上下文',
        ),
      );
      expect(contextRemoveButtons, findsNothing);
    },
  );

  testWidgets(
    'a selected paragraph updates its own dynamic slot without displacing the document',
    (tester) async {
      await pumpDesktop(tester);
      graphWidget(tester).onOpenDocument('city-running-script');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      final focusDocument = find.byKey(
        const ValueKey<String>('chat-context-focus-document'),
      );
      final focusSelection = find.byKey(
        const ValueKey<String>('chat-context-focus-selection'),
      );
      final editor = tester.widget<QuillEditor>(
        find.byKey(const ValueKey<String>('editor-body')),
      );
      editor.controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 8),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.pump();

      expect(focusDocument, findsOneWidget);
      expect(focusSelection, findsOneWidget);
      expect(
        find.descendant(
          of: focusDocument,
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: focusSelection,
          matching: find.textContaining('夜色落下以后'),
        ),
        findsOneWidget,
      );

      editor.controller.replaceText(
        0,
        0,
        '更',
        const TextSelection.collapsed(offset: 1),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.descendant(
          of: focusDocument,
          matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: focusSelection,
          matching: find.textContaining('更夜色落下以后'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'remove-chat-context-paragraph-city-running-script-0',
          ),
        ),
        findsNothing,
      );
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('chat answer transfers into the active free-creation document', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-input')),
      '把访谈主题整理成文章提纲',
    );
    await tester.tap(find.byKey(const ValueKey<String>('chat-send')));
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.byKey(const ValueKey<String>('chat-to-creation')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('chat-to-creation')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('editor-body')), findsOneWidget);
    expect(find.text('已转到创作空间'), findsOneWidget);
  });

  testWidgets('history keeps its public Agent label and next-turn Profile', (
    tester,
  ) async {
    final chat = FakeDesktopChatPort(
      thread: const DesktopChatThread(threadId: 'visual-thread', title: '视觉方案'),
      detailThread: const DesktopChatThread(
        threadId: 'visual-thread',
        title: '视觉方案',
        agentProfileId: 'visual_chat',
      ),
    );
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: chat,
        demoMode: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('视觉设计'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('chat-thread-picker')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey<String>(
                'desktop-chat-history-agent-visual-thread',
              ),
            ),
          )
          .data,
      '视觉设计',
    );
    await tester.tap(find.text('视觉方案'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-input')),
      '继续完善画面',
    );
    await tester.tap(find.byKey(const ValueKey<String>('chat-send')));
    await tester.pump();

    expect(chat.lastAgentProfileId, 'visual_chat');
  });

  testWidgets(
    'new chat clears manual tags while retaining current dynamic focus',
    (tester) async {
      await pumpDesktop(tester);
      await openCreationWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey<String>('chat-context-add')));
      await tester.pumpAndSettle();
      final cityRawCandidate = find.descendant(
        of: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        matching: find.text('短视频脚本：城市夜跑 · 原始内容'),
      );
      expect(cityRawCandidate, findsOneWidget);
      await tester.tap(cityRawCandidate);
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey<String>(
            'remove-chat-context-document-city-running-script-raw',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('new-chat')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('chat-context-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-add')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-context-focus-document')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'remove-chat-context-document-city-running-script-raw',
          ),
        ),
        findsNothing,
      );
      expect(find.text('这是一个新对话。把正在思考的问题发给我就可以。'), findsOneWidget);
    },
  );

  testWidgets(
    'fixed chat keeps an unfinished prompt while navigating to creation',
    (tester) async {
      await pumpDesktop(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('chat-input')),
        '聊天草稿',
      );

      await tester.tap(find.byKey(const ValueKey<String>('creation-mode')));
      await tester.pump();

      final input = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('chat-input')),
      );
      expect(input.controller!.text, '聊天草稿');
    },
  );

  testWidgets('account and settings expose complete functional surfaces', (
    tester,
  ) async {
    await pumpDesktop(tester);

    await tester.tap(find.byKey(const ValueKey<String>('account-mode')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('account-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('account-sign-out')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('account-sign-out')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('account-sign-in')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('settings-mode')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('settings-workspace')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('settings-palette-forest')),
    );
    await tester.pump();
    await tester.tap(find.text('图谱').last);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('graph-node-scale')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('graph-attraction-scale')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('graph-repulsion-scale')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('graph-damping-scale')),
      findsOneWidget,
    );
    expect(find.text('实时力场预览'), findsOneWidget);
    await tester.tap(find.text('写作').last);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('settings-auto-save')),
      findsOneWidget,
    );
    final noteDrafts = find.byKey(
      const ValueKey<String>('settings-note-drafts'),
    );
    expect(noteDrafts, findsOneWidget);
    expect(tester.widget<SwitchListTile>(noteDrafts).value, isTrue);
    await tester.tap(noteDrafts);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(noteDrafts).value, isFalse);
  });

  testWidgets('account nickname is saved through the injected profile port', (
    tester,
  ) async {
    final auth = FakeDesktopAuthPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: auth,
        assets: const FakeDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: FakeDesktopChatPort(),
        demoMode: false,
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('account-mode')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('account-edit-profile')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('account-name-input')),
      '桌面端昵称',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(auth.profile.displayName, '桌面端昵称');
    expect(find.text('桌面端昵称'), findsOneWidget);
  });

  testWidgets('sign out clears the document account binding', (tester) async {
    final documents = FakeDesktopDocumentSyncPort();
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: FakeDesktopAuthPort(),
        assets: const FakeDesktopAssetsPort(),
        documents: documents,
        chat: FakeDesktopChatPort(),
        demoMode: false,
      ),
    );
    await tester.pump();
    expect(documents.workspaceId, 'workspace-test');
    expect(documents.operations.take(3), <String>['bind', 'pull', 'flush']);
    expect(documents.snapshots, isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('account-mode')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('account-sign-out')));
    await tester.pump();

    expect(documents.workspaceId, isNull);
    expect(
      find.byKey(const ValueKey<String>('account-sign-in')),
      findsOneWidget,
    );
  });

  testWidgets('unconfigured remote services require sign-in before chat', (
    tester,
  ) async {
    await pumpDesktop(
      tester,
      services: DesktopServices(
        auth: const UnavailableDesktopAuthPort(),
        assets: const UnavailableDesktopAssetsPort(),
        documents: FakeDesktopDocumentSyncPort(),
        chat: const UnavailableDesktopChatPort(),
        demoMode: false,
      ),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey<String>('chat-input')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey<String>('chat-send')))
          .onPressed,
      isNull,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-to-creation')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('remote-assets-unavailable')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-assets-retry')));
    await tester.pump();
    expect(find.text('未配置后端，云端资产暂不可用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('account-mode')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('account-sign-in')),
      findsOneWidget,
    );
    expect(find.text('未配置后端，账号登录暂不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('account-sign-in')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('account-sign-in-input')),
      '13800000000',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('account-send-sms-code')),
    );
    await tester.pumpAndSettle();
    expect(find.text('未配置后端，无法发送验证码'), findsOneWidget);
  });

  testWidgets(
    'Workspace Book opens ordered Sections and exact Part revisions',
    (tester) async {
      final bookWork = FakeDesktopBookWorkPort();
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(),
          subscription: FakeDesktopSubscriptionPort(),
          bookWork: bookWork,
          demoMode: false,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('assets-mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-open-book')),
      );
      await tester.pumpAndSettle();

      final preface = find.byKey(
        const ValueKey<String>('book-work-section-preface'),
      );
      final chapter = find.byKey(
        const ValueKey<String>('book-work-section-chapter_1'),
      );
      expect(
        tester.getTopLeft(preface).dy,
        lessThan(tester.getTopLeft(chapter).dy),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-section-preface-raw')),
      );
      await tester.pumpAndSettle();
      expect(bookWork.lastBookPartRevisionId, 'book-preface-raw-1');
      expect(
        find.byKey(const ValueKey<String>('remote-asset-markdown-preview')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'creation history opens exact Work Part and retains mutation retry key',
    (tester) async {
      final bookWork = FakeDesktopBookWorkPort()..completeFailureCount = 1;
      await pumpDesktop(
        tester,
        services: DesktopServices(
          auth: FakeDesktopAuthPort(),
          assets: const FakeDesktopAssetsPort(),
          documents: FakeDesktopDocumentSyncPort(),
          chat: FakeDesktopChatPort(),
          subscription: FakeDesktopSubscriptionPort(),
          bookWork: bookWork,
          demoMode: false,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('tools-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创作历史').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-item-work-test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('book-work-detail-work-test-outline'),
        ),
      );
      await tester.pumpAndSettle();
      expect(bookWork.lastWorkPartRevisionId, 'work-outline-1');

      await tester.tap(find.byKey(const ValueKey<String>('tools-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创作历史').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-item-work-test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-complete')),
      );
      await tester.pumpAndSettle();
      final retryKey = bookWork.idempotencyKeys.single;
      await tester.tap(
        find.byKey(const ValueKey<String>('book-work-complete')),
      );
      await tester.pumpAndSettle();

      expect(bookWork.idempotencyKeys.take(2), <String>[retryKey, retryKey]);
      expect(bookWork.etags.take(2), <String>['"work-1"', '"work-1"']);
      expect(bookWork.operations.join(), isNot(contains('work-ai')));
      expect(bookWork.operations.join(), isNot(contains('feed-ai')));
    },
  );

  testWidgets('desktop workspace matches the visual baseline', (tester) async {
    await pumpDesktop(tester);
    await tester.pump(const Duration(milliseconds: 80));

    await expectLater(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      matchesGoldenFile('goldens/editor_workspace_1440x900.png'),
    );
  });

  testWidgets('fixed chat rail matches the visual baseline', (tester) async {
    await pumpDesktop(tester);
    await openCreationWorkspace(tester);
    await tester.tap(
      find
          .byKey(const ValueKey<String>('add-note-context-welcome-draft'))
          .first,
    );
    final workspaceContext = tester.element(
      find.byKey(const ValueKey<String>('desktop-workspace')),
    );
    await tester.runAsync<void>(
      () => Future.wait<void>([
        precacheImage(
          const AssetImage('assets/images/huahuo_brand_mark.png'),
          workspaceContext,
        ),
        precacheImage(
          const AssetImage('assets/images/chat_brand_mark.png'),
          workspaceContext,
        ),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 80));

    await expectLater(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      matchesGoldenFile('goldens/editor_workspace_chat_1440x900.png'),
    );
  });

  testWidgets('dark workspace matches the visual baseline', (tester) async {
    await pumpDesktop(tester, themeMode: ThemeMode.dark);
    await tester.pump(const Duration(milliseconds: 80));

    await expectLater(
      find.byKey(const ValueKey<String>('desktop-workspace')),
      matchesGoldenFile('goldens/editor_workspace_dark_1440x900.png'),
    );
  });
}

SharedWorkspaceSearchOutput _workspaceSearchOutput({
  required String title,
  required String noteId,
  required String revisionId,
}) => SharedWorkspaceSearchOutput(
  mode: 'keyword',
  queryFingerprint: 'fingerprint-$noteId',
  keywordReadiness: 'current',
  vectorReadiness: 'unavailable',
  contentCursor: '12',
  results: <SharedWorkspaceSearchResult>[
    SharedWorkspaceSearchResult(
      ownerRef: SharedWorkspaceOwnerRef(
        workspaceId: 'workspace-test',
        kind: 'hnote',
        id: noteId,
      ),
      revisionId: revisionId,
      part: 'raw',
      path: 'notes/$noteId/parts/raw',
      title: title,
      updatedAt: DateTime.utc(2026, 8, 7),
      matchMode: 'keyword',
      score: 0.9,
      staleSource: false,
    ),
  ],
);

SharedExplicitNoteRelation _explicitNoteRelation() =>
    SharedExplicitNoteRelation(
      relationId: 'relation-test',
      relationType: 'supports',
      source: SharedNotePartSourceRef(
        noteId: 'note-welcome-draft',
        part: 'raw',
        partRevisionId: 'part-source-exact',
      ),
      target: SharedNotePartSourceRef(
        noteId: 'note-target',
        part: 'outline',
        partRevisionId: 'part-target-exact',
      ),
      rationale: '目标笔记提供事实支持',
      version: 1,
      etag: '"relation-test-v1"',
    );

Future<ByteData> _loadPackageFile(
  String packageName,
  String relativePath,
) async {
  var directory = Directory.current.absolute;
  File? packageConfig;
  while (true) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}package_config.json',
    );
    if (candidate.existsSync()) {
      packageConfig = candidate;
      break;
    }
    if (directory.parent.path == directory.path) break;
    directory = directory.parent;
  }
  if (packageConfig == null) {
    throw StateError('Cannot find package_config.json');
  }
  final decoded = jsonDecode(await packageConfig.readAsString());
  final packages = (decoded as Map<String, Object?>)['packages'];
  if (packages is! List) throw const FormatException('Invalid package config');
  final entry = packages.cast<Map<String, Object?>>().firstWhere(
    (item) => item['name'] == packageName,
  );
  final rootUri = Uri.parse(entry['rootUri']! as String);
  final packageRoot = rootUri.isAbsolute
      ? rootUri
      : packageConfig.parent.uri.resolveUri(rootUri);
  final packageDirectory = Directory.fromUri(packageRoot);
  final bytes = await File.fromUri(
    packageDirectory.uri.resolve(relativePath),
  ).readAsBytes();
  return ByteData.sublistView(bytes);
}

final class _FixedDesktopTopicsPort implements DesktopTopicsPort {
  _FixedDesktopTopicsPort([this.run = _runningTopicCollisionRun]);

  int createCalls = 0;

  final TopicCollisionRun run;

  static const _runningTopicCollisionRun = TopicCollisionRun(
    topicCollisionRunId: 'desktop-collision-running',
    status: 'running',
    selectedNoteCount: 4,
    sources: <TopicCollisionSource>[
      TopicCollisionSource(inputRef: 'note-01', title: '来源笔记 1'),
      TopicCollisionSource(inputRef: 'note-02', title: '来源笔记 2'),
      TopicCollisionSource(inputRef: 'note-03', title: '来源笔记 3'),
      TopicCollisionSource(inputRef: 'note-04', title: '来源笔记 4'),
    ],
  );

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> createTopicCollision(
    String workspaceId, {
    required String idempotencyKey,
  }) async {
    createCalls += 1;
    return DesktopServiceResult<TopicCollisionRun>.success(run);
  }

  @override
  Future<DesktopServiceResult<TopicCollisionRun>> getTopicCollision(
    String workspaceId,
    String runId,
  ) async => DesktopServiceResult<TopicCollisionRun>.success(run);

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> dismissDailyTopic(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _dailyUnavailable<DailyTopicRecommendation>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> getDailyTopic(
    String workspaceId,
    String recommendationId,
  ) async => _dailyUnavailable<DailyTopicRecommendation>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendationPage>> listDailyTopics(
    String workspaceId,
  ) async => _dailyUnavailable<DailyTopicRecommendationPage>();

  @override
  Future<DesktopServiceResult<DailyTopicRecommendation>> markDailyTopicRead(
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
}

final class _FakeActivityCalendarPort implements DesktopActivityCalendarPort {
  final List<String> workspaceIds = <String>[];

  @override
  Future<DesktopServiceResult<WorkspaceNoteMetricsPage>> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  }) async {
    workspaceIds.add(workspaceId);
    return DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
      WorkspaceNoteMetricsPage(
        schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
        metricId: 'new_note_count',
        timezone: 'Asia/Shanghai',
        asOf: DateTime.utc(2026, 9, 3),
        coverage: WorkspaceNoteMetricsCoverage(
          startAt: DateTime.utc(2026, 9, 3),
          startDate: '2026-09-03',
          completeFromDate: '2026-09-03',
          currentDate: '2026-09-03',
          historyComplete: true,
        ),
        days: const <WorkspaceNoteMetricDay>[
          WorkspaceNoteMetricDay(date: '2026-09-03', count: 6, complete: true),
        ],
        hasMore: false,
        nextCursor: '',
      ),
    );
  }
}

final class _EditorWorkspaceManagementRepository
    implements WorkspaceManagementRepository {
  int listCalls = 0;

  @override
  Future<ProductResult<List<ProductWorkspace>>> list() async {
    listCalls++;
    return const ProductResult<List<ProductWorkspace>>.success(
      <ProductWorkspace>[
        ProductWorkspace(
          workspaceId: 'workspace-test',
          displayName: '桌面工作空间',
          state: 'ready',
          isDefault: true,
          etag: '"workspace-test-v1"',
        ),
      ],
    );
  }

  @override
  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) async => const ProductResult<ProductWorkspaceBootstrap>.failure(
    code: 'TEST_NOT_USED',
    message: '测试未调用',
  );

  @override
  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async => _unusedWorkspaceMutation();

  @override
  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _unusedWorkspaceMutation();

  @override
  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _unusedWorkspaceMutation();

  @override
  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _unusedWorkspaceMutation();
}

ProductResult<ProductWorkspace> _unusedWorkspaceMutation() =>
    const ProductResult<ProductWorkspace>.failure(
      code: 'TEST_NOT_USED',
      message: '测试未调用',
    );

final class _EditorHomeRepository implements ProductHomeRepository {
  final List<String> workspaceIds = <String>[];

  @override
  Future<ProductResult<ProductHome>> load(String workspaceId) async {
    workspaceIds.add(workspaceId);
    return ProductResult<ProductHome>.success(
      ProductHome(
        action: const ProductHomeAction(
          type: ProductHomeActionType.uploadRecording,
          label: 'Upload recording',
        ),
        suggestion: null,
        runningTaskCount: 0,
        recordingCount: 6,
        depositedRecordingCount: 3,
        availableGenerationCredits: 72,
        redDotCount: 0,
        serverTime: DateTime.utc(2026, 9, 3, 3),
      ),
    );
  }

  @override
  Future<ProductResult<void>> markSuggestionViewed({
    required String workspaceId,
    required String suggestionId,
    required String idempotencyKey,
  }) async => const ProductResult<void>.success(null);
}

final class _EditorRecordingRepository implements ProductRecordingsRepository {
  final workspaceIds = <String>[];

  @override
  Future<ProductResult<List<ProductRecording>>> list(String workspaceId) async {
    workspaceIds.add(workspaceId);
    return const ProductResult<List<ProductRecording>>.success([]);
  }

  @override
  Future<ProductResult<ProductRecordingDetail>> detail(
    String recordingId,
  ) async => const ProductResult<ProductRecordingDetail>.failure(
    code: 'UNUSED',
    message: 'unused',
  );

  @override
  Future<ProductResult<ProductSpeakerPanel>> speakerPanel(
    String recordingId,
  ) async => const ProductResult<ProductSpeakerPanel>.failure(
    code: 'UNUSED',
    message: 'unused',
  );

  @override
  Future<ProductResult<void>> retryStage({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async =>
      const ProductResult<void>.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<void>> saveSpeakerDraft({
    required String recordingId,
    required Map<String, String> names,
    required String? selfSpeakerId,
    required String idempotencyKey,
  }) async =>
      const ProductResult<void>.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<void>> submitSpeakerLabels({
    required String recordingId,
    required int baseAsrTaskVersion,
    required Map<String, String> names,
    required String selfSpeakerId,
    required String idempotencyKey,
  }) async =>
      const ProductResult<void>.failure(code: 'UNUSED', message: 'unused');
}

final class _EditorCreationRepository implements ProductCreationsRepository {
  final workspaceIds = <String>[];

  @override
  Future<ProductResult<List<ProductCreationSummary>>> list(
    String workspaceId,
  ) async {
    workspaceIds.add(workspaceId);
    return ProductResult.success([_editorCreationDocument.summary]);
  }

  @override
  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  ) async => ProductResult.success(_editorCreationDocument);

  @override
  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  }) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  }) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');
}

final class _EditorProposalRepository
    implements ProductDocumentProposalsRepository {
  final workspaceIds = <String>[];
  final ownerIds = <String?>[];
  final rawPartRevisionIds = <String>[];

  ProductResult<T> _unused<T>() =>
      const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async {
    workspaceIds.add(workspaceId);
    ownerIds.add(ownerId);
    return ProductResult.success(ProductDocumentProposalPage(items: const []));
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async {
    rawPartRevisionIds.add(creation.rawPartRevisionId);
    return _unused();
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();

  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) async => _unused();

  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();

  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async => _unused();

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async => _unused();

  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async => _unused();
}

final _editorCreationDocument = ProductCreationDocument(
  summary: ProductCreationSummary(
    id: 'creation-desktop',
    title: '云端创作',
    lifecycle: 'active',
    revisionId: 'creation-revision-1',
    revision: 1,
    partRevisionIds: const {'raw': 'raw-revision-1'},
    etag: 'etag-1',
  ),
  rawMarkdown: '# 云端正文',
  rawPartRevisionId: 'raw-revision-1',
  rawPartEtag: 'part-etag-1',
);

final class _EditorSupportRepository implements ProductSupportRepository {
  int catalogLoads = 0;

  @override
  Future<ProductResult<ProductSupportCatalog>> loadCatalog() async {
    catalogLoads++;
    return ProductResult.success(
      ProductSupportCatalog(
        contentVersion: '2026.09.03',
        locale: 'zh-CN',
        categories: const [
          ProductSupportCategory(
            id: 'desktop',
            title: '桌面端',
            summary: '桌面端帮助',
            order: 0,
          ),
        ],
        articles: [
          ProductSupportArticleSummary(
            id: 'desktop-help',
            title: '桌面帮助',
            summary: '桌面端使用指南',
            categoryId: 'desktop',
            order: 0,
            tags: const ['桌面'],
          ),
        ],
      ),
    );
  }

  @override
  Future<ProductResult<ProductSupportArticle>> loadArticle(
    String articleId,
  ) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');

  @override
  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  ) async => const ProductResult.failure(code: 'UNUSED', message: 'unused');
}

const _failedTopicCollisionRun = TopicCollisionRun(
  topicCollisionRunId: 'desktop-collision-failed',
  status: 'failed',
  selectedNoteCount: 4,
  sources: <TopicCollisionSource>[
    TopicCollisionSource(inputRef: 'note-01', title: '来源笔记 1'),
    TopicCollisionSource(inputRef: 'note-02', title: '来源笔记 2'),
    TopicCollisionSource(inputRef: 'note-03', title: '来源笔记 3'),
    TopicCollisionSource(inputRef: 'note-04', title: '来源笔记 4'),
  ],
  failureCode: 'TOPIC_COLLISION_MODEL_FAILED',
);

DesktopServiceResult<T> _dailyUnavailable<T>() =>
    DesktopServiceResult<T>.unavailable(
      code: 'DAILY_TOPIC_SERVICE_UNAVAILABLE',
      message: '每日推荐服务暂不可用',
    );

final class _MemoryDocumentStore implements DocumentStore {
  _MemoryDocumentStore([
    Iterable<HuahuoDocumentSnapshot> documents =
        const <HuahuoDocumentSnapshot>[],
  ]) : _documents = <String, HuahuoDocumentSnapshot>{
         for (final document in documents) document.id: document,
       };

  final Map<String, HuahuoDocumentSnapshot> _documents;

  @override
  Future<void> delete(String documentId) async {
    _documents.remove(documentId);
  }

  @override
  Future<List<HuahuoDocumentSnapshot>> loadAll() async =>
      _documents.values.toList(growable: false);

  @override
  Future<void> save(HuahuoDocumentSnapshot snapshot) async {
    _documents[snapshot.id] = snapshot;
  }
}

final class _FakeWindowController implements DesktopWindowController {
  final Set<VoidCallback> _listeners = <VoidCallback>{};
  bool maximized = false;
  int dragCount = 0;
  int minimizeCount = 0;
  int maximizeCount = 0;
  int unmaximizeCount = 0;
  int closeCount = 0;

  @override
  void addStateListener(VoidCallback listener) => _listeners.add(listener);

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  void dispose() => _listeners.clear();

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> maximize() async {
    maximizeCount++;
    maximized = true;
    _notify();
  }

  @override
  Future<void> minimize() async {
    minimizeCount++;
  }

  @override
  void removeStateListener(VoidCallback listener) =>
      _listeners.remove(listener);

  @override
  Future<void> startDragging() async {
    dragCount++;
  }

  @override
  Future<void> unmaximize() async {
    unmaximizeCount++;
    maximized = false;
    _notify();
  }

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}
