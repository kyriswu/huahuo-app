import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_deposit_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';

import '../../support/figma_golden_test_support.dart';

const _surface = Size(402, 874);

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M04 assets default', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    expect(find.bySemanticsLabel('返回'), findsOneWidget);

    await expectLater(
      find.byType(V3MyAssetsPage),
      matchesGoldenFile('goldens/m04_assets_default.png'),
    );
  });

  testWidgets('M04 folder collapsed', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await tester.tap(
      find.byKey(ValueKey('asset-folder-toggle-${fixture.inspiration.id}')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(V3MyAssetsPage),
      matchesGoldenFile('goldens/m04_assets_folder_collapsed.png'),
    );
  });

  testWidgets('M04 note drag target and move success', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);
    final note = fixture.notes.first;
    final drag = find.byKey(ValueKey('asset-note-drag-${note.id}'));
    final target = find.byKey(
      ValueKey('asset-deposit-folder-${fixture.product.id}'),
    );
    final gesture = await tester.startGesture(tester.getCenter(drag));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 180));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_note_drag.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      fixture.controller.depositRecordFor(note.id)?.folderId,
      fixture.product.id,
    );
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_note_moved.png'),
    );
  });

  testWidgets('M04 note actions', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openNoteActions(tester, fixture.notes.first.title);
    expect(find.text('创建副本'), findsOneWidget);
    expect(find.text('编辑内容'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_note_actions.png'),
    );
  });

  testWidgets('M04 new folder', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await tester.tap(find.byKey(const ValueKey('asset-create-deposit-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('asset-deposit-folder-name')),
      '正在学习',
    );
    await tester.pump();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_new_folder.png'),
    );
  });

  testWidgets('M04 rename note', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openNoteActions(tester, fixture.notes.first.title);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_rename_note.png'),
    );
  });

  testWidgets('M04 delete note', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openNoteActions(tester, fixture.notes.first.title);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_delete_note.png'),
    );
  });

  testWidgets('M04 folder actions', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openFolderActions(tester, fixture.inspiration.name);
    expect(find.text('拖动调整顺序'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_folder_actions.png'),
    );
  });

  testWidgets('M04 delete folder', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openFolderActions(tester, fixture.inspiration.name);
    await tester.tap(find.text('删除文件夹'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_delete_folder.png'),
    );
  });

  testWidgets('M04 duplicate folder create validation', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await tester.tap(find.byKey(const ValueKey('asset-create-deposit-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('asset-deposit-folder-name')),
      fixture.inspiration.name,
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('已存在同名文件夹'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_folder_create_duplicate.png'),
    );
  });

  testWidgets('M04 folder reorder drag', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);
    final first = find.byKey(
      ValueKey('asset-folder-drag-${fixture.inspiration.id}'),
    );
    final target = find.byKey(
      ValueKey('asset-deposit-folder-${fixture.product.id}'),
    );
    final before = tester.getTopLeft(first).dy;
    final gesture = await tester.startGesture(tester.getCenter(first));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 180));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_folder_drag.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dy, isNot(before));
  });

  testWidgets('M04 rename folder', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openFolderActions(tester, fixture.inspiration.name);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('asset-deposit-folder-rename')),
      '创作灵感',
    );
    await tester.pump();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_rename_folder.png'),
    );
  });

  testWidgets('M04 duplicate folder rename validation', (tester) async {
    final fixture = await _pumpAssets(tester);
    addTearDown(fixture.dispose);

    await _openFolderActions(tester, fixture.product.name);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('asset-deposit-folder-rename')),
      fixture.inspiration.name,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('已存在同名文件夹'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m04_assets_folder_rename_duplicate.png'),
    );
  });
}

Future<void> _openNoteActions(WidgetTester tester, String title) async {
  await tester.tap(find.byTooltip('笔记操作 $title'));
  await tester.pumpAndSettle();
}

Future<void> _openFolderActions(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('管理文件夹 $name'));
  await tester.pumpAndSettle();
}

Future<_AssetsFixture> _pumpAssets(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(_surface);
  final notes = _fixtureNotes();
  final controller = KnowledgeLibraryController(
    initialNotes: notes,
    includeDemoFixtures: false,
    now: () => DateTime(2026, 8, 24, 15, 4),
  );
  final inspiration = controller.createDepositFolder(
    '灵感与创作',
    createdAt: DateTime(2026, 8, 20, 8),
  )!;
  final product = controller.createDepositFolder(
    '产品与工作',
    createdAt: DateTime(2026, 8, 20, 9),
  )!;
  final archive = controller.createDepositFolder(
    '未归档',
    createdAt: DateTime(2026, 8, 20, 10),
  )!;
  for (final note in notes.take(3)) {
    controller.depositContent(note.id, folderId: inspiration.id);
  }
  for (final note in notes.skip(3).take(3)) {
    controller.depositContent(note.id, folderId: product.id);
  }
  for (final note in notes.skip(6)) {
    controller.depositContent(note.id, folderId: archive.id);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((_) => controller),
        profileHubControllerProvider.overrideWith(
          (_) => ProfileHubController(),
        ),
      ],
      child: MaterialApp(
        theme: figmaGoldenTheme(),
        debugShowCheckedModeBanner: false,
        home: const V3MyAssetsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _AssetsFixture(
    tester: tester,
    controller: controller,
    notes: notes,
    inspiration: inspiration,
    product: product,
  );
}

List<V3FeedItem> _fixtureNotes() {
  final titles = <String>[
    '把零散灵感整理成可持续生长的知识网络',
    '内容不是堆数量，而是形成判断',
    '今天值得记录的三个片段',
    '产品复盘：从信息到判断',
    '用户访谈问题清单',
    '专业工具为什么更容易被相信',
    '创作素材整理方法',
    '本周会议结论',
  ];
  return <V3FeedItem>[
    for (var index = 0; index < titles.length; index++)
      V3FeedItem(
        id: 'm04-note-$index',
        title: titles[index],
        source: index.isEven ? V3MaterialSource.note : V3MaterialSource.meeting,
        createdAt: DateTime(2026, 8, 20 - index, 9, 18),
        updatedAt: DateTime(2026, 8, 20 - index, 10, 9),
        rawBody: '整理信息之后补上自己的判断依据，让笔记能够在下一次决策中直接被复用。',
        summaryBody: index == 3 ? '记录一次产品复盘的关键证据、结论与待验证问题，方便后续继续推进。' : null,
        topics: const <String>['外部知识'],
      ),
  ];
}

final class _AssetsFixture {
  const _AssetsFixture({
    required this.tester,
    required this.controller,
    required this.notes,
    required this.inspiration,
    required this.product,
  });

  final WidgetTester tester;
  final KnowledgeLibraryController controller;
  final List<V3FeedItem> notes;
  final V3DepositFolder inspiration;
  final V3DepositFolder product;

  Future<void> dispose() async {
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  }
}
