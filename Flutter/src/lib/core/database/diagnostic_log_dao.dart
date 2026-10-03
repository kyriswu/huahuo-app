import 'dart:async';
import 'dart:convert';

import '../diagnostics/privacy_redactor.dart';
import 'app_database.dart';
import 'database_worker.dart';
import 'database_write_queue.dart';

enum DiagnosticSeverity {
  debug('debug'),
  info('info'),
  warning('warning'),
  error('error');

  const DiagnosticSeverity(this.wireName);

  final String wireName;
}

final class DiagnosticLogRecord {
  const DiagnosticLogRecord({
    required this.eventId,
    required this.createdAt,
    required this.category,
    required this.severity,
    required this.correlationId,
    required this.safeSummary,
    required this.redactedMetadata,
    required this.developerOnly,
    required this.retentionUntil,
  });

  final String eventId;
  final DateTime createdAt;
  final String category;
  final DiagnosticSeverity severity;
  final String correlationId;
  final String safeSummary;
  final Map<String, Object> redactedMetadata;
  final bool developerOnly;
  final DateTime retentionUntil;
}

final class DiagnosticLogQuery {
  const DiagnosticLogQuery({
    this.since,
    this.until,
    this.categories = const <String>[],
    this.includeDeveloperOnly = false,
    this.limit = 200,
  });

  final DateTime? since;
  final DateTime? until;
  final List<String> categories;
  final bool includeDeveloperOnly;
  final int limit;
}

final class DiagnosticLogDao {
  DiagnosticLogDao(
    this._database, {
    PrivacyRedactor redactor = privacyRedactor,
    DatabaseRecordWorkerPort? worker,
    DatabaseWriteQueue? writeQueue,
  }) : // Public parameter names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _worker = worker,
       // ignore: prefer_initializing_formals
       _writeQueue = writeQueue,
       // Public parameter name intentionally differs from private storage.
       // ignore: prefer_initializing_formals
       _redactor = redactor;

  final AppDatabase _database;
  final PrivacyRedactor _redactor;
  final DatabaseRecordWorkerPort? _worker;
  final DatabaseWriteQueue? _writeQueue;
  final Map<String, DiagnosticLogRecord> _staged =
      <String, DiagnosticLogRecord>{};
  final Map<String, DiagnosticLogRecord> _workerPersisted =
      <String, DiagnosticLogRecord>{};
  var _batchSequence = 0;

  int get stagedCount => _staged.length;

  bool get supportsDeferredWrites {
    final worker = _worker;
    return worker != null &&
        worker.isEnabled &&
        !worker.isDisposed &&
        _writeQueue != null;
  }

  String stage(DiagnosticLogRecord event) {
    final safeEvent = _sanitizeEvent(event);
    _staged[safeEvent.eventId] = safeEvent;
    return safeEvent.eventId;
  }

  bool isStaged(String eventId) => _staged.containsKey(eventId);

  String append(DiagnosticLogRecord event) {
    final safeEvent = _sanitizeEvent(event);
    _persistBatchSync(<String, DiagnosticLogRecord>{
      safeEvent.eventId: safeEvent,
    });
    _removeStagedIfCurrent(safeEvent);
    return safeEvent.eventId;
  }

  List<String> appendBatch(Iterable<DiagnosticLogRecord> events) {
    final byId = <String, DiagnosticLogRecord>{};
    for (final event in events) {
      final safeEvent = _sanitizeEvent(event);
      byId[safeEvent.eventId] = safeEvent;
    }
    if (byId.isEmpty) return const <String>[];
    _persistBatchSync(byId);
    for (final event in byId.values) {
      _removeStagedIfCurrent(event);
    }
    return List<String>.unmodifiable(byId.keys);
  }

  Future<List<String>> appendBatchDeferred(
    Iterable<DiagnosticLogRecord> events,
  ) async {
    final byId = <String, DiagnosticLogRecord>{};
    for (final event in events) {
      final safeEvent = _sanitizeEvent(event);
      byId[safeEvent.eventId] = safeEvent;
    }
    if (byId.isEmpty) return const <String>[];
    if (!supportsDeferredWrites) return appendBatch(byId.values);
    await _enqueueWorkerBatch(byId);
    return List<String>.unmodifiable(byId.keys);
  }

  List<DiagnosticLogRecord> query([
    DiagnosticLogQuery query = const DiagnosticLogQuery(),
  ]) {
    final since = query.since;
    final until = query.until;
    final categories = query.categories.toSet();
    final limit = query.limit < 0 ? 0 : query.limit;
    final byId = <String, DiagnosticLogRecord>{
      for (final event in _persistedEvents()) event.eventId: event,
      ..._workerPersisted,
      ..._staged,
    };
    final records =
        byId.values
            .where(
              (event) => query.includeDeveloperOnly || !event.developerOnly,
            )
            .where(
              (event) =>
                  categories.isEmpty || categories.contains(event.category),
            )
            .where((event) => since == null || !event.createdAt.isBefore(since))
            .where((event) => until == null || !event.createdAt.isAfter(until))
            .toList(growable: false)
          ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List<DiagnosticLogRecord>.unmodifiable(records.take(limit));
  }

  int prune({required DateTime now, required int maxEvents}) {
    final allEvents = _persistedEvents()
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    final deleteIds = <String>{};
    for (final event in allEvents) {
      if (!event.retentionUntil.isAfter(now)) {
        deleteIds.add(event.eventId);
      }
    }

    final cap = maxEvents < 0 ? 0 : maxEvents;
    final retained = allEvents
        .where((event) => !deleteIds.contains(event.eventId))
        .toList(growable: false);
    deleteIds.addAll(retained.skip(cap).map((event) => event.eventId));
    if (deleteIds.isEmpty) return 0;
    final result = _database.withTransaction<void>((database) {
      for (final eventId in deleteIds) {
        database.deleteRecord(LocalTableName.diagnosticLogs, eventId);
      }
    });
    _requireTransaction(result, 'DIAGNOSTIC_PRUNE_FAILED');
    for (final eventId in deleteIds) {
      _workerPersisted.remove(eventId);
    }
    _mirrorDeletes(deleteIds, reason: 'retention_prune');
    return deleteIds.length;
  }

  int clear() {
    final eventIds = _persistedEvents().map((event) => event.eventId).toSet();
    final stagedIds = _staged.keys.toSet();
    if (eventIds.isNotEmpty) {
      final result = _database.withTransaction<void>((database) {
        for (final eventId in eventIds) {
          database.deleteRecord(LocalTableName.diagnosticLogs, eventId);
        }
      });
      _requireTransaction(result, 'DIAGNOSTIC_CLEAR_FAILED');
    }
    _staged.clear();
    _workerPersisted.clear();
    _mirrorDeletes(eventIds, reason: 'explicit_clear');
    return eventIds.union(stagedIds).length;
  }

  List<DiagnosticLogRecord> _persistedEvents() {
    final byId = <String, DiagnosticLogRecord>{
      for (final event
          in _database
              .listRecords<LocalDatabaseRecord>(LocalTableName.diagnosticLogs)
              .map(_fromRecord)
              .whereType<DiagnosticLogRecord>())
        event.eventId: event,
      ..._workerPersisted,
    };
    return byId.values.toList(growable: false);
  }

  void _persistBatchSync(Map<String, DiagnosticLogRecord> byId) {
    final result = _database.withTransaction<void>((database) {
      for (final event in byId.values) {
        database.upsertRecord(
          LocalTableName.diagnosticLogs,
          event.eventId,
          _toRecord(event),
        );
      }
    });
    _requireTransaction(result, 'DIAGNOSTIC_BATCH_APPEND_FAILED');
  }

  Future<void> _enqueueWorkerBatch(Map<String, DiagnosticLogRecord> events) {
    final records = <String, LocalDatabaseRecord>{
      for (final event in events.values) event.eventId: _toRecord(event),
    };
    final sequence = _batchSequence++;
    return _writeQueue!.enqueue(
      key: 'diagnostic-batch:$sequence',
      operationLabel: 'append_batch_deferred',
      table: LocalTableName.diagnosticLogs.dbName,
      reason: 'diagnostic_flush',
      callerFeature: 'diagnostics',
      rows: records.length,
      bytes: utf8.encode(jsonEncode(records.values.toList())).length,
      operation: () async {
        await _worker!.upsertRecordBatch(
          table: LocalTableName.diagnosticLogs,
          records: records,
        );
        for (final event in events.values) {
          final existing = _workerPersisted[event.eventId];
          if (existing == null || !_isNewer(existing, event)) {
            _workerPersisted[event.eventId] = event;
          }
          _removeStagedIfCurrent(event);
        }
      },
    );
  }

  void _mirrorDeletes(Set<String> eventIds, {required String reason}) {
    if (!supportsDeferredWrites || eventIds.isEmpty) return;
    final ids = Set<String>.unmodifiable(eventIds);
    final sequence = _batchSequence++;
    unawaited(
      _writeQueue!
          .enqueue(
            key: 'diagnostic-delete:$sequence',
            operationLabel: 'delete_batch_deferred',
            table: LocalTableName.diagnosticLogs.dbName,
            reason: reason,
            callerFeature: 'diagnostics',
            rows: ids.length,
            operation: () async {
              final worker = _worker!;
              if (worker is LocalDatabaseWriteWorkerPort) {
                await (worker as LocalDatabaseWriteWorkerPort)
                    .applyRecordMutations(
                      schemaVersion: _database.schemaVersion,
                      mutations: <LocalDatabaseMutation>[
                        for (final eventId in ids)
                          LocalDatabaseMutation.delete(
                            table: LocalTableName.diagnosticLogs,
                            key: eventId,
                          ),
                      ],
                    );
              } else {
                for (final eventId in ids) {
                  await worker.deleteRecord(
                    table: LocalTableName.diagnosticLogs,
                    key: eventId,
                  );
                }
              }
            },
          )
          .catchError((Object _) {}),
    );
  }

  void _removeStagedIfCurrent(DiagnosticLogRecord event) {
    final staged = _staged[event.eventId];
    if (staged != null && !_isNewer(staged, event)) {
      _staged.remove(event.eventId);
    }
  }

  bool _isNewer(DiagnosticLogRecord left, DiagnosticLogRecord right) {
    final leftCount = left.redactedMetadata['aggregate_count'];
    final rightCount = right.redactedMetadata['aggregate_count'];
    if (leftCount is int && rightCount is int && leftCount != rightCount) {
      return leftCount > rightCount;
    }
    return left.retentionUntil.isAfter(right.retentionUntil);
  }

  void _requireTransaction(
    LocalDatabaseResult<void> result,
    String fallbackCode,
  ) {
    if (result.ok) return;
    final code = result.error?.code ?? fallbackCode;
    throw StateError(code);
  }

  DiagnosticLogRecord _sanitizeEvent(DiagnosticLogRecord event) {
    final correlationId = _redactor.sanitizeCorrelationId(event.correlationId);
    final eventId = _redactor.sanitizeCorrelationId(event.eventId);
    final category = _safeIdentifier(event.category, fallback: 'app');
    return DiagnosticLogRecord(
      eventId: eventId == 'app'
          ? 'diagnostic-$correlationId-${event.createdAt.microsecondsSinceEpoch}'
          : eventId,
      createdAt: event.createdAt.toUtc(),
      category: category,
      severity: event.severity,
      correlationId: correlationId,
      safeSummary: _redactor.safeSummary(event.safeSummary),
      redactedMetadata: _redactor.redactMetadata(event.redactedMetadata),
      developerOnly: event.developerOnly,
      retentionUntil: event.retentionUntil.toUtc(),
    );
  }

  LocalDatabaseRecord _toRecord(DiagnosticLogRecord event) {
    return <String, Object?>{
      'event_id': event.eventId,
      'created_at': event.createdAt.toIso8601String(),
      'category': event.category,
      'severity': event.severity.wireName,
      'correlation_id': event.correlationId,
      'safe_summary': event.safeSummary,
      'redacted_metadata_json': jsonEncode(event.redactedMetadata),
      'developer_only': event.developerOnly,
      'retention_until': event.retentionUntil.toIso8601String(),
    };
  }

  DiagnosticLogRecord? _fromRecord(LocalDatabaseRecord record) {
    try {
      final eventId = _string(record['event_id']);
      final createdAt = DateTime.parse(_string(record['created_at'])).toUtc();
      final category = _string(record['category']);
      final severity = _severity(record['severity']);
      final correlationId = _string(record['correlation_id']);
      final safeSummary = _string(record['safe_summary']);
      final metadata = _metadata(record['redacted_metadata_json']);
      final developerOnly = record['developer_only'] == true;
      final retentionUntil = DateTime.parse(
        _string(record['retention_until']),
      ).toUtc();
      return _sanitizeEvent(
        DiagnosticLogRecord(
          eventId: eventId,
          createdAt: createdAt,
          category: category,
          severity: severity,
          correlationId: correlationId,
          safeSummary: safeSummary,
          redactedMetadata: metadata,
          developerOnly: developerOnly,
          retentionUntil: retentionUntil,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  String _string(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    throw StateError('Invalid diagnostic log record');
  }

  DiagnosticSeverity _severity(Object? value) {
    final text = _string(value);
    for (final severity in DiagnosticSeverity.values) {
      if (severity.wireName == text) return severity;
    }
    throw StateError('Invalid diagnostic severity');
  }

  Map<String, Object> _metadata(Object? value) {
    final decoded = jsonDecode(_string(value));
    if (decoded is! Map<String, Object?>) return const <String, Object>{};
    return _redactor.redactMetadata(decoded);
  }

  String _safeIdentifier(String value, {required String fallback}) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_:-]'), '');
    if (sanitized.isEmpty) return fallback;
    return sanitized.length > 96 ? sanitized.substring(0, 96) : sanitized;
  }
}
