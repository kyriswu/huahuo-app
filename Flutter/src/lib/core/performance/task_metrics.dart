import 'dart:math' as math;

import 'performance_snapshot.dart';

enum TaskMetricOutcome { succeeded, failed, cancelled }

final class _TaskKindAggregate {
  var started = 0;
  var succeeded = 0;
  var failed = 0;
  var cancelled = 0;
  var retries = 0;
  var active = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'started': started,
    'succeeded': succeeded,
    'failed': failed,
    'cancelled': cancelled,
    'retries': retries,
    'active': active,
  };
}

final class TaskMetricsSummary {
  const TaskMetricsSummary({
    required this.started,
    required this.succeeded,
    required this.failed,
    required this.cancelled,
    required this.retries,
    required this.active,
    required this.peakActive,
    required this.duration,
    required this.retainedSampleCount,
    required this.byKind,
  });

  final int started;
  final int succeeded;
  final int failed;
  final int cancelled;
  final int retries;
  final int active;
  final int peakActive;
  final MetricPercentiles duration;
  final int retainedSampleCount;
  final Map<String, Map<String, Object?>> byKind;

  Map<String, Object?> toJson() => <String, Object?>{
    'started': started,
    'succeeded': succeeded,
    'failed': failed,
    'cancelled': cancelled,
    'retries': retries,
    'active': active,
    'peakActive': peakActive,
    'duration': duration.toJson(),
    'retainedSampleCount': retainedSampleCount,
    'byKind': byKind,
  };
}

final class TaskMetrics {
  TaskMetrics({int capacity = 200, this.maxKinds = 24})
    : _durations = BoundedMetricBuffer<Duration>(capacity: capacity) {
    if (maxKinds < 1) {
      throw ArgumentError.value(maxKinds, 'maxKinds', 'must be positive');
    }
  }

  final int maxKinds;
  final BoundedMetricBuffer<Duration> _durations;
  final Map<String, _TaskKindAggregate> _byKind =
      <String, _TaskKindAggregate>{};
  var _started = 0;
  var _succeeded = 0;
  var _failed = 0;
  var _cancelled = 0;
  var _retries = 0;
  var _active = 0;
  var _peakActive = 0;

  void recordStarted(String kind) {
    final aggregate = _aggregate(kind);
    aggregate
      ..started += 1
      ..active += 1;
    _started += 1;
    _active += 1;
    _peakActive = math.max(_peakActive, _active);
  }

  void recordFinished(
    String kind, {
    required TaskMetricOutcome outcome,
    Duration? elapsed,
  }) {
    final aggregate = _aggregate(kind);
    if (aggregate.active > 0) aggregate.active -= 1;
    if (_active > 0) _active -= 1;
    switch (outcome) {
      case TaskMetricOutcome.succeeded:
        aggregate.succeeded += 1;
        _succeeded += 1;
      case TaskMetricOutcome.failed:
        aggregate.failed += 1;
        _failed += 1;
      case TaskMetricOutcome.cancelled:
        aggregate.cancelled += 1;
        _cancelled += 1;
    }
    if (elapsed != null) {
      _durations.add(elapsed.isNegative ? Duration.zero : elapsed);
    }
  }

  void recordRetry(String kind) {
    _aggregate(kind).retries += 1;
    _retries += 1;
  }

  TaskMetricsSummary snapshot() => TaskMetricsSummary(
    started: _started,
    succeeded: _succeeded,
    failed: _failed,
    cancelled: _cancelled,
    retries: _retries,
    active: _active,
    peakActive: _peakActive,
    duration: MetricPercentiles.fromDurations(_durations.values),
    retainedSampleCount: _durations.length,
    byKind: Map<String, Map<String, Object?>>.unmodifiable(
      <String, Map<String, Object?>>{
        for (final entry in _byKind.entries) entry.key: entry.value.toJson(),
      },
    ),
  );

  _TaskKindAggregate _aggregate(String rawKind) {
    final safeKind = sanitizeMetricLabel(rawKind, maxLength: 40);
    final key = _byKind.containsKey(safeKind) || _byKind.length < maxKinds
        ? safeKind
        : 'other';
    return _byKind.putIfAbsent(key, _TaskKindAggregate.new);
  }
}
