import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/creations/product_creation.dart';
import '../../domain/product_result.dart';

final class RemoteProductCreationsRepository
    implements ProductCreationsRepository {
  RemoteProductCreationsRepository(ApiClient api)
    : _client = CreationClient(api);

  final CreationClient _client;

  @override
  Future<ProductResult<List<ProductCreationSummary>>> list(
    String workspaceId,
  ) async {
    try {
      final result = await _client.list(workspaceId);
      final page = result.data;
      if (!result.ok || page == null) return _failure(result.error);
      return ProductResult.success(List.unmodifiable(page.items.map(_summary)));
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  ) async {
    try {
      return _loadDocument(workspaceId, creationId);
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) async {
    try {
      final created = await _client.create(
        workspaceId,
        title: title,
        rawMarkdown: rawMarkdown,
        idempotencyKey: idempotencyKey,
      );
      if (!created.ok || created.data == null) return _failure(created.error);
      return _loadDocument(workspaceId, created.data!.objectId);
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  }) async {
    try {
      final freshResult = await _loadDocument(workspaceId, current.summary.id);
      var fresh = freshResult.data;
      if (!freshResult.isSuccess || fresh == null) return freshResult;
      if (fresh.summary.isTrashed) {
        return const ProductResult.failure(
          code: 'CREATION_TRASHED',
          message: '已删除的创作不能保存，请先恢复',
        );
      }
      if (fresh.summary.title != title.trim()) {
        final renamed = await _client.rename(
          workspaceId,
          fresh.summary.id,
          title: title,
          etag: fresh.summary.etag,
          idempotencyKey: titleIdempotencyKey,
        );
        if (!renamed.ok) return _failure(renamed.error);
        final refreshed = await _loadDocument(workspaceId, fresh.summary.id);
        fresh = refreshed.data;
        if (!refreshed.isSuccess || fresh == null) return refreshed;
      }
      if (fresh.rawMarkdown != rawMarkdown) {
        final updated = await _client.putPart(
          workspaceId,
          fresh.summary.id,
          'raw',
          contentMarkdown: rawMarkdown,
          basePartRevisionId: fresh.rawPartRevisionId,
          etag: fresh.rawPartEtag,
          idempotencyKey: contentIdempotencyKey,
        );
        if (!updated.ok) return _failure(updated.error);
      }
      return _loadDocument(workspaceId, fresh.summary.id);
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    try {
      final result = await _client.delete(
        workspaceId,
        creation.id,
        etag: creation.etag,
        idempotencyKey: idempotencyKey,
      );
      return result.ok
          ? const ProductResult.success(null)
          : _failure(result.error);
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    try {
      final result = await _client.restore(
        workspaceId,
        creation.id,
        etag: creation.etag,
        idempotencyKey: idempotencyKey,
      );
      return result.ok
          ? const ProductResult.success(null)
          : _failure(result.error);
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  }) async {
    try {
      final result = await _client.revisions(workspaceId, creationId, 'raw');
      final page = result.data;
      if (!result.ok || page == null) return _failure(result.error);
      return ProductResult.success(
        List.unmodifiable(
          page.items.map(
            (item) => ProductCreationRevision(
              id: item.partRevisionId,
              revision: item.revision,
              markdown: item.contentMarkdown,
              createdAt: item.createdAt,
            ),
          ),
        ),
      );
    } on Object {
      return _unexpected();
    }
  }

  Future<ProductResult<ProductCreationDocument>> _loadDocument(
    String workspaceId,
    String creationId,
  ) async {
    final detail = await _client.detail(workspaceId, creationId);
    final creation = detail.data;
    if (!detail.ok || creation == null) return _failure(detail.error);
    final raw = await _client.part(workspaceId, creationId, 'raw');
    final part = raw.data;
    if (!raw.ok || part == null) return _failure(raw.error);
    if (creation.part('raw').currentRevisionId != part.partRevisionId) {
      return const ProductResult.failure(
        code: 'CREATION_PART_REVISION_MISMATCH',
        message: '创作内容版本已变化，请刷新后重试',
        retryable: true,
      );
    }
    return ProductResult.success(
      ProductCreationDocument(
        summary: _summary(creation),
        rawMarkdown: part.contentMarkdown,
        rawPartRevisionId: part.partRevisionId,
        rawPartEtag: part.etag,
      ),
    );
  }
}

ProductCreationSummary _summary(CreationDto value) => ProductCreationSummary(
  id: value.creationId,
  title: value.title,
  lifecycle: value.lifecycle,
  revisionId: value.revisionId,
  revision: value.revision,
  partRevisionIds: {
    for (final part in value.parts) part.part: part.currentRevisionId,
  },
  etag: value.etag,
);

ProductResult<T> _failure<T>(AppFailure? failure) => ProductResult.failure(
  code: failure?.code ?? 'CREATION_REQUEST_FAILED',
  message: failure?.message ?? '创作请求失败，请重试',
  retryable: failure?.isRetryable ?? true,
);

ProductResult<T> _unexpected<T>() => const ProductResult.failure(
  code: 'CREATION_UNEXPECTED',
  message: '创作服务暂时不可用，请重试',
  retryable: true,
);
