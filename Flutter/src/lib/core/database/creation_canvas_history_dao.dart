import 'dart:convert';

import 'app_database.dart';

final class CreationCanvasHistoryDao {
  CreationCanvasHistoryDao(this._database);

  final AppDatabase _database;

  Future<void> flushPersistence() => _database.flushPersistence();

  List<LocalDatabaseRecord> list(String userScope) {
    final scope = _normalize(userScope, 'userScope');
    return _database
        .listRecords<LocalDatabaseRecord>(LocalTableName.creationCanvasHistory)
        .where((record) => record['user_scope'] == scope)
        .toList(growable: false);
  }

  LocalDatabaseRecord? find(String userScope, String historyId) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(historyId, 'historyId');
    return _database.getRecord<LocalDatabaseRecord>(
      LocalTableName.creationCanvasHistory,
      _key(scope, id),
    );
  }

  void upsert({
    required String userScope,
    required String historyId,
    required String noteId,
    required String title,
    required String markdown,
    required String documentJson,
    required int documentFormatVersion,
    required int revision,
    required String linkedMaterialsJson,
    required String createdAt,
    required String updatedAt,
    String? sourceTopicId,
    String? sourceTitle,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(historyId, 'historyId');
    _database.upsertRecord(
      LocalTableName.creationCanvasHistory,
      _key(scope, id),
      <String, Object?>{
        'user_scope': scope,
        'history_id': id,
        'note_id': _normalize(noteId, 'noteId'),
        'title': _normalize(title, 'title'),
        'markdown': markdown,
        'document_json': documentJson,
        'document_format_version': documentFormatVersion,
        'revision': revision,
        'linked_materials_json': linkedMaterialsJson,
        'source_topic_id': sourceTopicId,
        'source_title': sourceTitle,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
    );
  }

  bool delete(String userScope, String historyId) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(historyId, 'historyId');
    return _database.deleteRecord(
      LocalTableName.creationCanvasHistory,
      _key(scope, id),
    );
  }

  String _key(String scope, String id) =>
      'v1:scope:${_encode(scope)}:creation-history:${_encode(id)}';

  String _encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _normalize(String value, String name) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
    return normalized;
  }
}
