import '../product_result.dart';

final class ProductCreationSummary {
  ProductCreationSummary({
    required this.id,
    required this.title,
    required this.lifecycle,
    required this.revisionId,
    required this.revision,
    required Map<String, String> partRevisionIds,
    required this.etag,
  }) : partRevisionIds = Map.unmodifiable(partRevisionIds);

  final String id;
  final String title;
  final String lifecycle;
  final String revisionId;
  final int revision;
  final Map<String, String> partRevisionIds;
  final String etag;

  bool get isTrashed => lifecycle == 'trashed';
}

final class ProductCreationDocument {
  const ProductCreationDocument({
    required this.summary,
    required this.rawMarkdown,
    required this.rawPartRevisionId,
    required this.rawPartEtag,
  });

  final ProductCreationSummary summary;
  final String rawMarkdown;
  final String rawPartRevisionId;
  final String rawPartEtag;
}

final class ProductCreationRevision {
  const ProductCreationRevision({
    required this.id,
    required this.revision,
    required this.markdown,
    required this.createdAt,
  });

  final String id;
  final int revision;
  final String markdown;
  final DateTime createdAt;
}

abstract interface class ProductCreationsRepository {
  Future<ProductResult<List<ProductCreationSummary>>> list(String workspaceId);

  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  );

  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  });

  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  });

  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  });

  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  });
}

final class UnavailableProductCreationsRepository
    implements ProductCreationsRepository {
  const UnavailableProductCreationsRepository();

  ProductResult<T> _unavailable<T>() => const ProductResult.failure(
    code: 'PRODUCT_CREATIONS_UNAVAILABLE',
    message: '创作服务尚未配置',
  );

  @override
  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  ) async => _unavailable();

  @override
  Future<ProductResult<List<ProductCreationSummary>>> list(
    String workspaceId,
  ) async => _unavailable();

  @override
  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  }) async => _unavailable();
}
