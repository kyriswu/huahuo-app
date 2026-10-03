import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/tasking/task_orchestrator.dart';
import '../lifecycle/app_activity_coordinator.dart';

typedef ForegroundResumeCallback = FutureOr<void> Function();
typedef RecordingCardForegroundResumeCallback =
    FutureOr<void> Function({required bool refreshDirectory});
typedef ForegroundResumeErrorReporter =
    void Function(String taskKey, Object error, StackTrace stackTrace);

final class ForegroundResumeSession {
  const ForegroundResumeSession({
    required this.authenticated,
    required this.workspaceReady,
  });

  final bool authenticated;
  final bool workspaceReady;
}

final class InitialPositioningLifecycle {
  const InitialPositioningLifecycle({
    required this.identity,
    required this.start,
    required this.resume,
    required this.pause,
  });

  final Object identity;
  final ForegroundResumeCallback start;
  final ForegroundResumeCallback resume;
  final void Function() pause;
}

/// Owns account activation and generation-scoped foreground recovery.
final class ForegroundResumeCoordinator {
  ForegroundResumeCoordinator({
    required AppActivityCoordinator activity,
    required TaskOrchestrator orchestrator,
    required ForegroundResumeSession Function() readSession,
    required void Function() activateRecordingCard,
    required RecordingCardForegroundResumeCallback resumeRecordingCard,
    required ForegroundResumeCallback synchronizeWorkspace,
    required ForegroundResumeCallback recoverPendingOrder,
    required InitialPositioningLifecycle Function() resolvePositioning,
    required Future<void> Function() awaitDeferredFrame,
    ForegroundResumeErrorReporter? reportError,
    Duration billingDelay = const Duration(milliseconds: 120),
    Duration positioningDelay = const Duration(milliseconds: 220),
    Duration workspaceResumeMinimumBackgroundDuration = const Duration(
      seconds: 30,
    ),
    DateTime Function()? now,
  }) : this._(
         activity,
         orchestrator,
         readSession,
         activateRecordingCard,
         resumeRecordingCard,
         synchronizeWorkspace,
         recoverPendingOrder,
         resolvePositioning,
         awaitDeferredFrame,
         reportError ?? _reportFlutterError,
         billingDelay,
         positioningDelay,
         workspaceResumeMinimumBackgroundDuration,
         now ?? DateTime.now,
       );

  ForegroundResumeCoordinator._(
    this._activity,
    this._orchestrator,
    this._readSession,
    this._activateRecordingCard,
    this._resumeRecordingCard,
    this._synchronizeWorkspace,
    this._recoverPendingOrder,
    this._resolvePositioning,
    this._awaitDeferredFrame,
    this._reportError,
    this._billingDelay,
    this._positioningDelay,
    this._workspaceResumeMinimumBackgroundDuration,
    this._now,
  );

  static const _ownedTaskKeys = <String>{
    'onboarding:initial-positioning:start',
    'recording-card:foreground-resume',
    'knowledge:workspace-resume-sync',
    'billing:pending-order-recovery',
    'onboarding:initial-positioning:resume',
  };

  final AppActivityCoordinator _activity;
  final TaskOrchestrator _orchestrator;
  final ForegroundResumeSession Function() _readSession;
  final void Function() _activateRecordingCard;
  final RecordingCardForegroundResumeCallback _resumeRecordingCard;
  final ForegroundResumeCallback _synchronizeWorkspace;
  final ForegroundResumeCallback _recoverPendingOrder;
  final InitialPositioningLifecycle Function() _resolvePositioning;
  final Future<void> Function() _awaitDeferredFrame;
  final ForegroundResumeErrorReporter _reportError;
  final Duration _billingDelay;
  final Duration _positioningDelay;
  final Duration _workspaceResumeMinimumBackgroundDuration;
  final DateTime Function() _now;

  InitialPositioningLifecycle? _positioning;
  DateTime? _backgroundedAt;
  var _recordingCardDirectoryRefreshRequired = false;
  var _handledForegroundGeneration = -1;
  var _started = false;
  var _disposed = false;

  bool get started => _started;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _activity.addListener(_handleActivityChanged);
    _activateAuthenticatedRuntime();
    _scheduleForegroundRecovery();
  }

  void sessionChanged() {
    if (!_started || _disposed) return;
    _activateAuthenticatedRuntime();
  }

  void positioningChanged() {
    if (!_started || _disposed || !_readSession().authenticated) return;
    _schedulePositioningStart();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _activity.removeListener(_handleActivityChanged);
    _positioning?.pause();
    _positioning = null;
    _handledForegroundGeneration = -1;
    _cancelOwnedTasks('foreground-resume-stopped');
  }

  void _handleActivityChanged() {
    final activity = _activity.state;
    if (activity.isBackground) {
      _backgroundedAt ??= _now();
      _recordingCardDirectoryRefreshRequired = true;
      _positioning?.pause();
      return;
    }
    if (!activity.isForeground) return;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    final refreshRecordingCardDirectory =
        _recordingCardDirectoryRefreshRequired;
    final backgroundDuration = backgroundedAt == null
        ? null
        : _now().difference(backgroundedAt);
    _scheduleForegroundRecovery(
      refreshRecordingCardDirectory: refreshRecordingCardDirectory,
      skipWorkspaceSync:
          backgroundDuration != null &&
          !backgroundDuration.isNegative &&
          backgroundDuration < _workspaceResumeMinimumBackgroundDuration,
    );
  }

  void _activateAuthenticatedRuntime() {
    if (!_readSession().authenticated) {
      _positioning?.pause();
      _cancelOwnedTasks('foreground-resume-unauthenticated');
      return;
    }
    _activateRecordingCard();
    _schedulePositioningStart();
  }

  void _schedulePositioningStart() {
    _currentPositioning();
    _schedule(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'onboarding:initial-positioning:start',
        owner: 'onboarding',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        await _currentPositioning().start();
      },
    );
  }

  void _scheduleForegroundRecovery({
    bool skipWorkspaceSync = false,
    bool refreshRecordingCardDirectory = false,
  }) {
    final activity = _activity.state;
    if (!_started ||
        !activity.isForeground ||
        activity.foregroundGeneration == _handledForegroundGeneration) {
      return;
    }
    final generation = activity.foregroundGeneration;
    _handledForegroundGeneration = generation;
    final session = _readSession();
    if (!session.authenticated) return;

    _schedule(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'recording-card:foreground-resume',
        owner: 'recording-card',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        await _resumeRecordingCard(
          refreshDirectory: refreshRecordingCardDirectory,
        );
        token.throwIfCancelled();
        if (refreshRecordingCardDirectory && _ownsGeneration(generation)) {
          _recordingCardDirectoryRefreshRequired = false;
        }
      },
    );
    if (session.workspaceReady && !skipWorkspaceSync) {
      _schedule(
        // performance-rfc: runtime-activation-resident-tasks
        TaskSpec(
          key: 'knowledge:workspace-resume-sync',
          owner: 'knowledge',
          priority: TaskPriority.foregroundDeferred,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
        ),
        (token) async {
          await _awaitDeferredFrame();
          token.throwIfCancelled();
          if (!_ownsGeneration(generation)) return;
          await _synchronizeWorkspace();
        },
      );
    }
    _schedule(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'billing:pending-order-recovery',
        owner: 'billing',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
      ),
      (token) async {
        await token.delay(_billingDelay);
        token.throwIfCancelled();
        if (!_ownsGeneration(generation)) return;
        await _recoverPendingOrder();
      },
    );
    _currentPositioning();
    _schedule(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'onboarding:initial-positioning:resume',
        owner: 'onboarding',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
      ),
      (token) async {
        await token.delay(_positioningDelay);
        token.throwIfCancelled();
        if (!_ownsGeneration(generation)) return;
        await _currentPositioning().resume();
      },
    );
  }

  InitialPositioningLifecycle _currentPositioning() {
    final next = _resolvePositioning();
    final current = _positioning;
    if (current != null && !identical(current.identity, next.identity)) {
      current.pause();
    }
    return _positioning = identical(current?.identity, next.identity)
        ? current!
        : next;
  }

  bool _ownsGeneration(int generation) =>
      _started &&
      _activity.state.canRunForegroundWork &&
      _activity.state.foregroundGeneration == generation;

  void _cancelOwnedTasks(String reason) {
    for (final key in _ownedTaskKeys) {
      _orchestrator.cancel(key, reason: reason);
    }
  }

  void _schedule(TaskSpec spec, AppTaskBody<void> body) {
    final future = _orchestrator.schedule<void>(spec, body);
    unawaited(_observe(spec.key, future));
  }

  Future<void> _observe(String key, Future<void> future) async {
    try {
      await future;
    } on AppTaskCancelledException {
      // A newer lifecycle generation or coordinator owner superseded this run.
    } catch (error, stackTrace) {
      _reportError(key, error, stackTrace);
    }
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
  }
}

void _reportFlutterError(String taskKey, Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'huahuo app runtime',
      context: ErrorDescription('while running $taskKey'),
    ),
  );
}
