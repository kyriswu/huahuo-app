import 'dart:async';
import 'dart:collection';

import '../performance/database_metrics.dart';

typedef DatabaseWriteAction = FutureOr<void> Function();
typedef DatabaseAppendBatchAction<T> = FutureOr<void> Function(List<T> values);

final class DatabaseWriteQueue {
  DatabaseWriteQueue({DatabaseMetrics? metrics, DateTime Function()? now})
    : // Public parameter name intentionally differs from private storage.
      // ignore: prefer_initializing_formals
      _metrics = metrics,
      _now = now ?? DateTime.now;

  final DatabaseMetrics? _metrics;
  final DateTime Function() _now;
  final ListQueue<_QueuedDatabaseWrite> _pending =
      ListQueue<_QueuedDatabaseWrite>();
  final Map<String, _ReplaceableDatabaseWrite> _replaceableByKey =
      <String, _ReplaceableDatabaseWrite>{};
  final Map<String, _AppendDatabaseWrite<Object?>> _appendByKey =
      <String, _AppendDatabaseWrite<Object?>>{};
  final List<Completer<void>> _flushWaiters = <Completer<void>>[];

  bool _draining = false;
  bool _drainScheduled = false;
  bool _accepting = true;
  bool _disposed = false;
  Object? _firstError;
  StackTrace? _firstErrorStack;
  Future<void>? _disposeFuture;

  int get queueDepth => _pending.length + (_draining ? 1 : 0);
  bool get isDisposed => _disposed;

  Future<void> enqueue({
    required String key,
    required DatabaseWriteAction operation,
    bool replacePending = false,
    String operationLabel = 'queued_write',
    String table = 'unknown',
    String reason = 'unspecified',
    String callerFeature = 'unknown',
    int rows = 1,
    int bytes = 0,
  }) {
    final stableKey = _stableKey(key);
    if (!_accepting) return _rejectedFuture();
    final waiter = Completer<void>();
    if (replacePending) {
      final existing = _replaceableByKey[stableKey];
      if (existing != null) {
        existing.replace(
          operation: operation,
          operationLabel: operationLabel,
          table: table,
          reason: reason,
          callerFeature: callerFeature,
          rows: rows,
          bytes: bytes,
          waiter: waiter,
        );
        return waiter.future;
      }
    }

    final queued = _ReplaceableDatabaseWrite(
      stableKey: stableKey,
      enqueuedAt: _now().toUtc(),
      operation: operation,
      operationLabel: operationLabel,
      table: table,
      reason: reason,
      callerFeature: callerFeature,
      rows: rows,
      bytes: bytes,
      replaceable: replacePending,
      waiter: waiter,
    );
    _pending.addLast(queued);
    if (replacePending) _replaceableByKey[stableKey] = queued;
    _scheduleDrain();
    return waiter.future;
  }

  Future<void> enqueueAppend<T>({
    required String key,
    required T value,
    required DatabaseAppendBatchAction<T> operation,
    String operationLabel = 'append_batch',
    String table = 'unknown',
    String reason = 'append',
    String callerFeature = 'unknown',
    int bytes = 0,
  }) {
    final stableKey = _stableKey(key);
    if (!_accepting) return _rejectedFuture();
    final waiter = Completer<void>();
    final existing = _appendByKey[stableKey];
    if (existing != null) {
      if (existing is! _AppendDatabaseWrite<T>) {
        return Future<void>.error(
          StateError('Database append key reused with a different value type'),
        );
      }
      existing.add(value: value, bytes: bytes, waiter: waiter);
      return waiter.future;
    }

    final queued = _AppendDatabaseWrite<T>(
      stableKey: stableKey,
      enqueuedAt: _now().toUtc(),
      value: value,
      operation: operation,
      operationLabel: operationLabel,
      table: table,
      reason: reason,
      callerFeature: callerFeature,
      bytes: bytes,
      waiter: waiter,
    );
    _appendByKey[stableKey] = queued as _AppendDatabaseWrite<Object?>;
    _pending.addLast(queued);
    _scheduleDrain();
    return waiter.future;
  }

  Future<void> flush() {
    if (!_draining && _pending.isEmpty) return _completedOrFailedFlush();
    final waiter = Completer<void>();
    _flushWaiters.add(waiter);
    _scheduleDrain();
    return waiter.future;
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _accepting = false;
    final future = flush().whenComplete(() {
      _disposed = true;
      _metrics?.setQueueDepth(0);
    });
    _disposeFuture = future;
    return future;
  }

  void _scheduleDrain() {
    _updateDepthMetric();
    if (_draining || _drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(_drain);
  }

  Future<void> _drain() async {
    if (_draining) return;
    _drainScheduled = false;
    _draining = true;
    while (_pending.isNotEmpty) {
      final queued = _pending.removeFirst();
      if (queued is _ReplaceableDatabaseWrite && queued.replaceable) {
        if (identical(_replaceableByKey[queued.stableKey], queued)) {
          _replaceableByKey.remove(queued.stableKey);
        }
      } else if (queued is _AppendDatabaseWrite<Object?>) {
        if (identical(_appendByKey[queued.stableKey], queued)) {
          _appendByKey.remove(queued.stableKey);
        }
      }
      _updateDepthMetric();
      final startedAt = _now().toUtc();
      Object? error;
      StackTrace? errorStack;
      try {
        await queued.run();
        queued.complete();
      } catch (cause, stackTrace) {
        error = cause;
        errorStack = stackTrace;
        _firstError ??= cause;
        _firstErrorStack ??= stackTrace;
        queued.completeError(cause, stackTrace);
      }
      final finishedAt = _now().toUtc();
      _recordMetrics(
        queued,
        queueWait: _elapsed(queued.enqueuedAt, startedAt),
        execute: _elapsed(startedAt, finishedAt),
        success: error == null,
      );
      if (error != null && errorStack == null) {
        _firstErrorStack ??= StackTrace.current;
      }
    }
    _draining = false;
    _updateDepthMetric();
    _completeFlushWaiters();
  }

  void _recordMetrics(
    _QueuedDatabaseWrite queued, {
    required Duration queueWait,
    required Duration execute,
    required bool success,
  }) {
    try {
      _metrics?.record(
        operation: queued.operationLabel,
        table: queued.table,
        queueWait: queueWait,
        execute: execute,
        rows: queued.rows,
        bytes: queued.bytes,
        reason: queued.reason,
        callerFeature: queued.callerFeature,
        success: success,
      );
    } catch (_) {
      // Observability must never alter queue completion semantics.
    }
  }

  void _updateDepthMetric() {
    try {
      _metrics?.setQueueDepth(queueDepth);
    } catch (_) {
      // Observability must never alter queue completion semantics.
    }
  }

  Future<void> _completedOrFailedFlush() {
    final error = _firstError;
    if (error == null) return Future<void>.value();
    final stackTrace = _firstErrorStack ?? StackTrace.current;
    _firstError = null;
    _firstErrorStack = null;
    return Future<void>.error(error, stackTrace);
  }

  void _completeFlushWaiters() {
    if (_flushWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_flushWaiters);
    _flushWaiters.clear();
    final error = _firstError;
    final stackTrace = _firstErrorStack ?? StackTrace.current;
    _firstError = null;
    _firstErrorStack = null;
    for (final waiter in waiters) {
      if (error == null) {
        waiter.complete();
      } else {
        waiter.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _rejectedFuture() => Future<void>.error(
    StateError('DatabaseWriteQueue does not accept new writes after dispose'),
  );
}

abstract class _QueuedDatabaseWrite {
  _QueuedDatabaseWrite({
    required this.stableKey,
    required this.enqueuedAt,
    required this.operationLabel,
    required this.table,
    required this.reason,
    required this.callerFeature,
    required this.bytes,
    required Completer<void> waiter,
  }) : waiters = <Completer<void>>[waiter];

  final String stableKey;
  final DateTime enqueuedAt;
  String operationLabel;
  String table;
  String reason;
  String callerFeature;
  int bytes;
  final List<Completer<void>> waiters;

  int get rows;
  Future<void> run();

  void complete() {
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
    }
  }
}

final class _ReplaceableDatabaseWrite extends _QueuedDatabaseWrite {
  _ReplaceableDatabaseWrite({
    required super.stableKey,
    required super.enqueuedAt,
    required DatabaseWriteAction operation,
    required super.operationLabel,
    required super.table,
    required super.reason,
    required super.callerFeature,
    required int rows,
    required super.bytes,
    required this.replaceable,
    required super.waiter,
  }) : // Public parameter name is shared with the queue API.
       // ignore: prefer_initializing_formals
       _operation = operation,
       _rows = rows < 0 ? 0 : rows;

  DatabaseWriteAction _operation;
  int _rows;
  final bool replaceable;

  @override
  int get rows => _rows;

  void replace({
    required DatabaseWriteAction operation,
    required String operationLabel,
    required String table,
    required String reason,
    required String callerFeature,
    required int rows,
    required int bytes,
    required Completer<void> waiter,
  }) {
    _operation = operation;
    this.operationLabel = operationLabel;
    this.table = table;
    this.reason = reason;
    this.callerFeature = callerFeature;
    _rows = rows < 0 ? 0 : rows;
    this.bytes = bytes < 0 ? 0 : bytes;
    waiters.add(waiter);
  }

  @override
  Future<void> run() => Future<void>.sync(_operation);
}

final class _AppendDatabaseWrite<T> extends _QueuedDatabaseWrite {
  _AppendDatabaseWrite({
    required super.stableKey,
    required super.enqueuedAt,
    required T value,
    required DatabaseAppendBatchAction<T> operation,
    required super.operationLabel,
    required super.table,
    required super.reason,
    required super.callerFeature,
    required super.bytes,
    required super.waiter,
  }) : // Public parameter name is shared with the queue API.
       // ignore: prefer_initializing_formals
       _operation = operation,
       _values = <T>[value];

  final DatabaseAppendBatchAction<T> _operation;
  final List<T> _values;

  @override
  int get rows => _values.length;

  void add({
    required T value,
    required int bytes,
    required Completer<void> waiter,
  }) {
    _values.add(value);
    this.bytes += bytes < 0 ? 0 : bytes;
    waiters.add(waiter);
  }

  @override
  Future<void> run() =>
      Future<void>.sync(() => _operation(List<T>.unmodifiable(_values)));
}

String _stableKey(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 256) {
    throw ArgumentError.value(value, 'key', 'must be 1-256 characters');
  }
  return normalized;
}

Duration _elapsed(DateTime start, DateTime end) {
  final value = end.difference(start);
  return value.isNegative ? Duration.zero : value;
}
