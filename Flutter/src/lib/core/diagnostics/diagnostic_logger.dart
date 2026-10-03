import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../database/diagnostic_log_dao.dart';
import 'privacy_redactor.dart';

enum DiagnosticCategory {
  auth('auth'),
  device('device'),
  api('api'),
  recording('recording'),
  upload('upload'),
  asr('asr'),
  workAi('work_ai'),
  feedAi('feed_ai'),
  assets('assets'),
  player('player'),
  export('export'),
  permission('permission'),
  app('app');

  const DiagnosticCategory(this.wireName);

  final String wireName;
}

final class DiagnosticLogInput {
  const DiagnosticLogInput({
    required this.category,
    required this.severity,
    required this.safeSummary,
    this.correlationId,
    this.metadata = const <String, Object?>{},
    this.developerOnly = false,
    this.createdAt,
    this.retentionDays = 7,
    this.flushImmediately = false,
  });

  final DiagnosticCategory category;
  final DiagnosticSeverity severity;
  final String safeSummary;
  final String? correlationId;
  final Map<String, Object?> metadata;
  final bool developerOnly;
  final DateTime? createdAt;
  final int retentionDays;
  final bool flushImmediately;
}

typedef DiagnosticIdleScheduler = void Function(void Function() callback);

final class DiagnosticLogger {
  DiagnosticLogger({
    required DiagnosticLogDao dao,
    PrivacyRedactor redactor = privacyRedactor,
    DateTime Function()? now,
    DiagnosticIdleScheduler? scheduleIdle,
    bool Function()? canDeferFlush,
    this.flushInterval = Duration.zero,
    this.batchSize = 20,
    this.memoryCapacity = 100,
    this.aggregationWindow = const Duration(minutes: 1),
    this.pruneInterval = const Duration(minutes: 5),
    this.maxPersistedEvents = 1000,
  }) : // Public parameter names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _dao = dao,
       // ignore: prefer_initializing_formals
       _redactor = redactor,
       _now = now ?? DateTime.now,
       _scheduleIdle = scheduleIdle,
       _canDeferFlush = canDeferFlush {
    if (flushInterval < Duration.zero) {
      throw ArgumentError.value(
        flushInterval,
        'flushInterval',
        'must not be negative',
      );
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }
    if (memoryCapacity < 1) {
      throw ArgumentError.value(
        memoryCapacity,
        'memoryCapacity',
        'must be positive',
      );
    }
    if (aggregationWindow <= Duration.zero) {
      throw ArgumentError.value(
        aggregationWindow,
        'aggregationWindow',
        'must be positive',
      );
    }
    if (pruneInterval.isNegative) {
      throw ArgumentError.value(
        pruneInterval,
        'pruneInterval',
        'must not be negative',
      );
    }
    if (maxPersistedEvents < 0) {
      throw ArgumentError.value(
        maxPersistedEvents,
        'maxPersistedEvents',
        'must not be negative',
      );
    }
  }

  final DiagnosticLogDao _dao;
  final PrivacyRedactor _redactor;
  final DateTime Function() _now;
  final DiagnosticIdleScheduler? _scheduleIdle;
  final bool Function()? _canDeferFlush;
  final Duration flushInterval;
  final int batchSize;
  final int memoryCapacity;
  final Duration aggregationWindow;
  final Duration pruneInterval;
  final int maxPersistedEvents;
  final ListQueue<String> _pendingOrder = ListQueue<String>();
  final Map<String, _DiagnosticAggregate> _pendingById =
      <String, _DiagnosticAggregate>{};
  final LinkedHashMap<String, _DiagnosticAggregate> _recentByKey =
      LinkedHashMap<String, _DiagnosticAggregate>();

  var _sequence = 0;
  var _idleGeneration = 0;
  var _idleScheduled = false;
  var _disposed = false;
  DateTime? _lastPrunedAt;
  Object? _lastFlushError;
  Future<void>? _deferredFlushFuture;
  Timer? _idleTimer;

  int get pendingEventCount => _pendingById.length;
  bool get isDisposed => _disposed;
  Object? get lastFlushError => _lastFlushError;

  String log(DiagnosticLogInput input) {
    if (_disposed) {
      throw StateError('DiagnosticLogger is disposed');
    }
    final createdAt = (input.createdAt ?? _now()).toUtc();
    final safeSummary = _redactor.safeSummary(input.safeSummary);
    final safeMetadata = _redactor.redactMetadata(input.metadata);
    final explicitCorrelationId = input.correlationId == null
        ? null
        : _redactor.sanitizeCorrelationId(input.correlationId!);
    final retentionDays = input.retentionDays < 1 ? 1 : input.retentionDays;
    final aggregationKey = _aggregationKey(
      input: input,
      safeSummary: safeSummary,
      safeMetadata: safeMetadata,
      explicitCorrelationId: explicitCorrelationId,
      retentionDays: retentionDays,
    );
    _discardExpiredRecent(createdAt);

    var aggregate = _recentByKey.remove(aggregationKey);
    if (aggregate != null &&
        !_withinAggregationWindow(aggregate.lastSeenAt, createdAt)) {
      aggregate = null;
    }
    if (aggregate == null) {
      if (_pendingById.length >= memoryCapacity) flush();
      final correlationId =
          explicitCorrelationId ??
          createCorrelationId(input.category.wireName, createdAt: createdAt);
      final eventId = createCorrelationId(
        input.category.wireName,
        parentCorrelationId: correlationId,
        createdAt: createdAt,
      );
      aggregate = _DiagnosticAggregate(
        eventId: eventId,
        createdAt: createdAt,
        category: input.category.wireName,
        severity: input.severity,
        correlationId: correlationId,
        safeSummary: safeSummary,
        baseMetadata: safeMetadata,
        developerOnly: input.developerOnly,
        retentionUntil: createdAt.add(Duration(days: retentionDays)),
      );
    } else {
      aggregate.addOccurrence(
        createdAt,
        retentionUntil: createdAt.add(Duration(days: retentionDays)),
      );
    }
    _recentByKey[aggregationKey] = aggregate;
    _trimRecent();

    _dao.stage(aggregate.record);
    if (!_pendingById.containsKey(aggregate.eventId)) {
      _pendingById[aggregate.eventId] = aggregate;
      _pendingOrder.addLast(aggregate.eventId);
    }

    if (input.flushImmediately || !(_canDeferFlush?.call() ?? true)) {
      flush();
    } else if (_pendingById.length >= batchSize) {
      if (_dao.supportsDeferredWrites) {
        unawaited(flushDeferred().catchError((Object _) {}));
      } else {
        flush();
      }
    } else {
      _scheduleIdleFlush();
    }
    return aggregate.eventId;
  }

  void flush() {
    _cancelScheduledIdleFlush();
    if (_pendingOrder.isEmpty) return;

    final records = <DiagnosticLogRecord>[];
    final completedIds = <String>[];
    for (final eventId in _pendingOrder) {
      final aggregate = _pendingById[eventId];
      if (aggregate == null || !_dao.isStaged(eventId)) {
        completedIds.add(eventId);
        continue;
      }
      records.add(aggregate.record);
      completedIds.add(eventId);
    }

    try {
      if (records.isNotEmpty) _dao.appendBatch(records);
      _removePending(completedIds);
      _pruneIfDue();
      _lastFlushError = null;
    } catch (error) {
      _lastFlushError = error;
      rethrow;
    }
  }

  Future<void> flushDeferred() {
    final existing = _deferredFlushFuture;
    if (existing != null) return existing;
    final future = _flushDeferred();
    _deferredFlushFuture = future;
    return future.whenComplete(() {
      if (identical(_deferredFlushFuture, future)) {
        _deferredFlushFuture = null;
      }
      if (!_disposed && _lastFlushError == null && _pendingOrder.isNotEmpty) {
        _scheduleIdleFlush();
      }
    });
  }

  Future<void> _flushDeferred() async {
    _cancelScheduledIdleFlush();
    if (_pendingOrder.isEmpty) return;

    final records = <DiagnosticLogRecord>[];
    final capturedCounts = <String, int>{};
    for (final eventId in _pendingOrder) {
      final aggregate = _pendingById[eventId];
      if (aggregate == null || !_dao.isStaged(eventId)) continue;
      records.add(aggregate.record);
      capturedCounts[eventId] = aggregate.count;
    }
    if (records.isEmpty) {
      _removePending(_pendingOrder.toList(growable: false));
      return;
    }

    try {
      await _dao.appendBatchDeferred(records);
      final completedIds = <String>[
        for (final entry in capturedCounts.entries)
          if (_pendingById[entry.key]?.count == entry.value &&
              !_dao.isStaged(entry.key))
            entry.key,
      ];
      _removePending(completedIds);
      _pruneIfDue();
      _lastFlushError = null;
    } catch (error) {
      _lastFlushError = error;
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    flush();
    _disposed = true;
    _recentByKey.clear();
  }

  String createCorrelationId(
    String scene, {
    String? parentCorrelationId,
    DateTime? createdAt,
  }) {
    final safeScene = _safeScene(scene);
    final timestamp = (createdAt ?? _now()).toUtc().microsecondsSinceEpoch;
    final sequence = _sequence++;
    final suffix = _stableSuffix(
      '$safeScene:$timestamp:$parentCorrelationId:$sequence',
    );
    if (parentCorrelationId == null || parentCorrelationId.isEmpty) {
      return '$safeScene-$timestamp-$suffix';
    }
    final safeParent = _redactor.sanitizeCorrelationId(parentCorrelationId);
    return '$safeParent:$safeScene-$suffix';
  }

  ({String safeSummary, String developerSummary}) mapError(Object error) {
    return _redactor.mapErrorToDiagnosticSummary(error);
  }

  void _scheduleIdleFlush() {
    if (_idleScheduled || _pendingById.isEmpty) return;
    _idleScheduled = true;
    final generation = ++_idleGeneration;
    void flushPending() {
      if (_disposed || generation != _idleGeneration) return;
      _idleTimer = null;
      _idleScheduled = false;
      try {
        if (_dao.supportsDeferredWrites) {
          unawaited(flushDeferred().catchError((Object _) {}));
        } else {
          flush();
        }
      } catch (_) {
        // Keep the staged batch for an explicit flush or the next log call.
      }
    }

    final scheduleIdle = _scheduleIdle;
    if (scheduleIdle != null) {
      scheduleIdle(flushPending);
    } else if (flushInterval == Duration.zero) {
      scheduleMicrotask(flushPending);
    } else {
      _idleTimer = Timer(flushInterval, flushPending);
    }
  }

  void _cancelScheduledIdleFlush() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleScheduled = false;
    _idleGeneration += 1;
  }

  void _removePending(Iterable<String> eventIds) {
    final removed = eventIds.toSet();
    for (final eventId in removed) {
      _pendingById.remove(eventId);
    }
    _pendingOrder.removeWhere(removed.contains);
  }

  void _pruneIfDue() {
    final now = _now().toUtc();
    final lastPrunedAt = _lastPrunedAt;
    if (lastPrunedAt != null && now.difference(lastPrunedAt) < pruneInterval) {
      return;
    }
    _dao.prune(now: now, maxEvents: maxPersistedEvents);
    _lastPrunedAt = now;
  }

  void _discardExpiredRecent(DateTime createdAt) {
    _recentByKey.removeWhere(
      (_, aggregate) =>
          createdAt.difference(aggregate.lastSeenAt) > aggregationWindow,
    );
  }

  bool _withinAggregationWindow(DateTime lastSeenAt, DateTime createdAt) {
    final elapsed = createdAt.difference(lastSeenAt);
    return !elapsed.isNegative && elapsed <= aggregationWindow;
  }

  void _trimRecent() {
    while (_recentByKey.length > memoryCapacity) {
      _recentByKey.remove(_recentByKey.keys.first);
    }
  }

  String _aggregationKey({
    required DiagnosticLogInput input,
    required String safeSummary,
    required Map<String, Object> safeMetadata,
    required String? explicitCorrelationId,
    required int retentionDays,
  }) {
    final sortedMetadata = <String, Object>{
      for (final key in safeMetadata.keys.toList()..sort())
        key: safeMetadata[key]!,
    };
    return jsonEncode(<String, Object?>{
      'category': input.category.wireName,
      'severity': input.severity.wireName,
      'summary': safeSummary,
      'metadata': sortedMetadata,
      'correlation': explicitCorrelationId,
      'developerOnly': input.developerOnly,
      'retentionDays': retentionDays,
    });
  }

  String _safeScene(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (sanitized.isEmpty) return 'app';
    return sanitized.length > 24 ? sanitized.substring(0, 24) : sanitized;
  }

  String _stableSuffix(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 33 + codeUnit) % 0x3fffffff;
    }
    return hash.toRadixString(36).padLeft(6, '0').substring(0, 6);
  }
}

final class _DiagnosticAggregate {
  _DiagnosticAggregate({
    required this.eventId,
    required this.createdAt,
    required this.category,
    required this.severity,
    required this.correlationId,
    required this.safeSummary,
    required this.baseMetadata,
    required this.developerOnly,
    required this.retentionUntil,
  }) : firstSeenAt = createdAt,
       lastSeenAt = createdAt;

  final String eventId;
  final DateTime createdAt;
  final String category;
  final DiagnosticSeverity severity;
  final String correlationId;
  final String safeSummary;
  final Map<String, Object> baseMetadata;
  final bool developerOnly;
  final DateTime firstSeenAt;
  DateTime lastSeenAt;
  DateTime retentionUntil;
  var count = 1;

  DiagnosticLogRecord get record => DiagnosticLogRecord(
    eventId: eventId,
    createdAt: createdAt,
    category: category,
    severity: severity,
    correlationId: correlationId,
    safeSummary: safeSummary,
    redactedMetadata: Map<String, Object>.unmodifiable(<String, Object>{
      ...baseMetadata,
      'aggregate_count': count,
      'aggregate_first_seen_at': firstSeenAt.toIso8601String(),
      'aggregate_last_seen_at': lastSeenAt.toIso8601String(),
    }),
    developerOnly: developerOnly,
    retentionUntil: retentionUntil,
  );

  void addOccurrence(DateTime occurredAt, {required DateTime retentionUntil}) {
    count += 1;
    lastSeenAt = occurredAt;
    if (retentionUntil.isAfter(this.retentionUntil)) {
      this.retentionUntil = retentionUntil;
    }
  }
}
