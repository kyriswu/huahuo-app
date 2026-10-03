import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/chat/application/chat_thread_progress_poller.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';

void main() {
  testWidgets('uses a hashed orchestrated key and stops its cadence', (
    tester,
  ) async {
    final orchestrator = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    final poller = ChatThreadProgressPoller(
      orchestrator: orchestrator,
      activityMetrics: metrics,
      interval: const Duration(milliseconds: 5),
      maximumBackoff: const Duration(milliseconds: 5),
      jitter: 0,
    );
    addTearDown(() {
      poller.dispose();
      orchestrator.dispose();
      metrics.dispose();
    });

    var calls = 0;
    poller.start(
      threadId: 'private-thread-id',
      agentRunId: 'private-run-id',
      attempt: () async {
        calls += 1;
        return calls < 2;
      },
    );
    await tester.pump();

    expect(calls, 1);
    final task = orchestrator.snapshot.projections.single;
    expect(task.spec.owner, 'chat.thread-progress');
    expect(task.spec.key, isNot(contains('private-thread-id')));
    expect(task.spec.key, isNot(contains('private-run-id')));
    expect(metrics.current.activePollers, 1);

    await tester.pump(const Duration(milliseconds: 5));
    await tester.pump();
    expect(calls, 2);
    expect(metrics.current.activePollers, 0);

    poller.start(
      threadId: 'private-thread-id',
      agentRunId: 'private-run-id',
      attempt: () async {
        calls += 1;
        return true;
      },
    );
    await tester.pump();
    expect(calls, 3);

    poller.stop();
    await tester.pump(const Duration(milliseconds: 20));
    expect(calls, 3);
    expect(metrics.current.activePollers, 0);
  });

  test('maps provider-neutral progress events to polling deltas', () async {
    final batch = await readAssistantThreadProgress(
      progress: const _AssistantProgressPort(
        AssistantProgressPage(
          conversationId: 'thread-1',
          nextSequence: 3,
          events: <AssistantProgressEvent>[
            AssistantProgressEvent(
              sequence: 1,
              type: AssistantProgressEventType.draftDelta,
              runHandle: 'run-1',
              deltaText: 'stale',
            ),
            AssistantProgressEvent(
              sequence: 2,
              type: AssistantProgressEventType.draftDelta,
              runHandle: 'run-1',
              deltaText: 'first',
              replace: true,
            ),
            AssistantProgressEvent(
              sequence: 3,
              type: AssistantProgressEventType.status,
              runHandle: 'other-run',
            ),
            AssistantProgressEvent(
              sequence: 4,
              type: AssistantProgressEventType.draftDelta,
              runHandle: 'run-1',
              deltaText: 'second',
            ),
          ],
        ),
      ),
      conversationId: 'thread-1',
      runHandle: const AssistantRunHandle('run-1'),
      afterSequence: 1,
    );

    expect(batch?.nextSequence, 4);
    expect(
      batch?.deltas
          .map((delta) => (text: delta.text, replace: delta.replace))
          .toList(),
      <({bool replace, String text})>[
        (text: 'first', replace: true),
        (text: 'second', replace: false),
      ],
    );
  });
}

final class _AssistantProgressPort implements AssistantThreadProgressPort {
  const _AssistantProgressPort(this.page);

  final AssistantProgressPage page;

  @override
  Future<AssistantRuntimeRead<AssistantProgressPage>> readProgress({
    required String conversationId,
    required int afterSequence,
  }) async => AssistantRuntimeRead.success(page);
}
