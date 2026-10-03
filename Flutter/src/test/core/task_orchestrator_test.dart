import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/performance/task_metrics.dart';
import 'package:huahuoai_app/core/tasking/orchestrated_poller.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';

void main() {
  test('waitFor preserves results and source error stack traces', () async {
    final token = AppTaskCancellationToken();
    expect(await token.waitFor(Future<int>.value(7)), 7);
    final failure = StateError('source failed');
    final trace = StackTrace.current;
    try {
      await token.waitFor(Future<int>.error(failure, trace));
      fail('the source error must be forwarded');
    } catch (error, stackTrace) {
      expect(error, same(failure));
      expect(stackTrace, same(trace));
    }
  });

  test(
    'waitFor cancellation releases work before the shared source settles',
    () async {
      final orchestrator = TaskOrchestrator();
      addTearDown(orchestrator.dispose);
      final source = Completer<int>();
      final started = Completer<AppTaskCancellationToken>();
      final result = orchestrator.schedule<int>(
        TaskSpec(
          key: 'cancellable-projection',
          owner: 'test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (token) async {
          expect(await token.waitFor(Future<int>.value(1)), 1);
          started.complete(token);
          return token.waitFor(source.future);
        },
      );
      final token = await started.future;
      final cancellation = expectLater(
        result,
        throwsA(isA<AppTaskCancelledException>()),
      );
      orchestrator.cancel('cancellable-projection', reason: 'page-hidden');
      await cancellation;
      expect(source.isCompleted, isFalse);
      expect(orchestrator.snapshot.running, 0);
      source.completeError(StateError('late source failure'));
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        token.waitFor(Future<int>.error(StateError('already cancelled'))),
        throwsA(isA<AppTaskCancelledException>()),
      );
    },
  );

  test('joins equal keys and runs the body once', () async {
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    final gate = Completer<void>();
    var calls = 0;
    final spec = TaskSpec(
      key: 'workspace:sync',
      owner: 'knowledge',
      priority: TaskPriority.userVisible,
      resources: const <TaskResource>{TaskResource.network},
    );

    final first = orchestrator.schedule<int>(spec, (_) async {
      calls++;
      await gate.future;
      return 7;
    });
    final second = orchestrator.schedule<int>(spec, (_) => 9);
    gate.complete();

    expect(await Future.wait(<Future<int>>[first, second]), <int>[7, 7]);
    expect(calls, 1);
    expect(orchestrator.snapshot.completed, 1);
  });

  test(
    'cancelled running work is not a join target for the same key',
    () async {
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      addTearDown(orchestrator.dispose);
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      late AppTaskCancellationToken firstToken;
      final spec = TaskSpec(
        key: 'foreground:cancelled-single-flight',
        owner: 'test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
      );
      final first = orchestrator.schedule<int>(spec, (token) async {
        firstToken = token;
        started.complete();
        await release.future;
        token.throwIfCancelled();
        return 1;
      });
      await started.future;
      final firstFailure = expectLater(
        first,
        throwsA(isA<AppTaskCancelledException>()),
      );

      orchestrator.setForeground(false);
      expect(firstToken.isCancelled, isTrue);
      orchestrator.setForeground(true);
      var secondCalls = 0;
      final second = orchestrator.schedule<int>(spec, (_) {
        secondCalls += 1;
        return 2;
      });

      expect(orchestrator.snapshot.queued, 1);
      release.complete();
      await firstFailure;
      expect(await second, 2);
      expect(secondCalls, 1);
    },
  );

  test('holds work at the resource budget and honors priority', () async {
    final orchestrator = TaskOrchestrator(
      resourceBudgets: const <TaskResource, int>{
        TaskResource.network: 1,
        TaskResource.database: 1,
        TaskResource.cpu: 1,
        TaskResource.media: 1,
      },
    );
    addTearDown(orchestrator.dispose);
    final firstGate = Completer<void>();
    final order = <String>[];

    final first = orchestrator.schedule<void>(
      TaskSpec(
        key: 'first',
        owner: 'test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) async {
        order.add('first');
        await firstGate.future;
      },
    );
    final background = orchestrator.schedule<void>(
      TaskSpec(
        key: 'background',
        owner: 'test',
        priority: TaskPriority.backgroundOpportunistic,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => order.add('background'),
    );
    final blocking = orchestrator.schedule<void>(
      TaskSpec(
        key: 'blocking',
        owner: 'test',
        priority: TaskPriority.userBlocking,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => order.add('blocking'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(order, <String>['first']);
    expect(orchestrator.snapshot.queued, 2);
    firstGate.complete();
    await Future.wait(<Future<void>>[first, background, blocking]);
    expect(order, <String>['first', 'blocking', 'background']);
  });

  test(
    'runtime budget changes gate queued work without cancelling work',
    () async {
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 2},
      );
      addTearDown(orchestrator.dispose);
      final releases = List<Completer<void>>.generate(
        3,
        (_) => Completer<void>(),
      );
      var started = 0;

      Future<void> schedule(int index) => orchestrator.schedule<void>(
        TaskSpec(
          key: 'dynamic-budget-$index',
          owner: 'test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) async {
          started += 1;
          await releases[index].future;
        },
      );

      final first = schedule(0);
      final second = schedule(1);
      await Future<void>.delayed(Duration.zero);
      expect(started, 2);

      orchestrator.setResourceBudgets(const <TaskResource, int>{
        TaskResource.network: 1,
      });
      final third = schedule(2);
      releases[0].complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(started, 2);
      expect(orchestrator.resourceBudgets[TaskResource.network], 1);

      orchestrator.setResourceBudgets(const <TaskResource, int>{
        TaskResource.network: 2,
      });
      await Future<void>.delayed(Duration.zero);
      expect(started, 3);
      releases[1].complete();
      releases[2].complete();
      await Future.wait(<Future<void>>[second, third]);
    },
  );

  test('replacement cancels pending work cooperatively', () async {
    final orchestrator = TaskOrchestrator(
      resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
    );
    addTearDown(orchestrator.dispose);
    final blocker = Completer<void>();
    final occupying = orchestrator.schedule<void>(
      TaskSpec(
        key: 'occupying',
        owner: 'test',
        priority: TaskPriority.userBlocking,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => blocker.future,
    );
    final old = orchestrator.schedule<int>(
      TaskSpec(
        key: 'replace-me',
        owner: 'test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => 1,
    );
    final replacement = orchestrator.schedule<int>(
      TaskSpec(
        key: 'replace-me',
        owner: 'test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        replaceExisting: true,
      ),
      (_) => 2,
    );

    await expectLater(old, throwsA(isA<AppTaskCancelledException>()));
    blocker.complete();
    await occupying;
    expect(await replacement, 2);
  });

  test('foreground-only work waits and deadlines cancel the token', () async {
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    orchestrator.setForeground(false);
    var started = false;
    final waiting = orchestrator.schedule<void>(
      TaskSpec(
        key: 'visible-refresh',
        owner: 'test',
        priority: TaskPriority.foregroundDeferred,
        foregroundOnly: true,
      ),
      (_) => started = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    orchestrator.setForeground(true);
    await waiting;
    expect(started, isTrue);

    final settled = Completer<void>();
    AppTaskCancellationToken? token;
    final timedOut = orchestrator.schedule<void>(
      TaskSpec(
        key: 'deadline',
        owner: 'test',
        priority: TaskPriority.userVisible,
        deadline: const Duration(milliseconds: 10),
      ),
      (value) async {
        token = value;
        await settled.future;
      },
    );
    await expectLater(timedOut, throwsA(isA<TimeoutException>()));
    expect(token?.isCancelled, isTrue);
    settled.complete();
  });

  test(
    'background transition cancels the existing foreground queue only',
    () async {
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      addTearDown(orchestrator.dispose);
      final releaseBlocker = Completer<void>();
      addTearDown(() {
        if (!releaseBlocker.isCompleted) releaseBlocker.complete();
      });
      final blocker = orchestrator.schedule<void>(
        TaskSpec(
          key: 'foreground-queue:blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => releaseBlocker.future,
      );
      var staleCalls = 0;
      final stale = orchestrator.schedule<void>(
        TaskSpec(
          key: 'foreground-queue:stale',
          owner: 'test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
        ),
        (_) => staleCalls += 1,
      );
      final staleFailure = expectLater(
        stale,
        throwsA(isA<AppTaskCancelledException>()),
      );
      expect(orchestrator.snapshot.queued, 1);

      orchestrator.setForeground(false);
      await staleFailure;
      expect(orchestrator.snapshot.queued, 0);
      expect(staleCalls, 0);

      var deferredCalls = 0;
      final deferred = orchestrator.schedule<int>(
        TaskSpec(
          key: 'foreground-queue:submitted-while-backgrounded',
          owner: 'test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
        ),
        (_) {
          deferredCalls += 1;
          return 7;
        },
      );
      releaseBlocker.complete();
      await blocker;
      await Future<void>.delayed(Duration.zero);
      expect(orchestrator.snapshot.queued, 1);
      expect(deferredCalls, 0);

      orchestrator.setForeground(true);
      expect(await deferred, 7);
      expect(deferredCalls, 1);
    },
  );

  test(
    'publishes queued, running, reported and terminal task states',
    () async {
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      addTearDown(orchestrator.dispose);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      late AppTaskCancellationToken firstToken;

      final first = orchestrator.schedule<int>(
        TaskSpec(
          key: 'projection:first',
          owner: 'projection-test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (token) async {
          firstToken = token;
          firstStarted.complete();
          await releaseFirst.future;
          return 1;
        },
      );
      final second = orchestrator.schedule<int>(
        TaskSpec(
          key: 'projection:second',
          owner: 'projection-test',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => 2,
      );
      await firstStarted.future;

      expect(
        orchestrator.projectionFor('projection:first')?.state,
        isA<AppTaskRunning>(),
      );
      expect(
        orchestrator.projectionFor('projection:second')?.state,
        isA<AppTaskQueued>(),
      );
      expect(
        firstToken.reportState(const AppTaskRunning(progress: .25)),
        isTrue,
      );
      expect(
        (orchestrator.projectionFor('projection:first')!.state
                as AppTaskRunning)
            .progress,
        .25,
      );
      expect(firstToken.reportState(const AppTaskWaitingRemote()), isTrue);
      expect(
        orchestrator.projectionFor('projection:first')?.state,
        isA<AppTaskWaitingRemote>(),
      );
      expect(firstToken.reportState(const AppTaskPaused()), isTrue);
      expect(firstToken.reportState(const AppTaskSucceeded()), isFalse);

      releaseFirst.complete();
      expect(await first, 1);
      expect(await second, 2);
      expect(
        orchestrator.projectionFor('projection:first')?.state,
        isA<AppTaskSucceeded>(),
      );
      expect(
        orchestrator.projectionFor('projection:second')?.state,
        isA<AppTaskSucceeded>(),
      );
      expect(
        () => orchestrator.snapshot.projections.add(
          orchestrator.projectionFor('projection:first')!,
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'retains a bounded terminal ledger with safe failure metadata',
    () async {
      final orchestrator = TaskOrchestrator(terminalProjectionCapacity: 2);
      addTearDown(orchestrator.dispose);

      await orchestrator.schedule<void>(
        TaskSpec(
          key: 'terminal:first',
          owner: 'projection-test',
          priority: TaskPriority.userVisible,
        ),
        (_) {},
      );
      await expectLater(
        orchestrator.schedule<void>(
          TaskSpec(
            key: 'terminal:failed',
            owner: 'projection-test',
            priority: TaskPriority.userVisible,
            retryable: true,
          ),
          (_) => throw const _ProjectionFailure(),
        ),
        throwsA(isA<_ProjectionFailure>()),
      );
      final failed = orchestrator.projectionFor('terminal:failed')!.state;
      expect(failed, isA<AppTaskFailed>());
      expect((failed as AppTaskFailed).errorCategory, '_ProjectionFailure');
      expect(failed.retryable, isTrue);

      await orchestrator.schedule<void>(
        TaskSpec(
          key: 'terminal:last',
          owner: 'projection-test',
          priority: TaskPriority.userVisible,
        ),
        (_) {},
      );

      expect(orchestrator.projectionFor('terminal:first'), isNull);
      expect(
        orchestrator.snapshot.projections.map((item) => item.spec.key),
        containsAll(<String>['terminal:failed', 'terminal:last']),
      );
    },
  );

  test('replacement rejects stale task projection reports', () async {
    final orchestrator = TaskOrchestrator(
      resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
    );
    addTearDown(orchestrator.dispose);
    final oldStarted = Completer<void>();
    final releaseOld = Completer<void>();
    late AppTaskCancellationToken oldToken;

    final old = orchestrator.schedule<void>(
      TaskSpec(
        key: 'projection:replace',
        owner: 'projection-test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (token) async {
        oldToken = token;
        oldStarted.complete();
        await releaseOld.future;
      },
    );
    await oldStarted.future;
    final oldFailure = expectLater(
      old,
      throwsA(isA<AppTaskCancelledException>()),
    );
    final replacement = orchestrator.schedule<void>(
      TaskSpec(
        key: 'projection:replace',
        owner: 'projection-test',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        replaceExisting: true,
      ),
      (_) {},
    );

    expect(oldToken.isCancelled, isTrue);
    expect(oldToken.reportState(const AppTaskWaitingRemote()), isFalse);
    expect(
      orchestrator.projectionFor('projection:replace')?.state,
      isA<AppTaskQueued>(),
    );

    releaseOld.complete();
    await oldFailure;
    await replacement;
    expect(
      orchestrator.projectionFor('projection:replace')?.state,
      isA<AppTaskSucceeded>(),
    );
  });

  test(
    'poller retries through task metrics and clears activity owner',
    () async {
      final taskMetrics = TaskMetrics();
      final activityMetrics = RuntimeActivityMetrics();
      final orchestrator = TaskOrchestrator(metrics: taskMetrics);
      final finished = Completer<void>();
      var attempts = 0;
      final poller = OrchestratedPoller(
        orchestrator: orchestrator,
        spec: TaskSpec(
          key: 'poller:retry',
          owner: 'poller-test',
          priority: TaskPriority.foregroundDeferred,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
          replaceExisting: true,
          retryable: true,
          deadline: const Duration(seconds: 1),
        ),
        interval: const Duration(milliseconds: 1),
        maxBackoff: const Duration(milliseconds: 1),
        jitter: 0,
        activityMetrics: activityMetrics,
        poll: (_) {
          attempts += 1;
          if (attempts == 1) throw const _ProjectionFailure();
          finished.complete();
          return false;
        },
      );
      addTearDown(() {
        poller.dispose();
        orchestrator.dispose();
        activityMetrics.dispose();
      });

      poller.start();
      await finished.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(poller.isRunning, isFalse);
      expect(taskMetrics.snapshot().retries, 1);
      expect(taskMetrics.snapshot().byKind['poller-test']?['retries'], 1);
      expect(activityMetrics.snapshot().peakPollers, 1);
      expect(activityMetrics.current.activePollers, 0);
    },
  );

  test(
    'poller interval holds no permit and stop cancels in-flight work',
    () async {
      final activityMetrics = RuntimeActivityMetrics();
      final orchestrator = TaskOrchestrator(
        resourceBudgets: const <TaskResource, int>{TaskResource.network: 1},
      );
      final firstFinished = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseSecond = Completer<void>();
      AppTaskCancellationToken? secondToken;
      var attempts = 0;
      var normalJitterSamples = 0;
      final poller = OrchestratedPoller(
        orchestrator: orchestrator,
        spec: TaskSpec(
          key: 'poller:lifecycle',
          owner: 'poller-lifecycle-test',
          priority: TaskPriority.foregroundDeferred,
          resources: const <TaskResource>{TaskResource.network},
          replaceExisting: true,
          retryable: true,
          deadline: const Duration(seconds: 1),
        ),
        interval: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 10),
        jitter: 0,
        randomDouble: () {
          normalJitterSamples += 1;
          return .5;
        },
        activityMetrics: activityMetrics,
        poll: (token) async {
          attempts += 1;
          if (attempts == 1) {
            firstFinished.complete();
            return true;
          }
          secondToken = token;
          secondStarted.complete();
          await releaseSecond.future;
          return true;
        },
      );
      addTearDown(() {
        poller.dispose();
        orchestrator.dispose();
        activityMetrics.dispose();
      });

      poller.start();
      await firstFinished.future;
      await Future<void>.delayed(Duration.zero);
      expect(orchestrator.activeByResource[TaskResource.network] ?? 0, 0);
      expect(activityMetrics.current.activePollers, 1);
      expect(normalJitterSamples, 1);

      await secondStarted.future.timeout(const Duration(seconds: 1));
      poller.stop();
      expect(secondToken?.isCancelled, isTrue);
      expect(activityMetrics.current.activePollers, 0);
      releaseSecond.complete();
      await Future<void>.delayed(Duration.zero);
      expect(poller.isRunning, isFalse);
    },
  );

  test('foreground-only poller suspends and automatically resumes', () async {
    final activityMetrics = RuntimeActivityMetrics();
    final orchestrator = TaskOrchestrator()..setForeground(false);
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final resumed = Completer<void>();
    AppTaskCancellationToken? firstToken;
    var attempts = 0;
    final poller = OrchestratedPoller(
      orchestrator: orchestrator,
      spec: TaskSpec(
        key: 'poller:foreground',
        owner: 'poller-foreground-test',
        priority: TaskPriority.foregroundDeferred,
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 1),
      ),
      interval: const Duration(seconds: 1),
      jitter: 0,
      activityMetrics: activityMetrics,
      poll: (token) async {
        attempts += 1;
        if (attempts == 1) {
          firstToken = token;
          firstStarted.complete();
          await releaseFirst.future;
          return true;
        }
        resumed.complete();
        return false;
      },
    );
    addTearDown(() {
      poller.dispose();
      orchestrator.dispose();
      activityMetrics.dispose();
    });

    poller.start();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 0);
    expect(poller.isRunning, isFalse);
    expect(activityMetrics.current.activePollers, 0);

    orchestrator.setForeground(true);
    await firstStarted.future;
    expect(poller.isRunning, isTrue);
    expect(activityMetrics.current.activePollers, 1);

    orchestrator.setForeground(false);
    expect(firstToken?.isCancelled, isTrue);
    expect(poller.isRunning, isFalse);
    expect(activityMetrics.current.activePollers, 0);
    releaseFirst.complete();
    await Future<void>.delayed(Duration.zero);

    orchestrator.setForeground(true);
    await resumed.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);
    expect(poller.isRunning, isFalse);
    expect(activityMetrics.current.activePollers, 0);
  });

  test('cancellation owns and terminates stagger delays', () async {
    final orchestrator = TaskOrchestrator();
    final started = Completer<void>();
    final delayed = orchestrator.schedule<void>(
      TaskSpec(
        key: 'staggered-recovery',
        owner: 'test',
        priority: TaskPriority.foregroundDeferred,
      ),
      (token) async {
        started.complete();
        await token.delay(const Duration(days: 1));
      },
    );
    await started.future;

    orchestrator.dispose();

    await expectLater(delayed, throwsA(isA<AppTaskCancelledException>()));
  });
}

final class _ProjectionFailure implements Exception {
  const _ProjectionFailure();
}
