import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/home/widgets/desktop_home_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  testWidgets('renders complete Home data and dispatches every entry', (
    tester,
  ) async {
    final repository = _HomeRepository()
      ..loads.add(Future.value(ProductResult<ProductHome>.success(_home())))
      ..acknowledgements.add(const ProductResult<void>.success(null));
    final controller = ProductHomeController(
      repository,
      keyFactory: (suggestionId) => 'view-$suggestionId',
    );
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1');
    final primaryActions = <ProductHomeAction>[];
    final suggestions = <ProductHomeSuggestion>[];
    var recordings = 0;
    var credits = 0;

    await _pump(
      tester,
      controller,
      onPrimaryAction: primaryActions.add,
      onOpenSuggestion: suggestions.add,
      onOpenRecordings: () => recordings++,
      onOpenCredits: () => credits++,
    );

    expect(find.text('今日推荐'), findsNWidgets(2));
    expect(find.text('4'), findsOneWidget);
    expect(find.text('72'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('home-primary-action')));
    await tester.tap(find.byKey(const ValueKey<String>('home-recordings')));
    await tester.tap(find.byKey(const ValueKey<String>('home-credits')));
    await tester.tap(
      find.byKey(const ValueKey<String>('home-open-suggestion')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('home-acknowledge-suggestion')),
    );
    await tester.pumpAndSettle();

    expect(primaryActions.single.taskId, 'task-1');
    expect(suggestions.single.id, 'suggestion-1');
    expect(recordings, 1);
    expect(credits, 1);
    expect(repository.keys, <String>['view-suggestion-1']);
    expect(
      find.byKey(const ValueKey<String>('home-suggestion-unread')),
      findsNothing,
    );
  });

  testWidgets('failure retries into an empty Home state', (tester) async {
    final repository = _HomeRepository()
      ..loads.addAll(<Future<ProductResult<ProductHome>>>[
        Future.value(
          const ProductResult<ProductHome>.failure(
            code: 'OFFLINE',
            message: '网络不可用',
            retryable: true,
          ),
        ),
        Future.value(ProductResult<ProductHome>.success(_home(empty: true))),
      ]);
    final controller = ProductHomeController(repository);
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1');
    await _pump(tester, controller);

    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('home-retry')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home-suggestion-empty')),
      findsOneWidget,
    );
    expect(find.text('0'), findsNWidgets(2));
  });

  testWidgets('busy acknowledgement disables the read control', (tester) async {
    final acknowledgement = Completer<ProductResult<void>>();
    final repository = _HomeRepository()
      ..loads.add(Future.value(ProductResult<ProductHome>.success(_home())))
      ..pendingAcknowledgement = acknowledgement;
    final controller = ProductHomeController(repository);
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1');
    await _pump(tester, controller);

    await tester.tap(
      find.byKey(const ValueKey<String>('home-acknowledge-suggestion')),
    );
    await tester.pump();
    expect(find.text('更新中'), findsOneWidget);
    acknowledgement.complete(const ProductResult<void>.success(null));
    await tester.pumpAndSettle();
    expect(find.text('更新中'), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProductHomeController controller, {
  DesktopHomeActionCallback? onPrimaryAction,
  DesktopHomeSuggestionCallback? onOpenSuggestion,
  VoidCallback? onOpenRecordings,
  VoidCallback? onOpenCredits,
}) async {
  tester.view.physicalSize = const Size(1040, 680);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopHomeWorkspace(
          controller: controller,
          onPrimaryAction: onPrimaryAction ?? (_) {},
          onOpenSuggestion: onOpenSuggestion ?? (_) {},
          onOpenRecordings: onOpenRecordings ?? () {},
          onOpenCredits: onOpenCredits ?? () {},
        ),
      ),
    ),
  );
}

ProductHome _home({bool empty = false}) => ProductHome(
  action: ProductHomeAction(
    type: empty
        ? ProductHomeActionType.uploadRecording
        : ProductHomeActionType.openRunningTask,
    label: empty ? '上传录音' : '打开运行任务',
    taskId: empty ? null : 'task-1',
    threadId: empty ? null : 'thread-1',
  ),
  suggestion: empty
      ? null
      : ProductHomeSuggestion(
          id: 'suggestion-1',
          title: '今日推荐',
          summary: '一条正式推荐',
          eventBrief: null,
          discussionPoints: const <String>['讨论点'],
          topicAngles: const <String>['选题角度'],
          sourceName: '官方推荐',
          acknowledged: false,
        ),
  runningTaskCount: empty ? 0 : 1,
  recordingCount: empty ? 0 : 4,
  depositedRecordingCount: empty ? 0 : 2,
  availableGenerationCredits: 72,
  redDotCount: empty ? 0 : 1,
  serverTime: DateTime.utc(2026, 9, 3, 3),
);

final class _HomeRepository implements ProductHomeRepository {
  final loads = <Future<ProductResult<ProductHome>>>[];
  final acknowledgements = <ProductResult<void>>[];
  final keys = <String>[];
  Completer<ProductResult<void>>? pendingAcknowledgement;

  @override
  Future<ProductResult<ProductHome>> load(String workspaceId) =>
      loads.removeAt(0);

  @override
  Future<ProductResult<void>> markSuggestionViewed({
    required String workspaceId,
    required String suggestionId,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    final pending = pendingAcknowledgement;
    if (pending != null) return pending.future;
    return acknowledgements.removeAt(0);
  }
}
