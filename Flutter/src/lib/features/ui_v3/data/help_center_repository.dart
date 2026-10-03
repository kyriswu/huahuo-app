import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/help_center_models.dart';
import '../domain/v3_markdown_outline.dart';

export '../domain/help_center_models.dart' show HelpCenterRepository;

final class AssetHelpCenterRepository implements HelpCenterRepository {
  AssetHelpCenterRepository({
    AssetBundle? bundle,
    this.manifestAssetPath = helpCenterManifestAssetPath,
  }) : _bundle = bundle ?? rootBundle;

  static const _maximumArticleBytes = 128 * 1024;

  final AssetBundle _bundle;
  final String manifestAssetPath;
  Future<HelpCenterCatalog>? _catalogFuture;
  final Map<String, Future<HelpArticle>> _articleFutures =
      <String, Future<HelpArticle>>{};

  @override
  Future<HelpCenterCatalog> loadCatalog() {
    final existing = _catalogFuture;
    if (existing != null) return existing;
    late final Future<HelpCenterCatalog> loading;
    loading = (() async {
      try {
        return await _loadCatalog();
      } catch (_) {
        if (identical(_catalogFuture, loading)) _catalogFuture = null;
        rethrow;
      }
    })();
    _catalogFuture = loading;
    return loading;
  }

  @override
  Future<HelpArticle> loadArticle(String articleId) {
    final normalizedId = articleId.trim();
    if (!_articleIdPattern.hasMatch(normalizedId)) {
      return Future<HelpArticle>.error(
        const HelpCenterLoadException('HELP_ARTICLE_ID_INVALID'),
      );
    }
    final existing = _articleFutures[normalizedId];
    if (existing != null) return existing;
    late final Future<HelpArticle> loading;
    loading = (() async {
      try {
        return await _loadArticle(normalizedId);
      } catch (_) {
        if (identical(_articleFutures[normalizedId], loading)) {
          _articleFutures.remove(normalizedId);
        }
        rethrow;
      }
    })();
    _articleFutures[normalizedId] = loading;
    return loading;
  }

  Future<HelpCenterCatalog> _loadCatalog() async {
    final raw = await _loadString(
      manifestAssetPath,
      missingCode: 'HELP_MANIFEST_MISSING',
    );
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
    }
    if (decoded is! Map<String, Object?>) {
      throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
    }

    final schemaVersion = decoded['schemaVersion'];
    final contentVersion = _requiredString(decoded['contentVersion']);
    final locale = _requiredString(decoded['locale']);
    if (schemaVersion != 1 ||
        contentVersion == null ||
        !_contentVersionPattern.hasMatch(contentVersion) ||
        locale != 'zh-CN') {
      throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
    }

    final categoryRows = _mapRows(decoded['groups']);
    final articleRows = _mapRows(decoded['articles']);
    final imageRows = _mapRows(decoded['images']);
    if (categoryRows == null ||
        categoryRows.isEmpty ||
        articleRows == null ||
        articleRows.isEmpty ||
        imageRows == null) {
      throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
    }

    final categoryIds = <String>{};
    final categories = <HelpCenterCategory>[];
    for (final row in categoryRows) {
      final id = _requiredString(row['id']);
      final title = _boundedString(row['title'], maximum: 40);
      final summary = _boundedString(row['summary'], maximum: 120);
      final order = row['order'];
      if (id == null ||
          !_groupIdPattern.hasMatch(id) ||
          !categoryIds.add(id) ||
          title == null ||
          summary == null ||
          order is! int ||
          order < 0) {
        throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
      }
      categories.add(
        HelpCenterCategory(
          id: id,
          title: title,
          summary: summary,
          order: order,
        ),
      );
    }

    final articleIds = <String>{};
    final articles = <HelpArticleSummary>[];
    for (final row in articleRows) {
      final id = _requiredString(row['id']);
      final title = _boundedString(row['title'], maximum: 60);
      final summary = _boundedString(row['summary'], maximum: 160);
      final groupId = _requiredString(row['group']);
      final assetPath = _requiredString(row['assetPath']);
      final order = row['order'];
      final tags = _stringList(row['tags']);
      if (id == null ||
          !_articleIdPattern.hasMatch(id) ||
          !articleIds.add(id) ||
          title == null ||
          summary == null ||
          groupId == null ||
          !categoryIds.contains(groupId) ||
          order is! int ||
          order < 0 ||
          tags == null ||
          assetPath == null ||
          assetPath != 'assets/help/zh-CN/articles/$id.md') {
        throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
      }
      articles.add(
        HelpArticleSummary(
          id: id,
          title: title,
          summary: summary,
          groupId: groupId,
          order: order,
          assetPath: assetPath,
          tags: tags,
        ),
      );
    }

    final imageIds = <String>{};
    final images = <HelpImageAsset>[];
    for (final row in imageRows) {
      final id = _requiredString(row['id']);
      final assetPath = _requiredString(row['assetPath']);
      final alt = _boundedString(row['alt'], maximum: 80);
      if (id == null ||
          !_imageIdPattern.hasMatch(id) ||
          !imageIds.add(id) ||
          assetPath == null ||
          !_safeImageAssetPattern.hasMatch(assetPath) ||
          alt == null) {
        throw const HelpCenterLoadException('HELP_MANIFEST_INVALID');
      }
      images.add(HelpImageAsset(id: id, assetPath: assetPath, alt: alt));
    }

    categories.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder == 0 ? a.id.compareTo(b.id) : byOrder;
    });
    articles.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder == 0 ? a.id.compareTo(b.id) : byOrder;
    });
    return HelpCenterCatalog(
      schemaVersion: schemaVersion as int,
      contentVersion: contentVersion,
      locale: locale!,
      categories: categories,
      articles: articles,
      images: images,
    );
  }

  Future<HelpArticle> _loadArticle(String articleId) async {
    final catalog = await loadCatalog();
    final metadata = catalog.articleFor(articleId);
    if (metadata == null) {
      throw const HelpCenterLoadException('HELP_ARTICLE_NOT_FOUND');
    }
    final raw = await _loadString(
      metadata.assetPath,
      missingCode: 'HELP_ARTICLE_MISSING',
    );
    final markdown = _validatedMarkdown(raw, catalog);
    for (final imageId in _referencedImageIds(markdown)) {
      final image = catalog.imageFor(imageId)!;
      try {
        await _bundle.load(image.assetPath);
      } catch (_) {
        throw const HelpCenterLoadException('HELP_IMAGE_MISSING');
      }
    }
    List<V3MarkdownOutlineNode> sections;
    try {
      sections = parseV3MarkdownOutline(
        markdown,
        idPrefix: 'help',
        maximumLevel: 6,
      );
    } on FormatException {
      throw const HelpCenterLoadException('HELP_ARTICLE_TOO_COMPLEX');
    }
    return HelpArticle(
      metadata: metadata,
      markdown: markdown,
      sections: sections,
      images: catalog.images,
    );
  }

  Future<String> _loadString(String path, {required String missingCode}) async {
    try {
      return await _bundle.loadString(path, cache: true);
    } catch (_) {
      throw HelpCenterLoadException(missingCode);
    }
  }

  String _validatedMarkdown(String raw, HelpCenterCatalog catalog) {
    var normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.startsWith('\uFEFF')) normalized = normalized.substring(1);
    if (normalized.trim().isEmpty) {
      throw const HelpCenterLoadException('HELP_ARTICLE_EMPTY');
    }
    if (utf8.encode(normalized).length > _maximumArticleBytes) {
      throw const HelpCenterLoadException('HELP_ARTICLE_TOO_LARGE');
    }
    for (final rune in normalized.runes) {
      final unsafeControl = rune < 0x20 && rune != 0x09 && rune != 0x0A;
      final bidiControl =
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069);
      if (unsafeControl || bidiControl) {
        throw const HelpCenterLoadException('HELP_ARTICLE_UNSAFE');
      }
    }
    if (_activeHtmlPattern.hasMatch(normalized) ||
        _unsafeUriPattern.hasMatch(normalized)) {
      throw const HelpCenterLoadException('HELP_ARTICLE_UNSAFE');
    }
    final imageMatches = _markdownImagePattern.allMatches(normalized).toList();
    final withoutRecognizedImages = normalized.replaceAll(
      _markdownImagePattern,
      '',
    );
    if (withoutRecognizedImages.contains('![')) {
      throw const HelpCenterLoadException('HELP_ARTICLE_UNSAFE');
    }
    for (final match in imageMatches) {
      final imageId = match.group(2) ?? '';
      if (!_imageIdPattern.hasMatch(imageId) ||
          catalog.imageFor(imageId) == null) {
        throw const HelpCenterLoadException('HELP_ARTICLE_UNSAFE');
      }
    }
    return normalized.trimRight();
  }
}

final _articleIdPattern = RegExp(r'^[a-z][a-z0-9-]{1,63}$');
final _groupIdPattern = RegExp(r'^[A-Za-z][A-Za-z0-9]{1,31}$');
final _contentVersionPattern = RegExp(r'^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$');
final _imageIdPattern = RegExp(r'^[a-z][a-z0-9-]{1,63}$');
final _safeImageAssetPattern = RegExp(
  r'^assets/help/zh-CN/images/[a-z0-9][a-z0-9_-]{0,63}\.(?:png|jpe?g|webp)$',
);
final _activeHtmlPattern = RegExp(
  r'<\s*(?:script|style|iframe|object|embed|form|input|button|a|img|svg|meta|link|!--)\b',
  caseSensitive: false,
);
final _markdownImagePattern = RegExp(
  r'^!\[([^\]\r\n]*)\]\(asset:([a-z][a-z0-9-]{1,63})\)\s*$',
  multiLine: true,
);
final _unsafeUriPattern = RegExp(
  r'(?:https?|javascript|data|file|app-private|app-private-canvas-image)\s*:',
  caseSensitive: false,
);

String? _requiredString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _boundedString(Object? value, {required int maximum}) {
  final normalized = _requiredString(value);
  if (normalized == null || normalized.runes.length > maximum) return null;
  return normalized;
}

List<Map<String, Object?>>? _mapRows(Object? value) {
  if (value is! List<Object?>) return null;
  final result = <Map<String, Object?>>[];
  for (final item in value) {
    if (item is! Map<String, Object?>) return null;
    result.add(item);
  }
  return result;
}

List<String>? _stringList(Object? value) {
  if (value is! List<Object?> || value.length > 12) return null;
  final result = <String>[];
  final seen = <String>{};
  for (final item in value) {
    final normalized = _boundedString(item, maximum: 24);
    if (normalized == null || !seen.add(normalized.toLowerCase())) return null;
    result.add(normalized);
  }
  return result;
}

Iterable<String> _referencedImageIds(String markdown) sync* {
  for (final match in _markdownImagePattern.allMatches(markdown)) {
    yield match.group(2)!;
  }
}
