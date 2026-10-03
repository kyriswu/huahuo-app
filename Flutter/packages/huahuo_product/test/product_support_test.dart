import 'dart:async';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test(
    'loads, searches, filters, and opens article and legal content',
    () async {
      final repository = _SupportRepository();
      final controller = ProductSupportController(repository);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.status, ProductSupportStatus.ready);
      expect(controller.state.filteredArticles, hasLength(2));

      controller.setQuery('图谱');
      expect(controller.state.filteredArticles.single.id, 'graph');
      controller.setQuery('');
      controller.selectCategory('recording');
      expect(controller.state.filteredArticles.single.id, 'recording');

      await controller.openArticle('recording');
      expect(controller.state.article?.markdown, '# 录音');
      await controller.openLegal(ProductLegalDocumentKind.privacyPolicy);
      expect(controller.state.legalDocument?.title, '隐私政策');
      expect(controller.state.article, isNull);
    },
  );

  test(
    'reports retryable failures and contains unexpected exceptions',
    () async {
      final repository = _SupportRepository()
        ..catalogResults.addAll([
          Future.value(
            const ProductResult.failure(
              code: 'OFFLINE',
              message: '网络不可用',
              retryable: true,
            ),
          ),
          Future.error(StateError('asset unavailable')),
        ]);
      final controller = ProductSupportController(repository);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.status, ProductSupportStatus.failure);
      expect(controller.state.retryable, isTrue);
      await controller.load();
      expect(controller.state.errorMessage, '帮助内容暂时无法读取');
    },
  );

  test('newer selection and reset suppress stale content', () async {
    final oldArticle = Completer<ProductResult<ProductSupportArticle>>();
    final legal = Completer<ProductResult<ProductLegalDocument>>();
    final repository = _SupportRepository()
      ..articleResults.add(oldArticle.future)
      ..legalResults.add(legal.future);
    final controller = ProductSupportController(repository);
    addTearDown(controller.dispose);
    await controller.load();

    final articleLoad = controller.openArticle('graph');
    final legalLoad = controller.openLegal(
      ProductLegalDocumentKind.userAgreement,
    );
    oldArticle.complete(ProductResult.success(_article('graph', '# 旧文章')));
    await articleLoad;
    expect(controller.state.article, isNull);

    controller.reset();
    legal.complete(
      const ProductResult.success(
        ProductLegalDocument(
          kind: ProductLegalDocumentKind.userAgreement,
          title: '用户协议',
          markdown: '# 用户协议',
        ),
      ),
    );
    await legalLoad;
    expect(controller.state.status, ProductSupportStatus.idle);
  });

  test('rejects category and article ids outside the loaded catalog', () async {
    final repository = _SupportRepository();
    final controller = ProductSupportController(repository);
    addTearDown(controller.dispose);
    await controller.load();

    controller.selectCategory('missing');
    await controller.openArticle('missing');

    expect(controller.state.categoryId, isNull);
    expect(repository.articleLoads, isZero);
  });
}

final class _SupportRepository implements ProductSupportRepository {
  final List<Future<ProductResult<ProductSupportCatalog>>> catalogResults = [];
  final List<Future<ProductResult<ProductSupportArticle>>> articleResults = [];
  final List<Future<ProductResult<ProductLegalDocument>>> legalResults = [];
  int articleLoads = 0;

  @override
  Future<ProductResult<ProductSupportCatalog>> loadCatalog() =>
      catalogResults.isEmpty
      ? Future.value(ProductResult.success(_catalog()))
      : catalogResults.removeAt(0);

  @override
  Future<ProductResult<ProductSupportArticle>> loadArticle(String articleId) {
    articleLoads++;
    if (articleResults.isNotEmpty) return articleResults.removeAt(0);
    return Future.value(ProductResult.success(_article(articleId, '# 录音')));
  }

  @override
  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  ) {
    if (legalResults.isNotEmpty) return legalResults.removeAt(0);
    return Future.value(
      ProductResult.success(
        ProductLegalDocument(
          kind: kind,
          title: kind == ProductLegalDocumentKind.privacyPolicy
              ? '隐私政策'
              : '用户协议',
          markdown: '# 法律文档',
        ),
      ),
    );
  }
}

ProductSupportCatalog _catalog() => ProductSupportCatalog(
  contentVersion: '2026.09.03',
  locale: 'zh-CN',
  categories: const [
    ProductSupportCategory(
      id: 'software',
      title: '软件',
      summary: '软件帮助',
      order: 0,
    ),
    ProductSupportCategory(
      id: 'recording',
      title: '录音',
      summary: '录音帮助',
      order: 1,
    ),
  ],
  articles: [
    ProductSupportArticleSummary(
      id: 'graph',
      title: '思想图谱',
      summary: '图谱帮助',
      categoryId: 'software',
      order: 0,
      tags: const ['图谱'],
    ),
    ProductSupportArticleSummary(
      id: 'recording',
      title: '录音指南',
      summary: '录音帮助',
      categoryId: 'recording',
      order: 0,
      tags: const ['录音'],
    ),
  ],
);

ProductSupportArticle _article(String id, String markdown) =>
    ProductSupportArticle(
      metadata: _catalog().articles.firstWhere((item) => item.id == id),
      markdown: markdown,
    );
