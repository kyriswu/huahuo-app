import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'performance_snapshot.dart';

enum RuntimeSseState {
  disconnected,
  connecting,
  healthy,
  fallbackPolling,
  failed,
}

enum RuntimeVisualQuality { high, balanced, constrained }

final class RuntimeActivitySample {
  const RuntimeActivitySample({
    required this.observedAt,
    required this.route,
    required this.tab,
    required this.lifecycle,
    required this.activeTickers,
    required this.activePollers,
    required this.activeTasks,
    required this.sseState,
    required this.visualQuality,
  });

  final DateTime observedAt;
  final String route;
  final String tab;
  final AppLifecycleState lifecycle;
  final int activeTickers;
  final int activePollers;
  final int activeTasks;
  final RuntimeSseState sseState;
  final RuntimeVisualQuality visualQuality;

  Map<String, Object?> toJson() => <String, Object?>{
    'observedAt': observedAt.toUtc().toIso8601String(),
    'route': route,
    'tab': tab,
    'lifecycle': lifecycle.name,
    'activeTickers': activeTickers,
    'activePollers': activePollers,
    'activeTasks': activeTasks,
    'sseState': sseState.name,
    'visualQuality': visualQuality.name,
  };
}

final class RuntimeActivitySummary {
  const RuntimeActivitySummary({
    required this.current,
    required this.transitionCount,
    required this.retainedSampleCount,
    required this.peakTickers,
    required this.peakPollers,
    required this.peakTasks,
    required this.totalRebuilds,
    required this.rebuildsByOwner,
  });

  final RuntimeActivitySample current;
  final int transitionCount;
  final int retainedSampleCount;
  final int peakTickers;
  final int peakPollers;
  final int peakTasks;
  final int totalRebuilds;
  final Map<String, int> rebuildsByOwner;

  Map<String, Object?> toJson() => <String, Object?>{
    ...current.toJson(),
    'transitionCount': transitionCount,
    'retainedSampleCount': retainedSampleCount,
    'peakTickers': peakTickers,
    'peakPollers': peakPollers,
    'peakTasks': peakTasks,
    'totalRebuilds': totalRebuilds,
    'rebuildsByOwner': rebuildsByOwner,
  };
}

final class RuntimeActivityMetricsScope extends InheritedWidget {
  const RuntimeActivityMetricsScope({
    required this.metrics,
    required super.child,
    super.key,
  });

  final RuntimeActivityMetrics metrics;

  static RuntimeActivityMetrics? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<RuntimeActivityMetricsScope>()
      ?.metrics;

  @override
  bool updateShouldNotify(RuntimeActivityMetricsScope oldWidget) =>
      !identical(metrics, oldWidget.metrics);
}

final class RuntimeTickerMetricsLease {
  RuntimeTickerMetricsLease(String category)
    : _owner = '${sanitizeMetricLabel(category, maxLength: 28)}.${_nextId++}';

  static var _nextId = 0;
  final String _owner;
  RuntimeActivityMetrics? _metrics;
  var _active = false;

  void sync(BuildContext context, {required bool active}) {
    final nextMetrics = RuntimeActivityMetricsScope.maybeOf(context);
    if (!identical(_metrics, nextMetrics)) {
      if (_active) _metrics?.removeTicker(_owner);
      _metrics = nextMetrics;
      _active = false;
    }
    if (_active == active) return;
    _active = active;
    if (active) {
      _metrics?.setTickerActive(_owner);
    } else {
      _metrics?.removeTicker(_owner);
    }
  }

  void dispose() {
    if (_active) _metrics?.removeTicker(_owner);
    _active = false;
    _metrics = null;
  }
}

final class RuntimeActivityMetrics {
  RuntimeActivityMetrics({
    int capacity = 120,
    int maxRebuildOwners = 16,
    DateTime Function()? now,
  }) : _maxRebuildOwners = maxRebuildOwners,
       _samples = BoundedMetricBuffer<RuntimeActivitySample>(
         capacity: capacity,
       ),
       _now = now ?? DateTime.now {
    if (maxRebuildOwners < 1) {
      throw ArgumentError.value(
        maxRebuildOwners,
        'maxRebuildOwners',
        'must be positive',
      );
    }
    _current = _createSample();
  }

  final int _maxRebuildOwners;
  final BoundedMetricBuffer<RuntimeActivitySample> _samples;
  final DateTime Function() _now;
  late RuntimeActivitySample _current;
  var _transitionCount = 0;
  var _peakTickers = 0;
  var _peakPollers = 0;
  var _peakTasks = 0;
  var _totalRebuilds = 0;
  final Map<String, int> _rebuildsByOwner = <String, int>{};
  final Set<String> _tickerOwners = <String>{};
  final Set<String> _pollerOwners = <String>{};
  final Map<String, RuntimeSseState> _sseStatesByOwner =
      <String, RuntimeSseState>{};
  var _disposed = false;

  RuntimeActivitySample get current => _current;

  void recordRebuild(String owner) {
    if (_disposed) return;
    var label = sanitizeMetricLabel(owner, maxLength: 40);
    if (!_rebuildsByOwner.containsKey(label) &&
        _rebuildsByOwner.length >= _maxRebuildOwners) {
      label = 'other';
    }
    _rebuildsByOwner[label] = (_rebuildsByOwner[label] ?? 0) + 1;
    _totalRebuilds += 1;
  }

  void update({
    String? route,
    String? tab,
    AppLifecycleState? lifecycle,
    int? activeTasks,
    RuntimeVisualQuality? visualQuality,
  }) {
    if (_disposed) return;
    final nextLifecycle = lifecycle ?? _current.lifecycle;
    if (nextLifecycle != AppLifecycleState.resumed) {
      _clearActivityOwners();
    }
    final next = _createSample(
      route: route ?? _current.route,
      tab: tab ?? _current.tab,
      lifecycle: nextLifecycle,
      activeTickers: _tickerOwners.length,
      activePollers: _pollerOwners.length,
      activeTasks: activeTasks ?? _current.activeTasks,
      sseState: _aggregateSseState,
      visualQuality: visualQuality ?? _current.visualQuality,
    );
    _commit(next);
  }

  void setTickerActive(String owner) {
    if (_disposed || !_tickerOwners.add(_ownerKey(owner))) return;
    _publishOwnerActivity();
  }

  void removeTicker(String owner) {
    if (_disposed || !_tickerOwners.remove(_ownerKey(owner))) return;
    _publishOwnerActivity();
  }

  void setPollerActive(String owner) {
    if (_disposed || !_pollerOwners.add(_ownerKey(owner))) return;
    _publishOwnerActivity();
  }

  void removePoller(String owner) {
    if (_disposed || !_pollerOwners.remove(_ownerKey(owner))) return;
    _publishOwnerActivity();
  }

  void setSseState(String owner, RuntimeSseState state) {
    if (_disposed) return;
    final key = _ownerKey(owner);
    if (_sseStatesByOwner[key] == state) return;
    _sseStatesByOwner[key] = state;
    _publishOwnerActivity();
  }

  void removeSseState(String owner) {
    if (_disposed || _sseStatesByOwner.remove(_ownerKey(owner)) == null) return;
    _publishOwnerActivity();
  }

  void clearRuntimeOwners() {
    if (_disposed || !_clearActivityOwners()) return;
    _publishOwnerActivity();
  }

  void dispose() {
    if (_disposed) return;
    clearRuntimeOwners();
    _disposed = true;
  }

  void _publishOwnerActivity() {
    _commit(
      _createSample(
        route: _current.route,
        tab: _current.tab,
        lifecycle: _current.lifecycle,
        activeTickers: _tickerOwners.length,
        activePollers: _pollerOwners.length,
        activeTasks: _current.activeTasks,
        sseState: _aggregateSseState,
        visualQuality: _current.visualQuality,
      ),
    );
  }

  void _commit(RuntimeActivitySample next) {
    if (_sameActivity(_current, next)) return;
    _current = next;
    _samples.add(next);
    _transitionCount += 1;
    _peakTickers = math.max(_peakTickers, next.activeTickers);
    _peakPollers = math.max(_peakPollers, next.activePollers);
    _peakTasks = math.max(_peakTasks, next.activeTasks);
  }

  bool _clearActivityOwners() {
    if (_tickerOwners.isEmpty &&
        _pollerOwners.isEmpty &&
        _sseStatesByOwner.isEmpty) {
      return false;
    }
    _tickerOwners.clear();
    _pollerOwners.clear();
    _sseStatesByOwner.clear();
    return true;
  }

  RuntimeSseState get _aggregateSseState {
    var aggregate = RuntimeSseState.disconnected;
    for (final state in _sseStatesByOwner.values) {
      if (_sseSeverity(state) > _sseSeverity(aggregate)) aggregate = state;
    }
    return aggregate;
  }

  static String _ownerKey(String owner) =>
      sanitizeMetricLabel(owner, fallback: 'runtime_owner', maxLength: 40);

  RuntimeActivitySummary snapshot() => RuntimeActivitySummary(
    current: _current,
    transitionCount: _transitionCount,
    retainedSampleCount: _samples.length,
    peakTickers: math.max(_peakTickers, _current.activeTickers),
    peakPollers: math.max(_peakPollers, _current.activePollers),
    peakTasks: math.max(_peakTasks, _current.activeTasks),
    totalRebuilds: _totalRebuilds,
    rebuildsByOwner: UnmodifiableMapView<String, int>(_rebuildsByOwner),
  );

  RuntimeActivitySample _createSample({
    String route = '/',
    String tab = 'unknown',
    AppLifecycleState lifecycle = AppLifecycleState.detached,
    int activeTickers = 0,
    int activePollers = 0,
    int activeTasks = 0,
    RuntimeSseState sseState = RuntimeSseState.disconnected,
    RuntimeVisualQuality visualQuality = RuntimeVisualQuality.balanced,
  }) {
    return RuntimeActivitySample(
      observedAt: _now().toUtc(),
      route: sanitizeMetricRoute(route),
      tab: sanitizeMetricLabel(tab, maxLength: 32),
      lifecycle: lifecycle,
      activeTickers: math.max(0, activeTickers),
      activePollers: math.max(0, activePollers),
      activeTasks: math.max(0, activeTasks),
      sseState: sseState,
      visualQuality: visualQuality,
    );
  }
}

int _sseSeverity(RuntimeSseState state) => switch (state) {
  RuntimeSseState.disconnected => 0,
  RuntimeSseState.healthy => 1,
  RuntimeSseState.connecting => 2,
  RuntimeSseState.fallbackPolling => 3,
  RuntimeSseState.failed => 4,
};

bool _sameActivity(RuntimeActivitySample left, RuntimeActivitySample right) =>
    left.route == right.route &&
    left.tab == right.tab &&
    left.lifecycle == right.lifecycle &&
    left.activeTickers == right.activeTickers &&
    left.activePollers == right.activePollers &&
    left.activeTasks == right.activeTasks &&
    left.sseState == right.sseState &&
    left.visualQuality == right.visualQuality;
