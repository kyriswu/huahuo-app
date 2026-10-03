import 'package:flutter/foundation.dart';

import 'v3_markdown_outline.dart';

const helpCenterManifestAssetPath = 'assets/help/zh-CN/manifest.json';
const helpSoftwareGroupId = 'software';
const helpRecordingCardGroupId = 'recordingCard';
const helpCustomerServiceQrAssetPath =
    'assets/help/zh-CN/images/customer_service_qr.png';

@immutable
final class HelpCenterCategory {
  const HelpCenterCategory({
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

@immutable
final class HelpArticleSummary {
  HelpArticleSummary({
    required this.id,
    required this.title,
    required this.summary,
    required this.groupId,
    required this.order,
    required this.assetPath,
    required Iterable<String> tags,
  }) : tags = List<String>.unmodifiable(tags);

  final String id;
  final String title;
  final String summary;
  final String groupId;
  final int order;
  final String assetPath;
  final List<String> tags;

  bool matches(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return title.toLowerCase().contains(query) ||
        summary.toLowerCase().contains(query) ||
        tags.any((tag) => tag.toLowerCase().contains(query));
  }
}

@immutable
final class HelpImageAsset {
  const HelpImageAsset({
    required this.id,
    required this.assetPath,
    required this.alt,
  });

  final String id;
  final String assetPath;
  final String alt;
}

@immutable
final class HelpCenterCatalog {
  HelpCenterCatalog({
    required this.schemaVersion,
    required this.contentVersion,
    required this.locale,
    required Iterable<HelpCenterCategory> categories,
    required Iterable<HelpArticleSummary> articles,
    required Iterable<HelpImageAsset> images,
  }) : categories = List<HelpCenterCategory>.unmodifiable(categories),
       articles = List<HelpArticleSummary>.unmodifiable(articles),
       images = List<HelpImageAsset>.unmodifiable(images);

  final int schemaVersion;
  final String contentVersion;
  final String locale;
  final List<HelpCenterCategory> categories;
  final List<HelpArticleSummary> articles;
  final List<HelpImageAsset> images;

  HelpCenterCategory? categoryFor(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  HelpArticleSummary? articleFor(String id) {
    for (final article in articles) {
      if (article.id == id) return article;
    }
    return null;
  }

  HelpImageAsset? imageFor(String id) {
    for (final image in images) {
      if (image.id == id) return image;
    }
    return null;
  }

  List<HelpArticleSummary> articlesFor(String groupId) =>
      List<HelpArticleSummary>.unmodifiable(
        articles.where((article) => article.groupId == groupId),
      );
}

@immutable
final class HelpArticle {
  HelpArticle({
    required this.metadata,
    required this.markdown,
    required Iterable<V3MarkdownOutlineNode> sections,
    required Iterable<HelpImageAsset> images,
  }) : sections = List<V3MarkdownOutlineNode>.unmodifiable(sections),
       images = List<HelpImageAsset>.unmodifiable(images);

  final HelpArticleSummary metadata;
  final String markdown;
  final List<V3MarkdownOutlineNode> sections;
  final List<HelpImageAsset> images;

  Iterable<V3MarkdownOutlineNode> get flattenedSections sync* {
    for (final section in sections) {
      yield* section.flattened;
    }
  }

  HelpImageAsset? imageFor(String id) {
    for (final image in images) {
      if (image.id == id) return image;
    }
    return null;
  }
}

final class HelpCenterLoadException implements Exception {
  const HelpCenterLoadException(this.code);

  final String code;

  @override
  String toString() => code;
}

abstract interface class HelpCenterRepository {
  Future<HelpCenterCatalog> loadCatalog();

  Future<HelpArticle> loadArticle(String articleId);
}
