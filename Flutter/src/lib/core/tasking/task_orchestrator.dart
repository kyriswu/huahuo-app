import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../performance/task_metrics.dart';
import 'app_task_projection.dart';

export 'app_task_projection.dart';

final class AppTaskCancellationToken {
  bool _cancelled = false;
  String? _reason;
  final Map<Timer, Completer<void>> _delays = <Timer, Completer<void>>{};
  final Set<VoidCallback> _cancellationListeners = <VoidCallback>{};
  bool Function(AppTaskState state)? _reportState;

  bool get isCancelled => _cancelled;
  String? get reason => _reason;

  void throwIfCancelled() {
    if (_cancelled) throw AppTaskCancelledException(_reason ?? 'cancelled');
  }

  Future<T> waitFor<T>(Future<T> operation) {
    final completed = Completer<T>();
    void onCancelled() => completed.completeError(
      AppTaskCancelledException(_reason ?? 'cancelled'),
    );

    if (_cancelled) {
      onCancelled();
    } else {
      _cancellationListeners.add(onCancelled);
    }
    unawaited(
      operation.then<void>(
        (value) {
          _cancellationListeners.remove(onCancelled);
          if (!completed.isCompleted) completed.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          _cancellationListeners.remove(onCancelled);
          if (!completed.isCompleted) {
            completed.completeError(error, stackTrace);
          }
        },
      ),
    );
    return completed.future;
  }

  Future<void> delay(Duration duration) {
    throwIfCancelled();
    if (duration <= Duration.zero) return Future<void>.value();
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _delays.remove(timer);
      if (completer.isCompleted) return;
      if (_cancelled) {
        completer.completeError(
          AppTaskCancelledException(_reason ?? 'cancelled'),
        );
      } else {
        completer.complete();
      }
    });
    _delays[timer] = completer;
    return completer.future;
  }

  bool reportState(AppTaskState state) {
    if (_cancelled || state.isTerminal || state is AppTaskQueued) return false;
    return _reportState?.call(state) ?? false;
  }

  void _cancel(String reason) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final entry in _delays.entries) {
      entry.key.cancel();
      if (!entry.value.isCompleted) {
        entry.value.completeError(AppTaskCancelledException(reason));
      }
    }
    _delays.clear();
    final listeners = _cancellationListeners.toList(growable: false);
    _cancellationListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

typedef AppTaskBody<T> = FutureOr<T> Function(AppTaskCancellationToken token);

/// A keyed, resource-budgeted scheduler. Task cancellation is cooperative.
final class TaskOrchestrator extends ChangeNotifier {
  TaskOrchestrator({
    Map<TaskResource, int> resourceBudgets = const <TaskResource, int>{
      TaskResource.network: 3,
      TaskResource.database: 1,
      TaskResource.cpu: 2,
      TaskResource.media: 1,
    },
    int terminalProjectionCapacity = 64,
    TaskMetrics? metrics,
  }) : // Public parameter intentionally omits the private field prefix.
       // ignore: prefer_initializing_formals
       _metrics = metrics,
       _terminalProjectionCapacity = terminalProjectionCapacity,
       _resourceBudgets = <TaskResource, int>{
         for (final resource in TaskResource.values)
           resource: resourceBudgets[resource] ?? 1,
       } {
    if (terminalProjectionCapacity < 1) {
      throw ArgumentError.value(
        terminalProjectionCapacity,
        'terminalProjectionCapacity',
        'must be positive',
      );
    }
    for (final entry in _resourceBudgets.entries) {
      if (entry.value < 1) {
        throw ArgumentError.value(
          entry.value,
          'resourceBudgets[${entry.key.name}]',
          'must be positive',
        );
      }
    }
  }

  final TaskMetrics? _metrics;
  final int _terminalProjectionCapacity;
  final Map<TaskResource, int> _resourceBudgets;
  final Map<TaskResource, int> _activeByResource = <TaskResource, int>{};
  final List<_TaskEntry<dynamic>> _pending = <_TaskEntry<dynamic>>[];
  final Set<_TaskEntry<dynamic>> _running = <_TaskEntry<dynamic>>{};
  final Map<String, _TaskEntry<dynamic>> _latestByKey =
      <String, _TaskEntry<dynamic>>{};
  final LinkedHashMap<String, AppTaskProjection> _projections =
      LinkedHashMap<String, AppTaskProjection>();
  final Map<String, int> _projectionSequences = <String, int>{};
  final ListQueue<_TerminalProjectionRef> _terminalProjections =
      ListQueue<_TerminalProjectionRef>();
  int _sequence = 0;
  int _cancelled = 0;
  int _completed = 0;
  bool _foreground = true;
  bool _disposed = false;

  bool get isForeground => _foreground;

  TaskOrchestratorSnapshot get snapshot => TaskOrchestratorSnapshot(
    queued: _pending.length,
    running: _running.length,
    cancelled: _cancelled,
    completed: _completed,
    projections: _projections.values,
  );

  AppTaskProjection? projectionFor(String key) => _projections[key.trim()];

  void recordRetry(TaskSpec spec) {
    if (!_disposed) _metrics?.recordRetry(spec.owner);
  }

  UnmodifiableMapView<TaskResource, int> get activeByResource =>
      UnmodifiableMapView<TaskResource, int>(_activeByResource);

  UnmodifiableMapView<TaskResource, int> get resourceBudgets =>
      UnmodifiableMapView<TaskResource, int>(_resourceBudgets);

  void setResourceBudgets(Map<TaskResource, int> budgets) {
    if (_disposed) return;
    for (final entry in budgets.entries) {
      if (entry.value < 1) {
        throw ArgumentError.value(
          entry.value,
          'budgets[${entry.key.name}]',
          'must be positive',
        );
      }
    }
    if (budgets.entries.every(
      (entry) => _resourceBudgets[entry.key] == entry.value,
    )) {
      return;
    }
    _resourceBudgets.addAll(budgets);
    _changed();
    _drain();
  }

  Future<T> schedule<T>(TaskSpec spec, AppTaskBody<T> body) {
    if (_disposed) {
      return Future<T>.error(
        const AppTaskCancelledException('orchestrator-disposed'),
      );
    }
    final existing = _latestByKey[spec.key];
    if (existing != null && !existing.token.isCancelled) {
      if (!spec.replaceExisting) {
        if (existing.resultType != T) {
          return Future<T>.error(
            StateError('Task ${spec.key} was scheduled with a different type'),
          );
        }
        return existing.future.then((value) => value as T);
      }
      _cancelEntry(existing, 'replaced');
    }

    final entry = _TaskEntry<T>(spec: spec, body: body, sequence: _sequence++);
    entry.token._reportState ??= (state) => _reportState(entry, state);
    _latestByKey[spec.key] = entry;
    _pending.add(entry);
    _projectionSequences.remove(spec.key);
    _setProjection(entry, const AppTaskQueued());
    _changed();
    _drain();
    return entry.completer.future;
  }

  bool cancel(String key, {String reason = 'cancelled'}) {
    final entry = _latestByKey[key];
    if (entry == null) return false;
    _cancelEntry(entry, reason);
    _drain();
    return true;
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground || _disposed) return;
    _foreground = foreground;
    if (!foreground) {
      for (final entry in _pending.toList(growable: false)) {
        if (entry.spec.foregroundOnly) {
          _cancelEntry(entry, 'application-backgrounded');
        }
      }
      for (final entry in _running.toList(growable: false)) {
        if (entry.spec.foregroundOnly) {
          _cancelEntry(entry, 'application-backgrounded');
        }
      }
    }
    _changed();
    if (foreground) _drain();
  }

  void _cancelEntry(_TaskEntry<dynamic> entry, String reason) {
    if (entry.token.isCancelled) return;
    _cancelToken(entry, reason);
    if (_pending.remove(entry)) {
      _cancelled++;
      _setProjection(entry, const AppTaskCancelled(), terminal: true);
      _removeLatest(entry);
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(AppTaskCancelledException(reason));
      }
      _changed();
    }
  }

  void _drain() {
    if (_disposed) return;
    _pending.sort((left, right) {
      final byPriority = left.spec.priority.index.compareTo(
        right.spec.priority.index,
      );
      return byPriority != 0
          ? byPriority
          : left.sequence.compareTo(right.sequence);
    });
    var started = true;
    while (started) {
      started = false;
      for (var index = 0; index < _pending.length; index++) {
        final entry = _pending[index];
        if (!_canStart(entry)) continue;
        _pending.removeAt(index);
        _start(entry);
        started = true;
        break;
      }
    }
  }

  bool _canStart(_TaskEntry<dynamic> entry) {
    if (entry.spec.foregroundOnly && !_foreground) return false;
    return entry.spec.resources.every(
      (resource) =>
          (_activeByResource[resource] ?? 0) < _resourceBudgets[resource]!,
    );
  }

  void _start(_TaskEntry<dynamic> entry) {
    _running.add(entry);
    _setProjection(entry, const AppTaskRunning());
    entry.stopwatch.start();
    _metrics?.recordStarted(entry.spec.owner);
    for (final resource in entry.spec.resources) {
      _activeByResource[resource] = (_activeByResource[resource] ?? 0) + 1;
    }
    _changed();
    unawaited(_run(entry));
  }

  Future<void> _run(_TaskEntry<dynamic> entry) async {
    final deadline = entry.spec.deadline;
    if (deadline != null) {
      entry.deadlineTimer = Timer(deadline, () {
        entry.deadlineTimer = null;
        if (entry.completer.isCompleted) return;
        entry.token._cancel('deadline-exceeded');
        entry.completer.completeError(
          TimeoutException('Task ${entry.spec.key} exceeded its deadline'),
        );
        _changed();
      });
    }
    var metricOutcome = TaskMetricOutcome.failed;
    AppTaskState terminalState = AppTaskFailed(
      errorCategory: 'unknown_error',
      retryable: entry.spec.retryable,
    );
    try {
      entry.token.throwIfCancelled();
      final value = await entry.invoke();
      if (entry.token.isCancelled) {
        if (!entry.completer.isCompleted) {
          entry.completer.completeError(
            AppTaskCancelledException(entry.token.reason ?? 'cancelled'),
          );
        }
        _cancelled++;
        metricOutcome = TaskMetricOutcome.cancelled;
        terminalState = const AppTaskCancelled();
      } else {
        if (!entry.completer.isCompleted) entry.complete(value);
        _completed++;
        metricOutcome = TaskMetricOutcome.succeeded;
        terminalState = const AppTaskSucceeded();
      }
    } catch (error, stackTrace) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(error, stackTrace);
      }
      if (entry.token.isCancelled) {
        _cancelled++;
        metricOutcome = TaskMetricOutcome.cancelled;
        terminalState = const AppTaskCancelled();
      } else {
        terminalState = AppTaskFailed(
          errorCategory: _safeErrorCategory(error),
          retryable: entry.spec.retryable,
        );
      }
    } finally {
      entry.deadlineTimer?.cancel();
      entry.deadlineTimer = null;
      entry.stopwatch.stop();
      _metrics?.recordFinished(
        entry.spec.owner,
        outcome: metricOutcome,
        elapsed: entry.stopwatch.elapsed,
      );
      _running.remove(entry);
      for (final resource in entry.spec.resources) {
        final next = (_activeByResource[resource] ?? 1) - 1;
        if (next == 0) {
          _activeByResource.remove(resource);
        } else {
          _activeByResource[resource] = next;
        }
      }
      _setProjection(entry, terminalState, terminal: true);
      _removeLatest(entry);
      _changed();
      _drain();
    }
  }

  void _removeLatest(_TaskEntry<dynamic> entry) {
    if (identical(_latestByKey[entry.spec.key], entry)) {
      _latestByKey.remove(entry.spec.key);
    }
  }

  bool _reportState(_TaskEntry<dynamic> entry, AppTaskState state) {
    if (_disposed ||
        entry.token.isCancelled ||
        !_running.contains(entry) ||
        !identical(_latestByKey[entry.spec.key], entry)) {
      return false;
    }
    _setProjection(entry, state);
    _changed();
    return true;
  }

  void _setProjection(
    _TaskEntry<dynamic> entry,
    AppTaskState state, {
    bool terminal = false,
  }) {
    if (_disposed) return;
    final currentSequence = _projectionSequences[entry.spec.key];
    if (currentSequence != null && currentSequence != entry.sequence) return;
    _projectionSequences[entry.spec.key] = entry.sequence;
    _projections[entry.spec.key] = AppTaskProjection(
      spec: entry.spec,
      state: state,
    );
    if (!terminal) return;
    _terminalProjections.addLast(
      _TerminalProjectionRef(entry.spec.key, entry.sequence),
    );
    while (_terminalProjections.length > _terminalProjectionCapacity) {
      final evicted = _terminalProjections.removeFirst();
      if (_projectionSequences[evicted.key] != evicted.sequence ||
          _projections[evicted.key]?.state.isTerminal != true) {
        continue;
      }
      _projectionSequences.remove(evicted.key);
      _projections.remove(evicted.key);
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _cancelToken(_TaskEntry<dynamic> entry, String reason) {
    entry.deadlineTimer?.cancel();
    entry.deadlineTimer = null;
    entry.token._cancel(reason);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _pending.toList(growable: false)) {
      _cancelToken(entry, 'orchestrator-disposed');
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          const AppTaskCancelledException('orchestrator-disposed'),
        );
      }
    }
    for (final entry in _running) {
      _cancelToken(entry, 'orchestrator-disposed');
    }
    _pending.clear();
    _latestByKey.clear();
    _projections.clear();
    _projectionSequences.clear();
    _terminalProjections.clear();
    super.dispose();
  }
}

final class _TerminalProjectionRef {
  const _TerminalProjectionRef(this.key, this.sequence);

  final String key;
  final int sequence;
}

final class _TaskEntry<T> {
  _TaskEntry({required this.spec, required this.body, required this.sequence});

  final TaskSpec spec;
  final AppTaskBody<T> body;
  final int sequence;
  final Type resultType = T;
  final token = AppTaskCancellationToken();
  final completer = Completer<T>();
  final stopwatch = Stopwatch();
  Timer? deadlineTimer;

  Future<T> get future => completer.future;
  Future<T> invoke() => Future<T>.sync(() => body(token));
  void complete(Object? value) => completer.complete(value as T);
}

String _safeErrorCategory(Object error) {
  final normalized = error.runtimeType.toString().replaceAll(
    RegExp(r'[^A-Za-z0-9._-]+'),
    '_',
  );
  if (normalized.isEmpty) return 'unknown_error';
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
}
