import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../domain/recording_card_auto_sync.dart';
import '../domain/recording_card_sync_ledger.dart';
import 'recording_card_sync_ledger_store.dart';

abstract interface class RecordingCardAutoSyncPersistencePort {
  RecordingCardAutoSyncPreferences loadPreferences();

  void savePreferences(RecordingCardAutoSyncPreferences preferences);

  List<RecordingCardAutoSyncTask> loadTasks();

  void saveTask(RecordingCardAutoSyncTask task);
}

final class RecordingCardAutoSyncStore
    implements
        RecordingCardAutoSyncPersistencePort,
        RecordingCardSyncLedgerPersistencePort {
  RecordingCardAutoSyncStore({
    required AppDatabase database,
    required String accountScope,
  }) : _database = database,
       _preferences = AppPreferencesDao(database),
       _ledgerStore = RecordingCardSyncLedgerStore(
         database: database,
         accountScope: accountScope,
       ),
       _accountScope = accountScope.trim(),
       _scopeHash = sha256
           .convert(utf8.encode(accountScope.trim()))
           .toString() {
    if (accountScope.trim().isEmpty) {
      throw ArgumentError.value(
        accountScope,
        'accountScope',
        'must not be empty',
      );
    }
  }

  static const _transferKind = 'recording_card_auto_sync';
  static const _preferenceSchema = 1;

  final AppDatabase _database;
  final AppPreferencesDao _preferences;
  final RecordingCardSyncLedgerStore _ledgerStore;
  final String _accountScope;
  final String _scopeHash;

  String get _preferenceKey =>
      'recording-card-auto-sync:${_scopeHash.substring(0, 24)}';

  @override
  String get accountScope => _accountScope;

  @override
  List<String> loadKnownCardDigests() => _ledgerStore.loadKnownCardDigests();

  @override
  String? latestKnownCardSnDigest() => _ledgerStore.latestKnownCardSnDigest();

  @override
  RecordingCardAutoSyncPreferences loadPreferences() {
    final raw = _preferences.readValue(_preferenceKey);
    if (raw == null) return const RecordingCardAutoSyncPreferences();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> ||
          decoded['schema'] != _preferenceSchema) {
        return const RecordingCardAutoSyncPreferences();
      }
      return RecordingCardAutoSyncPreferences(
        autoSyncEnabled: decoded['autoSyncEnabled'] is bool
            ? decoded['autoSyncEnabled']! as bool
            : true,
        autoTranscriptionEnabled: decoded['autoTranscriptionEnabled'] is bool
            ? decoded['autoTranscriptionEnabled']! as bool
            : false,
      );
    } on Object {
      return const RecordingCardAutoSyncPreferences();
    }
  }

  @override
  void savePreferences(RecordingCardAutoSyncPreferences preferences) {
    final now = DateTime.now().toUtc().toIso8601String();
    _preferences.upsertValue(
      preferenceKey: _preferenceKey,
      value: jsonEncode(<String, Object?>{
        'schema': _preferenceSchema,
        'autoSyncEnabled': preferences.autoSyncEnabled,
        'autoTranscriptionEnabled': preferences.autoTranscriptionEnabled,
      }),
      updatedAt: now,
    );
  }

  @override
  List<RecordingCardAutoSyncTask> loadTasks() {
    _migrateOwnedLegacyTaskKeys();
    final byTaskId = <String, RecordingCardAutoSyncTask>{};
    for (final record in _database.listRecords<LocalDatabaseRecord>(
      LocalTableName.localTransferRecords,
    )) {
      if (!_isOwnedTaskRecord(record)) continue;
      final task = _taskFromRecord(record);
      if (task == null) continue;
      final existing = byTaskId[task.taskId];
      if (existing == null || task.updatedAt.isAfter(existing.updatedAt)) {
        byTaskId[task.taskId] = task;
      }
    }
    final tasks =
        byTaskId.values
            .map(
              (task) =>
                  task.state == RecordingCardAutoSyncTaskState.downloading ||
                      task.state == RecordingCardAutoSyncTaskState.transcribing
                  ? task.copyWith(
                      state: RecordingCardAutoSyncTaskState.queued,
                      updatedAt: DateTime.now().toUtc(),
                      clearError: true,
                    )
                  : task,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final order = left.order.compareTo(right.order);
            return order != 0 ? order : left.taskId.compareTo(right.taskId);
          });
    return List<RecordingCardAutoSyncTask>.unmodifiable(tasks);
  }

  @override
  void saveTask(RecordingCardAutoSyncTask task) {
    final record = <String, Object?>{
      'transfer_id': task.taskId,
      'transfer_kind': _transferKind,
      'user_scope': _accountScope,
      'batch_id': _scopeHash,
      'device_fingerprint': _bounded(task.deviceFingerprint, 160),
      if (task.cardSnDigest != null)
        'device_identity': _bounded(task.cardSnDigest!, 160),
      'device_file_id': _bounded(task.deviceFileId, 200),
      'device_filename': _bounded(task.deviceFilename, 240),
      'local_file_key': _bounded(task.localFileKey, 200),
      'item_order': task.order < 0 ? 0 : task.order,
      'expected_size_bytes': task.expectedSizeBytes ?? 0,
      if (task.recordedAt != null)
        'recorded_at': task.recordedAt!.toUtc().toIso8601String(),
      if (task.contentHash != null)
        'content_hash': _bounded(task.contentHash!, 160),
      'attempt_count': task.attemptCount < 0 ? 0 : task.attemptCount,
      'batch_stage': 'automatic',
      'stage': task.state.name,
      if (task.errorCode != null) 'error_code': _bounded(task.errorCode!, 120),
      if (task.localRecordingId != null)
        'local_recording_id': _bounded(task.localRecordingId!, 200),
      'auto_transcription_requested': task.transcriptionRequested,
      'idempotency_key': task.sourceSignature ?? task.taskId,
      if (task.retryability != null) 'retryability': task.retryability!.name,
      if (task.nextRetryAt != null)
        'next_retry_at': task.nextRetryAt!.toUtc().toIso8601String(),
      'created_at': task.createdAt.toUtc().toIso8601String(),
      'updated_at': task.updatedAt.toUtc().toIso8601String(),
    };
    final scopedKey = _taskRecordKey(task.taskId);
    final result = _database.withTransaction<void>((database) {
      final scoped = database.getRecord<LocalDatabaseRecord>(
        LocalTableName.localTransferRecords,
        scopedKey,
      );
      if (scoped != null && !_isOwnedTaskRecord(scoped)) {
        throw StateError('Automatic-sync scoped task key is already owned');
      }
      database.upsertRecord(
        LocalTableName.localTransferRecords,
        scopedKey,
        record,
      );
      final legacy = database.getRecord<LocalDatabaseRecord>(
        LocalTableName.localTransferRecords,
        task.taskId,
      );
      if (legacy != null &&
          _isOwnedTaskRecord(legacy) &&
          legacy['transfer_id'] == task.taskId) {
        database.deleteRecord(LocalTableName.localTransferRecords, task.taskId);
      }
    });
    _requireTaskTransaction(result, 'save automatic-sync task');
  }

  void _migrateOwnedLegacyTaskKeys() {
    final taskIds = <String>{
      for (final record in _database.listRecords<LocalDatabaseRecord>(
        LocalTableName.localTransferRecords,
      ))
        if (_isOwnedTaskRecord(record))
          if (_string(record['transfer_id']) case final taskId?) taskId,
    };
    final legacyTaskIds = <String>[
      for (final taskId in taskIds)
        if (_database.getRecord<LocalDatabaseRecord>(
              LocalTableName.localTransferRecords,
              taskId,
            )
            case final legacy?)
          if (_isOwnedTaskRecord(legacy) && legacy['transfer_id'] == taskId)
            taskId,
    ];
    if (legacyTaskIds.isEmpty) return;

    final result = _database.withTransaction<void>((database) {
      for (final taskId in legacyTaskIds) {
        final legacy = database.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          taskId,
        );
        if (legacy == null ||
            !_isOwnedTaskRecord(legacy) ||
            legacy['transfer_id'] != taskId) {
          continue;
        }
        final scopedKey = _taskRecordKey(taskId);
        final scoped = database.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          scopedKey,
        );
        if (scoped != null && !_isOwnedTaskRecord(scoped)) {
          continue;
        }
        final legacyUpdatedAt = _date(legacy['updated_at']);
        final scopedUpdatedAt = _date(scoped?['updated_at']);
        if (scoped == null ||
            scopedUpdatedAt == null ||
            (legacyUpdatedAt != null &&
                legacyUpdatedAt.isAfter(scopedUpdatedAt))) {
          database.upsertRecord(
            LocalTableName.localTransferRecords,
            scopedKey,
            legacy,
          );
        }
        database.deleteRecord(LocalTableName.localTransferRecords, taskId);
      }
    });
    _requireTaskTransaction(result, 'migrate automatic-sync task keys');
  }

  bool _isOwnedTaskRecord(LocalDatabaseRecord record) =>
      record['transfer_kind'] == _transferKind &&
      record['user_scope'] == _accountScope &&
      record['batch_id'] == _scopeHash;

  String _taskRecordKey(String taskId) => '$_scopeHash:$taskId';

  RecordingCardAutoSyncTask? _taskFromRecord(LocalDatabaseRecord record) {
    final taskId = record['transfer_id'];
    final fingerprint = record['device_fingerprint'];
    final deviceFileId = record['device_file_id'];
    final filename = record['device_filename'];
    final localFileKey = record['local_file_key'];
    final stage = record['stage'];
    final createdAt = DateTime.tryParse('${record['created_at']}');
    final updatedAt = DateTime.tryParse('${record['updated_at']}');
    if (taskId is! String ||
        fingerprint is! String ||
        deviceFileId is! String ||
        filename is! String ||
        localFileKey is! String ||
        stage is! String ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    final state = RecordingCardAutoSyncTaskState.values
        .where((value) => value.name == stage)
        .firstOrNull;
    if (state == null) return null;
    final size = _int(record['expected_size_bytes']);
    return RecordingCardAutoSyncTask(
      taskId: taskId,
      deviceFingerprint: fingerprint,
      deviceFileId: deviceFileId,
      deviceFilename: filename,
      localFileKey: localFileKey,
      order: _int(record['item_order']) ?? 0,
      state: state,
      attemptCount: _int(record['attempt_count']) ?? 0,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      expectedSizeBytes: size == null || size <= 0 ? null : size,
      cardSnDigest: _string(record['device_identity']),
      sourceSignature: _sourceSignature(record),
      recordedAt: _date(record['recorded_at']),
      contentHash: _string(record['content_hash']),
      localRecordingId: record['local_recording_id'] as String?,
      transcriptionRequested: record['auto_transcription_requested'] == true,
      errorCode: record['error_code'] as String?,
      retryability: _enumByName(
        RecordingCardSyncRetryability.values,
        record['retryability'],
      ),
      nextRetryAt: _date(record['next_retry_at']),
    );
  }

  @override
  List<RecordingCardFileLedgerEntry> loadFileLedger(String cardSnDigest) =>
      _ledgerStore.loadFileLedger(cardSnDigest);

  @override
  RecordingCardFileLedgerEntry? findFileLedgerEntry({
    required String cardSnDigest,
    required String sourceSignature,
  }) => _ledgerStore.findFileLedgerEntry(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
  );

  @override
  RecordingCardFileLedgerEntry? findFileLedgerEntryByLocalRecordingId(
    String localRecordingId,
  ) => _ledgerStore.findFileLedgerEntryByLocalRecordingId(localRecordingId);

  @override
  List<RecordingCardFileLedgerEntry> findFileLedgerEntriesByLocalRecordingId(
    String localRecordingId,
  ) => _ledgerStore.findFileLedgerEntriesByLocalRecordingId(localRecordingId);

  @override
  void saveFileLedgerEntry(RecordingCardFileLedgerEntry entry) =>
      _ledgerStore.saveFileLedgerEntry(entry);

  @override
  void saveFileLedgerEntries(Iterable<RecordingCardFileLedgerEntry> entries) =>
      _ledgerStore.saveFileLedgerEntries(entries);

  @override
  RecordingCardSyncCheckpoint? loadSyncCheckpoint(String cardSnDigest) =>
      _ledgerStore.loadSyncCheckpoint(cardSnDigest);

  @override
  void saveSyncCheckpoint(RecordingCardSyncCheckpoint checkpoint) =>
      _ledgerStore.saveSyncCheckpoint(checkpoint);

  @override
  void commitVerifiedSync({
    required Iterable<RecordingCardFileLedgerEntry> entries,
    required RecordingCardSyncCheckpoint checkpoint,
  }) =>
      _ledgerStore.commitVerifiedSync(entries: entries, checkpoint: checkpoint);

  @override
  Future<void> flushSyncPersistence() => _ledgerStore.flushSyncPersistence();

  @override
  List<RecordingCardFileLedgerEntry> recoverInterruptedEntries({
    required String cardSnDigest,
    required DateTime at,
    required bool Function(RecordingCardFileLedgerEntry entry) localFileExists,
  }) => _ledgerStore.recoverInterruptedEntries(
    cardSnDigest: cardSnDigest,
    at: at,
    localFileExists: localFileExists,
  );

  @override
  RecordingCardLegacySeedResult seedLegacyData({
    required String cardSnDigest,
    required String legacyDeviceFingerprint,
    required List<RecordingCardScannedFile> directoryFiles,
    required DateTime at,
  }) => _ledgerStore.seedLegacyData(
    cardSnDigest: cardSnDigest,
    legacyDeviceFingerprint: legacyDeviceFingerprint,
    directoryFiles: directoryFiles,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry queueManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.queueManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.beginManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _ledgerStore.beginManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry queueManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _ledgerStore.queueManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry completeManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String localRecordingId,
    required DateTime at,
    String? contentHash,
  }) => _ledgerStore.completeManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    localRecordingId: localRecordingId,
    at: at,
    contentHash: contentHash,
  );

  @override
  RecordingCardFileLedgerEntry failManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    required DateTime at,
  }) => _ledgerStore.failManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    errorCode: errorCode,
    retryability: retryability,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.beginLocalDeletion(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry finishLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.finishLocalDeletion(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry restoreLocalDeletion({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.restoreLocalDeletion(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry markCardDeleted({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _ledgerStore.markCardDeleted(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry markCardDeletedForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _ledgerStore.markCardDeletedForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );
}

int? _int(Object? raw) => switch (raw) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value),
  _ => null,
};

DateTime? _date(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

String? _string(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

String? _sourceSignature(LocalDatabaseRecord record) {
  final cardDigest = _string(record['device_identity']);
  final value = _string(record['idempotency_key']);
  if (cardDigest == null || value == null || value == record['transfer_id']) {
    return null;
  }
  return value;
}

T? _enumByName<T extends Enum>(Iterable<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

String _bounded(String value, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, 'value');
  return normalized.length <= maximum
      ? normalized
      : normalized.substring(0, maximum);
}

void _requireTaskTransaction(
  LocalDatabaseResult<void> result,
  String operation,
) {
  if (result.ok) return;
  throw StateError('$operation failed: ${result.error?.code ?? 'unknown'}');
}
