import 'dart:async';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('loads ready and empty Home states for a Workspace', () async {
    final repository = _HomeRepository()
      ..loads.addAll(<Future<ProductResult<ProductHome>>>[
        Future.value(ProductResult<ProductHome>.success(_home())),
        Future.value(ProductResult<ProductHome>.success(_home(empty: true))),
      ]);
    final controller = ProductHomeController(repository);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    expect(controller.state.status, ProductHomeStatus.ready);
    expect(controller.state.home?.runningTaskCount, 1);

    await controller.reload();
    expect(controller.state.status, ProductHomeStatus.empty);
  });

  test('exposes retryable failure and recovers on reload', () async {
    final repository = _HomeRepository()
      ..loads.addAll(<Future<ProductResult<ProductHome>>>[
        Future.value(
          const ProductResult<ProductHome>.failure(
            code: 'OFFLINE',
            message: '网络不可用',
            retryable: true,
          ),
        ),
        Future.value(ProductResult<ProductHome>.success(_home())),
      ]);
    final controller = ProductHomeController(repository);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    expect(controller.state.status, ProductHomeStatus.failure);
    expect(controller.state.retryable, isTrue);
    await controller.reload();
    expect(controller.state.status, ProductHomeStatus.ready);
  });

  test(
    'acknowledgement updates immutable state and reuses retry key',
    () async {
      final repository = _HomeRepository()
        ..loads.add(Future.value(ProductResult<ProductHome>.success(_home())))
        ..acknowledgements.addAll(<ProductResult<void>>[
          const ProductResult<void>.failure(
            code: 'OFFLINE',
            message: '网络不可用',
            retryable: true,
          ),
          const ProductResult<void>.success(null),
        ]);
      var keyCount = 0;
      final controller = ProductHomeController(
        repository,
        keyFactory: (suggestionId) => 'key-${++keyCount}',
      );
      addTearDown(controller.dispose);
      await controller.bindWorkspace('workspace-1');

      expect(await controller.acknowledgeSuggestion(), isFalse);
      expect(await controller.acknowledgeSuggestion(), isTrue);

      expect(repository.keys, <String>['key-1', 'key-1']);
      expect(controller.state.home?.redDotCount, 0);
      expect(controller.state.home?.suggestion?.acknowledged, isTrue);
    },
  );

  test(
    'newer reload wins and Workspace replacement suppresses stale data',
    () async {
      final first = Completer<ProductResult<ProductHome>>();
      final second = Completer<ProductResult<ProductHome>>();
      final third = Completer<ProductResult<ProductHome>>();
      final repository = _HomeRepository()
        ..loads.addAll(<Future<ProductResult<ProductHome>>>[
          first.future,
          second.future,
          third.future,
        ]);
      final controller = ProductHomeController(repository);
      addTearDown(controller.dispose);

      final initial = controller.bindWorkspace('workspace-1');
      final newer = controller.reload();
      second.complete(ProductResult<ProductHome>.success(_home(recordings: 2)));
      await newer;
      first.complete(ProductResult<ProductHome>.success(_home(recordings: 99)));
      await initial;
      expect(controller.state.home?.recordingCount, 2);

      final replacement = controller.bindWorkspace('workspace-2');
      controller.reset();
      third.complete(ProductResult<ProductHome>.success(_home(recordings: 88)));
      await replacement;
      expect(controller.state.status, ProductHomeStatus.idle);
      expect(controller.state.home, isNull);
    },
  );
}

ProductHome _home({bool empty = false, int recordings = 4}) => ProductHome(
  action: ProductHomeAction(
    type: empty
        ? ProductHomeActionType.uploadRecording
        : ProductHomeActionType.openRunningTask,
    label: empty ? '上传录音' : '打开任务',
    taskId: empty ? null : 'task-1',
    threadId: empty ? null : 'thread-1',
  ),
  suggestion: empty
      ? null
      : ProductHomeSuggestion(
          id: 'suggestion-1',
          title: '今日推荐',
          summary: '摘要',
          eventBrief: '概览',
          discussionPoints: const <String>['讨论点'],
          topicAngles: const <String>['角度'],
          sourceName: '官方推荐',
          acknowledged: false,
        ),
  runningTaskCount: empty ? 0 : 1,
  recordingCount: empty ? 0 : recordings,
  depositedRecordingCount: empty ? 0 : 2,
  availableGenerationCredits: 72,
  redDotCount: empty ? 0 : 1,
  serverTime: DateTime.utc(2026, 9, 3, 3),
);

final class _HomeRepository implements ProductHomeRepository {
  final loads = <Future<ProductResult<ProductHome>>>[];
  final acknowledgements = <ProductResult<void>>[];
  final keys = <String>[];

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
    return acknowledgements.removeAt(0);
  }
}
