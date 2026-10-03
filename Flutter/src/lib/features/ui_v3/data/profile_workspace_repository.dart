import 'dart:convert';

import '../../../core/database/profile_workspace_dao.dart';
import '../domain/profile_workspace_models.dart';

final class ProfileWorkspaceRepository {
  ProfileWorkspaceRepository({
    required ProfileWorkspaceDao dao,
    required String userScope,
  }) : _dao = dao,
       _userScope = _normalize(userScope);

  final ProfileWorkspaceDao _dao;
  final String _userScope;

  static const _hubPositionKey = 'profile-floating-hub-position';
  static const _masterpieceKey = 'profile-masterpiece-workspace';

  List<ProfileTodo> loadTodos() {
    final todos = <ProfileTodo>[
      for (final record in _dao.listTodos(_userScope))
        if (_todoFromRecord(record) case final todo?) todo,
    ]..sort(_compareTodos);
    return List<ProfileTodo>.unmodifiable(todos);
  }

  ProfileHubPosition? loadHubPosition() {
    for (final record in _dao.listViewPreferences(_userScope)) {
      if (record['preference_key'] != _hubPositionKey) continue;
      final parts = '${record['card_mode'] ?? ''}'.split(',');
      if (parts.length != 2) return null;
      final x = double.tryParse(parts[0]);
      final y = double.tryParse(parts[1]);
      if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
      return ProfileHubPosition(x: x, y: y);
    }
    return null;
  }

  MasterpieceWorkspaceState loadMasterpiece() {
    final raw = _viewPreferenceValue(_masterpieceKey);
    if (raw == null) return const MasterpieceWorkspaceState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const MasterpieceWorkspaceState();
      }
      final markdown = _string(decoded['markdown']);
      final generatedAt = _date(decoded['generatedAt']);
      final included = decoded['includedNoteIds'];
      final cadenceName = _string(decoded['cadence']);
      final state = MasterpieceWorkspaceState(
        isVisible: decoded['isVisible'] is bool
            ? decoded['isVisible'] as bool
            : true,
        cadence: MasterpieceCadence.fromName(cadenceName),
        markdown: markdown,
        generatedAt: generatedAt,
        includedNoteIds: included is List
            ? List<String>.unmodifiable(
                included.map(_string).whereType<String>(),
              )
            : const <String>[],
        isDepositedAsAsset: decoded['isDepositedAsAsset'] == true,
      );
      if (cadenceName == 'daily') {
        saveMasterpiece(state, updatedAt: DateTime.now().toUtc());
      }
      return state;
    } catch (_) {
      return const MasterpieceWorkspaceState();
    }
  }

  void saveTodo(ProfileTodo todo) {
    _dao.upsertTodo(
      userScope: _userScope,
      todoId: todo.id,
      title: todo.title,
      dueAt: todo.dueAt?.toUtc().toIso8601String(),
      completedAt: todo.completedAt?.toUtc().toIso8601String(),
      createdAt: todo.createdAt.toUtc().toIso8601String(),
      updatedAt: todo.updatedAt.toUtc().toIso8601String(),
    );
  }

  void deleteTodo(String todoId) {
    _dao.deleteTodo(userScope: _userScope, todoId: todoId);
  }

  void saveHubPosition(ProfileHubPosition position, {DateTime? updatedAt}) {
    _dao.upsertViewPreference(
      userScope: _userScope,
      preferenceKey: _hubPositionKey,
      value:
          '${position.x.toStringAsFixed(5)},${position.y.toStringAsFixed(5)}',
      updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  void saveMasterpiece(MasterpieceWorkspaceState state, {DateTime? updatedAt}) {
    _dao.upsertViewPreference(
      userScope: _userScope,
      preferenceKey: _masterpieceKey,
      value: jsonEncode(<String, Object?>{
        'isVisible': state.isVisible,
        'cadence': state.cadence.name,
        'markdown': state.markdown,
        'generatedAt': state.generatedAt?.toUtc().toIso8601String(),
        'includedNoteIds': state.includedNoteIds,
        'isDepositedAsAsset': state.isDepositedAsAsset,
      }),
      updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  String? _viewPreferenceValue(String key) {
    for (final record in _dao.listViewPreferences(_userScope)) {
      if (record['preference_key'] == key) {
        return _string(record['card_mode']);
      }
    }
    return null;
  }
}

ProfileTodo? _todoFromRecord(Map<String, Object?> record) {
  final id = _string(record['todo_id']);
  final title = _string(record['title']);
  final createdAt = _date(record['created_at']);
  final updatedAt = _date(record['updated_at']);
  if (id == null || title == null || createdAt == null || updatedAt == null) {
    return null;
  }
  return ProfileTodo(
    id: id,
    title: title,
    dueAt: _date(record['due_at']),
    completedAt: _date(record['completed_at']),
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

int _compareTodos(ProfileTodo left, ProfileTodo right) {
  if (left.isCompleted != right.isCompleted) return left.isCompleted ? 1 : -1;
  final leftDue = left.dueAt;
  final rightDue = right.dueAt;
  if (leftDue != null && rightDue != null) return leftDue.compareTo(rightDue);
  if (leftDue != null) return -1;
  if (rightDue != null) return 1;
  return right.updatedAt.compareTo(left.updatedAt);
}

DateTime? _date(Object? value) {
  final raw = _string(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
}

String? _string(Object? value) {
  final normalized = '${value ?? ''}'.trim();
  return normalized.isEmpty ? null : normalized;
}

String _normalize(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'userScope', 'must not be empty');
  }
  return normalized;
}
