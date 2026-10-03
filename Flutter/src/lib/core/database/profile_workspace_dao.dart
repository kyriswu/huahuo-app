import 'dart:convert';

import 'app_database.dart';

final class ProfileWorkspaceDao {
  ProfileWorkspaceDao(this._database);

  final AppDatabase _database;

  List<LocalDatabaseRecord> listTodos(String userScope) =>
      _listScoped(LocalTableName.profileTodos, userScope);

  List<LocalDatabaseRecord> listViewPreferences(String userScope) =>
      _listScoped(LocalTableName.knowledgeViewPreferences, userScope);

  void upsertTodo({
    required String userScope,
    required String todoId,
    required String title,
    required String createdAt,
    required String updatedAt,
    String? dueAt,
    String? completedAt,
  }) {
    final scope = _normalized(userScope, 'userScope');
    final id = _normalized(todoId, 'todoId');
    _database.upsertRecord(
      LocalTableName.profileTodos,
      '${_scopeKey(scope)}:todo:${_encoded(id)}',
      <String, Object?>{
        'user_scope': scope,
        'todo_id': id,
        'title': title,
        'due_at': dueAt,
        'completed_at': completedAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
    );
  }

  void deleteTodo({required String userScope, required String todoId}) {
    final scope = _normalized(userScope, 'userScope');
    final id = _normalized(todoId, 'todoId');
    _database.deleteRecord(
      LocalTableName.profileTodos,
      '${_scopeKey(scope)}:todo:${_encoded(id)}',
    );
  }

  void upsertViewPreference({
    required String userScope,
    required String preferenceKey,
    required String value,
    required String updatedAt,
  }) {
    final scope = _normalized(userScope, 'userScope');
    final key = _normalized(preferenceKey, 'preferenceKey');
    _database.upsertRecord(
      LocalTableName.knowledgeViewPreferences,
      'knowledge-view:${_encoded(scope)}:${_encoded(key)}',
      <String, Object?>{
        'user_scope': scope,
        'preference_key': key,
        'card_mode': value,
        'updated_at': updatedAt,
      },
    );
  }

  List<LocalDatabaseRecord> _listScoped(
    LocalTableName table,
    String userScope,
  ) {
    final scope = _normalized(userScope, 'userScope');
    return _database
        .listRecords<LocalDatabaseRecord>(table)
        .where((record) => record['user_scope'] == scope)
        .toList(growable: false);
  }

  String _scopeKey(String scope) => 'v1:scope:${_encoded(scope)}';

  String _encoded(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _normalized(String value, String name) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
    return normalized;
  }
}
