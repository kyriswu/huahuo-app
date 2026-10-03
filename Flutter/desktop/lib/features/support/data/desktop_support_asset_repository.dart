import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:huahuo_product/huahuo_product.dart';

final class DesktopSupportAssetRepository implements ProductSupportRepository {
  DesktopSupportAssetRepository({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  static const manifestAsset = 'assets/support/help/zh-CN/manifest.json';
  static const customerServiceQrAsset =
      'assets/support/help/zh-CN/images/customer_service_qr.png';
  static const _mobileArticlePrefix = 'assets/help/zh-CN/articles/';
  static const _desktopArticlePrefix = 'assets/support/help/zh-CN/articles/';
  static const _maximumMarkdownBytes = 128 * 1024;

  final AssetBundle _bundle;
  ProductSupportCatalog? _catalog;
  Map<String, String> _articleAssets = const {};

  @override
  Future<ProductResult<ProductSupportCatalog>> loadCatalog() async {
    try {
      final raw = await _bundle.loadString(manifestAsset, cache: false);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> ||
          decoded['schemaVersion'] != 1 ||
          decoded['locale'] != 'zh-CN') {
        throw const FormatException('Unsupported support manifest');
      }
      final contentVersion = _requiredString(decoded, 'contentVersion');
      final categories = _parseCategories(decoded['groups']);
      final categoryIds = categories.map((item) => item.id).toSet();
      final parsed = _parseArticles(decoded['articles'], categoryIds);
      final catalog = ProductSupportCatalog(
        contentVersion: contentVersion,
        locale: 'zh-CN',
        categories: categories,
        articles: parsed.summaries,
      );
      _catalog = catalog;
      _articleAssets = Map.unmodifiable(parsed.assets);
      return ProductResult.success(catalog);
    } on Object {
      _catalog = null;
      _articleAssets = const {};
      return const ProductResult.failure(
        code: 'SUPPORT_CATALOG_INVALID',
        message: '帮助内容读取失败，请重试',
        retryable: true,
      );
    }
  }

  @override
  Future<ProductResult<ProductSupportArticle>> loadArticle(
    String articleId,
  ) async {
    final normalizedId = articleId.trim();
    final catalog = _catalog;
    final asset = _articleAssets[normalizedId];
    if (catalog == null || asset == null) {
      return const ProductResult.failure(
        code: 'SUPPORT_ARTICLE_NOT_DECLARED',
        message: '该帮助文章不存在',
      );
    }
    try {
      final markdown = await _loadMarkdown(asset);
      final metadata = catalog.articles.firstWhere(
        (item) => item.id == normalizedId,
      );
      return ProductResult.success(
        ProductSupportArticle(metadata: metadata, markdown: markdown),
      );
    } on Object {
      return const ProductResult.failure(
        code: 'SUPPORT_ARTICLE_INVALID',
        message: '帮助文章读取失败，请重试',
        retryable: true,
      );
    }
  }

  @override
  Future<ProductResult<ProductLegalDocument>> loadLegal(
    ProductLegalDocumentKind kind,
  ) async {
    final (title, asset) = switch (kind) {
      ProductLegalDocumentKind.userAgreement => (
        '用户服务协议',
        'assets/support/legal/user_service_agreement.md',
      ),
      ProductLegalDocumentKind.privacyPolicy => (
        '隐私政策',
        'assets/support/legal/privacy_policy.md',
      ),
    };
    try {
      return ProductResult.success(
        ProductLegalDocument(
          kind: kind,
          title: title,
          markdown: await _loadMarkdown(asset),
        ),
      );
    } on Object {
      return const ProductResult.failure(
        code: 'SUPPORT_LEGAL_INVALID',
        message: '法律文档读取失败，请重试',
        retryable: true,
      );
    }
  }

  Future<String> _loadMarkdown(String asset) async {
    final markdown = await _bundle.loadString(asset, cache: false);
    if (markdown.trim().isEmpty ||
        utf8.encode(markdown).length > _maximumMarkdownBytes) {
      throw const FormatException('Invalid Markdown document');
    }
    return markdown;
  }

  static List<ProductSupportCategory> _parseCategories(Object? raw) {
    if (raw is! List<Object?> || raw.isEmpty) {
      throw const FormatException('Missing support groups');
    }
    final ids = <String>{};
    final result = <ProductSupportCategory>[];
    for (final value in raw) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Invalid support group');
      }
      final id = _safeId(_requiredString(value, 'id'));
      if (!ids.add(id)) throw const FormatException('Duplicate support group');
      result.add(
        ProductSupportCategory(
          id: id,
          title: _requiredString(value, 'title'),
          summary: _requiredString(value, 'summary'),
          order: _requiredInt(value, 'order'),
        ),
      );
    }
    result.sort((left, right) => left.order.compareTo(right.order));
    return List.unmodifiable(result);
  }

  static ({
    List<ProductSupportArticleSummary> summaries,
    Map<String, String> assets,
  })
  _parseArticles(Object? raw, Set<String> categoryIds) {
    if (raw is! List<Object?> || raw.isEmpty) {
      throw const FormatException('Missing support articles');
    }
    final ids = <String>{};
    final summaries = <ProductSupportArticleSummary>[];
    final assets = <String, String>{};
    for (final value in raw) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Invalid support article');
      }
      final id = _safeId(_requiredString(value, 'id'));
      final categoryId = _safeId(_requiredString(value, 'group'));
      if (!ids.add(id) || !categoryIds.contains(categoryId)) {
        throw const FormatException('Invalid support article relationship');
      }
      final sourceAsset = _requiredString(value, 'assetPath');
      if (!sourceAsset.startsWith(_mobileArticlePrefix) ||
          !sourceAsset.endsWith('/$id.md') ||
          sourceAsset.substring(_mobileArticlePrefix.length).contains('/')) {
        throw const FormatException('Invalid support article asset');
      }
      final tags = value['tags'];
      if (tags is! List<Object?> || tags.any((tag) => tag is! String)) {
        throw const FormatException('Invalid support article tags');
      }
      summaries.add(
        ProductSupportArticleSummary(
          id: id,
          title: _requiredString(value, 'title'),
          summary: _requiredString(value, 'summary'),
          categoryId: categoryId,
          order: _requiredInt(value, 'order'),
          tags: tags.cast<String>(),
        ),
      );
      assets[id] = '$_desktopArticlePrefix$id.md';
    }
    summaries.sort((left, right) {
      final category = left.categoryId.compareTo(right.categoryId);
      return category != 0 ? category : left.order.compareTo(right.order);
    });
    return (summaries: List.unmodifiable(summaries), assets: assets);
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Missing $key');
    }
    return value.trim();
  }

  static int _requiredInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int || value < 0) throw FormatException('Invalid $key');
    return value;
  }

  static String _safeId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,79}$').hasMatch(value)) {
      throw const FormatException('Unsafe support id');
    }
    return value;
  }
}
