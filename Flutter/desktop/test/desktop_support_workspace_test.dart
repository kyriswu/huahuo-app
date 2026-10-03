import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_product/huahuo_product.dart';

import 'package:huahuo_desktop/features/support/data/desktop_support_asset_repository.dart';
import 'package:huahuo_desktop/features/support/widgets/desktop_support_workspace.dart';

void main() {
  testWidgets('bundled Mobile-aligned catalog and Markdown load', (
    tester,
  ) async {
    final repository = DesktopSupportAssetRepository();

    final catalog = await repository.loadCatalog();
    final article = await repository.loadArticle('software-getting-started');
    final legal = await repository.loadLegal(
      ProductLegalDocumentKind.privacyPolicy,
    );

    expect(catalog.isSuccess, isTrue);
    expect(catalog.data?.articles, hasLength(19));
    expect(article.data?.markdown, contains('快速开始'));
    expect(legal.data?.markdown, contains('隐私'));
  });

  testWidgets('searches, opens an article, and returns on narrow windows', (
    tester,
  ) async {
    final repository = _SupportRepository();
    await tester.binding.setSurfaceSize(const Size(680, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, repository);

    await tester.enterText(
      find.byKey(const ValueKey<String>('support-search')),
      '图谱',
    );
    await tester.pump();
    expect(find.text('思想图谱'), findsOneWidget);
    expect(find.text('录音指南'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('support-article-graph')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('图谱正文'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('support-reader-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('support-search')),
      findsOneWidget,
    );
  });

  testWidgets('opens legal content and customer-service dialog', (
    tester,
  ) async {
    await _pump(tester, _SupportRepository());

    await tester.tap(find.text('隐私政策'));
    await tester.pumpAndSettle();
    expect(find.textContaining('隐私正文'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('support-customer-service')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('support-customer-service-qr')),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('联系客服'), findsOneWidget);
  });

  testWidgets('shows catalog failure and retries into ready content', (
    tester,
  ) async {
    final repository = _SupportRepository()..failCatalogOnce = true;
    await _pump(tester, repository);
    expect(find.text('资源暂时不可用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('support-retry')));
    await tester.pumpAndSettle();

    expect(find.text('思想图谱'), findsOneWidget);
    expect(repository.catalogLoads, 2);
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProductSupportRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: DesktopSupportWorkspace(repository: repository)),
    ),
  );
  await tester.pumpAndSettle();
}

final class _SupportRepository implements ProductSupportRepository {
  bool failCatalogOnce = false;
  int catalogLoads = 0;

  @override
  Future<ProductResult<ProductSupportCatalog>> loadCatalog() async {
    catalogLoads++;
    if (failCatalogOnce) {
      failCatalogOnce = false;
      return const ProductResult.failure(
        code: 'ASSET_FAILURE',
        message: '资源暂时不可用',
        retryable: true,
      );
    }
    return ProductResult.success(
      ProductSupportCatalog(
        contentVersion: '2026.09.03',
        locale: 'zh-CN',
        categories: const [
          ProductSupportCategory(
            id: 'software',
            title: '软件指南',
            summary: '软件帮助',
            order: 0,
          ),
          ProductSupportCategory(
            id: 'recording',
            title: '录音卡指南',
            summary: '录音帮助',
            order: 1,
          ),
        ],
        articles: [
          ProductSupportArticleSummary(
            id: 'graph',
            title: '思想图谱',
            summary: '查看图谱帮助',
            categoryId: 'software',
            order: 0,
            tags: const ['图谱'],
          ),
          ProductSupportArticleSummary(
            id: 'recording',
            title: '录音指南',
            summary: '查看录音帮助',
            categoryId: 'recording',
            order: 0,
            tags: const ['录音'],
          ),
        ],
      ),
    );
  }

  @override
  Future<ProductResult<ProductSupportArticle>> loadArticle(
    String articleId,
  ) async => ProductResult.success(
    ProductSupportArticle(
      metadata: ProductSupportArticleSummary(
        id: articleId,
        title: '思想图谱',
        summary: '图谱帮助',
        categoryId: 'software',
        order: 0,
        tags: const ['图谱'],
      ),
      markdown: '# 图谱正文\n\n可以拖拽和缩放。',
    ),
  );

  @override
  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  ) async => ProductResult.success(
    ProductLegalDocument(
      kind: kind,
      title: kind == ProductLegalDocumentKind.privacyPolicy ? '隐私政策' : '用户服务协议',
      markdown: kind == ProductLegalDocumentKind.privacyPolicy
          ? '# 隐私正文'
          : '# 协议正文',
    ),
  );
}
