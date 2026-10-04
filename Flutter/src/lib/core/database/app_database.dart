import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:huahuo_api/huahuo_api.dart';
import '../performance/database_metrics.dart';
import 'database_write_queue.dart';

const localDatabaseSchemaVersion = 16;

enum LocalTableName {
  localRecordings('local_recordings'),
  localRecordingTags('local_recording_tags'),
  localRecordingTagLinks('local_recording_tag_links'),
  localRecordingTrash('local_recording_trash'),
  localRecordingPlayback('local_recording_playback'),
  deviceLocalRecordingMappings('device_local_recording_mappings'),
  recordingCardDownloadedManifest('recording_card_downloaded_manifest'),
  localRecordingUploadDrafts('local_recording_upload_drafts'),
  localRecordingRecoveryCheckpoints('local_recording_recovery_checkpoints'),
  localTransferRecords('local_transfer_records'),
  recordingCardFileLedger('recording_card_file_ledger'),
  recordingCardSyncCheckpoints('recording_card_sync_checkpoints'),
  recordingTranscriptionReceipts('recording_transcription_receipts'),
  materialIngestionDrafts('material_ingestion_drafts'),
  diagnosticLogs('diagnostic_logs'),
  knowledgeLibraryMemberships('knowledge_library_memberships'),
  depositRecords('deposit_records'),
  depositFolders('deposit_folders'),
  voiceprintProfiles('voiceprint_profiles'),
  chatThreadAliases('chat_thread_aliases'),
  chatEntryThreadBindings('chat_entry_thread_bindings'),
  knowledgeItemUserMetadata('knowledge_item_user_metadata'),
  knowledgeViewPreferences('knowledge_view_preferences'),
  creationCanvasDrafts('creation_canvas_drafts'),
  assetClassifications('asset_classifications'),
  growthLedger('growth_ledger'),
  creationCanvasHistory('creation_canvas_history'),
  profileTodos('profile_todos'),
  usageSessions('usage_sessions'),
  recordingCardAccountBindings('recording_card_account_bindings'),
  appPreferences('app_preferences');

  const LocalTableName(this.dbName);

  final String dbName;
}

final class LocalDatabaseTableSchema {
  const LocalDatabaseTableSchema({
    required this.name,
    required this.columns,
    this.storesAudioBlob = false,
  });

  final LocalTableName name;
  final List<String> columns;
  final bool storesAudioBlob;
}

final class LocalDatabaseIndex {
  const LocalDatabaseIndex({
    required this.name,
    required this.table,
    required this.columns,
  });

  final String name;
  final LocalTableName table;
  final List<String> columns;
}

final class LocalDatabaseSchema {
  const LocalDatabaseSchema({
    required this.version,
    required this.tables,
    required this.indexes,
  });

  final int version;
  final List<LocalDatabaseTableSchema> tables;
  final List<LocalDatabaseIndex> indexes;
}

typedef LocalDatabaseRecord = Map<String, Object?>;

enum LocalDatabaseMutationKind { upsert, delete }

final class LocalDatabaseMutation {
  const LocalDatabaseMutation.upsert({
    required this.table,
    required this.key,
    required this.value,
  }) : kind = LocalDatabaseMutationKind.upsert;

  const LocalDatabaseMutation.delete({required this.table, required this.key})
    : kind = LocalDatabaseMutationKind.delete,
      value = null;

  final LocalDatabaseMutationKind kind;
  final LocalTableName table;
  final String key;
  final LocalDatabaseRecord? value;
}

abstract interface class LocalDatabaseWriteWorkerPort {
  bool get isDisposed;

  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  });

  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  });
}

final class DatabaseHealth {
  const DatabaseHealth({
    required this.readable,
    required this.writable,
    required this.schemaVersion,
    required this.tables,
    required this.indexes,
    required this.safeSummary,
  });

  final bool readable;
  final bool writable;
  final int schemaVersion;
  final List<LocalTableName> tables;
  final List<String> indexes;
  final String safeSummary;
}

final class LocalDatabaseResult<T> {
  const LocalDatabaseResult._({required this.ok, this.value, this.error});

  factory LocalDatabaseResult.success(T value) {
    return LocalDatabaseResult<T>._(ok: true, value: value);
  }

  factory LocalDatabaseResult.failure(AppFailure error) {
    return LocalDatabaseResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class AppDatabase {
  AppDatabase({
    this.name = 'huahuo-ai-local.db',
    int schemaVersion = localDatabaseSchemaVersion,
    LocalDatabaseSnapshotStore? snapshotStore,
    DatabaseMetrics? metrics,
    LocalDatabaseWriteWorkerPort? writeWorker,
    DatabaseWriteQueue? writeQueue,
  }) : _schemaVersion = schemaVersion,
       // The public constructor name intentionally differs from the field.
       // ignore: prefer_initializing_formals
       _snapshotStore = snapshotStore,
       // ignore: prefer_initializing_formals
       _metrics = metrics,
       _writeWorker = writeWorker,
       _writeQueue = writeQueue {
    if ((writeWorker == null) != (writeQueue == null)) {
      throw ArgumentError(
        'writeWorker and writeQueue must either both be provided or both omitted',
      );
    }
    for (final table in appDatabaseSchema.tables) {
      _tables[table.name] = <String, LocalDatabaseRecord>{};
    }
    _loadSnapshot();
    if (_schemaVersion < schemaVersion) {
      runMigrations(schemaVersion);
    }
  }

  final String name;
  int _schemaVersion;
  final LocalDatabaseSnapshotStore? _snapshotStore;
  final DatabaseMetrics? _metrics;
  final LocalDatabaseWriteWorkerPort? _writeWorker;
  final DatabaseWriteQueue? _writeQueue;
  final Map<LocalTableName, Map<String, LocalDatabaseRecord>> _tables =
      <LocalTableName, Map<String, LocalDatabaseRecord>>{};
  int _transactionDepth = 0;
  final Map<String, LocalDatabaseMutation> _transactionMutations =
      <String, LocalDatabaseMutation>{};
  bool _transactionRequiresFullSnapshot = false;
  var _batchSequence = 0;

  int get schemaVersion => _schemaVersion;
  bool get usesWorkerPersistence => _writeWorker != null;

  Future<void> flushPersistence() =>
      _writeQueue?.flush() ?? Future<void>.value();

  LocalDatabaseResult<({int from, int to})> runMigrations(int targetVersion) {
    if (targetVersion < _schemaVersion) {
      return LocalDatabaseResult<({int from, int to})>.failure(
        _localDbError('LOCAL_DB_MIGRATION_DOWNGRADE_BLOCKED'),
      );
    }
    final from = _schemaVersion;
    for (final table in appDatabaseSchema.tables) {
      _tables.putIfAbsent(table.name, () => <String, LocalDatabaseRecord>{});
    }
    if (_schemaVersion < 9 && targetVersion >= 9) {
      _migrateAssetClassificationsToV9();
      _backfillGrowthLedgerToV9();
    }
    if (_schemaVersion < 10 && targetVersion >= 10) {
      _migrateDepositFoldersToV10();
    }
    if (_schemaVersion < 12 && targetVersion >= 12) {
      _preserveUnownedRecordingRowsForV12();
    }
    if (_schemaVersion < 15 && targetVersion >= 15) {
      _discardUnscopedChatEntryBindingsForV15();
    }
    if (_schemaVersion < 16 && targetVersion >= 16) {
      _backfillRecordingCardLedgerResumeStateForV16();
    }
    _schemaVersion = targetVersion;
    if (_transactionDepth > 0) {
      _transactionRequiresFullSnapshot = true;
    }
    _persistSnapshot(reason: 'schema_migration');
    return LocalDatabaseResult<({int from, int to})>.success((
      from: from,
      to: targetVersion,
    ));
  }

  void _migrateAssetClassificationsToV9() {
    final rows = _tables[LocalTableName.assetClassifications];
    if (rows == null || rows.isEmpty) return;
    final migrated = <String, LocalDatabaseRecord>{};
    for (final entry in rows.entries) {
      final value = entry.value;
      final scope = value['user_scope'];
      final contentId = value['content_id'];
      final category = switch (value['category']) {
        'expressionTendency' => 'expression',
        'creationOutcome' => 'creation',
        final String category => category,
        _ => null,
      };
      if (scope is! String ||
          scope.trim().isEmpty ||
          contentId is! String ||
          contentId.trim().isEmpty ||
          category == null) {
        migrated[entry.key] = value;
        continue;
      }
      final normalized = <String, Object?>{
        ...value,
        'category': category,
        'knowledge_secondary_labels': category == 'knowledge'
            ? value['knowledge_secondary_labels'] ?? const <Object?>[]
            : const <Object?>[],
        'is_demo': value['is_demo'] == true,
      };
      final key =
          'v3:scope:${_encodedDatabaseKey(scope.trim())}:asset:'
          '${_encodedDatabaseKey(contentId.trim())}:'
          '${_encodedDatabaseKey(category)}';
      final existing = migrated[key];
      if (existing == null ||
          '${normalized['updated_at']}'.compareTo(
                '${existing['updated_at']}',
              ) >=
              0) {
        migrated[key] = Map<String, Object?>.unmodifiable(normalized);
      }
    }
    rows
      ..clear()
      ..addAll(migrated);
  }

  void _backfillGrowthLedgerToV9() {
    final growthRows = _tables[LocalTableName.growthLedger]!;
    final migrated = <String, LocalDatabaseRecord>{};
    final protectedKeys = <String>{};

    for (final entry in growthRows.entries) {
      final value = entry.value;
      final scope = _normalizedMigrationValue(value['user_scope']);
      final contentId = _normalizedMigrationValue(value['content_id']);
      final firstDepositedAt = _validMigrationTimestamp(
        value['first_deposited_at'],
      );
      if (scope == null || contentId == null || firstDepositedAt == null) {
        migrated[entry.key] = value;
        continue;
      }
      final key = _growthLedgerMigrationKey(scope, contentId);
      final existing = migrated[key];
      if (existing == null ||
          _timestampPrecedes(
            firstDepositedAt,
            '${existing['first_deposited_at']}',
          )) {
        migrated[key] = Map<String, Object?>.unmodifiable(<String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'first_deposited_at': firstDepositedAt,
        });
      }
      protectedKeys.add(key);
    }

    final membershipCreatedAt = <String, String>{};
    for (final value
        in _tables[LocalTableName.knowledgeLibraryMemberships]!.values) {
      if (value['collection'] != 'deposits') continue;
      final scope = _normalizedMigrationValue(value['user_scope']);
      final contentId = _normalizedMigrationValue(value['content_id']);
      final createdAt = _validMigrationTimestamp(value['created_at']);
      if (scope == null || contentId == null || createdAt == null) continue;
      final key = _growthLedgerMigrationKey(scope, contentId);
      final existing = membershipCreatedAt[key];
      if (existing == null || _timestampPrecedes(createdAt, existing)) {
        membershipCreatedAt[key] = createdAt;
      }
    }

    for (final value in _tables[LocalTableName.depositRecords]!.values) {
      final scope = _normalizedMigrationValue(value['user_scope']);
      final contentId = _normalizedMigrationValue(value['content_id']);
      if (scope == null || contentId == null) continue;
      final key = _growthLedgerMigrationKey(scope, contentId);
      if (protectedKeys.contains(key)) continue;
      final depositedAt =
          _validMigrationTimestamp(value['deposited_at']) ??
          membershipCreatedAt[key];
      if (depositedAt == null) continue;
      final existing = migrated[key];
      if (existing == null ||
          _timestampPrecedes(
            depositedAt,
            '${existing['first_deposited_at']}',
          )) {
        migrated[key] = Map<String, Object?>.unmodifiable(<String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'first_deposited_at': depositedAt,
        });
      }
    }

    growthRows
      ..clear()
      ..addAll(migrated);
  }

  void _migrateDepositFoldersToV10() {
    final rows = _tables[LocalTableName.depositFolders];
    if (rows == null || rows.isEmpty) return;
    for (final entry in rows.entries.toList(growable: false)) {
      final value = entry.value;
      if (value.containsKey('parent_folder_id')) continue;
      rows[entry.key] = Map<String, Object?>.unmodifiable(<String, Object?>{
        ...value,
        'parent_folder_id': null,
      });
    }
  }

  void _preserveUnownedRecordingRowsForV12() {
    // Legacy recording metadata has no trustworthy owner. Keep it intact but
    // unassigned so account-scoped repositories never expose it by accident.
  }

  void _discardUnscopedChatEntryBindingsForV15() {
    final rows = _tables[LocalTableName.chatEntryThreadBindings];
    if (rows == null || rows.isEmpty) return;
    rows.removeWhere(
      (_, value) => _normalizedMigrationValue(value['workspace_scope']) == null,
    );
  }

  void _backfillRecordingCardLedgerResumeStateForV16() {
    final rows = _tables[LocalTableName.recordingCardFileLedger];
    if (rows == null || rows.isEmpty) return;
    for (final entry in rows.entries.toList(growable: false)) {
      final value = entry.value;
      if (value.containsKey('resume_requested')) continue;
      final localState = value['local_state'];
      rows[entry.key] = Map<String, Object?>.unmodifiable(<String, Object?>{
        ...value,
        'resume_requested': localState == 'queued' || localState == 'syncing',
      });
    }
  }

  LocalDatabaseResult<T> withTransaction<T>(T Function(AppDatabase db) action) {
    final metricStopwatch = _transactionDepth == 0
        ? (Stopwatch()..start())
        : null;
    final snapshot = _cloneTables();
    final snapshotSchemaVersion = _schemaVersion;
    final parentTransactionDepth = _transactionDepth;
    final parentMutations = Map<String, LocalDatabaseMutation>.of(
      _transactionMutations,
    );
    final parentRequiresFullSnapshot = _transactionRequiresFullSnapshot;
    if (parentTransactionDepth == 0) {
      _transactionMutations.clear();
      _transactionRequiresFullSnapshot = false;
    }
    _transactionDepth += 1;
    var affectedRows = 0;
    var affectedBytes = 0;
    var persistenceAttempted = false;
    try {
      final result = action(this);
      _transactionDepth = parentTransactionDepth;
      if (parentTransactionDepth == 0) {
        affectedRows = _transactionMutations.length;
        affectedBytes = _transactionMutations.values.fold<int>(
          0,
          (sum, mutation) => sum + _recordBytes(mutation.value),
        );
        persistenceAttempted = true;
        _commitTransactionMutations();
        _transactionMutations
          ..clear()
          ..addAll(parentMutations);
        _transactionRequiresFullSnapshot = parentRequiresFullSnapshot;
      }
      return LocalDatabaseResult<T>.success(result);
    } catch (cause) {
      affectedRows = _transactionMutations.length;
      affectedBytes = _transactionMutations.values.fold<int>(
        0,
        (sum, mutation) => sum + _recordBytes(mutation.value),
      );
      _transactionDepth = parentTransactionDepth;
      _tables
        ..clear()
        ..addAll(snapshot);
      _schemaVersion = snapshotSchemaVersion;
      _transactionMutations
        ..clear()
        ..addAll(parentMutations);
      _transactionRequiresFullSnapshot = parentRequiresFullSnapshot;
      if (parentTransactionDepth == 0) {
        final snapshotStore = _snapshotStore;
        if (!usesWorkerPersistence &&
            snapshotStore != null &&
            !snapshotStore.supportsAtomicRecordBatch) {
          _persistSnapshot(force: true, reason: 'transaction_rollback');
        }
      }
      if (metricStopwatch != null &&
          !usesWorkerPersistence &&
          !persistenceAttempted) {
        metricStopwatch.stop();
        _recordDatabaseMetric(
          operation: 'transaction',
          table: 'multiple',
          elapsed: metricStopwatch.elapsed,
          rows: affectedRows,
          bytes: affectedBytes,
          reason: 'rollback',
          success: false,
        );
      }
      return LocalDatabaseResult<T>.failure(
        _localDbError('LOCAL_DB_TRANSACTION_FAILED', cause),
      );
    }
  }

  DatabaseHealth getHealth() {
    final presentTables = appDatabaseSchema.tables
        .where((table) => _tables.containsKey(table.name))
        .map((table) => table.name)
        .toList(growable: false);
    return DatabaseHealth(
      readable: presentTables.length == appDatabaseSchema.tables.length,
      writable: true,
      schemaVersion: _schemaVersion,
      tables: presentTables,
      indexes: appDatabaseSchema.indexes
          .map((index) => index.name)
          .toList(growable: false),
      safeSummary:
          'local-db schema=$_schemaVersion tables=${presentTables.length}',
    );
  }

  LocalDatabaseResult<({int clearedRows, String scope})>
  clearUserScopedLocalData(String scope) {
    final normalizedScope = scope.trim();
    if (normalizedScope.isEmpty) {
      throw ArgumentError.value(scope, 'scope', 'must not be empty');
    }
    final mutations = <LocalDatabaseMutation>[];
    for (final table in userScopedLocalTables) {
      final rows = _tables[table];
      if (rows != null) {
        for (final entry in rows.entries.toList(growable: false)) {
          if (entry.value['user_scope'] != normalizedScope) continue;
          rows.remove(entry.key);
          mutations.add(
            LocalDatabaseMutation.delete(table: table, key: entry.key),
          );
        }
      }
    }
    if (_transactionDepth > 0) {
      for (final mutation in mutations) {
        _stageMutation(mutation);
      }
    } else {
      _commitMutations(
        mutations,
        operation: 'clear_scope',
        reason: 'account_cleanup',
        queueKey: 'clear-scope:${_batchSequence++}',
      );
    }
    return LocalDatabaseResult<({int clearedRows, String scope})>.success((
      clearedRows: mutations.length,
      scope: normalizedScope,
    ));
  }

  void upsertRecord(
    LocalTableName table,
    String key,
    LocalDatabaseRecord value,
  ) {
    _upsertRecord(table, key, value);
  }

  void upsertCheckpointRecord(
    LocalTableName table,
    String key,
    LocalDatabaseRecord value,
  ) {
    _upsertRecord(table, key, value);
  }

  void _upsertRecord(
    LocalTableName table,
    String key,
    LocalDatabaseRecord value,
  ) {
    validateLocalDatabaseRecord(value);
    final rows = _tables[table];
    if (rows == null) {
      throw StateError('Missing local table: ${table.dbName}');
    }
    final record = Map<String, Object?>.unmodifiable(value);
    rows[key] = record;
    final mutation = LocalDatabaseMutation.upsert(
      table: table,
      key: key,
      value: record,
    );
    if (_transactionDepth > 0) {
      _stageMutation(mutation);
      return;
    }
    _commitMutations(
      <LocalDatabaseMutation>[mutation],
      operation: 'upsert',
      reason: 'record_mutation',
      queueKey: 'record:${table.dbName}:$key',
      replacePending: true,
    );
  }

  T? getRecord<T extends LocalDatabaseRecord>(
    LocalTableName table,
    String key,
  ) {
    return _tables[table]?[key] as T?;
  }

  List<T> listRecords<T extends LocalDatabaseRecord>(LocalTableName table) {
    return List<T>.unmodifiable(
      (_tables[table]?.values ?? const <LocalDatabaseRecord>[]).cast<T>(),
    );
  }

  bool deleteRecord(LocalTableName table, String key) {
    final removed = _tables[table]?.remove(key) != null;
    if (removed) {
      if (_transactionDepth > 0) {
        _stageMutation(LocalDatabaseMutation.delete(table: table, key: key));
        return true;
      }
      _commitMutations(
        <LocalDatabaseMutation>[
          LocalDatabaseMutation.delete(table: table, key: key),
        ],
        operation: 'delete',
        reason: 'record_mutation',
        queueKey: 'record:${table.dbName}:$key',
        replacePending: true,
      );
    }
    return removed;
  }

  Map<LocalTableName, Map<String, LocalDatabaseRecord>> _cloneTables() {
    return <LocalTableName, Map<String, LocalDatabaseRecord>>{
      for (final entry in _tables.entries)
        entry.key: <String, LocalDatabaseRecord>{...entry.value},
    };
  }

  void _stageMutation(LocalDatabaseMutation mutation) {
    _transactionMutations['${mutation.table.dbName}\u0000${mutation.key}'] =
        mutation;
  }

  void _commitTransactionMutations() {
    if (_transactionRequiresFullSnapshot) {
      _persistSnapshot(force: true, reason: 'schema_migration');
      return;
    }
    _commitMutations(
      _transactionMutations.values,
      operation: 'transaction',
      reason: 'atomic_batch',
      queueKey: 'transaction:${_batchSequence++}',
    );
  }

  void _commitMutations(
    Iterable<LocalDatabaseMutation> mutations, {
    required String operation,
    required String reason,
    required String queueKey,
    bool replacePending = false,
  }) {
    final pending = List<LocalDatabaseMutation>.of(mutations, growable: false);
    if (pending.isEmpty) return;
    final worker = _writeWorker;
    final queue = _writeQueue;
    if (worker != null && queue != null) {
      final future = queue.enqueue(
        key: queueKey.length <= 256
            ? queueKey
            : 'write-sha256:${sha256.convert(utf8.encode(queueKey))}',
        replacePending: replacePending,
        operationLabel: operation,
        table: pending.length == 1 ? pending.single.table.dbName : 'multiple',
        reason: reason,
        callerFeature: 'core_database',
        rows: pending.length,
        bytes: pending.fold<int>(
          0,
          (sum, mutation) => sum + _recordBytes(mutation.value),
        ),
        operation: () => worker.applyRecordMutations(
          schemaVersion: _schemaVersion,
          mutations: pending,
        ),
      );
      unawaited(future.catchError((Object _) {}));
      return;
    }

    final snapshotStore = _snapshotStore;
    if (snapshotStore == null) return;
    if (!snapshotStore.supportsAtomicRecordBatch) {
      final stopwatch = Stopwatch()..start();
      try {
        _persistSnapshot(reason: 'snapshot_fallback');
        stopwatch.stop();
        _recordDatabaseMetric(
          operation: operation,
          table: pending.length == 1 ? pending.single.table.dbName : 'multiple',
          elapsed: stopwatch.elapsed,
          rows: pending.length,
          bytes: pending.fold<int>(
            0,
            (sum, mutation) => sum + _recordBytes(mutation.value),
          ),
          reason: reason,
          success: true,
        );
      } catch (_) {
        stopwatch.stop();
        _recordDatabaseMetric(
          operation: operation,
          table: pending.length == 1 ? pending.single.table.dbName : 'multiple',
          elapsed: stopwatch.elapsed,
          rows: pending.length,
          reason: reason,
          success: false,
        );
        rethrow;
      }
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      if (pending.length == 1) {
        final mutation = pending.single;
        switch (mutation.kind) {
          case LocalDatabaseMutationKind.upsert:
            // performance-rfc: database-worker-persistence
            snapshotStore.upsertRecord(
              schemaVersion: _schemaVersion,
              table: mutation.table,
              key: mutation.key,
              value: mutation.value!,
            );
          case LocalDatabaseMutationKind.delete:
            // performance-rfc: database-worker-persistence
            snapshotStore.deleteRecord(
              schemaVersion: _schemaVersion,
              table: mutation.table,
              key: mutation.key,
            );
        }
      } else {
        snapshotStore._applyRecordBatch(
          schemaVersion: _schemaVersion,
          mutations: pending,
        );
      }
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: operation,
        table: pending.length == 1 ? pending.single.table.dbName : 'multiple',
        elapsed: stopwatch.elapsed,
        rows: pending.length,
        bytes: pending.fold<int>(
          0,
          (sum, mutation) => sum + _recordBytes(mutation.value),
        ),
        reason: reason,
        success: true,
      );
    } catch (_) {
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: operation,
        table: pending.length == 1 ? pending.single.table.dbName : 'multiple',
        elapsed: stopwatch.elapsed,
        rows: pending.length,
        reason: reason,
        success: false,
      );
      rethrow;
    }
  }

  void _loadSnapshot() {
    final snapshotStore = _snapshotStore;
    if (snapshotStore == null) return;
    final stopwatch = Stopwatch()..start();
    try {
      final snapshot = snapshotStore.load();
      if (snapshot != null) {
        _schemaVersion = snapshot.schemaVersion;
        for (final table in appDatabaseSchema.tables) {
          _tables[table.name] = <String, LocalDatabaseRecord>{
            ...?snapshot.tables[table.name],
          };
        }
      }
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: 'load',
        table: 'all',
        elapsed: stopwatch.elapsed,
        rows:
            snapshot?.tables.values.fold<int>(
              0,
              (sum, rows) => sum + rows.length,
            ) ??
            0,
        bytes: _snapshotFileBytes(snapshotStore),
        reason: 'startup_restore',
        success: true,
        isWrite: false,
      );
    } catch (_) {
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: 'load',
        table: 'all',
        elapsed: stopwatch.elapsed,
        reason: 'startup_restore',
        success: false,
        isWrite: false,
      );
      rethrow;
    }
  }

  void _persistSnapshot({
    bool force = false,
    String reason = 'snapshot_fallback',
  }) {
    if (!force && _transactionDepth > 0) return;
    final worker = _writeWorker;
    final queue = _writeQueue;
    if (worker != null && queue != null) {
      final tables = _cloneTables();
      final future = queue.enqueue(
        key: 'projection:${_batchSequence++}',
        operationLabel: 'replace_projection',
        table: 'all',
        reason: reason,
        callerFeature: 'core_database',
        rows: tables.values.fold<int>(0, (sum, rows) => sum + rows.length),
        operation: () => worker.replaceAllRecords(
          schemaVersion: _schemaVersion,
          tables: tables,
        ),
      );
      unawaited(future.catchError((Object _) {}));
      return;
    }
    final snapshotStore = _snapshotStore;
    if (snapshotStore == null) return;
    final stopwatch = Stopwatch()..start();
    try {
      snapshotStore.save(schemaVersion: _schemaVersion, tables: _tables);
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: 'full_snapshot',
        table: 'all',
        elapsed: stopwatch.elapsed,
        rows: _tables.values.fold<int>(0, (sum, rows) => sum + rows.length),
        bytes: _snapshotFileBytes(snapshotStore),
        reason: reason,
        success: true,
      );
    } catch (_) {
      stopwatch.stop();
      _recordDatabaseMetric(
        operation: 'full_snapshot',
        table: 'all',
        elapsed: stopwatch.elapsed,
        rows: _tables.values.fold<int>(0, (sum, rows) => sum + rows.length),
        reason: reason,
        success: false,
      );
      rethrow;
    }
  }

  void _recordDatabaseMetric({
    required String operation,
    required String table,
    required Duration elapsed,
    int rows = 0,
    int bytes = 0,
    required String reason,
    required bool success,
    bool isWrite = true,
  }) {
    try {
      _metrics?.record(
        operation: operation,
        table: table,
        queueWait: Duration.zero,
        execute: elapsed,
        rows: rows,
        bytes: bytes,
        reason: reason,
        callerFeature: 'core_database',
        isWrite: isWrite,
        success: success,
      );
    } catch (_) {
      // Metrics must never affect database durability or return semantics.
    }
  }

  int _recordBytes(LocalDatabaseRecord? value) {
    if (_metrics == null || value == null) return 0;
    try {
      return utf8.encode(jsonEncode(_recordToJson(value))).length;
    } catch (_) {
      return 0;
    }
  }

  int _snapshotFileBytes(LocalDatabaseSnapshotStore store) {
    if (_metrics == null) return 0;
    try {
      return store.file.existsSync() ? store.file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }
}

final class LocalDatabaseSnapshot {
  const LocalDatabaseSnapshot({
    required this.schemaVersion,
    required this.tables,
  });

  final int schemaVersion;
  final Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables;
}

class LocalDatabaseSnapshotStore {
  const LocalDatabaseSnapshotStore({
    required this.file,
    this.backend = LocalDatabaseSnapshotBackend.json,
  });

  final File file;
  final LocalDatabaseSnapshotBackend backend;

  bool get supportsIncrementalRecordUpsert =>
      backend == LocalDatabaseSnapshotBackend.sqlite;

  bool get supportsIncrementalRecordDelete =>
      backend == LocalDatabaseSnapshotBackend.sqlite;

  bool get supportsAtomicRecordBatch =>
      backend == LocalDatabaseSnapshotBackend.sqlite;

  LocalDatabaseSnapshot? load() {
    return switch (backend) {
      LocalDatabaseSnapshotBackend.json => _loadJson(),
      LocalDatabaseSnapshotBackend.sqlite => _loadSqlite(),
    };
  }

  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    switch (backend) {
      case LocalDatabaseSnapshotBackend.json:
        _saveJson(schemaVersion: schemaVersion, tables: tables);
      case LocalDatabaseSnapshotBackend.sqlite:
        _saveSqlite(schemaVersion: schemaVersion, tables: tables);
    }
  }

  void upsertRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord value,
  }) {
    if (!supportsIncrementalRecordUpsert) {
      throw UnsupportedError(
        'Incremental record upsert is unavailable for $backend',
      );
    }
    validateLocalDatabaseRecord(value);
    final db = _openSqlite();
    try {
      _ensureSqliteSchema(db);
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          'INSERT INTO local_metadata(key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          <Object?>['schemaVersion', schemaVersion.toString()],
        );
        db.execute(
          'INSERT INTO local_records(table_name, record_key, payload_json) '
          'VALUES (?, ?, ?) '
          'ON CONFLICT(table_name, record_key) '
          'DO UPDATE SET payload_json = excluded.payload_json',
          <Object?>[table.dbName, key, jsonEncode(_recordToJson(value))],
        );
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.close();
    }
  }

  void deleteRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
  }) {
    if (!supportsIncrementalRecordDelete) {
      throw UnsupportedError(
        'Incremental record delete is unavailable for $backend',
      );
    }
    final db = _openSqlite();
    try {
      _ensureSqliteSchema(db);
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          'INSERT INTO local_metadata(key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          <Object?>['schemaVersion', schemaVersion.toString()],
        );
        db.execute(
          'DELETE FROM local_records '
          'WHERE table_name = ? AND record_key = ?',
          <Object?>[table.dbName, key],
        );
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.close();
    }
  }

  void _applyRecordBatch({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) {
    if (!supportsAtomicRecordBatch) {
      throw UnsupportedError('Atomic record batch is unavailable for $backend');
    }
    final pending = List<LocalDatabaseMutation>.of(mutations, growable: false);
    for (final mutation in pending) {
      final value = mutation.value;
      if (value != null) validateLocalDatabaseRecord(value);
    }
    final db = _openSqlite();
    try {
      _ensureSqliteSchema(db);
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          'INSERT INTO local_metadata(key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          <Object?>['schemaVersion', schemaVersion.toString()],
        );
        final upsert = db.prepare(
          'INSERT INTO local_records(table_name, record_key, payload_json) '
          'VALUES (?, ?, ?) '
          'ON CONFLICT(table_name, record_key) '
          'DO UPDATE SET payload_json = excluded.payload_json',
        );
        try {
          final delete = db.prepare(
            'DELETE FROM local_records '
            'WHERE table_name = ? AND record_key = ?',
          );
          try {
            for (final mutation in pending) {
              switch (mutation.kind) {
                case LocalDatabaseMutationKind.upsert:
                  upsert.execute(<Object?>[
                    mutation.table.dbName,
                    mutation.key,
                    jsonEncode(_recordToJson(mutation.value!)),
                  ]);
                case LocalDatabaseMutationKind.delete:
                  delete.execute(<Object?>[
                    mutation.table.dbName,
                    mutation.key,
                  ]);
              }
            }
          } finally {
            delete.close();
          }
        } finally {
          upsert.close();
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.close();
    }
  }

  LocalDatabaseSnapshot? _loadJson() {
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw StateError('Invalid local database snapshot');
    }
    final schemaVersion = decoded['schemaVersion'];
    final tablesJson = decoded['tables'];
    if (schemaVersion is! int || tablesJson is! Map<String, Object?>) {
      throw StateError('Invalid local database snapshot');
    }
    final tables = <LocalTableName, Map<String, LocalDatabaseRecord>>{};
    for (final table in appDatabaseSchema.tables) {
      final rowsJson = tablesJson[table.name.dbName];
      final rows = <String, LocalDatabaseRecord>{};
      if (rowsJson is Map<String, Object?>) {
        for (final entry in rowsJson.entries) {
          final record = _recordFromJson(entry.value);
          validateLocalDatabaseRecord(record);
          rows[entry.key] = Map<String, Object?>.unmodifiable(record);
        }
      }
      tables[table.name] = rows;
    }
    return LocalDatabaseSnapshot(schemaVersion: schemaVersion, tables: tables);
  }

  void _saveJson({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    file.parent.createSync(recursive: true);
    final payload = <String, Object?>{
      'schemaVersion': schemaVersion,
      'tables': <String, Object?>{
        for (final table in appDatabaseSchema.tables)
          table.name.dbName: <String, Object?>{
            for (final entry
                in (tables[table.name] ?? const <String, LocalDatabaseRecord>{})
                    .entries)
              entry.key: _recordToJson(entry.value),
          },
      },
    };
    final part = File('${file.path}.part');
    part.writeAsStringSync(jsonEncode(payload), flush: true);
    if (file.existsSync()) {
      file.deleteSync();
    }
    part.renameSync(file.path);
  }

  LocalDatabaseSnapshot? _loadSqlite() {
    if (!file.existsSync()) return null;
    final db = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    try {
      final existingTables = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        'AND name IN (?, ?)',
        <Object?>['local_metadata', 'local_records'],
      );
      final tableNames = existingTables.map((row) => '${row['name']}').toSet();
      if (!tableNames.contains('local_records')) return null;
      final versionRows = tableNames.contains('local_metadata')
          ? db.select(
              'SELECT value FROM local_metadata WHERE key = ?',
              <Object?>['schemaVersion'],
            )
          : const <sqlite.Row>[];
      final schemaVersion = versionRows.isEmpty
          ? localDatabaseSchemaVersion
          : int.tryParse('${versionRows.first['value']}') ??
                localDatabaseSchemaVersion;
      final tables = <LocalTableName, Map<String, LocalDatabaseRecord>>{
        for (final table in appDatabaseSchema.tables)
          table.name: <String, LocalDatabaseRecord>{},
      };
      final rows = db.select(
        'SELECT table_name, record_key, payload_json FROM local_records',
      );
      for (final row in rows) {
        final table = _tableByDbName('${row['table_name']}');
        if (table == null) continue;
        final key = '${row['record_key']}';
        final record = _recordFromJson(jsonDecode('${row['payload_json']}'));
        validateLocalDatabaseRecord(record);
        final tableRows = tables.putIfAbsent(
          table,
          () => <String, LocalDatabaseRecord>{},
        );
        tableRows[key] = Map<String, Object?>.unmodifiable(record);
      }
      return LocalDatabaseSnapshot(
        schemaVersion: schemaVersion,
        tables: tables,
      );
    } finally {
      db.close();
    }
  }

  void _saveSqlite({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    final db = _openSqlite();
    try {
      _ensureSqliteSchema(db);
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('DELETE FROM local_metadata');
        db.execute('DELETE FROM local_records');
        db.execute(
          'INSERT INTO local_metadata(key, value) VALUES (?, ?)',
          <Object?>['schemaVersion', schemaVersion.toString()],
        );
        final statement = db.prepare(
          'INSERT INTO local_records(table_name, record_key, payload_json) '
          'VALUES (?, ?, ?)',
        );
        try {
          for (final table in appDatabaseSchema.tables) {
            final rows =
                tables[table.name] ?? const <String, LocalDatabaseRecord>{};
            for (final entry in rows.entries) {
              statement.execute(<Object?>[
                table.name.dbName,
                entry.key,
                jsonEncode(_recordToJson(entry.value)),
              ]);
            }
          }
        } finally {
          statement.close();
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.close();
    }
  }

  sqlite.Database _openSqlite() {
    file.parent.createSync(recursive: true);
    return sqlite.sqlite3.open(file.path);
  }

  void _ensureSqliteSchema(sqlite.Database db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_metadata ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL'
      ')',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_records ('
      'table_name TEXT NOT NULL, '
      'record_key TEXT NOT NULL, '
      'payload_json TEXT NOT NULL, '
      'PRIMARY KEY(table_name, record_key)'
      ')',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_records_table '
      'ON local_records(table_name)',
    );
  }
}

enum LocalDatabaseSnapshotBackend { json, sqlite }

LocalDatabaseRecord _recordFromJson(Object? value) {
  if (value is! Map<String, Object?>) {
    throw StateError('Invalid local database record snapshot');
  }
  return <String, Object?>{
    for (final entry in value.entries) entry.key: _jsonValue(entry.value),
  };
}

Map<String, Object?> _recordToJson(LocalDatabaseRecord record) {
  return <String, Object?>{
    for (final entry in record.entries) entry.key: _jsonValue(entry.value),
  };
}

Object? _jsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Iterable) {
    return value.map(_jsonValue).toList(growable: false);
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _jsonValue(entry.value),
    };
  }
  throw StateError('Unsupported local database record value');
}

LocalTableName? _tableByDbName(String dbName) {
  for (final table in LocalTableName.values) {
    if (table.dbName == dbName) return table;
  }
  return null;
}

void validateLocalDatabaseRecord(Object? value) {
  _validateLocalDatabaseValue(value);
}

void _validateLocalDatabaseValue(Object? value, [String? key]) {
  if (key != null &&
      (_unsafeLocalDbPatterns.any((pattern) => pattern.hasMatch(key)) ||
          _unsafeLocalDbKeyPatterns.any((pattern) => pattern.hasMatch(key)))) {
    throw StateError('Unsafe local database record');
  }
  if (value is String) {
    if (_unsafeLocalDbPatterns.any((pattern) => pattern.hasMatch(value))) {
      throw StateError('Unsafe local database record');
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      _validateLocalDatabaseValue(entry.value, entry.key.toString());
    }
    return;
  }
  if (value is Iterable) {
    if (value is List<int>) {
      throw StateError('Unsafe local database record');
    }
    for (final item in value) {
      _validateLocalDatabaseValue(item);
    }
  }
}

LocalDatabaseSchema getAppDatabaseSchema() => appDatabaseSchema;

String? _normalizedMigrationValue(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _validMigrationTimestamp(Object? value) {
  final normalized = _normalizedMigrationValue(value);
  if (normalized == null || DateTime.tryParse(normalized) == null) return null;
  return normalized;
}

bool _timestampPrecedes(String candidate, String existing) => DateTime.parse(
  candidate,
).toUtc().isBefore(DateTime.parse(existing).toUtc());

String _growthLedgerMigrationKey(String userScope, String contentId) =>
    'v3:scope:${_encodedDatabaseKey(userScope)}:growth:'
    '${_encodedDatabaseKey(contentId)}';

String _encodedDatabaseKey(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

const appDatabaseSchema = LocalDatabaseSchema(
  version: localDatabaseSchemaVersion,
  tables: <LocalDatabaseTableSchema>[
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordings,
      columns: <String>[
        'user_scope',
        'recording_id',
        'local_file_id',
        'card_file_id',
        'content_hash',
        'source',
        'status',
        'format',
        'local_file_state',
        'app_private_uri',
        'recorded_at',
        'display_name',
        'device_filename',
        'original_filename',
        'duration_seconds',
        'size_bytes',
        'is_favorite',
        'tag_ids',
        'created_at',
        'updated_at',
        'deleted_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingTags,
      columns: <String>[
        'user_scope',
        'tag_id',
        'name',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingTagLinks,
      columns: <String>['user_scope', 'recording_id', 'tag_id', 'created_at'],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingTrash,
      columns: <String>[
        'user_scope',
        'recording_id',
        'deleted_at',
        'retention_until',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingPlayback,
      columns: <String>[
        'user_scope',
        'recording_id',
        'position_seconds',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.deviceLocalRecordingMappings,
      columns: <String>[
        'user_scope',
        'device_id',
        'device_file_key',
        'local_recording_id',
        'sync_status',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.recordingCardDownloadedManifest,
      columns: <String>[
        'user_scope',
        'device_file_id',
        'device_fingerprint',
        'device_filename',
        'local_file_id',
        'app_private_uri',
        'expected_size_bytes',
        'actual_size_bytes',
        'duration_seconds',
        'content_hash',
        'downloaded_at',
        'local_state',
        'local_deleted_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingUploadDrafts,
      columns: <String>[
        'user_scope',
        'draft_id',
        'local_file_id',
        'recording_id',
        'stage',
        'resource_id',
        'asr_task_id',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localRecordingRecoveryCheckpoints,
      columns: <String>[
        'user_scope',
        'checkpoint_id',
        'local_file_id',
        'checkpoint_type',
        'accepted_bytes',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.localTransferRecords,
      columns: <String>[
        'user_scope',
        'transfer_id',
        'transfer_kind',
        'batch_id',
        'workspace_scope',
        'primary_item_id',
        'job_id',
        'note_id',
        'recording_id',
        'device_fingerprint',
        'device_identity',
        'card_sn_digest',
        'device_file_id',
        'device_filename',
        'local_file_key',
        'item_order',
        'expected_size_bytes',
        'attempt_count',
        'batch_stage',
        'batch_error_code',
        'stage',
        'last_phase',
        'error_code',
        'waiting_reason',
        'local_recording_id',
        'file_format',
        'mime_type',
        'duration_seconds',
        'recorded_at',
        'content_hash',
        'ledger_source_signature',
        'staged_native_file_id',
        'source_size_confidence',
        'planned_native_file_id',
        'attempt_id',
        'stop_requested',
        'staged_file_format',
        'staged_size_bytes',
        'staged_content_hash',
        'idempotency_key',
        'observation_started_at',
        'last_authoritative_progress_at',
        'observation_deadline_at',
        'item_payload_json',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.recordingCardFileLedger,
      columns: <String>[
        'user_scope',
        'card_sn_digest',
        'source_signature',
        'device_file_id',
        'device_filename',
        'recorded_at',
        'size_bytes',
        'duration_seconds',
        'content_hash',
        'local_recording_id',
        'local_state',
        'card_state',
        'last_synced_at',
        'local_deleted_at',
        'last_seen_at',
        'error_code',
        'retryability',
        'attempt_count',
        'next_retry_at',
        'planned_native_file_id',
        'sync_origin',
        'resume_requested',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.recordingCardSyncCheckpoints,
      columns: <String>[
        'user_scope',
        'card_sn_digest',
        'last_successful_auto_sync_at',
        'last_transfer_completed_at',
        'last_directory_read_at',
        'committed_through_recorded_at',
        'committed_snapshot_hash',
        'migration_mode',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.recordingTranscriptionReceipts,
      columns: <String>[
        'user_scope',
        'file_identity',
        'device_filename',
        'content_hash',
        'local_recording_id',
        'remote_recording_id',
        'note_id',
        'transcript_completed_at',
        'asset_ready_at',
        'outline_completed_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.materialIngestionDrafts,
      columns: <String>[
        'draft_id',
        'owner_scope',
        'source',
        'status',
        'checkpoint',
        'resource_id',
        'remote_task_id',
        'note_id',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.diagnosticLogs,
      columns: <String>[
        'event_id',
        'created_at',
        'category',
        'severity',
        'correlation_id',
        'safe_summary',
        'redacted_metadata_json',
        'developer_only',
        'retention_until',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.knowledgeLibraryMemberships,
      columns: <String>['user_scope', 'content_id', 'collection', 'created_at'],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.depositRecords,
      columns: <String>[
        'user_scope',
        'content_id',
        'folder_id',
        'deposited_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.depositFolders,
      columns: <String>[
        'user_scope',
        'folder_id',
        'parent_folder_id',
        'name',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.voiceprintProfiles,
      columns: <String>[
        'user_scope',
        'profile_id',
        'name',
        'enrolled_at',
        'updated_at',
        'is_demo',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.chatThreadAliases,
      columns: <String>[
        'user_scope',
        'scene',
        'thread_id',
        'alias',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.chatEntryThreadBindings,
      columns: <String>[
        'user_scope',
        'workspace_scope',
        'scene',
        'entry_kind',
        'entry_id',
        'thread_id',
        'agent_profile_id',
        'bound_at',
        'last_opened_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.knowledgeItemUserMetadata,
      columns: <String>[
        'user_scope',
        'content_id',
        'custom_tags_json',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.knowledgeViewPreferences,
      columns: <String>[
        'user_scope',
        'preference_key',
        'card_mode',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.creationCanvasDrafts,
      columns: <String>[
        'user_scope',
        'title',
        'markdown',
        'document_json',
        'document_format_version',
        'linked_materials_json',
        'shared_metadata_json',
        'source_topic_id',
        'source_title',
        'revision',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.assetClassifications,
      columns: <String>[
        'user_scope',
        'content_id',
        'category',
        'knowledge_secondary_labels',
        'is_demo',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.growthLedger,
      columns: <String>['user_scope', 'content_id', 'first_deposited_at'],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.creationCanvasHistory,
      columns: <String>[
        'user_scope',
        'history_id',
        'note_id',
        'title',
        'markdown',
        'document_json',
        'document_format_version',
        'revision',
        'linked_materials_json',
        'source_topic_id',
        'source_title',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.profileTodos,
      columns: <String>[
        'user_scope',
        'todo_id',
        'title',
        'due_at',
        'completed_at',
        'created_at',
        'updated_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.usageSessions,
      columns: <String>[
        'user_scope',
        'session_id',
        'started_at',
        'last_seen_at',
      ],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.recordingCardAccountBindings,
      columns: <String>['user_scope', 'opaque_claim', 'bound_at', 'updated_at'],
    ),
    LocalDatabaseTableSchema(
      name: LocalTableName.appPreferences,
      columns: <String>['preference_key', 'value', 'updated_at'],
    ),
  ],
  indexes: <LocalDatabaseIndex>[
    LocalDatabaseIndex(
      name: 'idx_local_recordings_scope_updated_at',
      table: LocalTableName.localRecordings,
      columns: <String>['user_scope', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_tags_scope_name',
      table: LocalTableName.localRecordingTags,
      columns: <String>['user_scope', 'name'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_tag_links_scope_recording',
      table: LocalTableName.localRecordingTagLinks,
      columns: <String>['user_scope', 'recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_trash_scope_deleted_at',
      table: LocalTableName.localRecordingTrash,
      columns: <String>['user_scope', 'deleted_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_playback_scope_recording',
      table: LocalTableName.localRecordingPlayback,
      columns: <String>['user_scope', 'recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_device_local_mappings_scope_device_file',
      table: LocalTableName.deviceLocalRecordingMappings,
      columns: <String>['user_scope', 'device_id', 'device_file_key'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_manifest_scope_device_file',
      table: LocalTableName.recordingCardDownloadedManifest,
      columns: <String>['user_scope', 'device_file_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_upload_drafts_scope_file_stage',
      table: LocalTableName.localRecordingUploadDrafts,
      columns: <String>['user_scope', 'local_file_id', 'stage'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_transfer_records_scope_stage',
      table: LocalTableName.localTransferRecords,
      columns: <String>['user_scope', 'stage', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_transfer_records_scope_batch_order',
      table: LocalTableName.localTransferRecords,
      columns: <String>['user_scope', 'batch_id', 'item_order'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_ledger_scope_card_source',
      table: LocalTableName.recordingCardFileLedger,
      columns: <String>['user_scope', 'card_sn_digest', 'source_signature'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_ledger_scope_local_recording',
      table: LocalTableName.recordingCardFileLedger,
      columns: <String>['user_scope', 'local_recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_ledger_scope_card_state',
      table: LocalTableName.recordingCardFileLedger,
      columns: <String>['user_scope', 'card_sn_digest', 'local_state'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_checkpoints_scope_card',
      table: LocalTableName.recordingCardSyncCheckpoints,
      columns: <String>['user_scope', 'card_sn_digest'],
    ),
    LocalDatabaseIndex(
      name: 'idx_transcription_receipts_scope_file',
      table: LocalTableName.recordingTranscriptionReceipts,
      columns: <String>['user_scope', 'file_identity'],
    ),
    LocalDatabaseIndex(
      name: 'idx_transcription_receipts_scope_content_hash',
      table: LocalTableName.recordingTranscriptionReceipts,
      columns: <String>['user_scope', 'content_hash'],
    ),
    LocalDatabaseIndex(
      name: 'idx_transcription_receipts_scope_local_recording',
      table: LocalTableName.recordingTranscriptionReceipts,
      columns: <String>['user_scope', 'local_recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_transcription_receipts_scope_remote_recording',
      table: LocalTableName.recordingTranscriptionReceipts,
      columns: <String>['user_scope', 'remote_recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recordings_recording_id',
      table: LocalTableName.localRecordings,
      columns: <String>['recording_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recordings_card_file_id',
      table: LocalTableName.localRecordings,
      columns: <String>['card_file_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recordings_content_hash',
      table: LocalTableName.localRecordings,
      columns: <String>['content_hash'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recordings_source_status_recorded_at',
      table: LocalTableName.localRecordings,
      columns: <String>['source', 'status', 'recorded_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_device_local_mappings_device_file',
      table: LocalTableName.deviceLocalRecordingMappings,
      columns: <String>['device_id', 'device_file_key'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_manifest_device_file',
      table: LocalTableName.recordingCardDownloadedManifest,
      columns: <String>['device_file_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_upload_drafts_local_file_stage',
      table: LocalTableName.localRecordingUploadDrafts,
      columns: <String>['local_file_id', 'stage'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_tags_name',
      table: LocalTableName.localRecordingTags,
      columns: <String>['name'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_recording_trash_deleted_at',
      table: LocalTableName.localRecordingTrash,
      columns: <String>['deleted_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_transfer_records_stage',
      table: LocalTableName.localTransferRecords,
      columns: <String>['stage', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_local_transfer_records_batch_order',
      table: LocalTableName.localTransferRecords,
      columns: <String>['batch_id', 'item_order'],
    ),
    LocalDatabaseIndex(
      name: 'idx_material_ingestion_status_updated_at',
      table: LocalTableName.materialIngestionDrafts,
      columns: <String>['status', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_diagnostic_logs_retention_until',
      table: LocalTableName.diagnosticLogs,
      columns: <String>['retention_until'],
    ),
    LocalDatabaseIndex(
      name: 'idx_knowledge_library_memberships_scope_collection',
      table: LocalTableName.knowledgeLibraryMemberships,
      columns: <String>['user_scope', 'collection'],
    ),
    LocalDatabaseIndex(
      name: 'idx_deposit_records_scope_folder',
      table: LocalTableName.depositRecords,
      columns: <String>['user_scope', 'folder_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_deposit_folders_scope_updated_at',
      table: LocalTableName.depositFolders,
      columns: <String>['user_scope', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_deposit_folders_scope_parent_updated_at',
      table: LocalTableName.depositFolders,
      columns: <String>['user_scope', 'parent_folder_id', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_voiceprint_profiles_scope_updated_at',
      table: LocalTableName.voiceprintProfiles,
      columns: <String>['user_scope', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_chat_thread_aliases_scope_scene',
      table: LocalTableName.chatThreadAliases,
      columns: <String>['user_scope', 'scene'],
    ),
    LocalDatabaseIndex(
      name: 'idx_chat_entry_bindings_scope_entry_opened',
      table: LocalTableName.chatEntryThreadBindings,
      columns: <String>[
        'user_scope',
        'workspace_scope',
        'scene',
        'entry_kind',
        'entry_id',
        'last_opened_at',
      ],
    ),
    LocalDatabaseIndex(
      name: 'idx_knowledge_item_metadata_scope_content',
      table: LocalTableName.knowledgeItemUserMetadata,
      columns: <String>['user_scope', 'content_id'],
    ),
    LocalDatabaseIndex(
      name: 'idx_knowledge_view_preferences_scope_key',
      table: LocalTableName.knowledgeViewPreferences,
      columns: <String>['user_scope', 'preference_key'],
    ),
    LocalDatabaseIndex(
      name: 'idx_creation_canvas_drafts_scope_updated_at',
      table: LocalTableName.creationCanvasDrafts,
      columns: <String>['user_scope', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_asset_classifications_scope_category',
      table: LocalTableName.assetClassifications,
      columns: <String>['user_scope', 'category'],
    ),
    LocalDatabaseIndex(
      name: 'idx_growth_ledger_scope_first_deposited_at',
      table: LocalTableName.growthLedger,
      columns: <String>['user_scope', 'first_deposited_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_creation_canvas_history_scope_updated_at',
      table: LocalTableName.creationCanvasHistory,
      columns: <String>['user_scope', 'updated_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_profile_todos_scope_due_at',
      table: LocalTableName.profileTodos,
      columns: <String>['user_scope', 'due_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_usage_sessions_scope_started_at',
      table: LocalTableName.usageSessions,
      columns: <String>['user_scope', 'started_at'],
    ),
    LocalDatabaseIndex(
      name: 'idx_recording_card_bindings_scope_claim',
      table: LocalTableName.recordingCardAccountBindings,
      columns: <String>['user_scope', 'opaque_claim'],
    ),
  ],
);

const userScopedLocalTables = <LocalTableName>[
  LocalTableName.localRecordings,
  LocalTableName.localRecordingTags,
  LocalTableName.localRecordingTagLinks,
  LocalTableName.localRecordingTrash,
  LocalTableName.localRecordingPlayback,
  LocalTableName.deviceLocalRecordingMappings,
  LocalTableName.recordingCardDownloadedManifest,
  LocalTableName.localRecordingUploadDrafts,
  LocalTableName.localRecordingRecoveryCheckpoints,
  LocalTableName.localTransferRecords,
  LocalTableName.recordingCardFileLedger,
  LocalTableName.recordingCardSyncCheckpoints,
  LocalTableName.recordingTranscriptionReceipts,
  LocalTableName.materialIngestionDrafts,
  LocalTableName.knowledgeLibraryMemberships,
  LocalTableName.depositRecords,
  LocalTableName.depositFolders,
  LocalTableName.voiceprintProfiles,
  LocalTableName.chatThreadAliases,
  LocalTableName.chatEntryThreadBindings,
  LocalTableName.knowledgeItemUserMetadata,
  LocalTableName.knowledgeViewPreferences,
  LocalTableName.creationCanvasDrafts,
  LocalTableName.assetClassifications,
  LocalTableName.growthLedger,
  LocalTableName.creationCanvasHistory,
  LocalTableName.profileTodos,
  LocalTableName.usageSessions,
  LocalTableName.recordingCardAccountBindings,
];

AppFailure _localDbError(String code, [Object? cause]) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: 'Local database operation failed',
    userMessageKey: 'storage.localDb.operationFailed',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
    cause: cause,
  );
}

final _unsafeLocalDbPatterns = <RegExp>[
  RegExp('access-token', caseSensitive: false),
  RegExp('refresh-token', caseSensitive: false),
  RegExp('runtime:tenant:', caseSensitive: false),
  RegExp('openclaw', caseSensitive: false),
  RegExp('verification.*code', caseSensitive: false),
  RegExp('sms.*code', caseSensitive: false),
  RegExp('provider.*key', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('api.*key', caseSensitive: false),
  RegExp('wifi.*password', caseSensitive: false),
  RegExp('file://', caseSensitive: false),
  RegExp(r'[A-Za-z]:\\'),
  RegExp('/Users/', caseSensitive: false),
  RegExp('/home/huahuo-runtime/', caseSensitive: false),
  RegExp('/home/data/huahuo/(runtime|workspaces)/', caseSensitive: false),
  RegExp('workspace.*path', caseSensitive: false),
  RegExp('server.*path', caseSensitive: false),
  RegExp('local.*path', caseSensitive: false),
  RegExp('audioContent', caseSensitive: false),
  RegExp(r'audio.*(bytes|blob)', caseSensitive: false),
  RegExp('transcriptFull', caseSensitive: false),
];

final _unsafeLocalDbKeyPatterns = <RegExp>[
  RegExp(r'audio.*(content|bytes|blob)', caseSensitive: false),
  RegExp(r'(content|bytes|blob).*audio', caseSensitive: false),
  RegExp(r'(^|_)blob($|_)', caseSensitive: false),
  RegExp('transcriptFull', caseSensitive: false),
];
