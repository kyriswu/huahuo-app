import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/settings/domain/app_appearance_preset.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the PDF requirements visual acceptance set', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    await _waitFor(tester, find.text('思想图谱'));
    await _pumpFrames(tester, 12);

    final providerContext = tester.element(find.text('思想图谱'));
    final container = ProviderScope.containerOf(providerContext);
    final router = container.read(appRouterProvider);
    final graph = find.byKey(const ValueKey('feed-graph-interactive-viewer'));
    expect(graph, findsOneWidget);
    expect(find.byKey(const ValueKey('feed-graph-scene')), findsOneWidget);

    final sphere = await _capture(binding, tester, '01_ai_feed_3d');
    expect(sphere.length, greaterThan(5000));

    expect(
      container
          .read(appAppearanceControllerProvider)
          .selectPreset(AppAppearancePreset.sakura),
      isTrue,
    );
    await _pumpFrames(tester, 10);
    await _capture(binding, tester, '03_ai_feed_3d_sakura');

    expect(
      container
          .read(appAppearanceControllerProvider)
          .selectPreset(AppAppearancePreset.aurora),
      isTrue,
    );
    await _pumpFrames(tester, 10);
    await _capture(binding, tester, '04_ai_feed_3d_aurora');

    container
        .read(appAppearanceControllerProvider)
        .selectPreset(AppAppearancePreset.light);
    await _go(
      tester,
      router,
      '/v3/workbench',
      find.byKey(const ValueKey('home-workbench-surface')),
    );
    await _capture(binding, tester, '05_workbench');

    await _go(
      tester,
      router,
      '/v3/profile/knowledge?tab=subscribed',
      find.byKey(const ValueKey('knowledge-tab-subscribed')),
    );
    await _capture(binding, tester, '06_knowledge_subscribed');
    await tester.tap(
      find.byKey(const ValueKey('knowledge-tab-square')).hitTestable(),
    );
    await _pumpFrames(tester, 8);
    await _capture(binding, tester, '07_knowledge_square');

    await _go(
      tester,
      router,
      '/v3/profile/assets?page=deposited',
      find.byKey(const ValueKey('asset-tab-deposited')),
    );
    await _capture(binding, tester, '08_my_assets');

    await _go(
      tester,
      router,
      '/v3/feed/items/need?stage=raw',
      find.byKey(const ValueKey('detail-asset-label-strip')),
    );
    await _capture(binding, tester, '09_note_detail');

    await _go(
      tester,
      router,
      '/v3/feed/note/need',
      find.byKey(const ValueKey('note-save-button')),
    );
    await _capture(binding, tester, '10_note_editor');

    await _go(tester, router, '/v3/notifications', find.text('待处理消息'));
    await _capture(binding, tester, '11_pending_messages');

    final incomingFixture = await _installIncomingMaterialFixture();
    addTearDown(incomingFixture.dispose);
    await _go(
      tester,
      router,
      '/v3/feed/import/documents',
      find.text('确认导入外部文件'),
    );
    await _capture(binding, tester, '12_external_import_confirmation');
    await incomingFixture.restoreChannel();

    await _go(
      tester,
      router,
      '/v3/workbench/deep-positioning',
      find.byKey(const ValueKey('deep-positioning-level-section')),
    );
    await _capture(binding, tester, '13_deep_positioning');

    await _go(
      tester,
      router,
      '/v3/recording-card/details',
      find.text('录音卡设备详情'),
    );
    final autoSync = find.byKey(
      const ValueKey('recording-card-auto-sync-switch'),
    );
    await tester.scrollUntilVisible(
      autoSync,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 20,
    );
    await _pumpFrames(tester, 8);
    await _capture(binding, tester, '14_recording_card_auto_sync');

    await _go(
      tester,
      router,
      '/v3/profile/assets?page=knowledge',
      find.byKey(const ValueKey('knowledge-secondary-directory')),
    );
    await _capture(binding, tester, '15_assets_knowledge_directory');

    await _go(
      tester,
      router,
      '/v3/profile/assets?page=experience',
      find.byKey(const ValueKey('experience-asset-timeline')),
    );
    await _capture(binding, tester, '16_assets_experience_timeline');

    await _go(
      tester,
      router,
      '/v3/workbench/canvas',
      find.byKey(const ValueKey('canvas-body-field')),
    );
    final canvasEditor = tester.widget<QuillEditor>(
      find.byKey(const ValueKey('canvas-body-field')),
    );
    canvasEditor.controller.replaceText(
      0,
      canvasEditor.controller.document.length - 1,
      '选中一段内容后，可以从原生上下文菜单使用同一组 AI 功能。',
      const TextSelection.collapsed(offset: 12),
    );
    await _pumpFrames(tester, 6);
    await _capture(binding, tester, '17_creation_canvas_bottom_tools');
    await tester.tap(find.byKey(const ValueKey('canvas-ai-tools')));
    await _waitFor(tester, find.text('AI 创作工具'));
    await _capture(binding, tester, '18_creation_canvas_ai_tools');
    await tester.tapAt(const Offset(8, 96));
    await _pumpFrames(tester, 4);
    canvasEditor.controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 6),
      ChangeSource.local,
    );
    canvasEditor.focusNode.requestFocus();
    await _pumpFrames(tester, 3);
    final rawEditorState = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    expect(rawEditorState.showToolbar(), isTrue);
    await _pumpFrames(tester, 6);
    await _capture(binding, tester, '20_creation_canvas_selection_tools');
    for (
      var attempt = 0;
      attempt < 3 && find.text('AI 改写').evaluate().isEmpty;
      attempt++
    ) {
      final toolbar = find.byType(CupertinoTextSelectionToolbar);
      expect(toolbar, findsOneWidget);
      final pager = find.descendant(
        of: toolbar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector && widget.onHorizontalDragEnd != null,
        ),
      );
      expect(pager, findsOneWidget);
      await tester.fling(pager, const Offset(-120, 0), 1000);
      await _pumpFrames(tester, 4);
    }
    await tester.tap(find.text('AI 改写').hitTestable());
    await _waitFor(tester, find.text('AI 创作工具'));
    expect(find.text('已选择正文'), findsOneWidget);
    expect(find.text('社会关系转变'), findsOneWidget);
    await _capture(binding, tester, '21_creation_canvas_selection_ai_actions');
    Navigator.of(tester.element(find.text('AI 创作工具'))).pop();
    await _pumpFrames(tester, 4);
    expect(find.text('AI 创作工具'), findsNothing);

    await _go(
      tester,
      router,
      '/v3/workbench/deep-positioning',
      find.byKey(const ValueKey('deep-positioning-chat-entry')),
    );
    await tester.tap(find.byKey(const ValueKey('deep-positioning-chat-entry')));
    await _waitFor(tester, find.textContaining('定位对话已开启'));
    await _pumpFrames(tester, 8);
    await _capture(binding, tester, '19_deep_positioning_chat');
  });
}

Future<void> _go(
  WidgetTester tester,
  GoRouter router,
  String location,
  Finder ready,
) async {
  router.go(location);
  await tester.pump();
  await _waitFor(tester, ready);
  await _pumpFrames(tester, 8);
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  expect(finder, findsWidgets);
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<List<int>> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await _pumpFrames(tester, 4);
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty, reason: name);
  return bytes;
}

Future<_IncomingFixture> _installIncomingMaterialFixture() async {
  final directory = await Directory.systemTemp.createTemp(
    'huahuo-pdf-import-screenshot-',
  );
  final file = File('${directory.path}/外部资料.txt');
  final bytes = utf8.encode('花火 AI 外部文件确认截图资料。');
  await file.writeAsBytes(bytes, flush: true);
  final hash = sha256.convert(bytes).toString();
  const channel = MethodChannel('huahuoai/native_file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    return switch (call.method) {
      'consumeIncomingMaterials' => <Object?>[
        <String, Object?>{
          'opaqueRef': 'incoming-material://pdf-screenshot-fixture',
          'displayName': '外部资料.txt',
          'mimeType': 'text/plain',
          'sizeBytes': bytes.length,
          'sourcePath': file.path,
          'contentHash': hash,
          'sourceIdentifier': 'qa-fixture',
          'origin': 'open',
        },
      ],
      'acknowledgeIncomingMaterials' => true,
      _ => null,
    };
  });
  return _IncomingFixture(directory: directory, channel: channel);
}

final class _IncomingFixture {
  const _IncomingFixture({required this.directory, required this.channel});

  final Directory directory;
  final MethodChannel channel;

  Future<void> restoreChannel() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<void> dispose() async {
    await restoreChannel();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
