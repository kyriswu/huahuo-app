import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_generated_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_generating_page.dart';

void main() {
  testWidgets(
    'covered completion waits for activation and old results survive new selection',
    (tester) async {
      final harness = await _pump(tester);
      final flight = harness.controller.generate();
      final operationId = harness.controller.generationId!;
      unawaited(harness.router.push(_progress(operationId)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('取消生成'), findsNothing);
      unawaited(harness.router.push('/cover'));
      await tester.pumpAndSettle();
      harness.repository.complete('第一项结果');
      expect(await flight, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('上层页面'), findsOneWidget);
      harness.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(V3WorkbenchGeneratedPage), findsOneWidget);
      expect(
        tester
            .widget<V3WorkbenchGeneratedPage>(
              find.byType(V3WorkbenchGeneratedPage),
            )
            .operationId,
        operationId,
      );
      unawaited(harness.router.push('/cover'));
      await tester.pumpAndSettle();
      harness.controller.startSelection(WorkbenchPurpose.lead);
      harness.controller.clearForWorkbench();
      await tester.pumpAndSettle();
      expect(find.text('上层页面'), findsOneWidget);
      harness.router.pop();
      await tester.pumpAndSettle();
      expect(find.textContaining('第一项结果'), findsOneWidget);
      expect(find.text('引用材料（1）'), findsOneWidget);
      expect(harness.repository.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background return preserves the operation and stale recovery cannot submit',
    (tester) async {
      final harness = await _pump(tester);
      final flight = harness.controller.generate();
      final operationId = harness.controller.generationId!;
      unawaited(harness.router.push(_progress(operationId)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('先返回，稍后查看'));
      await tester.tap(find.text('先返回，稍后查看'));
      await tester.pumpAndSettle();
      expect(find.text('原始入口'), findsOneWidget);
      expect(
        harness.controller.taskForId(operationId)!.status,
        WorkbenchGenerationTaskStatus.processing,
      );
      unawaited(harness.router.push(_progress('missing')));
      await tester.pumpAndSettle();
      expect(find.text('生成记录不可用'), findsOneWidget);
      expect(harness.repository.calls, 1);
      harness.repository.complete('保留结果');
      await flight;
      await tester.pumpAndSettle();
      expect(find.byType(V3WorkbenchGeneratedPage), findsNothing);
      harness.router.go(_result(operationId));
      await tester.pumpAndSettle();
      expect(find.textContaining('保留结果'), findsOneWidget);
      harness.router.go(_result('missing'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这次生成结果已不在当前会话中'), findsOneWidget);
      expect(find.textContaining('保留结果'), findsNothing);
      expect(harness.repository.calls, 1);
      harness.controller.consumeSelection();
      harness.router.go(AppRoutePaths.workbenchGenerating('persona'));
      await tester.pumpAndSettle();
      expect(find.text('生成记录不可用'), findsOneWidget);
      expect(harness.repository.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

String _progress(String operationId) => Uri(
  path: AppRoutePaths.workbenchGenerating('persona'),
  queryParameters: {'operationId': operationId},
).toString();

String _result(String operationId) => Uri(
  path: AppRoutePaths.workbenchGenerated('persona'),
  queryParameters: {'operationId': operationId},
).toString();

Future<
  ({
    GoRouter router,
    WorkbenchGenerationController controller,
    _Repository repository,
  })
>
_pump(WidgetTester tester) async {
  final note = V3FeedItem(
    id: 'source',
    title: '原始来源',
    source: V3MaterialSource.note,
    createdAt: DateTime.utc(2026, 9, 1),
    rawBody: '原始内容',
  );
  final library = KnowledgeLibraryController(initialNotes: [note]);
  final repository = _Repository();
  final controller =
      WorkbenchGenerationController(library: library, repository: repository)
        ..startSelection(WorkbenchPurpose.persona)
        ..toggleNote(note.id);
  final router = GoRouter(
    initialLocation: '/',
    observers: [appRouteObserver],
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('原始入口')),
      ),
      GoRoute(
        path: '/cover',
        builder: (_, __) => const Scaffold(body: Text('上层页面')),
      ),
      GoRoute(
        path: AppRoutePaths.workbenchGeneratingRoute,
        builder: (_, state) => V3WorkbenchGeneratingPage(
          purpose: WorkbenchPurpose.persona,
          resumeOperationId: state.uri.queryParameters['operationId'],
        ),
      ),
      GoRoute(
        path: AppRoutePaths.workbenchGeneratedRoute,
        builder: (_, state) => V3WorkbenchGeneratedPage(
          purpose: WorkbenchPurpose.persona,
          operationId: state.uri.queryParameters['operationId'],
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        workbenchGenerationControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, controller: controller, repository: repository);
}

final class _Repository implements WorkbenchGenerationRepository {
  final _completion = Completer<WorkbenchGenerationResult>();
  int calls = 0;

  void complete(String markdown) => _completion.complete(
    WorkbenchGenerationResult(
      markdown: markdown,
      generatedAt: DateTime.utc(2026, 9, 1),
    ),
  );

  @override
  Future<WorkbenchGenerationResult> generate({
    required WorkbenchPurpose purpose,
    required List<V3FeedItem> notes,
    required String operationId,
  }) {
    calls += 1;
    return _completion.future;
  }
}
