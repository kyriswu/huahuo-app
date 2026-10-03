import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'feed_item_models.dart';

enum WorkbenchPurpose { persona, lead }

enum AssetCanvasSourceStage { raw, outline, sprout }

enum AssetCanvasInitialSourceMode { generateTranscript, useOriginal }

extension AssetCanvasInitialSourceModeX on AssetCanvasInitialSourceMode {
  String get wireValue => switch (this) {
    AssetCanvasInitialSourceMode.generateTranscript => 'generate_transcript',
    AssetCanvasInitialSourceMode.useOriginal => 'use_original',
  };

  static AssetCanvasInitialSourceMode? tryParse(String? value) =>
      switch (value) {
        'generate_transcript' =>
          AssetCanvasInitialSourceMode.generateTranscript,
        'use_original' => AssetCanvasInitialSourceMode.useOriginal,
        _ => null,
      };
}

extension AssetCanvasSourceStageX on AssetCanvasSourceStage {
  V3ContentStage get contentStage => switch (this) {
    AssetCanvasSourceStage.raw => V3ContentStage.raw,
    AssetCanvasSourceStage.outline => V3ContentStage.summary,
    AssetCanvasSourceStage.sprout => V3ContentStage.sprout,
  };

  String get wireValue => switch (this) {
    AssetCanvasSourceStage.raw => 'raw',
    AssetCanvasSourceStage.outline => 'outline',
    AssetCanvasSourceStage.sprout => 'germination',
  };

  static AssetCanvasSourceStage fromContentStage(V3ContentStage stage) =>
      switch (stage) {
        V3ContentStage.raw => AssetCanvasSourceStage.raw,
        V3ContentStage.summary => AssetCanvasSourceStage.outline,
        V3ContentStage.sprout => AssetCanvasSourceStage.sprout,
      };
}

/// Immutable source snapshot handed from an asset detail to free creation.
@immutable
final class AssetCanvasSeed {
  const AssetCanvasSeed({
    required this.assetId,
    required this.title,
    required this.stage,
    required this.sourceMarkdown,
    required this.partRevisionId,
    required this.sourceHash,
    required this.linkedReference,
    this.initialSourceMode,
  });

  final String assetId;
  final String title;
  final AssetCanvasSourceStage stage;
  final String sourceMarkdown;
  final String partRevisionId;
  final String sourceHash;
  final V3LinkedMaterialRef linkedReference;
  final AssetCanvasInitialSourceMode? initialSourceMode;

  bool get isValid =>
      assetId.trim().isNotEmpty &&
      title.trim().isNotEmpty &&
      sourceMarkdown.trim().isNotEmpty &&
      partRevisionId.trim().isNotEmpty &&
      sourceHash == hashSourceMarkdown(sourceMarkdown) &&
      linkedReference.id.trim() == assetId.trim() &&
      linkedReference.title.trim() == title.trim();

  String get stableSourceId =>
      'asset:${assetId.trim()}:${stage.wireValue}:${partRevisionId.trim()}:'
      '$sourceHash';

  AssetCanvasSeed withInitialSourceMode(AssetCanvasInitialSourceMode mode) =>
      AssetCanvasSeed(
        assetId: assetId,
        title: title,
        stage: stage,
        sourceMarkdown: sourceMarkdown,
        partRevisionId: partRevisionId,
        sourceHash: sourceHash,
        linkedReference: linkedReference,
        initialSourceMode: mode,
      );

  static AssetCanvasSeed? tryFromItem({
    required V3FeedItem item,
    required V3ContentStage stage,
  }) {
    final sourceStage = AssetCanvasSourceStageX.fromContentStage(stage);
    final markdown = switch (stage) {
      V3ContentStage.raw => item.rawBody,
      V3ContentStage.summary => item.summaryBody,
      V3ContentStage.sprout => item.sproutReport?.markdown,
    };
    final isExternalArticle =
        item.ownership == V3NoteOwnership.subscribed ||
        item.ownership == V3NoteOwnership.knowledgeSquare;
    final partRevisionId = switch (stage) {
      V3ContentStage.raw =>
        isExternalArticle ? item.articleRevisionId : item.rawPartRevisionId,
      V3ContentStage.summary => item.outlinePartRevisionId,
      V3ContentStage.sprout => item.germinationPartRevisionId,
    };
    final normalizedAssetId = item.id.trim();
    final normalizedTitle = item.title.trim();
    final remoteRevision = partRevisionId?.trim();
    final isLocalOwnedNote =
        item.source == V3MaterialSource.note &&
        !item.isReadOnly &&
        (item.remoteNoteId?.trim().isEmpty ?? true);
    final normalizedRevision = remoteRevision?.isNotEmpty == true
        ? remoteRevision
        : isLocalOwnedNote && markdown?.trim().isNotEmpty == true
        ? 'local-${item.localRevision}-${hashSourceMarkdown(markdown!)}'
        : null;
    if (normalizedAssetId.isEmpty ||
        normalizedTitle.isEmpty ||
        markdown == null ||
        markdown.trim().isEmpty ||
        normalizedRevision == null ||
        normalizedRevision.isEmpty) {
      return null;
    }
    final seed = AssetCanvasSeed(
      assetId: normalizedAssetId,
      title: normalizedTitle,
      stage: sourceStage,
      sourceMarkdown: markdown,
      partRevisionId: normalizedRevision,
      sourceHash: hashSourceMarkdown(markdown),
      linkedReference: V3LinkedMaterialRef(
        id: normalizedAssetId,
        source: item.source,
        title: normalizedTitle,
        summary: item.summaryBody,
      ),
    );
    return seed.isValid ? seed : null;
  }

  static String hashSourceMarkdown(String markdown) =>
      sha256.convert(utf8.encode(markdown)).toString();
}

extension WorkbenchPurposeX on WorkbenchPurpose {
  String get routeName => switch (this) {
    WorkbenchPurpose.persona => 'persona',
    WorkbenchPurpose.lead => 'lead',
  };

  String get label => switch (this) {
    WorkbenchPurpose.persona => '人设',
    WorkbenchPurpose.lead => '获客',
  };

  String get pickerTitle => '选择你的资产';

  String get pickerSubtitle => switch (this) {
    WorkbenchPurpose.persona => '选择一到两条你的资产，我将分析个人 IP 创作方向',
    WorkbenchPurpose.lead => '选择一到两条你的资产，我将分析获客营销方向',
  };

  String get generateLabel => '生成$label内容';
  String get generatingTitle => '正在生成$label内容';
  String get resultTitle => '$label内容方案';

  /// Client-owned first turn for a user-confirmed asset analysis.
  ///
  /// This text is sent as the visible user message together with immutable
  /// HNote references. Keep it here so product copy can evolve without
  /// coupling a purpose-specific prompt to the transport layer.
  String get assetAnalysisPrompt => '基于我上传的资产，按照huahuo的分析框架帮我分析';
}

/// Transient, editable material passed from a daily-topic detail to Canvas.
///
/// This stays out of the route URI because [briefMarkdown] can be substantial.
@immutable
final class DailyTopicCanvasSeed {
  factory DailyTopicCanvasSeed({
    required String recommendationId,
    required String topicId,
    required String title,
    required String briefMarkdown,
    required Iterable<DailyTopicCanvasSourceRef> sourceRefs,
    String? sourceRevisionId,
    String? sourceHash,
    V3LinkedMaterialRef? linkedReference,
  }) {
    final frozenSourceRefs = List<DailyTopicCanvasSourceRef>.unmodifiable(
      sourceRefs,
    );
    final editableMarkdown = _composeEditableMarkdown(
      briefMarkdown,
      frozenSourceRefs,
    );
    return DailyTopicCanvasSeed._(
      recommendationId: recommendationId,
      topicId: topicId,
      title: title,
      briefMarkdown: briefMarkdown,
      sourceRefs: frozenSourceRefs,
      sourceRevisionId: sourceRevisionId,
      sourceHash:
          sourceHash ?? AssetCanvasSeed.hashSourceMarkdown(editableMarkdown),
      linkedReference: linkedReference,
    );
  }

  const DailyTopicCanvasSeed._({
    required this.recommendationId,
    required this.topicId,
    required this.title,
    required this.briefMarkdown,
    required this.sourceRefs,
    required this.sourceRevisionId,
    required this.sourceHash,
    required this.linkedReference,
  });

  final String recommendationId;
  final String topicId;
  final String title;
  final String briefMarkdown;
  final List<DailyTopicCanvasSourceRef> sourceRefs;
  final String? sourceRevisionId;
  final String sourceHash;
  final V3LinkedMaterialRef? linkedReference;

  bool get isValid {
    final revision = sourceRevisionId;
    final reference = linkedReference;
    return recommendationId.trim().isNotEmpty &&
        topicId.trim().isNotEmpty &&
        title.trim().isNotEmpty &&
        briefMarkdown.trim().isNotEmpty &&
        sourceHash == AssetCanvasSeed.hashSourceMarkdown(editableMarkdown) &&
        (revision == null ||
            (revision == revision.trim() &&
                revision.isNotEmpty &&
                revision.length <= 256)) &&
        (reference == null ||
            (reference.id == topicId && reference.title.trim().isNotEmpty)) &&
        sourceRefs.every((sourceRef) => sourceRef.isValid);
  }

  String get stableSourceId =>
      'daily-topic:${recommendationId.trim()}:${topicId.trim()}';

  /// The user can revise every word, including the provenance shown below it.
  String get editableMarkdown =>
      _composeEditableMarkdown(briefMarkdown, sourceRefs);

  static String _composeEditableMarkdown(
    String briefMarkdown,
    Iterable<DailyTopicCanvasSourceRef> sourceRefs,
  ) {
    final sourceLines = sourceRefs
        .map(
          (sourceRef) =>
              '- ${sourceRef.displayLabel}（${sourceRef.hotspotId.trim()}）',
        )
        .toList(growable: false);
    return <String>[
      briefMarkdown,
      if (sourceLines.isNotEmpty) ...<String>[
        '',
        '## 来源参考',
        '',
        ...sourceLines,
      ],
    ].join('\n');
  }
}

/// Transient Assistant reply passed to a fresh free-creation canvas.
@immutable
final class AssistantReplyCanvasSeed {
  const AssistantReplyCanvasSeed({required this.title, required this.markdown});

  final String title;
  final String markdown;

  bool get isValid => title.trim().isNotEmpty && markdown.trim().isNotEmpty;
}

@immutable
final class DailyTopicCanvasSourceRef {
  const DailyTopicCanvasSourceRef({required this.hotspotId, this.label});

  final String hotspotId;
  final String? label;

  bool get isValid => hotspotId.trim().isNotEmpty;

  String get displayLabel {
    final normalized = label?.trim();
    return normalized == null || normalized.isEmpty ? '热点来源' : normalized;
  }
}

sealed class CanvasEntryIntent {
  const CanvasEntryIntent();

  const factory CanvasEntryIntent.blank() = CanvasBlankEntryIntent;

  const factory CanvasEntryIntent.dailyTopic(DailyTopicCanvasSeed seed) =
      CanvasDailyTopicEntryIntent;

  const factory CanvasEntryIntent.asset(AssetCanvasSeed seed) =
      CanvasAssetEntryIntent;

  const factory CanvasEntryIntent.existingNote(String noteId) =
      CanvasExistingNoteEntryIntent;

  const factory CanvasEntryIntent.history(String historyId) =
      CanvasHistoryEntryIntent;

  const factory CanvasEntryIntent.assistantReply(
    AssistantReplyCanvasSeed seed,
  ) = CanvasAssistantReplyEntryIntent;

  bool get requiresInitialDraftGeneration;
  bool get isValid;
  String get stableSourceId;
}

final class CanvasBlankEntryIntent extends CanvasEntryIntent {
  const CanvasBlankEntryIntent();

  @override
  bool get requiresInitialDraftGeneration => false;

  @override
  bool get isValid => true;

  @override
  String get stableSourceId => 'blank';
}

final class CanvasDailyTopicEntryIntent extends CanvasEntryIntent {
  const CanvasDailyTopicEntryIntent(this.seed);

  final DailyTopicCanvasSeed seed;

  @override
  bool get requiresInitialDraftGeneration => true;

  @override
  bool get isValid =>
      seed.isValid &&
      _isSafeCanvasIdentifier(seed.recommendationId, maxLength: 256) &&
      _isSafeCanvasIdentifier(seed.topicId, maxLength: 256);

  @override
  String get stableSourceId => seed.stableSourceId;
}

final class CanvasAssetEntryIntent extends CanvasEntryIntent {
  const CanvasAssetEntryIntent(this.seed);

  final AssetCanvasSeed seed;

  String get assetId => seed.assetId;

  @override
  bool get requiresInitialDraftGeneration => true;

  @override
  bool get isValid {
    return _isSafeCanvasIdentifier(assetId) && seed.isValid;
  }

  @override
  String get stableSourceId => seed.stableSourceId;
}

final class CanvasExistingNoteEntryIntent extends CanvasEntryIntent {
  const CanvasExistingNoteEntryIntent(this.noteId);

  final String noteId;

  @override
  bool get requiresInitialDraftGeneration => false;

  @override
  bool get isValid => _isSafeCanvasIdentifier(noteId);

  @override
  String get stableSourceId => 'existing-note:${noteId.trim()}';
}

final class CanvasHistoryEntryIntent extends CanvasEntryIntent {
  const CanvasHistoryEntryIntent(this.historyId);

  final String historyId;

  @override
  bool get requiresInitialDraftGeneration => false;

  @override
  bool get isValid => _isSafeCanvasIdentifier(historyId);

  @override
  String get stableSourceId => 'history:${historyId.trim()}';
}

final class CanvasAssistantReplyEntryIntent extends CanvasEntryIntent {
  const CanvasAssistantReplyEntryIntent(this.seed);

  final AssistantReplyCanvasSeed seed;

  @override
  bool get requiresInitialDraftGeneration => false;

  @override
  bool get isValid => seed.isValid;

  @override
  String get stableSourceId =>
      'assistant-reply:${AssetCanvasSeed.hashSourceMarkdown('${seed.title}\u0000${seed.markdown}')}';
}

bool _isSafeCanvasIdentifier(String value, {int maxLength = 128}) {
  final normalized = value.trim();
  return normalized.isNotEmpty &&
      normalized == value &&
      normalized.length <= maxLength &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized);
}

WorkbenchPurpose? workbenchPurposeFromRoute(String value) => WorkbenchPurpose
    .values
    .where((purpose) => purpose.routeName == value)
    .firstOrNull;

enum WorkbenchAction { persona, lead, videoAnalysis, deepPositioning }

extension WorkbenchActionX on WorkbenchAction {
  String get label => switch (this) {
    WorkbenchAction.persona => '人设',
    WorkbenchAction.lead => '获客',
    WorkbenchAction.videoAnalysis => '视频分析',
    WorkbenchAction.deepPositioning => '社媒定位',
  };

  String get subtitle => switch (this) {
    WorkbenchAction.persona => '用内容塑造可信形象',
    WorkbenchAction.lead => '用内容激发咨询意愿',
    WorkbenchAction.videoAnalysis => '分析链接或本地视频',
    WorkbenchAction.deepPositioning => '明确账号方向与价值',
  };

  String get route => switch (this) {
    WorkbenchAction.persona => '/v3/feed/chat?agentProfileId=renshe_content',
    WorkbenchAction.lead => '/v3/feed/chat?agentProfileId=huoke_content',
    WorkbenchAction.videoAnalysis => '/v3/workbench/video-analysis',
    WorkbenchAction.deepPositioning => '/v3/workbench/deep-positioning',
  };

  IconData get icon => switch (this) {
    WorkbenchAction.persona => Icons.person_outline_rounded,
    WorkbenchAction.lead => Icons.forum_outlined,
    WorkbenchAction.videoAnalysis => Icons.video_library_outlined,
    WorkbenchAction.deepPositioning => Icons.explore_outlined,
  };
}

enum WorkbenchGenerationStatus {
  idle,
  selecting,
  generating,
  succeeded,
  failed,
}

enum WorkbenchNoteFilter { all, hotspot, mine, subscribed, knowledgeSquare }

extension WorkbenchNoteFilterX on WorkbenchNoteFilter {
  String get label => switch (this) {
    WorkbenchNoteFilter.all => '全部笔记',
    WorkbenchNoteFilter.hotspot => '热点',
    WorkbenchNoteFilter.mine => '我的内容',
    WorkbenchNoteFilter.subscribed => '已订阅',
    WorkbenchNoteFilter.knowledgeSquare => '知识世界',
  };
}

enum VideoInputType { link, localFile }

extension VideoInputTypeX on VideoInputType {
  String get label => switch (this) {
    VideoInputType.link => '视频链接',
    VideoInputType.localFile => '本地视频',
  };
}

enum VideoAnalysisStatus { idle, ready, analyzing, succeeded, failed }

enum FeedAggregationStatus {
  idle,
  selecting,
  aggregating,
  backgroundPending,
  succeeded,
  failed,
}

enum FeedAggregationDestination { freeCreation, persona, lead, visual }

enum AggregationAgentKind { persona, lead, visual }

extension AggregationAgentKindX on AggregationAgentKind {
  String get routeValue => name;

  String get label => switch (this) {
    AggregationAgentKind.persona => '人设',
    AggregationAgentKind.lead => '获客',
    AggregationAgentKind.visual => '影像',
  };
}

@immutable
final class AggregationAgentLaunchRequest {
  AggregationAgentLaunchRequest({
    required this.kind,
    required Iterable<String> noteIds,
    required this.hotspotId,
  }) : noteIds = List<String>.unmodifiable(noteIds);

  final AggregationAgentKind kind;
  final List<String> noteIds;
  final String hotspotId;

  bool get isValid => noteIds.length == 4 && hotspotId.trim().isNotEmpty;
}

@immutable
final class AggregationAgentSession {
  const AggregationAgentSession({
    required this.id,
    required this.kind,
    required this.materialIds,
    required this.openingMessage,
  });

  final String id;
  final AggregationAgentKind kind;
  final List<String> materialIds;
  final String openingMessage;
}

enum V3GraphCluster {
  viewpoint,
  method,
  inspiration,
  caseItem,
  industry,
  trend,
}

String canonicalGraphEntityType(String value) {
  final normalized = value.trim().replaceAll(
    RegExp(r'\s+', unicode: true),
    ' ',
  );
  if (normalized.isEmpty) return 'Entity';
  final folded = normalized.toLowerCase();
  final compact = folded.replaceAll(RegExp(r'[\s_-]+', unicode: true), '');
  return switch (compact) {
    'entity' => 'Entity',
    'person' || 'people' || 'human' => 'Person',
    'organization' || 'organisation' || 'org' || 'company' => 'Organization',
    'project' => 'Project',
    'product' => 'Product',
    'viewpoint' || 'opinion' || 'claim' || 'perspective' => 'Viewpoint',
    'method' || 'methodology' => 'Method',
    'inspiration' || 'idea' => 'Inspiration',
    'case' || 'caseitem' || 'event' => 'Case',
    'industry' || 'sector' => 'Industry',
    'trend' => 'Trend',
    'topic' || 'theme' || 'subject' => 'Topic',
    'location' || 'place' => 'Location',
    'concept' => 'Concept',
    'technology' => 'Technology',
    '实体' => '实体',
    '人物' || '人' => '人物',
    '组织' || '机构' || '公司' || '企业' => '组织',
    '项目' => '项目',
    '产品' => '产品',
    '观点' || '看法' || '视角' => '观点',
    '方法' || '方法论' => '方法',
    '灵感' || '想法' => '灵感',
    '案例' || '事件' => '案例',
    '行业' => '行业',
    '趋势' => '趋势',
    '主题' || '话题' => '主题',
    _ => folded,
  };
}

enum V3GraphFilter { all, audio, note, external, hotspot, aggregated, recent }

extension V3GraphFilterX on V3GraphFilter {
  String get label => switch (this) {
    V3GraphFilter.all => '全部',
    V3GraphFilter.audio => '音频',
    V3GraphFilter.note => '笔记',
    V3GraphFilter.external => '外部材料',
    V3GraphFilter.hotspot => '热点',
    V3GraphFilter.aggregated => '聚合结果',
    V3GraphFilter.recent => '近期新增',
  };
}

extension V3GraphClusterX on V3GraphCluster {
  String get label => switch (this) {
    V3GraphCluster.viewpoint => '观点',
    V3GraphCluster.method => '方法',
    V3GraphCluster.inspiration => '灵感',
    V3GraphCluster.caseItem => '案例',
    V3GraphCluster.industry => '行业',
    V3GraphCluster.trend => '趋势',
  };

  IconData get icon => switch (this) {
    V3GraphCluster.viewpoint => Icons.lightbulb_outline,
    V3GraphCluster.method => Icons.grid_view_rounded,
    V3GraphCluster.inspiration => Icons.auto_awesome_outlined,
    V3GraphCluster.caseItem => Icons.description_outlined,
    V3GraphCluster.industry => Icons.bar_chart_rounded,
    V3GraphCluster.trend => Icons.trending_up_rounded,
  };

  V3GraphCommunity get community => switch (this) {
    V3GraphCluster.viewpoint ||
    V3GraphCluster.trend => V3GraphCommunity.viewpointTrend,
    V3GraphCluster.method => V3GraphCommunity.method,
    V3GraphCluster.inspiration => V3GraphCommunity.inspiration,
    V3GraphCluster.caseItem ||
    V3GraphCluster.industry => V3GraphCommunity.caseIndustry,
  };
}

enum V3GraphCommunity { viewpointTrend, method, inspiration, caseIndustry }

extension V3GraphCommunityX on V3GraphCommunity {
  String get label => switch (this) {
    V3GraphCommunity.viewpointTrend => '观点与趋势',
    V3GraphCommunity.method => '方法',
    V3GraphCommunity.inspiration => '灵感',
    V3GraphCommunity.caseIndustry => '案例与行业',
  };
}

enum V3GraphNodeRole { center, core, satellite }

@immutable
final class V3GraphCommunitySnapshot {
  const V3GraphCommunitySnapshot({
    required this.community,
    required this.coreNodeId,
    required this.memberNodeIds,
  });

  final V3GraphCommunity community;
  final String coreNodeId;
  final List<String> memberNodeIds;
}

@immutable
final class V3GraphNode {
  const V3GraphNode({
    required this.id,
    required this.label,
    required this.cluster,
    required this.position,
    required this.summary,
    this.entityType = 'Entity',
    this.attributes = const <String, Object?>{},
    this.labels = const <String>[],
    this.contentId,
    this.weight = 1,
    this.center = false,
    this.source = V3MaterialSource.note,
    this.materialSourceProvided = true,
    this.updatedAt,
    this.topics = const <String>[],
    this.isHotspot = false,
    this.isAggregated = false,
    this.isRecent = false,
  });

  final String id;
  final String label;
  final V3GraphCluster cluster;
  final Offset position;
  final String summary;
  final String entityType;
  final Map<String, Object?> attributes;
  final List<String> labels;
  final String? contentId;
  final double weight;
  final bool center;
  final V3MaterialSource source;
  final bool materialSourceProvided;
  final DateTime? updatedAt;
  final List<String> topics;
  final bool isHotspot;
  final bool isAggregated;
  final bool isRecent;
}

enum V3GraphRelationKind {
  membership,
  communityAffinity,
  linkedMaterial,
  sharedTopic,
  sharedContentLine,
  other,
}

extension V3GraphRelationKindX on V3GraphRelationKind {
  String get label => switch (this) {
    V3GraphRelationKind.membership => '属于',
    V3GraphRelationKind.communityAffinity => '语义关联',
    V3GraphRelationKind.linkedMaterial => '引用',
    V3GraphRelationKind.sharedTopic => '共同主题',
    V3GraphRelationKind.sharedContentLine => '同一内容线',
    V3GraphRelationKind.other => '其他关系',
  };
}

@immutable
final class V3GraphEdge {
  const V3GraphEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.kind,
    required this.label,
    this.relationType,
    this.fact,
    this.attributes = const <String, Object?>{},
    this.episodes = const <String>[],
    this.weight = 1,
    this.directed = false,
    this.createdAt,
    this.validAt,
  });

  final String id;
  final String sourceId;
  final String targetId;
  final V3GraphRelationKind kind;
  final String label;
  final String? relationType;
  final String? fact;
  final Map<String, Object?> attributes;
  final List<String> episodes;
  final double weight;
  final bool directed;
  final DateTime? createdAt;
  final DateTime? validAt;

  bool get isSelfLoop => sourceId == targetId;
}
