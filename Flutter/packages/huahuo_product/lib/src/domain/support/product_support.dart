import '../product_result.dart';

enum ProductLegalDocumentKind { userAgreement, privacyPolicy }

final class ProductSupportCategory {
  const ProductSupportCategory({
    required this.id,
    required this.title,
    required this.summary,
    required this.order,
  });

  final String id;
  final String title;
  final String summary;
  final int order;
}

final class ProductSupportArticleSummary {
  ProductSupportArticleSummary({
    required this.id,
    required this.title,
    required this.summary,
    required this.categoryId,
    required this.order,
    required Iterable<String> tags,
  }) : tags = List<String>.unmodifiable(tags);

  final String id;
  final String title;
  final String summary;
  final String categoryId;
  final int order;
  final List<String> tags;

  bool matches(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    return query.isEmpty ||
        title.toLowerCase().contains(query) ||
        summary.toLowerCase().contains(query) ||
        tags.any((tag) => tag.toLowerCase().contains(query));
  }
}

final class ProductSupportCatalog {
  ProductSupportCatalog({
    required this.contentVersion,
    required this.locale,
    required Iterable<ProductSupportCategory> categories,
    required Iterable<ProductSupportArticleSummary> articles,
  }) : categories = List<ProductSupportCategory>.unmodifiable(categories),
       articles = List<ProductSupportArticleSummary>.unmodifiable(articles);

  final String contentVersion;
  final String locale;
  final List<ProductSupportCategory> categories;
  final List<ProductSupportArticleSummary> articles;
}

final class ProductSupportArticle {
  const ProductSupportArticle({required this.metadata, required this.markdown});

  final ProductSupportArticleSummary metadata;
  final String markdown;
}

final class ProductLegalDocument {
  const ProductLegalDocument({
    required this.kind,
    required this.title,
    required this.markdown,
  });

  final ProductLegalDocumentKind kind;
  final String title;
  final String markdown;
}

abstract interface class ProductSupportRepository {
  Future<ProductResult<ProductSupportCatalog>> loadCatalog();

  Future<ProductResult<ProductSupportArticle>> loadArticle(String articleId);

  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  );
}

final class UnavailableProductSupportRepository
    implements ProductSupportRepository {
  const UnavailableProductSupportRepository();

  @override
  Future<ProductResult<ProductSupportCatalog>> loadCatalog() async =>
      const ProductResult.failure(
        code: 'PRODUCT_SUPPORT_UNAVAILABLE',
        message: '帮助内容尚未配置',
      );

  @override
  Future<ProductResult<ProductSupportArticle>> loadArticle(
    String articleId,
  ) async => const ProductResult.failure(
    code: 'PRODUCT_SUPPORT_UNAVAILABLE',
    message: '帮助内容尚未配置',
  );

  @override
  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  ) async => const ProductResult.failure(
    code: 'PRODUCT_SUPPORT_UNAVAILABLE',
    message: '法律文档尚未配置',
  );
}
