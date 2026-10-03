import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/foreground_resume_coordinator.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rebinds positioning without replaying unrelated recovery', () async {
    final harness = _ResumeHarness();
    addTearDown(harness.dispose);
    harness.coordinator.start();
    await harness.settle();
    final activations = harness.recordingActivations;
    final syncs = harness.knowledgeSyncs;
    final billing = harness.billingRecoveries;
    final pauses = harness.positioningPauses;
    final replacement = Object();
    harness.positioningIdentity = replacement;

    harness.coordinator.positioningChanged();
    await harness.settle();

    expect(harness.positioningStartsByIdentity[replacement], 1);
    expect(harness.positioningPauses, pauses + 1);
    expect(harness.recordingActivations, activations);
    expect(harness.knowledgeSyncs, syncs);
    expect(harness.billingRecoveries, billing);
  });

  test('defers replacement positioning start until foreground', () async {
    final harness = _ResumeHarness();
    addTearDown(harness.dispose);
    harness.coordinator.start();
    await harness.settle();
    harness.activity.updateLifecycle(AppLifecycleState.paused);
    final replacement = Object();
    harness.positioningIdentity = replacement;
    harness.coordinator.positioningChanged();
    await harness.settle();
    expect(harness.positioningStartsByIdentity[replacement], isNull);

    harness.activity.updateLifecycle(AppLifecycleState.resumed);
    await harness.settle();
    expect(harness.positioningStartsByIdentity[replacement], 1);
  });

  test(
    'starts once and runs one recovery wave per foreground generation',
    () async {
      final harness = _ResumeHarness();
      addTearDown(harness.dispose);

      harness.coordinator
        ..start()
        ..start();
      await harness.settle();

      expect(harness.recordingActivations, 1);
      expect(harness.positioningStarts, 1);
      expect(harness.recordingResumes, 1);
      expect(harness.recordingDirectoryRefreshes, <bool>[false]);
      expect(harness.knowledgeSyncs, 1);
      expect(harness.billingRecoveries, 1);
      expect(harness.positioningResumes, 1);

      harness.activity.updateLifecycle(AppLifecycleState.paused);
      expect(harness.positioningPauses, 1);
      harness.advance(const Duration(seconds: 31));
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await harness.settle();

      expect(harness.recordingResumes, 2);
      expect(harness.recordingDirectoryRefreshes, <bool>[false, true]);
      expect(harness.knowledgeSyncs, 2);
      expect(harness.billingRecoveries, 2);
      expect(harness.positioningResumes, 2);
    },
  );

  test(
    'brief platform interruption does not pause or replay recovery',
    () async {
      final harness = _ResumeHarness();
      addTearDown(harness.dispose);
      harness.coordinator.start();
      await harness.settle();
      final positioningPauses = harness.positioningPauses;

      harness.activity.updateLifecycle(AppLifecycleState.inactive);
      harness.advance(const Duration(seconds: 2));
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await harness.settle();

      expect(harness.recordingResumes, 1);
      expect(harness.recordingDirectoryRefreshes, <bool>[false]);
      expect(harness.billingRecoveries, 1);
      expect(harness.positioningResumes, 1);
      expect(harness.positioningPauses, positioningPauses);
      expect(harness.knowledgeSyncs, 1);
    },
  );

  test(
    'cancelled queued card refresh remains latched for the next resume',
    () async {
      final harness = _ResumeHarness(networkBudget: 1);
      addTearDown(harness.dispose);
      harness.coordinator.start();
      await harness.settle();

      final releaseBlocker = Completer<void>();
      addTearDown(() {
        if (!releaseBlocker.isCompleted) releaseBlocker.complete();
      });
      final blocker = harness.orchestrator.schedule<void>(
        TaskSpec(
          key: 'foreground-resume:directory-refresh-blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => releaseBlocker.future,
      );
      await Future<void>.delayed(Duration.zero);

      harness.activity.updateLifecycle(AppLifecycleState.paused);
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(harness.recordingResumes, 1);
      expect(
        harness.orchestrator
            .projectionFor('recording-card:foreground-resume')
            ?.state,
        isA<AppTaskQueued>(),
      );

      harness.activity.updateLifecycle(AppLifecycleState.paused);
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      releaseBlocker.complete();
      await blocker;
      await harness.settle();

      expect(harness.recordingResumes, 2);
      expect(harness.recordingDirectoryRefreshes, <bool>[false, true]);
    },
  );

  test(
    'session changes activate work without replaying the current generation',
    () async {
      final harness = _ResumeHarness(
        authenticated: false,
        workspaceReady: false,
      );
      addTearDown(harness.dispose);

      harness.coordinator.start();
      await harness.settle();
      expect(harness.recordingActivations, 0);
      expect(harness.recordingResumes, 0);

      harness.authenticated = true;
      harness.coordinator.sessionChanged();
      await harness.settle();
      expect(harness.recordingActivations, 1);
      expect(harness.positioningStarts, 1);
      expect(harness.recordingResumes, 0);

      harness.activity.updateLifecycle(AppLifecycleState.paused);
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await harness.settle();
      expect(harness.recordingResumes, 1);
      expect(harness.billingRecoveries, 1);
      expect(harness.positioningResumes, 1);
      expect(harness.knowledgeSyncs, 0);

      harness.workspaceReady = true;
      harness.activity.updateLifecycle(AppLifecycleState.paused);
      harness.advance(const Duration(seconds: 31));
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await harness.settle();
      expect(harness.knowledgeSyncs, 1);

      harness.authenticated = false;
      harness.coordinator.sessionChanged();
      expect(harness.positioningPauses, greaterThanOrEqualTo(3));
    },
  );

  test(
    'stop cancels owned delayed tasks and disposal prevents restart',
    () async {
      final harness = _ResumeHarness(
        billingDelay: const Duration(seconds: 5),
        positioningDelay: const Duration(seconds: 5),
      );
      addTearDown(harness.dispose);

      harness.coordinator.start();
      await Future<void>.delayed(Duration.zero);
      harness.coordinator
        ..stop()
        ..stop();
      await harness.settle();

      expect(harness.billingRecoveries, 0);
      expect(harness.positioningResumes, 0);
      expect(harness.orchestrator.snapshot.queued, 0);
      expect(harness.orchestrator.snapshot.running, 0);

      harness.coordinator.dispose();
      harness.coordinator.start();
      harness.activity.updateLifecycle(AppLifecycleState.paused);
      harness.activity.updateLifecycle(AppLifecycleState.resumed);
      await harness.settle();
      expect(harness.recordingActivations, 1);
      expect(harness.recordingResumes, 1);
    },
  );

  test('an unauthenticated session cancels every queued owned task', () async {
    final harness = _ResumeHarness(networkBudget: 1);
    addTearDown(harness.dispose);
    final releaseBlocker = Completer<void>();
    addTearDown(() {
      if (!releaseBlocker.isCompleted) releaseBlocker.complete();
    });
    final blocker = harness.orchestrator.schedule<void>(
      TaskSpec(
        key: 'foreground-resume:test-blocker',
        owner: 'test',
        priority: TaskPriority.userBlocking,
        resources: const <TaskResource>{TaskResource.network},
      ),
      (_) => releaseBlocker.future,
    );

    harness.coordinator.start();
    await Future<void>.delayed(Duration.zero);
    expect(harness.orchestrator.snapshot.queued, 5);

    harness.authenticated = false;
    harness.coordinator.sessionChanged();
    await harness.settle();

    expect(harness.orchestrator.snapshot.queued, 0);
    for (final key in const <String>[
      'onboarding:initial-positioning:start',
      'recording-card:foreground-resume',
      'knowledge:workspace-resume-sync',
      'billing:pending-order-recovery',
      'onboarding:initial-positioning:resume',
    ]) {
      expect(
        harness.orchestrator.projectionFor(key)?.state,
        isA<AppTaskCancelled>(),
        reason: key,
      );
    }
    expect(harness.recordingResumes, 0);
    expect(harness.knowledgeSyncs, 0);
    expect(harness.billingRecoveries, 0);
    expect(harness.positioningStarts, 0);
    expect(harness.positioningResumes, 0);

    releaseBlocker.complete();
    await blocker;
  });

  test(
    'queued positioning work resolves the latest lifecycle identity',
    () async {
      final harness = _ResumeHarness(networkBudget: 1);
      addTearDown(harness.dispose);
      final releaseBlocker = Completer<void>();
      addTearDown(() {
        if (!releaseBlocker.isCompleted) releaseBlocker.complete();
      });
      final blocker = harness.orchestrator.schedule<void>(
        TaskSpec(
          key: 'foreground-resume:positioning-blocker',
          owner: 'test',
          priority: TaskPriority.userBlocking,
          resources: const <TaskResource>{TaskResource.network},
        ),
        (_) => releaseBlocker.future,
      );
      final staleIdentity = harness.positioningIdentity;

      harness.coordinator.start();
      await Future<void>.delayed(Duration.zero);
      final latestIdentity = Object();
      harness.positioningIdentity = latestIdentity;
      releaseBlocker.complete();
      await blocker;
      await harness.settle();

      expect(harness.positioningStartsByIdentity[staleIdentity] ?? 0, 0);
      expect(harness.positioningResumesByIdentity[staleIdentity] ?? 0, 0);
      expect(harness.positioningStartsByIdentity[latestIdentity], 1);
      expect(harness.positioningResumesByIdentity[latestIdentity], 1);
    },
  );
}

final class _ResumeHarness {
  _ResumeHarness({
    this.authenticated = true,
    this.workspaceReady = true,
    Duration billingDelay = Duration.zero,
    Duration positioningDelay = Duration.zero,
    int networkBudget = 8,
  }) : activity = AppActivityCoordinator(),
       orchestrator = TaskOrchestrator(
         resourceBudgets: <TaskResource, int>{
           TaskResource.network: networkBudget,
           TaskResource.database: 1,
           TaskResource.cpu: 1,
           TaskResource.media: 1,
         },
       ) {
    activity.addListener(_followActivity);
    coordinator = ForegroundResumeCoordinator(
      activity: activity,
      orchestrator: orchestrator,
      readSession: () => ForegroundResumeSession(
        authenticated: authenticated,
        workspaceReady: workspaceReady,
      ),
      activateRecordingCard: () => recordingActivations++,
      resumeRecordingCard: ({required refreshDirectory}) {
        recordingResumes += 1;
        recordingDirectoryRefreshes.add(refreshDirectory);
      },
      synchronizeWorkspace: () => knowledgeSyncs++,
      recoverPendingOrder: () => billingRecoveries++,
      resolvePositioning: () {
        final identity = positioningIdentity;
        return InitialPositioningLifecycle(
          identity: identity,
          start: () {
            positioningStarts += 1;
            positioningStartsByIdentity.update(
              identity,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          },
          resume: () {
            positioningResumes += 1;
            positioningResumesByIdentity.update(
              identity,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          },
          pause: () => positioningPauses++,
        );
      },
      awaitDeferredFrame: () => Future<void>.value(),
      reportError: (taskKey, error, stackTrace) {
        errors.add((taskKey: taskKey, error: error));
      },
      billingDelay: billingDelay,
      positioningDelay: positioningDelay,
      now: () => now,
    );
  }

  final AppActivityCoordinator activity;
  final TaskOrchestrator orchestrator;
  late final ForegroundResumeCoordinator coordinator;
  Object positioningIdentity = Object();
  final positioningStartsByIdentity = <Object, int>{};
  final positioningResumesByIdentity = <Object, int>{};
  final errors = <({String taskKey, Object error})>[];

  bool authenticated;
  bool workspaceReady;
  DateTime now = DateTime.utc(2026, 9, 1, 9);
  var recordingActivations = 0;
  var recordingResumes = 0;
  final recordingDirectoryRefreshes = <bool>[];
  var knowledgeSyncs = 0;
  var billingRecoveries = 0;
  var positioningStarts = 0;
  var positioningResumes = 0;
  var positioningPauses = 0;

  void advance(Duration duration) => now = now.add(duration);

  void _followActivity() {
    orchestrator.setForeground(activity.state.canRunForegroundWork);
  }

  Future<void> settle() async {
    for (var index = 0; index < 24; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(errors, isEmpty);
  }

  void dispose() {
    coordinator.dispose();
    activity.removeListener(_followActivity);
    orchestrator.dispose();
    activity.dispose();
  }
}
