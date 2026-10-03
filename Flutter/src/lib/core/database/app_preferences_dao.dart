import 'dart:async';
import 'dart:convert';

import 'app_database.dart';
import 'database_worker.dart';
import 'database_write_queue.dart';

final class AppPreferencesDao {
  AppPreferencesDao(
    this._database, {
    DatabaseRecordWorkerPort? worker,
    DatabaseWriteQueue? writeQueue,
  }) : // Public parameter names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _worker = worker,
       // ignore: prefer_initializing_formals
       _writeQueue = writeQueue;

  final AppDatabase _database;
  final DatabaseRecordWorkerPort? _worker;
  final DatabaseWriteQueue? _writeQueue;
  final Map<String, LocalDatabaseRecord?> _deferredByPreferenceKey =
      <String, LocalDatabaseRecord?>{};

  bool get supportsDeferredWrites {
    final worker = _worker;
    return worker != null &&
        worker.isEnabled &&
        !worker.isDisposed &&
        _writeQueue != null;
  }

  String? readValue(String preferenceKey) {
    final key = _normalizeKey(preferenceKey);
    if (_deferredByPreferenceKey.containsKey(key)) {
      final value = _deferredByPreferenceKey[key]?['value'];
      return value is String ? value : null;
    }
    final record = _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.appPreferences,
      _recordKey(key),
    );
    final value = record?['value'];
    return value is String ? value : null;
  }

  void upsertValue({
    required String preferenceKey,
    required String value,
    required String updatedAt,
  }) {
    final key = _normalizeKey(preferenceKey);
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      throw ArgumentError.value(value, 'value', 'must not be empty');
    }
    final record = _record(
      key: key,
      value: normalizedValue,
      updatedAt: updatedAt,
    );
    _database.upsertRecord(
      LocalTableName.appPreferences,
      _recordKey(key),
      record,
    );
    _deferredByPreferenceKey[key] = record;
  }

  Future<void> upsertValueDeferred({
    required String preferenceKey,
    required String value,
    required String updatedAt,
  }) {
    final key = _normalizeKey(preferenceKey);
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      throw ArgumentError.value(value, 'value', 'must not be empty');
    }
    final recordKey = _recordKey(key);
    final record = _record(
      key: key,
      value: normalizedValue,
      updatedAt: updatedAt,
    );
    _deferredByPreferenceKey[key] = record;
    if (!supportsDeferredWrites) {
      return Future<void>.sync(() {
        _database.upsertRecord(
          LocalTableName.appPreferences,
          recordKey,
          record,
        );
      }).then((_) => _database.flushPersistence());
    }
    return _writeQueue!.enqueue(
      key: 'preference:$recordKey',
      replacePending: true,
      operationLabel: 'upsert_deferred',
      table: LocalTableName.appPreferences.dbName,
      reason: 'cache_checkpoint',
      callerFeature: 'app_preferences',
      rows: 1,
      bytes: utf8.encode(jsonEncode(record)).length,
      operation: () => _worker!.upsertRecord(
        table: LocalTableName.appPreferences,
        key: recordKey,
        record: record,
      ),
    );
  }

  bool deleteValue(String preferenceKey) {
    final key = _normalizeKey(preferenceKey);
    final deleted = _database.deleteRecord(
      LocalTableName.appPreferences,
      _recordKey(key),
    );
    _deferredByPreferenceKey[key] = null;
    return deleted;
  }

  Future<bool> deleteValueDeferred(String preferenceKey) async {
    final key = _normalizeKey(preferenceKey);
    final existed = readValue(key) != null;
    final recordKey = _recordKey(key);
    _deferredByPreferenceKey[key] = null;
    if (!supportsDeferredWrites) {
      final deleted = _database.deleteRecord(
        LocalTableName.appPreferences,
        recordKey,
      );
      await _database.flushPersistence();
      return deleted;
    }
    await _writeQueue!.enqueue(
      key: 'preference:$recordKey',
      replacePending: true,
      operationLabel: 'delete_deferred',
      table: LocalTableName.appPreferences.dbName,
      reason: 'cache_invalidate',
      callerFeature: 'app_preferences',
      rows: 1,
      operation: () => _worker!.deleteRecord(
        table: LocalTableName.appPreferences,
        key: recordKey,
      ),
    );
    return existed;
  }

  List<LocalDatabaseRecord> listPreferences() {
    final byKey = <String, LocalDatabaseRecord>{
      for (final record in _database.listRecords<LocalDatabaseRecord>(
        LocalTableName.appPreferences,
      ))
        if (record['preference_key'] is String)
          record['preference_key']! as String: record,
    };
    for (final entry in _deferredByPreferenceKey.entries) {
      final record = entry.value;
      if (record == null) {
        byKey.remove(entry.key);
      } else {
        byKey[entry.key] = record;
      }
    }
    return List<LocalDatabaseRecord>.unmodifiable(byKey.values);
  }

  LocalDatabaseRecord _record({
    required String key,
    required String value,
    required String updatedAt,
  }) => <String, Object?>{
    'preference_key': key,
    'value': value,
    'updated_at': updatedAt,
  };

  String _recordKey(String key) =>
      'app-preference:${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}';

  String _normalizeKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 80) {
      throw ArgumentError.value(value, 'preferenceKey', 'must be 1-80 chars');
    }
    return normalized;
  }
}
