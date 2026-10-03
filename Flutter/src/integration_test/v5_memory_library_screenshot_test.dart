import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_activity_models.dart';
import 'package:integration_test/integration_test.dart';

const _nativeFileChannel = MethodChannel('huahuoai/native_file');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures the 10-week activity heatmap', (tester) async {
    await _launchFeed(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 450));

    expect(find.text('活跃热力图'), findsOneWidget);
    expect(find.text('时间（周）'), findsOneWidget);
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    final screenshot = await binding.takeScreenshot(
      'v5_profile_weekly_heatmap_actual',
    );
    expect(screenshot, isNotEmpty);

    final day = v3TrailingNaturalWeekStarts(referenceDay: DateTime.now()).last;
    final dateKey =
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    await tester.tap(
      find.byKey(ValueKey<String>('profile-heatmap-cell-$dateKey')),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 350));
    expect(find.text('每天沉淀的内容行为'), findsOneWidget);
  });

  testWidgets('captures a document import synchronized to the graph', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('huahuo-v3-');
    final source = File('${directory.path}/integration-memory.txt');
    await source.writeAsString('A local document should appear in memory.');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_nativeFileChannel, (call) async {
      if (call.method != 'pickDocumentFiles') return null;
      return <Map<String, Object>>[
        <String, Object>{
          'displayName': 'integration-memory.txt',
          'sizeBytes': await source.length(),
          'sourcePath': source.path,
          'mimeType': 'text/plain',
          'sourceIdentifier': 'integration-memory',
        },
      ];
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(_nativeFileChannel, null);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await _launchFeed(tester);
    GoRouter.of(
      tester.element(find.byType(Navigator).first),
    ).push('/v3/feed/import');
    await _waitWithFrames(tester, const Duration(milliseconds: 350));
    expect(find.text('导入'), findsOneWidget);
    await tester.tap(find.text('本地文档导入').hitTestable());
    await _waitWithFrames(tester, const Duration(milliseconds: 350));
    expect(find.text('导入资料'), findsOneWidget);

    await tester.tap(find.text('选择文件并导入'));
    await _waitWithFrames(tester, const Duration(milliseconds: 600));
    expect(find.textContaining('已导入 1 条记忆笔记'), findsOneWidget);
    final importContainer = ProviderScope.containerOf(
      tester.element(find.text('导入资料').first),
    );
    final importedNote = importContainer
        .read(v3DocumentImportControllerProvider)
        .state
        .importedNotes
        .single;
    expect(
      importContainer
          .read(knowledgeLibraryControllerProvider)
          .noteForId(importedNote.id),
      isNotNull,
    );
    expect(
      importContainer
          .read(feedGraphControllerProvider)
          .nodes
          .any((node) => node.id == importedNote.id),
      isTrue,
    );
    final importScreenshot = await binding.takeScreenshot(
      'v5_document_import_success_actual',
    );
    expect(importScreenshot, isNotEmpty);

    await tester.tap(find.text('返回 思想图谱'));
    await _waitWithFrames(tester, const Duration(milliseconds: 900));
    expect(find.text('思想图谱'), findsOneWidget);
    await tester.tap(
      find
          .byKey(const ValueKey<String>('feed-graph-search-open'))
          .hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 250));
    final graphSearch = find.byKey(
      const ValueKey<String>('feed-graph-search-input'),
    );
    expect(graphSearch, findsOneWidget);
    final feedContainer = ProviderScope.containerOf(
      tester.element(graphSearch),
    );
    expect(
      feedContainer
          .read(knowledgeLibraryControllerProvider)
          .noteForId(importedNote.id),
      isNotNull,
    );
    expect(
      feedContainer
          .read(feedGraphControllerProvider)
          .nodes
          .any((node) => node.id == importedNote.id),
      isTrue,
    );
    await tester.enterText(graphSearch, 'integration-memory');
    await _waitWithFrames(tester, const Duration(milliseconds: 300));
    expect(find.text('integration-memory.txt'), findsWidgets);
    final graphScreenshot = await binding.takeScreenshot(
      'v5_document_import_graph_sync_actual',
    );
    expect(graphScreenshot, isNotEmpty);
  });

  testWidgets('captures folder-first notes and an expanded outline', (
    tester,
  ) async {
    await _launchFeed(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-profile-menu')).hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 450));
    await tester.tap(find.text('沉淀').hitTestable());
    await _waitWithFrames(tester, const Duration(milliseconds: 450));

    expect(find.text('全部笔记'), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);
    const folderName = '截图文档';
    final search = find.byKey(
      const ValueKey<String>('knowledge-library-search'),
    );
    final container = ProviderScope.containerOf(tester.element(search));
    final library = container.read(knowledgeLibraryControllerProvider);
    for (final stale
        in library.depositFolders
            .where((candidate) => candidate.name == folderName)
            .toList(growable: false)) {
      expect(library.deleteDepositFolder(stale.id), isTrue);
    }
    await tester.pump();
    final rootScreenshot = await binding.takeScreenshot(
      'v5_memory_folder_root_actual',
    );
    expect(rootScreenshot, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey('knowledge-create-folder')).hitTestable(),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 180));
    await tester.enterText(find.byType(EditableText).last, folderName);
    await tester.tap(find.text('创建'));
    await _waitWithFrames(tester, const Duration(milliseconds: 4200));
    expect(find.text(folderName), findsOneWidget);

    final folder = library.depositFolders.singleWhere(
      (candidate) => candidate.name == folderName,
    );
    final note = library.createManualNoteDraft(
      V3NoteDraft(
        title: '访谈洞察文档',
        rawBody: '# 章节总览\n访谈背景与核心判断。\n\n## 客户证据\n客户希望先验证一个真实场景。',
      ),
    );
    expect(
      library.assignToDepositFolder(contentId: note.id, folderId: folder.id),
      isTrue,
    );
    await tester.pump();

    await tester.tap(find.byKey(ValueKey('knowledge-folder-${folder.id}')));
    await _waitWithFrames(tester, const Duration(milliseconds: 300));
    expect(find.text('访谈洞察文档'), findsOneWidget);
    final collapsed = await binding.takeScreenshot(
      'v5_memory_note_card_collapsed_actual',
    );
    expect(collapsed, isNotEmpty);

    await tester.tap(
      find.byKey(ValueKey('knowledge-stage-toggle-${note.id}-raw')),
    );
    await _waitWithFrames(tester, const Duration(milliseconds: 220));
    await tester.tap(find.byTooltip('展开章节总览'));
    await _waitWithFrames(tester, const Duration(milliseconds: 600));
    expect(find.text('客户证据'), findsOneWidget);
    final expanded = await binding.takeScreenshot(
      'v5_memory_note_outline_expanded_actual',
    );
    expect(expanded, isNotEmpty);
  });
}

Future<void> _launchFeed(WidgetTester tester) async {
  await app.main();
  await tester.pump();
  await _waitWithFrames(tester, const Duration(milliseconds: 700));
  expect(find.text('思想图谱'), findsOneWidget);
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
