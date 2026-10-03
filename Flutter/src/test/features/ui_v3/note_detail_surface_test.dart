import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/note/note_detail_surface.dart';

import 'note_detail_figma_fixture.dart';

void main() {
  testWidgets('renders the canonical M02 note detail controls', (tester) async {
    await tester.pumpWidget(noteDetailFigmaFixture());
    await tester.pumpAndSettle();

    expect(find.text('资料详情'), findsOneWidget);
    expect(find.text('内容不是堆数量，而是形成判断'), findsOneWidget);
    expect(find.text('原始'), findsOneWidget);
    expect(find.text('纲要'), findsOneWidget);
    expect(find.text('深度洞察'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-chat-entry')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
      findsOneWidget,
    );
  });

  testWidgets('switches stages and exposes all detail actions', (tester) async {
    var back = 0;
    var more = 0;
    var chat = 0;
    var assistant = 0;
    var freeCreation = 0;
    await tester.pumpWidget(
      noteDetailFigmaFixture(
        onBack: () => back += 1,
        onMore: () => more += 1,
        onChat: () => chat += 1,
        onAssistant: () => assistant += 1,
        onFreeCreation: () => freeCreation += 1,
      ),
    );

    await tester.tap(find.text('纲要'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fixture-summary-page')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.tap(find.bySemanticsLabel('更多操作'));
    await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
    );
    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
    );

    expect((back, more, chat, assistant, freeCreation), (1, 1, 1, 1, 1));
  });

  testWidgets('read-only notes allow the supplied creation-copy action', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(
      noteDetailFigmaFixture(readOnly: true, onFreeCreation: () => copies += 1),
    );

    expect(find.byKey(const ValueKey('detail-chat-entry')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 辅助创作')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
    );
    expect(copies, 1);
  });

  testWidgets('read-only notes without copy capability hide free creation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoteDetailCreationDock(
            readOnly: true,
            onChat: () {},
            onAssistant: () {},
            onFreeCreation: null,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('detail-floating-action-Agent 自由创作')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('detail-chat-entry')), findsOneWidget);
  });

  testWidgets('compact scaled creation dock keeps complete Agent labels', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pageController = PageController();
    addTearDown(pageController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            padding: EdgeInsets.only(top: 20),
            textScaler: TextScaler.linear(1.3),
          ),
          child: NoteDetailSurface(
            title: '窄屏资料详情',
            subtitle: '笔记 · 今天',
            stage: V3ContentStage.raw,
            onBack: () {},
            onMore: () {},
            onSelectStage: (_) {},
            pageController: pageController,
            onPageChanged: (_) {},
            pages: const [
              SizedBox.shrink(),
              SizedBox.shrink(),
              SizedBox.shrink(),
            ],
            bottomBar: NoteDetailCreationDock(
              readOnly: false,
              onChat: () {},
              onAssistant: () {},
              onFreeCreation: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final assistant = find.byKey(
      const ValueKey('detail-floating-action-Agent 辅助创作'),
    );
    final freeCreation = find.byKey(
      const ValueKey('detail-floating-action-Agent 自由创作'),
    );
    expect(
      tester.getRect(assistant).bottom,
      lessThan(tester.getRect(freeCreation).top),
    );
    for (final label in <String>['Agent 辅助创作', 'Agent 自由创作']) {
      final box = tester.renderObject<RenderBox>(find.text(label));
      expect(
        box.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(box.size.width + .1),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
