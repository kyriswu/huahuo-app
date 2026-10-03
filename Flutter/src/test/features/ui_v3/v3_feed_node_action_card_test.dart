import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';

void main() {
  testWidgets('graph node click stays on feed and shows only two actions', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'node-note',
      title: '节点笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 13),
      rawBody: '节点原始内容',
      summaryBody: '## 节点纲要\n- **重点**',
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    expect(library.depositContent(note.id), isNotNull);
    final router = GoRouter(
      initialLocation: '/v3/feed',
      routes: [
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Scaffold(body: V3FeedPage()),
        ),
        GoRoute(
          path: '/v3/feed/items/:id',
          builder: (context, state) => const Text('detail-route'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('知识笔记：节点笔记'));
    await tester.pump(const Duration(milliseconds: 450));

    expect(router.routeInformationProvider.value.uri.path, '/v3/feed');
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('聊一聊'), findsOneWidget);
    expect(find.text('节点纲要'), findsWidgets);
    expect(find.text('重点'), findsOneWidget);
    expect(find.text('## 节点纲要'), findsNothing);
    expect(find.text('生成选题'), findsNothing);
    expect(find.text('整理大纲'), findsNothing);
  });
}
