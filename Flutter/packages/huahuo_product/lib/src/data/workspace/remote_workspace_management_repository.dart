import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/product_result.dart';
import '../../domain/workspace/workspace_management.dart';

final class RemoteWorkspaceManagementRepository
    implements WorkspaceManagementRepository {
  RemoteWorkspaceManagementRepository(ApiClient api)
    : _client = WorkspaceLifecycleClient(api);

  final WorkspaceLifecycleClient _client;

  @override
  Future<ProductResult<List<ProductWorkspace>>> list() async {
    final result = await _client.list();
    final page = result.data;
    if (!result.ok || page == null) return _failure(result);
    return ProductResult<List<ProductWorkspace>>.success(
      List<ProductWorkspace>.unmodifiable(page.items.map(_workspace)),
    );
  }

  @override
  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) async {
    final result = await _client.create(
      displayName: displayName,
      setAsDefault: setAsDefault,
      idempotencyKey: idempotencyKey,
    );
    final value = result.data;
    if (!result.ok || value == null) return _failure(result);
    return ProductResult<ProductWorkspaceBootstrap>.success(
      ProductWorkspaceBootstrap(
        workspaceId: value.workspaceId,
        state: value.state,
        etag: value.etag,
        bootstrapReceiptId: value.bootstrapReceiptId,
        bootstrapContentCursor: value.bootstrapContentCursor,
        contentCursor: value.contentCursor,
      ),
    );
  }

  @override
  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async => _summary(
    await _client.update(
      workspaceId,
      displayName: displayName,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _summary(
    await _client.setDefault(
      workspaceId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _summary(
    await _client.disable(
      workspaceId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async => _summary(
    await _client.restore(
      workspaceId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );
}

ProductResult<ProductWorkspace> _summary(
  ApiResult<SharedWorkspaceSummary> result,
) {
  final value = result.data;
  if (!result.ok || value == null) return _failure(result);
  return ProductResult<ProductWorkspace>.success(_workspace(value));
}

ProductWorkspace _workspace(SharedWorkspaceSummary value) => ProductWorkspace(
  workspaceId: value.workspaceId,
  displayName: value.displayName,
  state: value.state,
  isDefault: value.isDefault,
  etag: value.etag,
);

ProductResult<T> _failure<T>(ApiResult<Object?> result) {
  final error = result.error;
  return ProductResult<T>.failure(
    code: error?.code ?? 'WORKSPACE_REQUEST_FAILED',
    message: _safeMessage(error?.message) ?? 'Workspace 操作失败',
    retryable: error?.isRetryable ?? false,
  );
}

String? _safeMessage(String? value) {
  final text = value?.trim();
  if (text == null ||
      text.isEmpty ||
      text.runes.length > 200 ||
      text.runes.any((rune) => rune <= 0x1f || rune == 0x7f)) {
    return null;
  }
  return text;
}
