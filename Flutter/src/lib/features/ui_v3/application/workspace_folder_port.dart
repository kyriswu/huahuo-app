import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

enum WorkspaceFolderPortStatus { success, unavailable, failure }

final class WorkspaceFolderPortResult<T> {
  const WorkspaceFolderPortResult._({
    required this.status,
    this.data,
    this.errorCode,
  });

  const WorkspaceFolderPortResult.success(T data)
    : this._(status: WorkspaceFolderPortStatus.success, data: data);

  const WorkspaceFolderPortResult.unavailable(String errorCode)
    : this._(
        status: WorkspaceFolderPortStatus.unavailable,
        errorCode: errorCode,
      );

  const WorkspaceFolderPortResult.failure(String errorCode)
    : this._(status: WorkspaceFolderPortStatus.failure, errorCode: errorCode);

  final WorkspaceFolderPortStatus status;
  final T? data;
  final String? errorCode;

  bool get isSuccess => status == WorkspaceFolderPortStatus.success;
}

/// Narrow mutation boundary for Workspace Folder and HNote placement.
abstract interface class WorkspaceFolderPort {
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> folder({
    required String folderId,
  });

  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> createFolder({
    required String displayName,
    required String? parentFolderId,
    required String idempotencyKey,
  });

  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> renameFolder({
    required String folderId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  });

  Future<WorkspaceFolderPortResult<SharedWorkspaceContentEvent>> moveFolder({
    required String folderId,
    required String? parentFolderId,
    required String etag,
    required String idempotencyKey,
  });

  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  deleteFolder({
    required String folderId,
    required String etag,
    required String idempotencyKey,
  });

  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  restoreFolder({
    required String folderId,
    String? parentFolderId,
    bool overrideParentFolder = false,
    required String etag,
    required String idempotencyKey,
  });

  Future<WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>> moveNotes({
    required String? folderId,
    required List<SharedHNoteBatchMoveInput> notes,
    required String idempotencyKey,
  });
}

final class UnavailableWorkspaceFolderPort implements WorkspaceFolderPort {
  const UnavailableWorkspaceFolderPort();

  static const _code = 'WORKSPACE_FOLDER_UNAVAILABLE';

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> folder({
    required String folderId,
  }) async =>
      const WorkspaceFolderPortResult<SharedWorkspaceFolder>.unavailable(_code);

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> createFolder({
    required String displayName,
    required String? parentFolderId,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<SharedWorkspaceFolder>.unavailable(_code);

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  deleteFolder({
    required String folderId,
    required String etag,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<
        SharedRecursiveFolderMutationResult
      >.unavailable(_code);

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  restoreFolder({
    required String folderId,
    String? parentFolderId,
    bool overrideParentFolder = false,
    required String etag,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<
        SharedRecursiveFolderMutationResult
      >.unavailable(_code);

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceContentEvent>> moveFolder({
    required String folderId,
    required String? parentFolderId,
    required String etag,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<SharedWorkspaceContentEvent>.unavailable(
        _code,
      );

  @override
  Future<WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>> moveNotes({
    required String? folderId,
    required List<SharedHNoteBatchMoveInput> notes,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>.unavailable(
        _code,
      );

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> renameFolder({
    required String folderId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<SharedWorkspaceFolder>.unavailable(_code);
}

final class ApiWorkspaceFolderPort implements WorkspaceFolderPort {
  ApiWorkspaceFolderPort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) : _client = WorkspaceContentClient(apiClient),
       _workspaceId = workspaceId;

  final WorkspaceContentClient _client;
  final String? Function() _workspaceId;

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> folder({
    required String folderId,
  }) => _run(
    operation: 'folder-read',
    request: (workspaceId) => _client.folder(workspaceId, folderId),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> createFolder({
    required String displayName,
    required String? parentFolderId,
    required String idempotencyKey,
  }) => _run(
    operation: 'folder-create',
    request: (workspaceId) => _client.createFolder(
      workspaceId,
      displayName: displayName,
      parentFolderId: parentFolderId,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> renameFolder({
    required String folderId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) => _run(
    operation: 'folder-rename',
    request: (workspaceId) => _client.updateFolder(
      workspaceId,
      folderId,
      displayName: displayName,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceContentEvent>> moveFolder({
    required String folderId,
    required String? parentFolderId,
    required String etag,
    required String idempotencyKey,
  }) => _run(
    operation: 'folder-move',
    request: (workspaceId) => _client.moveFolder(
      workspaceId,
      folderId,
      parentFolderId: parentFolderId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  deleteFolder({
    required String folderId,
    required String etag,
    required String idempotencyKey,
  }) => _run(
    operation: 'folder-delete',
    request: (workspaceId) => _client.deleteFolder(
      workspaceId,
      folderId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  restoreFolder({
    required String folderId,
    String? parentFolderId,
    bool overrideParentFolder = false,
    required String etag,
    required String idempotencyKey,
  }) => _run(
    operation: 'folder-restore',
    request: (workspaceId) => _client.restoreFolder(
      workspaceId,
      folderId,
      parentFolderId: parentFolderId,
      overrideParentFolder: overrideParentFolder,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>> moveNotes({
    required String? folderId,
    required List<SharedHNoteBatchMoveInput> notes,
    required String idempotencyKey,
  }) => _run(
    operation: 'hnote-batch-move',
    request: (workspaceId) => _client.batchMoveNotes(
      workspaceId,
      folderId: folderId,
      notes: notes,
      idempotencyKey: idempotencyKey,
    ),
  );

  Future<WorkspaceFolderPortResult<T>> _run<T>({
    required String operation,
    required Future<ApiResult<T>> Function(String workspaceId) request,
  }) async {
    final workspaceId = _nonEmpty(_workspaceId());
    if (workspaceId == null) {
      _debugWorkspaceFolder(
        'operation=$operation status=unavailable code=WORKSPACE_CONTEXT_UNAVAILABLE',
      );
      return WorkspaceFolderPortResult<T>.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    try {
      final response = await request(workspaceId);
      final data = response.data;
      if (response.ok && data != null) {
        _debugWorkspaceFolder('operation=$operation status=success');
        return WorkspaceFolderPortResult<T>.success(data);
      }
      final code = response.error?.code ?? 'WORKSPACE_FOLDER_MUTATION_FAILED';
      final result = _isUnavailable(code)
          ? WorkspaceFolderPortResult<T>.unavailable(code)
          : WorkspaceFolderPortResult<T>.failure(code);
      _debugWorkspaceFolder(
        'operation=$operation status=${result.status.name} code=$code',
      );
      return result;
    } on ArgumentError {
      _debugWorkspaceFolder(
        'operation=$operation status=failure code=WORKSPACE_FOLDER_REQUEST_INVALID',
      );
      return WorkspaceFolderPortResult<T>.failure(
        'WORKSPACE_FOLDER_REQUEST_INVALID',
      );
    } on FormatException {
      _debugWorkspaceFolder(
        'operation=$operation status=failure code=WORKSPACE_FOLDER_RESPONSE_INVALID',
      );
      return WorkspaceFolderPortResult<T>.failure(
        'WORKSPACE_FOLDER_RESPONSE_INVALID',
      );
    } on Object {
      _debugWorkspaceFolder(
        'operation=$operation status=failure code=WORKSPACE_FOLDER_MUTATION_FAILED',
      );
      return WorkspaceFolderPortResult<T>.failure(
        'WORKSPACE_FOLDER_MUTATION_FAILED',
      );
    }
  }
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _isUnavailable(String code) =>
    code == 'WORKSPACE_CONTEXT_UNAVAILABLE' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code.endsWith('_UNAVAILABLE');

void _debugWorkspaceFolder(String message) {
  if (kDebugMode) debugPrint('[WorkspaceFolders] $message');
}
