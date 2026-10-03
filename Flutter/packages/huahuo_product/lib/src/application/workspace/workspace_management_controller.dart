import 'dart:collection';

import '../../domain/product_result.dart';
import '../../domain/workspace/workspace_management.dart';

typedef WorkspaceManagementListener = void Function();
typedef WorkspaceIdempotencyKeyFactory =
    String Function(String operation, String entityId);

enum WorkspaceManagementStatus { idle, loading, empty, ready, failure }

final class WorkspaceManagementState {
  WorkspaceManagementState({
    required this.status,
    List<ProductWorkspace> workspaces = const <ProductWorkspace>[],
    Set<String> busyWorkspaceIds = const <String>{},
    this.creating = false,
    this.errorCode,
    this.errorMessage,
    this.retryable = false,
  }) : workspaces = UnmodifiableListView(workspaces),
       busyWorkspaceIds = UnmodifiableSetView(busyWorkspaceIds);

  factory WorkspaceManagementState.initial() =>
      WorkspaceManagementState(status: WorkspaceManagementStatus.idle);

  final WorkspaceManagementStatus status;
  final List<ProductWorkspace> workspaces;
  final Set<String> busyWorkspaceIds;
  final bool creating;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  ProductWorkspace? workspace(String workspaceId) {
    for (final workspace in workspaces) {
      if (workspace.workspaceId == workspaceId) return workspace;
    }
    return null;
  }

  WorkspaceManagementState copyWith({
    WorkspaceManagementStatus? status,
    List<ProductWorkspace>? workspaces,
    Set<String>? busyWorkspaceIds,
    bool? creating,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearError = false,
  }) => WorkspaceManagementState(
    status: status ?? this.status,
    workspaces: workspaces ?? this.workspaces,
    busyWorkspaceIds: busyWorkspaceIds ?? this.busyWorkspaceIds,
    creating: creating ?? this.creating,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}

final class WorkspaceManagementController {
  WorkspaceManagementController(
    this._repository, {
    WorkspaceIdempotencyKeyFactory? keyFactory,
  }) : _keyFactory = keyFactory ?? _defaultWorkspaceKey;

  final WorkspaceManagementRepository _repository;
  final WorkspaceIdempotencyKeyFactory _keyFactory;
  final Set<WorkspaceManagementListener> _listeners =
      <WorkspaceManagementListener>{};
  final Map<String, String> _pendingKeys = <String, String>{};
  WorkspaceManagementState _state = WorkspaceManagementState.initial();
  int _generation = 0;
  int _loadSequence = 0;
  bool _disposed = false;

  WorkspaceManagementState get state => _state;

  void addListener(WorkspaceManagementListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(WorkspaceManagementListener listener) =>
      _listeners.remove(listener);

  Future<void> reload() async {
    final generation = _generation;
    final sequence = ++_loadSequence;
    _state = _state.copyWith(
      status: WorkspaceManagementStatus.loading,
      clearError: true,
    );
    _notify();
    final result = await _repository.list();
    if (_disposed || generation != _generation || sequence != _loadSequence) {
      return;
    }
    final workspaces = result.data;
    if (!result.isSuccess || workspaces == null) {
      _state = _state.copyWith(
        status: WorkspaceManagementStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      );
    } else {
      _state = WorkspaceManagementState(
        status: workspaces.isEmpty
            ? WorkspaceManagementStatus.empty
            : WorkspaceManagementStatus.ready,
        workspaces: workspaces,
      );
    }
    _notify();
  }

  Future<bool> create({
    required String displayName,
    bool setAsDefault = true,
  }) async {
    final name = displayName.trim();
    if (_state.creating || name.isEmpty) return false;
    final operation = 'create:$name:$setAsDefault';
    final generation = _generation;
    _state = _state.copyWith(creating: true, clearError: true);
    _notify();
    final result = await _repository.create(
      displayName: name,
      setAsDefault: setAsDefault,
      idempotencyKey: _key(operation, name),
    );
    if (_disposed || generation != _generation) return false;
    if (!result.isSuccess) {
      _state = _state.copyWith(
        creating: false,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      );
      _notify();
      return false;
    }
    _pendingKeys.remove(operation);
    _state = _state.copyWith(creating: false, clearError: true);
    _notify();
    await reload();
    return true;
  }

  Future<bool> rename(String workspaceId, String displayName) {
    final name = displayName.trim();
    if (name.isEmpty) return Future<bool>.value(false);
    return _mutate(
      operation: 'rename:$workspaceId:$name',
      workspaceId: workspaceId,
      request: (workspace, key) => _repository.rename(
        workspaceId: workspaceId,
        displayName: name,
        etag: workspace.etag,
        idempotencyKey: key,
      ),
    );
  }

  Future<bool> setDefault(String workspaceId) => _mutate(
    operation: 'set-default:$workspaceId',
    workspaceId: workspaceId,
    defaultMutation: true,
    request: (workspace, key) => _repository.setDefault(
      workspaceId: workspaceId,
      etag: workspace.etag,
      idempotencyKey: key,
    ),
  );

  Future<bool> disable(String workspaceId) => _mutate(
    operation: 'disable:$workspaceId',
    workspaceId: workspaceId,
    request: (workspace, key) => _repository.disable(
      workspaceId: workspaceId,
      etag: workspace.etag,
      idempotencyKey: key,
    ),
  );

  Future<bool> restore(String workspaceId) => _mutate(
    operation: 'restore:$workspaceId',
    workspaceId: workspaceId,
    request: (workspace, key) => _repository.restore(
      workspaceId: workspaceId,
      etag: workspace.etag,
      idempotencyKey: key,
    ),
  );

  Future<bool> _mutate({
    required String operation,
    required String workspaceId,
    required Future<ProductResult<ProductWorkspace>> Function(
      ProductWorkspace workspace,
      String key,
    )
    request,
    bool defaultMutation = false,
  }) async {
    final workspace = _state.workspace(workspaceId);
    if (workspace == null || _state.busyWorkspaceIds.contains(workspaceId)) {
      return false;
    }
    final generation = _generation;
    _state = _state.copyWith(
      busyWorkspaceIds: <String>{..._state.busyWorkspaceIds, workspaceId},
      clearError: true,
    );
    _notify();
    final result = await request(workspace, _key(operation, workspaceId));
    if (_disposed || generation != _generation) return false;
    final busy = <String>{..._state.busyWorkspaceIds}..remove(workspaceId);
    final updated = result.data;
    if (!result.isSuccess || updated == null) {
      _state = _state.copyWith(
        busyWorkspaceIds: busy,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      );
      _notify();
      return false;
    }
    _pendingKeys.remove(operation);
    _state = _state.copyWith(
      workspaces: <ProductWorkspace>[
        for (final item in _state.workspaces)
          if (item.workspaceId == workspaceId)
            updated
          else if (defaultMutation)
            item.copyWith(isDefault: false)
          else
            item,
      ],
      busyWorkspaceIds: busy,
      clearError: true,
    );
    _notify();
    return true;
  }

  void reset() {
    _generation++;
    _loadSequence++;
    _pendingKeys.clear();
    _state = WorkspaceManagementState.initial();
    _notify();
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _listeners.clear();
    _pendingKeys.clear();
  }

  String _key(String operation, String entityId) => _pendingKeys.putIfAbsent(
    operation,
    () => _keyFactory(operation, entityId),
  );

  void _notify() {
    if (_disposed) return;
    for (final listener in List<WorkspaceManagementListener>.of(_listeners)) {
      listener();
    }
  }
}

int _workspaceKeyCounter = 0;

String _defaultWorkspaceKey(String operation, String entityId) {
  _workspaceKeyCounter++;
  return 'workspace-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_workspaceKeyCounter';
}
