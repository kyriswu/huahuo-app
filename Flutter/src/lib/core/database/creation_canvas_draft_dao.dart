import 'dart:async';
import 'dart:convert';

import 'app_database.dart';
import 'database_worker.dart';
import 'database_write_queue.dart';

final class CreationCanvasDraftDao {
  CreationCanvasDraftDao(
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
  final Map<String, LocalDatabaseRecord?> _deferredByScope =
      <String, LocalDatabaseRecord?>{};

  bool get supportsDeferredWrites {
    final worker = _worker;
    return worker != null &&
        worker.isEnabled &&
        !worker.isDisposed &&
        _writeQueue != null;
  }

  LocalDatabaseRecord? load(String userScope) {
    final scope = _normalizeScope(userScope);
    final record = _deferredByScope.containsKey(scope)
        ? _deferredByScope[scope]
        : _database.getRecord<LocalDatabaseRecord>(
            LocalTableName.creationCanvasDrafts,
            _recordKey(scope),
          );
    if (record == null || record['user_scope'] != scope) return null;
    return _decodeRecord(record);
  }

  LocalDatabaseRecord? _decodeRecord(LocalDatabaseRecord record) {
    try {
      return <String, Object?>{
        ...record,
        'title': _decodePayload(record['title']),
        'markdown': _decodePayload(record['markdown']),
        'document_json': _decodeOptionalPayloadSafely(record['document_json']),
        'linked_materials_json': _decodeOptionalPayloadSafely(
          record['linked_materials_json'],
        ),
        'shared_metadata_json': _decodeOptionalPayloadSafely(
          record['shared_metadata_json'],
        ),
        'source_topic_id': _decodeOptionalPayload(record['source_topic_id']),
        'source_title': _decodeOptionalPayload(record['source_title']),
      };
    } on FormatException {
      return null;
    }
  }

  void upsert({
    required String userScope,
    required String title,
    required String markdown,
    String? documentJson,
    int documentFormatVersion = 0,
    String? linkedMaterialsJson,
    String? sharedMetadataJson,
    required String? sourceTopicId,
    required String? sourceTitle,
    required int revision,
    required String createdAt,
    required String updatedAt,
  }) {
    final scope = _normalizeScope(userScope);
    final record = _encodedRecord(
      scope: scope,
      title: title,
      markdown: markdown,
      documentJson: documentJson,
      documentFormatVersion: documentFormatVersion,
      linkedMaterialsJson: linkedMaterialsJson,
      sharedMetadataJson: sharedMetadataJson,
      sourceTopicId: sourceTopicId,
      sourceTitle: sourceTitle,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
    final recordKey = _recordKey(scope);
    if (supportsDeferredWrites) {
      _deferredByScope[scope] = record;
      unawaited(_enqueueUpsert(recordKey, record).catchError((Object _) {}));
      return;
    }
    _database.upsertRecord(
      LocalTableName.creationCanvasDrafts,
      recordKey,
      record,
    );
    _deferredByScope[scope] = record;
  }

  Future<void> upsertDeferred({
    required String userScope,
    required String title,
    required String markdown,
    String? documentJson,
    int documentFormatVersion = 0,
    String? linkedMaterialsJson,
    String? sharedMetadataJson,
    required String? sourceTopicId,
    required String? sourceTitle,
    required int revision,
    required String createdAt,
    required String updatedAt,
  }) {
    final scope = _normalizeScope(userScope);
    final record = _encodedRecord(
      scope: scope,
      title: title,
      markdown: markdown,
      documentJson: documentJson,
      documentFormatVersion: documentFormatVersion,
      linkedMaterialsJson: linkedMaterialsJson,
      sharedMetadataJson: sharedMetadataJson,
      sourceTopicId: sourceTopicId,
      sourceTitle: sourceTitle,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
    final recordKey = _recordKey(scope);
    _deferredByScope[scope] = record;
    if (!supportsDeferredWrites) {
      return Future<void>.sync(() {
        _database.upsertRecord(
          LocalTableName.creationCanvasDrafts,
          recordKey,
          record,
        );
      }).then((_) => _database.flushPersistence());
    }
    return _enqueueUpsert(recordKey, record);
  }

  bool clear(String userScope) {
    final scope = _normalizeScope(userScope);
    final existed = load(scope) != null;
    final recordKey = _recordKey(scope);
    if (supportsDeferredWrites) {
      _deferredByScope[scope] = null;
      unawaited(_enqueueDelete(recordKey).catchError((Object _) {}));
      return existed;
    }
    final deleted = _database.deleteRecord(
      LocalTableName.creationCanvasDrafts,
      recordKey,
    );
    _deferredByScope[scope] = null;
    return existed || deleted;
  }

  Future<bool> clearDeferred(String userScope) async {
    final scope = _normalizeScope(userScope);
    final existed = load(scope) != null;
    final recordKey = _recordKey(scope);
    _deferredByScope[scope] = null;
    if (!supportsDeferredWrites) {
      final deleted = _database.deleteRecord(
        LocalTableName.creationCanvasDrafts,
        recordKey,
      );
      await _database.flushPersistence();
      return deleted;
    }
    await _enqueueDelete(recordKey);
    return existed;
  }

  Future<void> _enqueueUpsert(String recordKey, LocalDatabaseRecord record) {
    return _writeQueue!.enqueue(
      key: 'canvas:$recordKey',
      replacePending: false,
      operationLabel: 'upsert_deferred',
      table: LocalTableName.creationCanvasDrafts.dbName,
      reason: 'autosave',
      callerFeature: 'creation_canvas',
      rows: 1,
      bytes: utf8.encode(jsonEncode(record)).length,
      operation: () => _worker!.upsertRecord(
        table: LocalTableName.creationCanvasDrafts,
        key: recordKey,
        record: record,
      ),
    );
  }

  Future<void> _enqueueDelete(String recordKey) {
    return _writeQueue!.enqueue(
      key: 'canvas:$recordKey',
      replacePending: false,
      operationLabel: 'delete_deferred',
      table: LocalTableName.creationCanvasDrafts.dbName,
      reason: 'autosave_clear',
      callerFeature: 'creation_canvas',
      rows: 1,
      operation: () => _worker!.deleteRecord(
        table: LocalTableName.creationCanvasDrafts,
        key: recordKey,
      ),
    );
  }

  LocalDatabaseRecord _encodedRecord({
    required String scope,
    required String title,
    required String markdown,
    required String? documentJson,
    required int documentFormatVersion,
    required String? linkedMaterialsJson,
    required String? sharedMetadataJson,
    required String? sourceTopicId,
    required String? sourceTitle,
    required int revision,
    required String createdAt,
    required String updatedAt,
  }) {
    return <String, Object?>{
      'user_scope': scope,
      'title': _encodePayload(title),
      'markdown': _encodePayload(markdown),
      'document_json': _encodeOptionalPayload(documentJson),
      'document_format_version': documentFormatVersion,
      'linked_materials_json': _encodeOptionalPayload(linkedMaterialsJson),
      'shared_metadata_json': _encodeOptionalPayload(sharedMetadataJson),
      'source_topic_id': _encodeOptionalPayload(sourceTopicId),
      'source_title': _encodeOptionalPayload(sourceTitle),
      'revision': revision,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}

String _normalizeScope(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'userScope', 'must not be empty');
  }
  return normalized;
}

String _recordKey(String userScope) =>
    'creation-canvas:${base64Url.encode(utf8.encode(userScope)).replaceAll('=', '')}';

String _encodePayload(String value) =>
    'hex:${utf8.encode(value).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';

String? _encodeOptionalPayload(String? value) =>
    value == null ? null : _encodePayload(value);

String _decodePayload(Object? value) {
  if (value is! String) throw const FormatException('Invalid draft payload');
  if (value.startsWith('hex:')) {
    final encoded = value.substring(4);
    if (encoded.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(encoded)) {
      throw const FormatException('Invalid draft payload');
    }
    return utf8.decode(<int>[
      for (var index = 0; index < encoded.length; index += 2)
        int.parse(encoded.substring(index, index + 2), radix: 16),
    ]);
  }
  if (value.startsWith('b64:')) {
    final encoded = value.substring(4);
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    return utf8.decode(base64Url.decode(padded));
  }
  return value;
}

String? _decodeOptionalPayload(Object? value) =>
    value == null ? null : _decodePayload(value);

String? _decodeOptionalPayloadSafely(Object? value) {
  try {
    return _decodeOptionalPayload(value);
  } on FormatException {
    return null;
  }
}
