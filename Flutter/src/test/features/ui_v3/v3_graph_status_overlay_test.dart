import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_status_overlay.dart';

void main() {
  testWidgets('status overlay exposes every graph lifecycle state', (
    tester,
  ) async {
    var state = GraphLoadingState.loading;
    var refreshing = false;
    var showCompleted = false;
    var retries = 0;
    var creates = 0;
    var dismissals = 0;
    var canvasTaps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Stack(
                children: [
                  Positioned.fill(
                    child: TextButton(
                      key: const ValueKey('graph-canvas-action'),
                      onPressed: () => canvasTaps++,
                      child: const Text('graph canvas'),
                    ),
                  ),
                  Positioned.fill(
                    child: V3GraphStatusOverlay(
                      state: state,
                      progress: .4,
                      refreshing: refreshing,
                      showCompleted: showCompleted,
                      compactTopInset: 72,
                      errorMessage: '暂时无法加载图谱',
                      onRetry: () => retries++,
                      onCreate: () => creates++,
                      onDismissCompleted: () {
                        dismissals++;
                        update(() => showCompleted = false);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('正在加载图谱'), findsOne);

    update(() => state = GraphLoadingState.building);
    await tester.pumpAndSettle();
    expect(find.text('正在构建关系'), findsOne);
    expect(find.byType(LinearProgressIndicator), findsOne);

    update(() {
      state = GraphLoadingState.empty;
      refreshing = false;
      showCompleted = false;
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有可展示的知识'), findsOne);
    await tester.tap(find.text('添加内容'));
    expect(creates, 1);

    update(() => state = GraphLoadingState.ready);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-graph-status-hidden')), findsOne);
    await tester.tap(find.byKey(const ValueKey('graph-canvas-action')));
    expect(canvasTaps, 1);

    update(() => refreshing = true);
    await tester.pump(const Duration(milliseconds: 240));
    expect(
      find.byKey(const ValueKey('feed-graph-status-refreshing')),
      findsOne,
    );
    expect(find.text('正在刷新'), findsOne);
    expect(tester.getTopLeft(find.text('正在刷新')).dy, greaterThan(72));

    update(() {
      refreshing = false;
      showCompleted = true;
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-graph-status-completed')), findsOne);
    expect(find.text('构建完成'), findsOne);
    await tester.tap(
      find.byKey(const ValueKey('feed-graph-status-completed-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(dismissals, 1);
    expect(find.byKey(const ValueKey('feed-graph-status-hidden')), findsOne);

    update(() => state = GraphLoadingState.failure);
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载图谱'), findsOne);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });
}
