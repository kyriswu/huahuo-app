import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_knowledge_note_picker_sheet.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets(
    'searches all note fields and returns selection order across filters',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final notes = <V3FeedItem>[
        _note(
          id: 'link',
          title: '公开链接资料',
          source: V3MaterialSource.link,
          rawBody: '正文包含独特检索词',
        ),
        _note(
          id: 'meeting',
          title: '客户会议',
          source: V3MaterialSource.meeting,
          rawBody: '会议正文',
        ),
        _note(
          id: 'manual',
          title: '手写观察',
          source: V3MaterialSource.note,
          rawBody: '手写正文',
          topics: const ['产品灵感'],
        ),
        _note(
          id: 'import',
          title: '导入报告',
          source: V3MaterialSource.documentImport,
          rawBody: '导入正文',
          summaryBody: '摘要包含市场判断',
        ),
      ];
      V3KnowledgeNotePickerResult? result;

      await tester.pumpWidget(
        MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showV3KnowledgeNotePicker(
                    context: context,
                    notes: notes,
                    initialSelectedIds: const ['meeting', 'missing'],
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('完成 (1)'), findsOneWidget);
      final search = find.byKey(const ValueKey('knowledge-note-picker-search'));
      await tester.enterText(search, '独特检索词');
      await tester.pump();
      expect(find.text('公开链接资料'), findsOneWidget);
      expect(find.text('客户会议'), findsNothing);

      await tester.enterText(search, '市场判断');
      await tester.pump();
      expect(find.text('导入报告'), findsOneWidget);
      expect(find.text('公开链接资料'), findsNothing);

      await tester.enterText(search, '产品灵感');
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-note-manual')),
      );
      await tester.pump();
      expect(find.text('完成 (2)'), findsOneWidget);

      await tester.enterText(search, '');
      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-source-link')),
      );
      await tester.pump();
      expect(find.text('公开链接资料'), findsOneWidget);
      expect(find.text('客户会议'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-note-link')),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-source-all')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-note-meeting')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('knowledge-note-picker-note-meeting')),
      );
      await tester.pump();

      final confirm = find.byKey(
        const ValueKey('knowledge-note-picker-confirm'),
      );
      expect(tester.getSize(confirm).height, greaterThanOrEqualTo(44));
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('knowledge-note-picker-note-manual')),
            )
            .height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(result?.selectedIds, const ['manual', 'link', 'meeting']);
    },
  );

  testWidgets('distinguishes close from confirming an empty selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    V3KnowledgeNotePickerResult? result;
    var completed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showV3KnowledgeNotePicker(
                  context: context,
                  notes: const <V3FeedItem>[],
                );
                completed = true;
              },
              child: const Text('打开空列表'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开空列表'));
    await tester.pumpAndSettle();
    expect(find.text('暂无可选择的笔记'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);

    completed = false;
    await tester.tap(find.text('打开空列表'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('knowledge-note-picker-confirm')),
    );
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNotNull);
    expect(result!.selectedNotes, isEmpty);
  });

  testWidgets('clears a no-result search and source filter', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final note = _note(
      id: 'manual',
      title: '唯一笔记',
      source: V3MaterialSource.note,
      rawBody: '正文',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showV3KnowledgeNotePicker(context: context, notes: [note]),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('knowledge-note-picker-source-link')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-note-picker-search')),
      '不存在',
    );
    await tester.pump();
    expect(find.text('没有匹配的笔记'), findsOneWidget);
    final clear = find.byKey(
      const ValueKey('knowledge-note-picker-clear-filters'),
    );
    expect(tester.getSize(clear).height, greaterThanOrEqualTo(44));
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('唯一笔记'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('knowledge-note-picker-source-all')),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('keeps search and confirmation above a compact keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final notes = <V3FeedItem>[
      _note(
        id: 'keyboard',
        title: '键盘打开时仍可选择的笔记',
        source: V3MaterialSource.note,
        rawBody: '用于紧凑屏幕回归验证',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showV3KnowledgeNotePicker(context: context, notes: notes),
              child: const Text('打开键盘用例'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开键盘用例'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('knowledge-note-picker-search'));
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pumpAndSettle();

    final confirm = find.byKey(const ValueKey('knowledge-note-picker-confirm'));
    expect(search.hitTestable(), findsOneWidget);
    expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(160));
    expect(tester.takeException(), isNull);
  });
}

V3FeedItem _note({
  required String id,
  required String title,
  required V3MaterialSource source,
  required String rawBody,
  String? summaryBody,
  List<String> topics = const <String>[],
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: source,
    createdAt: DateTime(2026, 7, 23),
    rawBody: rawBody,
    summaryBody: summaryBody,
    topics: topics,
  );
}
