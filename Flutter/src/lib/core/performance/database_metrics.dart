import 'dart:math' as math;

import 'performance_snapshot.dart';

final class DatabaseMetricSample {
  const DatabaseMetricSample({
    required this.operation,
    required this.table,
    required this.queueWait,
    required this.execute,
    required this.rows,
    required this.bytes,
    required this.reason,
    required this.callerFeature,
    required this.isWrite,
    required this.success,
  });

  final String operation;
  final String table;
  final Duration queueWait;
  final Duration execute;
  final int rows;
  final int bytes;
  final String reason;
  final String callerFeature;
  final bool isWrite;
  final bool success;
}

final class DatabaseMetricsSummary {
  const DatabaseMetricsSummary({
    required this.operations,
    required this.reads,
    required this.writes,
    required this.failures,
    required this.rows,
    required this.bytes,
    required this.queueDepth,
    required this.peakQueueDepth,
    required this.queueWait,
    required this.execute,
    required this.longestExecuteMs,
    required this.retainedSampleCount,
    required this.byOperation,
    required this.byTable,
  });

  final int operations;
  final int reads;
  final int writes;
  final int failures;
  final int rows;
  final int bytes;
  final int queueDepth;
  final int peakQueueDepth;
  final MetricPercentiles queueWait;
  final MetricPercentiles execute;
  final double longestExecuteMs;
  final int retainedSampleCount;
  final Map<String, int> byOperation;
  final Map<String, int> byTable;

  Map<String, Object?> toJson() => <String, Object?>{
    'operations': operations,
    'reads': reads,
    'writes': writes,
    'failures': failures,
    'rows': rows,
    'bytes': bytes,
    'queueDepth': queueDepth,
    'peakQueueDepth': peakQueueDepth,
    'queueWait': queueWait.toJson(),
    'execute': execute.toJson(),
    'longestExecuteMs': longestExecuteMs,
    'retainedSampleCount': retainedSampleCount,
    'byOperation': byOperation,
    'byTable': byTable,
  };
}

final class DatabaseMetrics {
  DatabaseMetrics({int capacity = 200, this.maxLabels = 24})
    : _samples = BoundedMetricBuffer<DatabaseMetricSample>(capacity: capacity) {
    if (maxLabels < 1) {
      throw ArgumentError.value(maxLabels, 'maxLabels', 'must be positive');
    }
  }

  final int maxLabels;
  final BoundedMetricBuffer<DatabaseMetricSample> _samples;
  final Map<String, int> _byOperation = <String, int>{};
  final Map<String, int> _byTable = <String, int>{};
  var _operations = 0;
  var _reads = 0;
  var _writes = 0;
  var _failures = 0;
  var _rows = 0;
  var _bytes = 0;
  var _queueDepth = 0;
  var _peakQueueDepth = 0;
  var _longestExecute = Duration.zero;

  void setQueueDepth(int value) {
    _queueDepth = math.max(0, value);
    _peakQueueDepth = math.max(_peakQueueDepth, _queueDepth);
  }

  void record({
    required String operation,
    required String table,
    required Duration queueWait,
    required Duration execute,
    int rows = 0,
    int bytes = 0,
    String reason = 'unspecified',
    String callerFeature = 'unknown',
    bool isWrite = true,
    bool success = true,
  }) {
    final safeOperation = _boundedLabel(_byOperation, operation);
    final safeTable = _boundedLabel(_byTable, table);
    final sample = DatabaseMetricSample(
      operation: safeOperation,
      table: safeTable,
      queueWait: _nonNegative(queueWait),
      execute: _nonNegative(execute),
      rows: math.max(0, rows),
      bytes: math.max(0, bytes),
      reason: sanitizeMetricLabel(reason, maxLength: 40),
      callerFeature: sanitizeMetricLabel(callerFeature, maxLength: 40),
      isWrite: isWrite,
      success: success,
    );
    _samples.add(sample);
    _operations += 1;
    isWrite ? _writes += 1 : _reads += 1;
    if (!success) _failures += 1;
    _rows += sample.rows;
    _bytes += sample.bytes;
    if (sample.execute > _longestExecute) _longestExecute = sample.execute;
  }

  DatabaseMetricsSummary snapshot() => DatabaseMetricsSummary(
    operations: _operations,
    reads: _reads,
    writes: _writes,
    failures: _failures,
    rows: _rows,
    bytes: _bytes,
    queueDepth: _queueDepth,
    peakQueueDepth: _peakQueueDepth,
    queueWait: MetricPercentiles.fromDurations(
      _samples.values.map((sample) => sample.queueWait),
    ),
    execute: MetricPercentiles.fromDurations(
      _samples.values.map((sample) => sample.execute),
    ),
    longestExecuteMs: _longestExecute.inMicroseconds / 1000,
    retainedSampleCount: _samples.length,
    byOperation: Map<String, int>.unmodifiable(_byOperation),
    byTable: Map<String, int>.unmodifiable(_byTable),
  );

  String _boundedLabel(Map<String, int> counts, String raw) {
    final safe = sanitizeMetricLabel(raw, maxLength: 48);
    final key = counts.containsKey(safe) || counts.length < maxLabels
        ? safe
        : 'other';
    counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    return key;
  }
}

Duration _nonNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;
