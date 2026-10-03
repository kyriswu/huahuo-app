import '../product_result.dart';

final class ProductWorkspace {
  const ProductWorkspace({
    required this.workspaceId,
    required this.displayName,
    required this.state,
    required this.isDefault,
    required this.etag,
  });

  final String workspaceId;
  final String displayName;
  final String state;
  final bool isDefault;
  final String etag;

  bool get isDisabled => state == 'disabled';

  ProductWorkspace copyWith({bool? isDefault}) => ProductWorkspace(
    workspaceId: workspaceId,
    displayName: displayName,
    state: state,
    isDefault: isDefault ?? this.isDefault,
    etag: etag,
  );
}

final class ProductWorkspaceBootstrap {
  const ProductWorkspaceBootstrap({
    required this.workspaceId,
    required this.state,
    required this.etag,
    required this.bootstrapReceiptId,
    required this.bootstrapContentCursor,
    required this.contentCursor,
  });

  final String workspaceId;
  final String state;
  final String etag;
  final String bootstrapReceiptId;
  final String bootstrapContentCursor;
  final String contentCursor;
}

abstract interface class WorkspaceManagementRepository {
  Future<ProductResult<List<ProductWorkspace>>> list();

  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  });
}

final class UnavailableWorkspaceManagementRepository
    implements WorkspaceManagementRepository {
  const UnavailableWorkspaceManagementRepository();

  static const _failure = ProductResult<ProductWorkspace>.failure(
    code: 'WORKSPACE_MANAGEMENT_UNAVAILABLE',
    message: 'Workspace 管理服务尚未配置',
  );

  @override
  Future<ProductResult<List<ProductWorkspace>>> list() async =>
      const ProductResult<List<ProductWorkspace>>.failure(
        code: 'WORKSPACE_MANAGEMENT_UNAVAILABLE',
        message: 'Workspace 管理服务尚未配置',
      );

  @override
  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) async => const ProductResult<ProductWorkspaceBootstrap>.failure(
    code: 'WORKSPACE_MANAGEMENT_UNAVAILABLE',
    message: 'Workspace 管理服务尚未配置',
  );

  @override
  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async => _failure;

  @override
  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _failure;

  @override
  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _failure;

  @override
  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _failure;
}
