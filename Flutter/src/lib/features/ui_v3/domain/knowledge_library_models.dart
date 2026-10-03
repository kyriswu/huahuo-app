import 'package:flutter/foundation.dart';

import 'feed_item_models.dart';

enum V3KnowledgeLibraryTab { mine, subscribed, square }

enum KnowledgeChannel {
  treasure('treasure', '镇馆之宝', '精选跨领域代表性内容，关注能够长期复用的思想与作品。'),
  history('history', '历史', '从人物、制度与日常生活理解历史如何塑造今天。'),
  socialScience('social-science', '社科', '用社会学、传播学与心理学观察真实社会问题。'),
  art('art', '艺术', '连接艺术史、审美方法与当代创作现场。'),
  literature('literature', '文学', '阅读经典与当代写作，理解叙事、语言和人的处境。'),
  audio('audio', '必读/必听', '整理值得反复阅读和收听的书、播客与演讲。'),
  culture('culture', '文创', '关注文化内容如何转化为产品、空间与品牌体验。'),
  city('city', '城市漫游', '通过街区、建筑、店铺与公共空间重新认识城市。'),
  bookstore('bookstore', '书店', '发现独立书店、主题书单和阅读共同体。');

  const KnowledgeChannel(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static KnowledgeChannel? fromId(String value) {
    for (final channel in values) {
      if (channel.id == value) return channel;
    }
    return null;
  }
}

enum KnowledgeSourceCategory { all, recording, link, manual, imported, other }

extension KnowledgeSourceCategoryX on KnowledgeSourceCategory {
  String get label => switch (this) {
    KnowledgeSourceCategory.all => '全部笔记',
    KnowledgeSourceCategory.recording => '录音笔记',
    KnowledgeSourceCategory.link => '链接笔记',
    KnowledgeSourceCategory.manual => '手写笔记',
    KnowledgeSourceCategory.imported => '导入笔记',
    KnowledgeSourceCategory.other => '其他',
  };

  bool includes(V3MaterialSource source) =>
      this == KnowledgeSourceCategory.all ||
      knowledgeSourceCategoryFor(source) == this;
}

KnowledgeSourceCategory knowledgeSourceCategoryFor(V3MaterialSource source) {
  return switch (source) {
    V3MaterialSource.meeting ||
    V3MaterialSource.internalRecording ||
    V3MaterialSource.monologue ||
    V3MaterialSource.recordingCard => KnowledgeSourceCategory.recording,
    V3MaterialSource.link => KnowledgeSourceCategory.link,
    V3MaterialSource.note ||
    V3MaterialSource.chatExcerpt ||
    V3MaterialSource.topicCollision => KnowledgeSourceCategory.manual,
    V3MaterialSource.documentImport ||
    V3MaterialSource.mediaImport ||
    V3MaterialSource.materialMigration => KnowledgeSourceCategory.imported,
    V3MaterialSource.subscription ||
    V3MaterialSource.knowledgeSquare ||
    V3MaterialSource.hotspot ||
    V3MaterialSource.other => KnowledgeSourceCategory.other,
  };
}

enum KnowledgeCardDisplayMode { expanded, compact }

enum KnowledgeTimeFilter { all, today, last7Days, last30Days, thisYear, custom }

extension KnowledgeTimeFilterX on KnowledgeTimeFilter {
  String get label => switch (this) {
    KnowledgeTimeFilter.all => '全部时间',
    KnowledgeTimeFilter.today => '今天',
    KnowledgeTimeFilter.last7Days => '近 7 天',
    KnowledgeTimeFilter.last30Days => '近 30 天',
    KnowledgeTimeFilter.thisYear => '本年',
    KnowledgeTimeFilter.custom => '自定义范围',
  };
}

@immutable
final class KnowledgeDateRange {
  const KnowledgeDateRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

enum KnowledgeSourceFilter {
  all,
  meeting,
  internalRecording,
  link,
  monologue,
  manualNote,
  recordingCard,
  imported,
  hotspot,
  other,
}

extension KnowledgeSourceFilterX on KnowledgeSourceFilter {
  String get label => switch (this) {
    KnowledgeSourceFilter.all => '全部',
    KnowledgeSourceFilter.meeting => '会议',
    KnowledgeSourceFilter.internalRecording => '内录',
    KnowledgeSourceFilter.link => '链接',
    KnowledgeSourceFilter.monologue => '独白',
    KnowledgeSourceFilter.manualNote => '手写笔记',
    KnowledgeSourceFilter.recordingCard => '录音卡',
    KnowledgeSourceFilter.imported => '导入资料',
    KnowledgeSourceFilter.hotspot => '热点',
    KnowledgeSourceFilter.other => '其他',
  };

  bool includes(V3MaterialSource source) =>
      this == KnowledgeSourceFilter.all ||
      knowledgeSourceFilterFor(source) == this;
}

KnowledgeSourceFilter knowledgeSourceFilterFor(V3MaterialSource source) {
  return switch (source) {
    V3MaterialSource.meeting => KnowledgeSourceFilter.meeting,
    V3MaterialSource.internalRecording =>
      KnowledgeSourceFilter.internalRecording,
    V3MaterialSource.link => KnowledgeSourceFilter.link,
    V3MaterialSource.monologue => KnowledgeSourceFilter.monologue,
    V3MaterialSource.note ||
    V3MaterialSource.chatExcerpt ||
    V3MaterialSource.topicCollision => KnowledgeSourceFilter.manualNote,
    V3MaterialSource.recordingCard => KnowledgeSourceFilter.recordingCard,
    V3MaterialSource.documentImport ||
    V3MaterialSource.mediaImport ||
    V3MaterialSource.materialMigration => KnowledgeSourceFilter.imported,
    V3MaterialSource.hotspot => KnowledgeSourceFilter.hotspot,
    V3MaterialSource.subscription ||
    V3MaterialSource.knowledgeSquare ||
    V3MaterialSource.other => KnowledgeSourceFilter.other,
  };
}

enum V3KnowledgeGrouping { source, contentLine, folder, ownership }

extension V3KnowledgeGroupingX on V3KnowledgeGrouping {
  String get label => switch (this) {
    V3KnowledgeGrouping.source => '按笔记来源分类',
    V3KnowledgeGrouping.contentLine => '按主题/内容线分类',
    V3KnowledgeGrouping.folder => '按文件夹分类',
    V3KnowledgeGrouping.ownership => '按内容归属分类',
  };
}

enum V3KnowledgeSort { recentlyUpdated, earliestCreated, name }

@immutable
final class KnowledgeAssetSearchFilters {
  KnowledgeAssetSearchFilters({
    this.source = KnowledgeSourceCategory.all,
    this.time = KnowledgeTimeFilter.all,
    this.sort = V3KnowledgeSort.recentlyUpdated,
    Iterable<String> tags = const [],
  }) : tags = Set<String>.unmodifiable(
         tags
             .map((tag) => tag.trim().toLowerCase())
             .where((tag) => tag.isNotEmpty),
       );

  final KnowledgeSourceCategory source;
  final KnowledgeTimeFilter time;
  final V3KnowledgeSort sort;
  final Set<String> tags;

  bool get hasFilters =>
      source != KnowledgeSourceCategory.all ||
      time != KnowledgeTimeFilter.all ||
      tags.isNotEmpty;

  KnowledgeAssetSearchFilters copyWith({
    KnowledgeSourceCategory? source,
    KnowledgeTimeFilter? time,
    V3KnowledgeSort? sort,
    Iterable<String>? tags,
  }) => KnowledgeAssetSearchFilters(
    source: source ?? this.source,
    time: time ?? this.time,
    sort: sort ?? this.sort,
    tags: tags ?? this.tags,
  );

  List<V3FeedItem> apply(
    Iterable<V3FeedItem> notes, {
    required String query,
    required Iterable<String> Function(V3FeedItem) tagsFor,
    DateTime? now,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final today = (now ?? DateTime.now()).toLocal();
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final start = switch (time) {
      KnowledgeTimeFilter.today => DateTime(today.year, today.month, today.day),
      KnowledgeTimeFilter.last7Days => DateTime(
        today.year,
        today.month,
        today.day - 6,
      ),
      KnowledgeTimeFilter.last30Days => DateTime(
        today.year,
        today.month,
        today.day - 29,
      ),
      KnowledgeTimeFilter.thisYear => DateTime(today.year),
      KnowledgeTimeFilter.all || KnowledgeTimeFilter.custom => null,
    };
    final filtered = notes.where((note) {
      if (!source.includes(note.source)) return false;
      if (start != null &&
          (note.updatedAt.isBefore(start) ||
              !note.updatedAt.isBefore(tomorrow))) {
        return false;
      }
      final noteTags = tagsFor(
        note,
      ).map((tag) => tag.trim().toLowerCase()).toSet();
      if (tags.isNotEmpty && !noteTags.any(tags.contains)) return false;
      return normalizedQuery.isEmpty ||
          <String?>[
            note.title,
            note.rawBody,
            note.summaryBody,
            note.source.label,
            note.folderName,
            ...noteTags,
          ].whereType<String>().any(
            (value) => value.toLowerCase().contains(normalizedQuery),
          );
    }).toList();
    filtered.sort((left, right) {
      final comparison = switch (sort) {
        V3KnowledgeSort.recentlyUpdated => right.updatedAt.compareTo(
          left.updatedAt,
        ),
        V3KnowledgeSort.earliestCreated => left.createdAt.compareTo(
          right.createdAt,
        ),
        V3KnowledgeSort.name => left.title.compareTo(right.title),
      };
      return comparison == 0 ? left.id.compareTo(right.id) : comparison;
    });
    return List<V3FeedItem>.unmodifiable(filtered);
  }
}

extension V3KnowledgeSortX on V3KnowledgeSort {
  String get label => switch (this) {
    V3KnowledgeSort.recentlyUpdated => '最近更新',
    V3KnowledgeSort.earliestCreated => '最早创建',
    V3KnowledgeSort.name => '名称',
  };
}

extension V3KnowledgeLibraryTabX on V3KnowledgeLibraryTab {
  String get label => switch (this) {
    V3KnowledgeLibraryTab.mine => '我创建的',
    V3KnowledgeLibraryTab.subscribed => '订阅',
    V3KnowledgeLibraryTab.square => '知识世界',
  };
}

@immutable
final class V3KnowledgeLibraryEntry {
  const V3KnowledgeLibraryEntry({
    required this.id,
    required this.tab,
    required this.source,
    required this.title,
    required this.summary,
    this.feedItemId,
  });

  final String id;
  final V3KnowledgeLibraryTab tab;
  final V3MaterialSource source;
  final String title;
  final String summary;
  final String? feedItemId;
}

@immutable
final class V3NoteDraft {
  V3NoteDraft({
    required this.title,
    required this.rawBody,
    Iterable<String> topics = const <String>[],
    this.contentLineId,
    this.contentLineName,
    this.folderId,
    this.folderName,
    Iterable<V3LinkedMaterialRef> linkedMaterials =
        const <V3LinkedMaterialRef>[],
  }) : topics = List<String>.unmodifiable(
         topics.map((topic) => topic.trim()).where((topic) => topic.isNotEmpty),
       ),
       linkedMaterials = List<V3LinkedMaterialRef>.unmodifiable(
         linkedMaterials,
       );

  final String title;
  final String rawBody;
  final List<String> topics;
  final String? contentLineId;
  final String? contentLineName;
  final String? folderId;
  final String? folderName;
  final List<V3LinkedMaterialRef> linkedMaterials;
}
