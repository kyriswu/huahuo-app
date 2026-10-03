import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_workspace_repository.dart';
import '../domain/profile_workspace_models.dart';

// resident-provider: Shares one account-scoped profile workspace repository identity across dependent controllers.
final profileWorkspaceRepositoryProvider =
    Provider<ProfileWorkspaceRepository?>((ref) => null);

// resident-provider: Preserves the profile workspace controller state machine across route transitions.
final profileWorkspaceControllerProvider =
    ChangeNotifierProvider<ProfileWorkspaceController>((ref) {
      final controller = ProfileWorkspaceController(
        repository: ref.watch(profileWorkspaceRepositoryProvider),
      );
      controller.restore();
      return controller;
    });

final class ProfileWorkspaceController extends ChangeNotifier {
  ProfileWorkspaceController({
    ProfileWorkspaceRepository? repository,
    DateTime Function()? now,
  }) : // The public name intentionally differs from the private field.
       // ignore: prefer_initializing_formals
       _repository = repository,
       _now = now ?? DateTime.now;

  final ProfileWorkspaceRepository? _repository;
  final DateTime Function() _now;
  final List<ProfileTodo> _todos = <ProfileTodo>[];
  ProfileHubPosition? _hubPosition;
  MasterpieceWorkspaceState _masterpiece = const MasterpieceWorkspaceState();
  String? _errorCode;

  List<ProfileTodo> get todos => List<ProfileTodo>.unmodifiable(_todos);
  String? get errorCode => _errorCode;
  ProfileHubPosition? get hubPosition => _hubPosition;
  MasterpieceWorkspaceState get masterpiece => _masterpiece;
  DateTime get currentTime => _now();

  void restore() {
    try {
      _todos
        ..clear()
        ..addAll(_repository?.loadTodos() ?? const <ProfileTodo>[]);
      _hubPosition = _repository?.loadHubPosition();
      _masterpiece =
          _repository?.loadMasterpiece() ?? const MasterpieceWorkspaceState();
      _sortTodos();
      _errorCode = null;
    } catch (_) {
      _errorCode = 'PROFILE_WORKSPACE_RESTORE_FAILED';
    }
    notifyListeners();
  }

  ProfileTodo? createTodo(String title, {DateTime? dueAt}) {
    final normalized = _normalizeTitle(title);
    if (normalized == null) return null;
    final now = _now();
    final todo = ProfileTodo(
      id: _nextTodoId(now),
      title: normalized,
      dueAt: dueAt,
      createdAt: now,
      updatedAt: now,
    );
    if (!_saveTodo(todo)) return null;
    _todos.add(todo);
    _sortTodos();
    notifyListeners();
    return todo;
  }

  bool updateTodo(String id, {required String title, DateTime? dueAt}) {
    final index = _todos.indexWhere((todo) => todo.id == id);
    final normalized = _normalizeTitle(title);
    if (index == -1 || normalized == null) return false;
    final updated = _todos[index].copyWith(
      title: normalized,
      dueAt: dueAt,
      clearDueAt: dueAt == null,
      updatedAt: _now(),
    );
    if (!_saveTodo(updated)) return false;
    _todos[index] = updated;
    _sortTodos();
    notifyListeners();
    return true;
  }

  bool setTodoCompleted(String id, bool completed) {
    final index = _todos.indexWhere((todo) => todo.id == id);
    if (index == -1) return false;
    final now = _now();
    final updated = _todos[index].copyWith(
      completedAt: completed ? now : null,
      clearCompletedAt: !completed,
      updatedAt: now,
    );
    if (!_saveTodo(updated)) return false;
    _todos[index] = updated;
    _sortTodos();
    notifyListeners();
    return true;
  }

  bool deleteTodo(String id) {
    final index = _todos.indexWhere((todo) => todo.id == id);
    if (index == -1) return false;
    try {
      _repository?.deleteTodo(id);
      _errorCode = null;
    } catch (_) {
      _errorCode = 'PROFILE_TODO_DELETE_FAILED';
      notifyListeners();
      return false;
    }
    _todos.removeAt(index);
    notifyListeners();
    return true;
  }

  bool saveHubPosition(ProfileHubPosition position) {
    try {
      _repository?.saveHubPosition(position, updatedAt: _now());
      _hubPosition = position;
      _errorCode = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorCode = 'PROFILE_HUB_POSITION_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  bool setMasterpieceVisible(bool visible) {
    return _saveMasterpiece(_masterpiece.copyWith(isVisible: visible));
  }

  bool setMasterpieceCadence(MasterpieceCadence cadence) {
    return _saveMasterpiece(_masterpiece.copyWith(cadence: cadence));
  }

  bool saveMasterpieceDocument({
    required String markdown,
    required Iterable<String> includedNoteIds,
    DateTime? generatedAt,
    bool? isDepositedAsAsset,
  }) {
    final normalized = markdown.trim();
    if (normalized.isEmpty) return false;
    return _saveMasterpiece(
      _masterpiece.copyWith(
        markdown: normalized,
        generatedAt: generatedAt ?? _now(),
        includedNoteIds: includedNoteIds.toSet().toList(growable: false),
        isDepositedAsAsset: isDepositedAsAsset,
      ),
    );
  }

  bool masterpieceRefreshDue() => _masterpiece.isDueAt(_now());

  bool _saveMasterpiece(MasterpieceWorkspaceState state) {
    try {
      _repository?.saveMasterpiece(state, updatedAt: _now());
      _masterpiece = state;
      _errorCode = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorCode = 'PROFILE_MASTERPIECE_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  GrowthProgress growthProgress({
    required int personalContentCount,
    required int explicitDepositCount,
    required int completedCreationCount,
  }) => calculateGrowthProgress(
    personalContentCount: personalContentCount,
    explicitDepositCount: explicitDepositCount,
    completedCreationCount: completedCreationCount,
  );

  bool _saveTodo(ProfileTodo todo) {
    try {
      _repository?.saveTodo(todo);
      _errorCode = null;
      return true;
    } catch (_) {
      _errorCode = 'PROFILE_TODO_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }

  String? _normalizeTitle(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.runes.length > 60) return null;
    return normalized;
  }

  String _nextTodoId(DateTime now) {
    final prefix = 'todo-${now.microsecondsSinceEpoch}';
    if (_todos.every((todo) => todo.id != prefix)) return prefix;
    var suffix = 2;
    while (_todos.any((todo) => todo.id == '$prefix-$suffix')) {
      suffix++;
    }
    return '$prefix-$suffix';
  }

  void _sortTodos() {
    _todos.sort((left, right) {
      if (left.isCompleted != right.isCompleted) {
        return left.isCompleted ? 1 : -1;
      }
      final leftDue = left.dueAt;
      final rightDue = right.dueAt;
      if (leftDue != null && rightDue != null) {
        return leftDue.compareTo(rightDue);
      }
      if (leftDue != null) return -1;
      if (rightDue != null) return 1;
      return right.updatedAt.compareTo(left.updatedAt);
    });
  }
}
