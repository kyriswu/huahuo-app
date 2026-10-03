import 'package:flutter/foundation.dart';

enum V3ContentStage { raw, summary, sprout }

extension V3ContentStageX on V3ContentStage {
  String get label => switch (this) {
    V3ContentStage.raw => '原始',
    V3ContentStage.summary => '纲要',
    V3ContentStage.sprout => '深度洞察',
  };
}

enum V3MaterialSource {
  meeting,
  internalRecording,
  link,
  monologue,
  note,
  chatExcerpt,
  recordingCard,
  documentImport,
  mediaImport,
  materialMigration,
  subscription,
  topicCollision,
  knowledgeSquare,
  hotspot,
  other,
}

extension V3MaterialSourceX on V3MaterialSource {
  String get label => switch (this) {
    V3MaterialSource.meeting => '会议',
    V3MaterialSource.internalRecording => '内录',
    V3MaterialSource.link => '链接导入',
    V3MaterialSource.monologue => '独白',
    V3MaterialSource.note => '手动创建',
    V3MaterialSource.chatExcerpt => '聊一聊',
    V3MaterialSource.recordingCard => '录音转写',
    V3MaterialSource.documentImport => '文件导入',
    V3MaterialSource.mediaImport => '相册导入',
    V3MaterialSource.materialMigration => '历史资料',
    V3MaterialSource.subscription => '订阅文章',
    V3MaterialSource.topicCollision => '笔记碰撞',
    V3MaterialSource.knowledgeSquare => '知识世界',
    V3MaterialSource.hotspot => '热点',
    V3MaterialSource.other => '其他来源',
  };
}

enum V3NoteOwnership { mine, subscribed, knowledgeSquare, hotspot }

enum V3ContentOrigin { standard, freeCreation }

extension V3NoteOwnershipX on V3NoteOwnership {
  String get label => switch (this) {
    V3NoteOwnership.mine => '我的内容',
    V3NoteOwnership.subscribed => '已订阅',
    V3NoteOwnership.knowledgeSquare => '知识世界',
    V3NoteOwnership.hotspot => '热点',
  };
}

enum NoteSyncState { localOnly, pending, synced, conflict }

extension NoteSyncStateX on NoteSyncState {
  String get label => switch (this) {
    NoteSyncState.localOnly => '仅本地',
    NoteSyncState.pending => '待同步',
    NoteSyncState.synced => '已同步',
    NoteSyncState.conflict => '存在冲突',
  };
}

enum V3SproutTaskStatus { notStarted, queued, running, succeeded, failed }

extension V3SproutTaskStatusX on V3SproutTaskStatus {
  String get label => switch (this) {
    V3SproutTaskStatus.notStarted => '尚未开始',
    V3SproutTaskStatus.queued => '等待处理',
    V3SproutTaskStatus.running => '正在生成深度洞察',
    V3SproutTaskStatus.succeeded => '深度洞察已完成',
    V3SproutTaskStatus.failed => '深度洞察生成失败',
  };
}

enum V3DerivedTaskStage { outline, sprout }

extension V3DerivedTaskStageX on V3DerivedTaskStage {
  String get wireValue => switch (this) {
    V3DerivedTaskStage.outline => 'outline',
    V3DerivedTaskStage.sprout => 'sprout',
  };

  String get label => switch (this) {
    V3DerivedTaskStage.outline => '纲要',
    V3DerivedTaskStage.sprout => '深度洞察',
  };

  static V3DerivedTaskStage? tryParse(Object? value) => switch (value) {
    'outline' => V3DerivedTaskStage.outline,
    'sprout' => V3DerivedTaskStage.sprout,
    _ => null,
  };
}

@immutable
final class V3ActiveDerivedTask {
  const V3ActiveDerivedTask({
    required this.fileAgentRunId,
    required this.stage,
    required this.status,
    this.agentRunId,
  });

  final String fileAgentRunId;
  final String? agentRunId;
  final V3DerivedTaskStage stage;
  final String status;

  bool get isTerminal => const <String>{
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'conflict',
  }.contains(status);
}

@immutable
final class V3SproutReport {
  const V3SproutReport({
    required this.id,
    required this.noteId,
    required this.title,
    required this.markdown,
    required this.generatedAt,
  });

  final String id;
  final String noteId;
  final String title;
  final String markdown;
  final DateTime generatedAt;
}

@immutable
final class V3LinkedMaterialRef {
  const V3LinkedMaterialRef({
    required this.id,
    required this.source,
    required this.title,
    this.summary,
  });

  final String id;
  final V3MaterialSource source;
  final String title;
  final String? summary;
}

enum V3MediaAttachmentKind { image, video }

@immutable
final class V3MediaAttachment {
  const V3MediaAttachment({
    required this.privateUri,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    required this.privatePath,
  });

  /// Opaque app-private media identifier; it is safe for UI state and routing.
  final String privateUri;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final V3MediaAttachmentKind kind;

  /// Runtime-only private copy path. It must never be rendered or logged.
  final String privatePath;
}

/// A formal HNote Resource reference. Unlike [V3MediaAttachment], it never
/// contains a local path and must be resolved through authenticated playback.
@immutable
final class V3RemoteMediaAttachment {
  const V3RemoteMediaAttachment({
    required this.resourceId,
    required this.displayName,
    required this.mimeType,
    required this.usage,
    this.anchor,
  });

  final String resourceId;
  final String displayName;
  final String mimeType;
  final String usage;
  final String? anchor;

  bool get isImage => mimeType.toLowerCase().startsWith('image/');
}

@immutable
final class V3SubscriptionArticleAssetRef {
  V3SubscriptionArticleAssetRef({
    required String fileKey,
    required String logicalPath,
  }) : fileKey = fileKey.trim(),
       logicalPath = logicalPath.trim() {
    if (this.fileKey.isEmpty || this.logicalPath.isEmpty) {
      throw ArgumentError(
        'Subscription article asset references cannot be empty',
      );
    }
  }

  final String fileKey;
  final String logicalPath;
}

@immutable
final class V3FeedItem {
  const V3FeedItem({
    required this.id,
    required this.title,
    required this.source,
    required this.createdAt,
    required this.rawBody,
    this.summaryBody,
    this.summaryError,
    this.recordingId,
    this.minutesStatus,
    this.summaryStatus,
    this.linkedMaterials = const <V3LinkedMaterialRef>[],
    this.sproutStatus = V3SproutTaskStatus.notStarted,
    this.sproutError,
    this.sproutTopic,
    this.mediaAttachments = const <V3MediaAttachment>[],
    this.remoteMediaAttachments = const <V3RemoteMediaAttachment>[],
    this.ownership = V3NoteOwnership.mine,
    this.contentLineId,
    this.contentLineName,
    this.folderId,
    this.folderName,
    this.copiedFromContentId,
    this.publicUrl,
    this.topics = const <String>[],
    this.localRevision = 0,
    this.remoteRevision,
    this.remoteNoteId,
    this.remoteSourceKind,
    this.noteRevisionId,
    this.rawPartRevisionId,
    this.outlinePartRevisionId,
    this.germinationPartRevisionId,
    this.etag,
    this.contentCursor,
    this.publicationId,
    this.articleId,
    this.articleRevisionId,
    this.subscriptionArticleAssets = const <V3SubscriptionArticleAssetRef>[],
    this.author,
    this.syncState = NoteSyncState.synced,
    this.pendingRawOnlyUpdate = false,
    this.contentOrigin = V3ContentOrigin.standard,
    DateTime? updatedAt,
    this.sproutReport,
    this.activeDerivedTasks = const <V3ActiveDerivedTask>[],
    this.activeDerivedTasksAuthoritative = false,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String title;
  final V3MaterialSource source;
  final DateTime createdAt;
  final String rawBody;
  final String? summaryBody;
  final String? summaryError;
  final String? recordingId;
  final String? minutesStatus;
  final String? summaryStatus;
  final List<V3LinkedMaterialRef> linkedMaterials;
  final V3SproutTaskStatus sproutStatus;
  final String? sproutError;
  final String? sproutTopic;
  final List<V3MediaAttachment> mediaAttachments;
  final List<V3RemoteMediaAttachment> remoteMediaAttachments;
  final V3NoteOwnership ownership;
  final String? contentLineId;
  final String? contentLineName;
  final String? folderId;
  final String? folderName;
  final String? copiedFromContentId;
  final String? publicUrl;
  final List<String> topics;
  final int localRevision;
  final int? remoteRevision;
  final String? remoteNoteId;
  final String? remoteSourceKind;
  final String? noteRevisionId;
  final String? rawPartRevisionId;
  final String? outlinePartRevisionId;
  final String? germinationPartRevisionId;
  final String? etag;
  final String? contentCursor;
  final String? publicationId;
  final String? articleId;
  final String? articleRevisionId;
  final List<V3SubscriptionArticleAssetRef> subscriptionArticleAssets;
  final String? author;
  final NoteSyncState syncState;
  final bool pendingRawOnlyUpdate;
  final V3ContentOrigin contentOrigin;
  final DateTime updatedAt;
  final V3SproutReport? sproutReport;
  final List<V3ActiveDerivedTask> activeDerivedTasks;

  /// `true` only when the server explicitly supplied `activeDerivedTasks`.
  final bool activeDerivedTasksAuthoritative;

  bool get isHotspot =>
      source == V3MaterialSource.hotspot ||
      ownership == V3NoteOwnership.hotspot;

  bool get isReadOnly => ownership != V3NoteOwnership.mine;

  bool get isSavedSubscriptionNote {
    if (isReadOnly || remoteNoteId?.trim().isNotEmpty != true) return false;
    final sourceKind = remoteSourceKind?.trim();
    return sourceKind?.isNotEmpty == true
        ? sourceKind == 'subscription_article'
        : source == V3MaterialSource.subscription;
  }

  bool get isRecordingSource => switch (source) {
    V3MaterialSource.meeting ||
    V3MaterialSource.internalRecording ||
    V3MaterialSource.monologue ||
    V3MaterialSource.recordingCard => true,
    _ => false,
  };

  bool get isLinkImportSource {
    final sourceKind = remoteSourceKind?.trim();
    return sourceKind?.isNotEmpty == true
        ? sourceKind == 'url_import'
        : source == V3MaterialSource.link;
  }

  bool get usesBackendRecordingOutline =>
      recordingId?.trim().isNotEmpty == true || isRecordingSource;

  V3FeedItem copyWith({
    V3MaterialSource? source,
    String? title,
    String? rawBody,
    String? summaryBody,
    String? summaryError,
    String? recordingId,
    String? minutesStatus,
    String? summaryStatus,
    List<V3LinkedMaterialRef>? linkedMaterials,
    V3SproutTaskStatus? sproutStatus,
    String? sproutError,
    String? sproutTopic,
    List<V3MediaAttachment>? mediaAttachments,
    List<V3RemoteMediaAttachment>? remoteMediaAttachments,
    V3NoteOwnership? ownership,
    String? contentLineId,
    String? contentLineName,
    String? folderId,
    String? folderName,
    String? copiedFromContentId,
    String? publicUrl,
    List<String>? topics,
    int? localRevision,
    int? remoteRevision,
    String? remoteNoteId,
    String? remoteSourceKind,
    String? noteRevisionId,
    String? rawPartRevisionId,
    String? outlinePartRevisionId,
    String? germinationPartRevisionId,
    String? etag,
    String? contentCursor,
    String? publicationId,
    String? articleId,
    String? articleRevisionId,
    List<V3SubscriptionArticleAssetRef>? subscriptionArticleAssets,
    String? author,
    NoteSyncState? syncState,
    bool? pendingRawOnlyUpdate,
    V3ContentOrigin? contentOrigin,
    DateTime? updatedAt,
    V3SproutReport? sproutReport,
    List<V3ActiveDerivedTask>? activeDerivedTasks,
    bool? activeDerivedTasksAuthoritative,
    bool clearSummaryError = false,
    bool clearSproutError = false,
    bool clearContentLine = false,
    bool clearFolder = false,
    bool clearFolderName = false,
    bool clearCopiedFromContent = false,
    bool clearPublicUrl = false,
    bool clearRemoteRevision = false,
    bool clearRemoteBinding = false,
    bool clearOutlinePartRevisionId = false,
    bool clearGerminationPartRevisionId = false,
    bool clearSproutReport = false,
  }) {
    return V3FeedItem(
      id: id,
      title: title ?? this.title,
      source: source ?? this.source,
      createdAt: createdAt,
      rawBody: rawBody ?? this.rawBody,
      summaryBody: summaryBody ?? this.summaryBody,
      summaryError: clearSummaryError
          ? null
          : summaryError ?? this.summaryError,
      recordingId: recordingId ?? this.recordingId,
      minutesStatus: minutesStatus ?? this.minutesStatus,
      summaryStatus: summaryStatus ?? this.summaryStatus,
      linkedMaterials: linkedMaterials ?? this.linkedMaterials,
      sproutStatus: sproutStatus ?? this.sproutStatus,
      sproutError: clearSproutError ? null : sproutError ?? this.sproutError,
      sproutTopic: sproutTopic ?? this.sproutTopic,
      mediaAttachments: mediaAttachments ?? this.mediaAttachments,
      remoteMediaAttachments:
          remoteMediaAttachments ?? this.remoteMediaAttachments,
      ownership: ownership ?? this.ownership,
      contentLineId: clearContentLine
          ? null
          : contentLineId ?? this.contentLineId,
      contentLineName: clearContentLine
          ? null
          : contentLineName ?? this.contentLineName,
      folderId: clearFolder ? null : folderId ?? this.folderId,
      folderName: clearFolder || clearFolderName
          ? null
          : folderName ?? this.folderName,
      copiedFromContentId: clearCopiedFromContent
          ? null
          : copiedFromContentId ?? this.copiedFromContentId,
      publicUrl: clearPublicUrl ? null : publicUrl ?? this.publicUrl,
      topics: topics ?? this.topics,
      localRevision: localRevision ?? this.localRevision,
      remoteRevision: clearRemoteRevision
          ? null
          : remoteRevision ?? this.remoteRevision,
      remoteNoteId: clearRemoteBinding
          ? null
          : remoteNoteId ?? this.remoteNoteId,
      remoteSourceKind: clearRemoteBinding
          ? null
          : remoteSourceKind ?? this.remoteSourceKind,
      noteRevisionId: clearRemoteBinding
          ? null
          : noteRevisionId ?? this.noteRevisionId,
      rawPartRevisionId: clearRemoteBinding
          ? null
          : rawPartRevisionId ?? this.rawPartRevisionId,
      outlinePartRevisionId: clearRemoteBinding || clearOutlinePartRevisionId
          ? null
          : outlinePartRevisionId ?? this.outlinePartRevisionId,
      germinationPartRevisionId:
          clearRemoteBinding || clearGerminationPartRevisionId
          ? null
          : germinationPartRevisionId ?? this.germinationPartRevisionId,
      etag: clearRemoteBinding ? null : etag ?? this.etag,
      contentCursor: clearRemoteBinding
          ? null
          : contentCursor ?? this.contentCursor,
      publicationId: publicationId ?? this.publicationId,
      articleId: articleId ?? this.articleId,
      articleRevisionId: articleRevisionId ?? this.articleRevisionId,
      subscriptionArticleAssets:
          subscriptionArticleAssets ?? this.subscriptionArticleAssets,
      author: author ?? this.author,
      syncState: syncState ?? this.syncState,
      pendingRawOnlyUpdate: pendingRawOnlyUpdate ?? this.pendingRawOnlyUpdate,
      contentOrigin: contentOrigin ?? this.contentOrigin,
      updatedAt: updatedAt ?? this.updatedAt,
      sproutReport: clearSproutReport
          ? null
          : sproutReport ?? this.sproutReport,
      activeDerivedTasks: List<V3ActiveDerivedTask>.unmodifiable(
        activeDerivedTasks ?? this.activeDerivedTasks,
      ),
      activeDerivedTasksAuthoritative:
          activeDerivedTasksAuthoritative ??
          this.activeDerivedTasksAuthoritative,
    );
  }
}

String? normalizeV3PublicSourceUrl(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty || text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.removeFragment().toString();
}

typedef V3UrlImportRawProjection = ({String markdown, String? sourceUrl});

V3UrlImportRawProjection projectV3UrlImportRawContent(String source) {
  final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final envelopeStart = lines.indexWhere((line) => line.trim().isNotEmpty);
  if (envelopeStart < 0 || !lines[envelopeStart].startsWith('Source: ')) {
    return (markdown: source, sourceUrl: null);
  }
  final sourceUrl = normalizeV3PublicSourceUrl(
    lines[envelopeStart].substring('Source: '.length),
  );
  if (sourceUrl == null) return (markdown: source, sourceUrl: null);

  const metadataLabels = <String>['Platform: ', 'Author: ', 'Published: '];
  final envelopeLimit = (envelopeStart + 8).clamp(0, lines.length - 1);
  int? delimiterIndex;
  for (var index = envelopeStart + 1; index <= envelopeLimit; index++) {
    final line = lines[index];
    if (line == '---') {
      delimiterIndex = index;
      break;
    }
    if (line.trim().isEmpty) continue;
    if (!metadataLabels.any(
      (label) => line.startsWith(label) && line.length > label.length,
    )) {
      return (markdown: source, sourceUrl: null);
    }
  }
  if (delimiterIndex == null) return (markdown: source, sourceUrl: null);

  var bodyStart = delimiterIndex + 1;
  while (bodyStart < lines.length && lines[bodyStart].trim().isEmpty) {
    bodyStart++;
  }
  return (markdown: lines.sublist(bodyStart).join('\n'), sourceUrl: sourceUrl);
}

bool isV3SubscriptionNoteAssetPath(String value) =>
    value == value.trim() &&
    value.startsWith('assets/') &&
    !value.contains('\\') &&
    value
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

@immutable
final class ChatContextBundle {
  const ChatContextBundle({
    required this.primaryItemId,
    this.linkedMaterialRefs = const <V3LinkedMaterialRef>[],
    this.sproutReportId,
  });

  final String primaryItemId;
  final List<V3LinkedMaterialRef> linkedMaterialRefs;
  final String? sproutReportId;
}
