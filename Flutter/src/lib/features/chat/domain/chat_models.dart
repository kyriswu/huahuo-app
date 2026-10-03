import 'chat_context.dart';

enum ChatScene {
  workAi('work_ai'),
  feedAi('feed_ai');

  const ChatScene(this.apiValue);

  final String apiValue;

  static ChatScene? tryParse(Object? value) {
    for (final scene in ChatScene.values) {
      if (scene.apiValue == value) return scene;
    }
    return null;
  }
}

enum ChatConversationPurpose {
  general('general', 'general', 'self_media_creation_standard'),
  deepPositioning('deep-positioning', 'deep_positioning', 'work_ai');

  const ChatConversationPurpose(
    this.routeValue,
    this.apiValue,
    this.historyScene,
  );

  final String routeValue;
  final String apiValue;
  final String historyScene;

  ChatContextPurpose get contextPurpose => switch (this) {
    ChatConversationPurpose.general => ChatContextPurpose.general,
    ChatConversationPurpose.deepPositioning =>
      ChatContextPurpose.deepPositioning,
  };

  static ChatConversationPurpose fromRoute(String? value) {
    return tryParseRoute(value) ?? ChatConversationPurpose.general;
  }

  static ChatConversationPurpose? tryParseRoute(String? value) {
    for (final purpose in ChatConversationPurpose.values) {
      if (purpose.routeValue == value) return purpose;
    }
    return null;
  }

  static ChatConversationPurpose? tryParseApi(Object? value) {
    for (final purpose in ChatConversationPurpose.values) {
      if (purpose.apiValue == value) return purpose;
    }
    return null;
  }
}

const thoughtGraphChatEntryRouteValue = 'thought-graph';

enum OrdinaryChatEntryKind {
  asset('asset'),
  dailyRecommendation('daily_recommendation'),
  thoughtGraph('thought_graph');

  const OrdinaryChatEntryKind(this.storageValue);

  final String storageValue;

  static OrdinaryChatEntryKind? tryParse(Object? value) {
    for (final kind in OrdinaryChatEntryKind.values) {
      if (kind.storageValue == value) return kind;
    }
    return null;
  }
}

final class OrdinaryChatEntryPoint {
  const OrdinaryChatEntryPoint._({required this.kind, required this.entryId});

  factory OrdinaryChatEntryPoint.asset(String assetId) {
    final id = assetId.trim();
    if (!isSafeChatIdentifier(id)) {
      throw ArgumentError.value(assetId, 'assetId', 'unsafe identifier');
    }
    return OrdinaryChatEntryPoint._(
      kind: OrdinaryChatEntryKind.asset,
      entryId: id,
    );
  }

  factory OrdinaryChatEntryPoint.dailyRecommendation({
    required String recommendationId,
    required String topicId,
  }) {
    final recommendation = recommendationId.trim();
    final topic = topicId.trim();
    if (!isSafeChatIdentifier(recommendation)) {
      throw ArgumentError.value(
        recommendationId,
        'recommendationId',
        'unsafe identifier',
      );
    }
    if (!isSafeChatIdentifier(topic)) {
      throw ArgumentError.value(topicId, 'topicId', 'unsafe identifier');
    }
    return OrdinaryChatEntryPoint._(
      kind: OrdinaryChatEntryKind.dailyRecommendation,
      entryId:
          '${Uri.encodeComponent(recommendation)}/${Uri.encodeComponent(topic)}',
    );
  }

  static const thoughtGraph = OrdinaryChatEntryPoint._(
    kind: OrdinaryChatEntryKind.thoughtGraph,
    entryId: 'default',
  );

  final OrdinaryChatEntryKind kind;
  final String entryId;

  static OrdinaryChatEntryPoint? tryParse({
    required Object? kind,
    required Object? entryId,
  }) {
    final parsedKind = OrdinaryChatEntryKind.tryParse(kind);
    if (parsedKind == null || entryId is! String) return null;
    final id = entryId.trim();
    final valid = switch (parsedKind) {
      OrdinaryChatEntryKind.asset => isSafeChatIdentifier(id),
      OrdinaryChatEntryKind.dailyRecommendation =>
        _isValidDailyRecommendationEntryId(id),
      OrdinaryChatEntryKind.thoughtGraph => id == thoughtGraph.entryId,
    };
    return valid
        ? OrdinaryChatEntryPoint._(kind: parsedKind, entryId: id)
        : null;
  }

  @override
  bool operator ==(Object other) =>
      other is OrdinaryChatEntryPoint &&
      other.kind == kind &&
      other.entryId == entryId;

  @override
  int get hashCode => Object.hash(kind, entryId);
}

bool _isValidDailyRecommendationEntryId(String value) {
  final parts = value.split('/');
  if (parts.length != 2 || parts.any((part) => part.isEmpty)) return false;
  try {
    for (final part in parts) {
      final decoded = Uri.decodeComponent(part);
      if (!isSafeChatIdentifier(decoded) ||
          Uri.encodeComponent(decoded) != part) {
        return false;
      }
    }
    return true;
  } on FormatException {
    return false;
  }
}

enum ChatLaunchMode {
  exactThread,
  resumeRecent,
  fresh,
  history;

  bool get startsFresh =>
      this == ChatLaunchMode.fresh || this == ChatLaunchMode.history;
}

ChatLaunchMode resolveChatLaunchMode({
  required bool hasExactThread,
  required bool opensHistory,
  required bool hasExplicitWindow,
  required bool hasSourceContext,
  required bool hasAgentEntry,
  required bool isThoughtGraphEntry,
}) {
  if (hasExactThread) return ChatLaunchMode.exactThread;
  if (opensHistory) return ChatLaunchMode.history;
  if (hasExplicitWindow || hasSourceContext || hasAgentEntry) {
    return ChatLaunchMode.fresh;
  }
  return isThoughtGraphEntry
      ? ChatLaunchMode.resumeRecent
      : ChatLaunchMode.fresh;
}

enum ChatAgentScopeKind { fixed, threadBound, allProfiles }

final class ChatAgentScope {
  const ChatAgentScope.fixed(String agentProfileId)
    : kind = ChatAgentScopeKind.fixed,
      profileHint = agentProfileId;

  const ChatAgentScope.threadBound({this.profileHint})
    : kind = ChatAgentScopeKind.threadBound;

  const ChatAgentScope.allProfiles()
    : kind = ChatAgentScopeKind.allProfiles,
      profileHint = null;

  final ChatAgentScopeKind kind;
  final String? profileHint;

  bool get bindsFromThread => kind == ChatAgentScopeKind.threadBound;

  bool get includesAllProfiles => kind == ChatAgentScopeKind.allProfiles;

  String? get fixedProfileId =>
      kind == ChatAgentScopeKind.fixed ? profileHint : null;
}

enum WorkbenchChatSkill {
  persona('persona', '个人IP创作', true),
  lead('lead', '获客营销', true),
  visualDesign('visual-design', '视觉设计', false),
  videoAnalysis('video-analysis', '视频分析', false),
  positioningLv1('positioning-lv1', '基础定位', false),
  socialPositioning('social-positioning', '社媒定位', false),
  masterpiece('masterpiece', '代表作', false);

  const WorkbenchChatSkill(this.routeValue, this.label, this.requiresMaterials);

  final String routeValue;
  final String label;
  final bool requiresMaterials;

  static WorkbenchChatSkill? tryParse(String? value) {
    for (final skill in WorkbenchChatSkill.values) {
      if (skill.routeValue == value) return skill;
    }
    return null;
  }

  static WorkbenchChatSkill? fromAgentProfileId(String? value) =>
      switch (value?.trim()) {
        'renshe_content' => WorkbenchChatSkill.persona,
        'huoke_content' => WorkbenchChatSkill.lead,
        'visual_chat' => WorkbenchChatSkill.visualDesign,
        'video_analysis' => WorkbenchChatSkill.videoAnalysis,
        'positioning_lv1' => WorkbenchChatSkill.positioningLv1,
        'positioning_lv2' => WorkbenchChatSkill.socialPositioning,
        'book_writing' => WorkbenchChatSkill.masterpiece,
        _ => null,
      };
}

ChatContextPurpose chatContextPurposeForAgentProfileId(String? value) =>
    switch (value?.trim()) {
      'renshe_content' => ChatContextPurpose.persona,
      'huoke_content' => ChatContextPurpose.lead,
      'visual_chat' => ChatContextPurpose.visualDesign,
      'video_analysis' => ChatContextPurpose.videoAnalysis,
      'positioning_lv1' => ChatContextPurpose.deepPositioning,
      'positioning_lv2' => ChatContextPurpose.socialPositioning,
      'book_writing' => ChatContextPurpose.masterpiece,
      _ => ChatContextPurpose.general,
    };

String? agentProfileIdForWorkbenchSkill(WorkbenchChatSkill? skill) =>
    switch (skill) {
      WorkbenchChatSkill.persona => 'renshe_content',
      WorkbenchChatSkill.lead => 'huoke_content',
      WorkbenchChatSkill.visualDesign => 'visual_chat',
      WorkbenchChatSkill.videoAnalysis => 'video_analysis',
      WorkbenchChatSkill.positioningLv1 => 'positioning_lv1',
      WorkbenchChatSkill.socialPositioning => 'positioning_lv2',
      WorkbenchChatSkill.masterpiece => 'book_writing',
      null => null,
    };

ChatConversationPurpose resolveChatConversationPurposeForAgent({
  required ChatConversationPurpose requestedPurpose,
  String? agentProfileId,
}) {
  final profile = knownPublicChatAgentProfileId(agentProfileId);
  if (profile == null) return requestedPurpose;
  return profile == 'positioning_lv1' || profile == 'positioning_lv2'
      ? ChatConversationPurpose.deepPositioning
      : ChatConversationPurpose.general;
}

const standardCreationChatAgentProfileId = 'self_media_creation_standard';

const _knownPublicChatAgentProfileIds = <String>{
  'book_writing',
  'data_body',
  'positioning_lv1',
  'positioning_lv2',
  'faya_germination',
  'huoke_content',
  standardCreationChatAgentProfileId,
  'renshe_content',
  'self_media_creation',
  'video_analysis',
  'visual_chat',
};

/// Accepts only a currently published public Agent Profile at route ingress.
///
/// Thread responses remain opaque server data and are deliberately not filtered
/// through this helper: a newer server Profile can still render with the safe
/// generic label until the client adds its route mapping.
String? knownPublicChatAgentProfileId(String? value) {
  final profile = value?.trim();
  if (profile == null || !_knownPublicChatAgentProfileIds.contains(profile)) {
    return null;
  }
  return profile;
}

String chatAgentProfileLabel(String? value) => switch (value?.trim()) {
  'data_body' => '数字孪生',
  'self_media_creation' => '自媒体创作',
  standardCreationChatAgentProfileId => '标准创作',
  'renshe_content' => '个人IP创作',
  'huoke_content' => '获客营销',
  'visual_chat' => '视觉设计',
  'video_analysis' => '视频分析',
  'positioning_lv1' => '基础定位',
  'positioning_lv2' => '社媒定位',
  'book_writing' => '代表作',
  'faya_germination' => '深度洞察',
  _ => '聊一聊',
};

final class WorkbenchChatContext {
  WorkbenchChatContext({
    required this.skill,
    required Iterable<String> materialIds,
  }) : materialIds = List<String>.unmodifiable(<String>{
         for (final id in materialIds)
           if (isSafeChatIdentifier(id.trim())) id.trim(),
       });

  final WorkbenchChatSkill skill;
  final List<String> materialIds;

  bool get isUsable => !skill.requiresMaterials || materialIds.isNotEmpty;

  static WorkbenchChatContext? fromRoute({
    required String? skill,
    required String? materialIds,
  }) {
    final parsedSkill = WorkbenchChatSkill.tryParse(skill?.trim());
    if (parsedSkill == null) return null;
    final context = WorkbenchChatContext(
      skill: parsedSkill,
      materialIds: (materialIds ?? '').split(','),
    );
    return context.isUsable ? context : null;
  }
}

enum ChatMessageRole {
  user('user'),
  assistant('assistant'),
  system('system');

  const ChatMessageRole(this.apiValue);

  final String apiValue;

  static ChatMessageRole? tryParse(Object? value) {
    for (final role in ChatMessageRole.values) {
      if (role.apiValue == value) return role;
    }
    return null;
  }
}

enum ChatMessageContentType {
  text('text'),
  image('image'),
  voice('voice'),
  file('file'),
  audio('audio'),
  video('video');

  const ChatMessageContentType(this.apiValue);

  final String apiValue;

  static ChatMessageContentType? tryParse(Object? value) {
    for (final type in ChatMessageContentType.values) {
      if (type.apiValue == value) return type;
    }
    return null;
  }
}

final class ChatImageAttachment {
  const ChatImageAttachment({
    required this.resourceId,
    this.displayName,
    this.mimeType,
  });

  final String resourceId;
  final String? displayName;
  final String? mimeType;
}

enum ChatResourceAttachmentKind {
  image('image'),
  video('video'),
  audio('audio'),
  file('file');

  const ChatResourceAttachmentKind(this.apiValue);

  final String apiValue;

  static ChatResourceAttachmentKind? tryParse(Object? value) {
    for (final kind in ChatResourceAttachmentKind.values) {
      if (kind.apiValue == value) return kind;
    }
    return null;
  }
}

final class ChatResourceAttachment {
  const ChatResourceAttachment({
    required this.kind,
    required this.resourceId,
    this.displayName,
    this.mimeType,
    this.sizeBytes,
  });

  final ChatResourceAttachmentKind kind;
  final String resourceId;
  final String? displayName;
  final String? mimeType;
  final int? sizeBytes;
}

final class ChatAssetReference {
  const ChatAssetReference({required this.assetId, required this.title});

  final String assetId;
  final String title;

  bool get isValid =>
      isSafeChatIdentifier(assetId) &&
      title.trim().isNotEmpty &&
      title.trim().length <= 160;
}

enum ChatLocalDeliveryState { server, pending, failed }

enum ChatThreadTitleMode { auto, custom }

final class ChatThread {
  const ChatThread({
    required this.threadId,
    required this.scene,
    this.workspaceId,
    this.title,
    this.titleMode = ChatThreadTitleMode.auto,
    this.titleVersion = 1,
    this.updatedAt,
    this.firstUserMessageText,
    this.localAlias,
    this.purpose = ChatConversationPurpose.general,
    this.agentProfileId,
    this.activeRuns = const <ChatActiveRun>[],
  });

  final String threadId;
  final ChatScene scene;
  final String? workspaceId;
  final String? title;
  final ChatThreadTitleMode titleMode;
  final int titleVersion;
  final DateTime? updatedAt;
  final String? firstUserMessageText;
  final String? localAlias;
  final ChatConversationPurpose purpose;
  final String? agentProfileId;
  final List<ChatActiveRun> activeRuns;

  WorkbenchChatSkill? get workbenchSkill =>
      WorkbenchChatSkill.fromAgentProfileId(agentProfileId);

  String get sourceLabel => switch (agentProfileId?.trim()) {
    standardCreationChatAgentProfileId => '普通聊一聊',
    'renshe_content' => '个人 IP',
    'huoke_content' => '获客营销',
    'data_body' => '数字孪生',
    'self_media_creation' => '自媒体创作',
    'visual_chat' => '视觉设计',
    'video_analysis' => '视频分析',
    'positioning_lv1' => '基础定位',
    'positioning_lv2' => '深度定位',
    'book_writing' => '代表作',
    'faya_germination' => '深度洞察',
    _ => '来源待同步',
  };

  String get displayTitle {
    if (titleMode == ChatThreadTitleMode.custom) return defaultDisplayTitle;
    final alias = localAlias?.trim();
    if (alias != null && alias.isNotEmpty) return alias;
    return defaultDisplayTitle;
  }

  String get defaultDisplayTitle {
    final serverTitle = title?.trim();
    if (titleMode == ChatThreadTitleMode.custom &&
        serverTitle != null &&
        serverTitle.isNotEmpty) {
      return serverTitle;
    }
    final firstMessage = normalizeChatThreadFirstMessage(firstUserMessageText);
    if (firstMessage != null) return firstMessage;
    return serverTitle == null || serverTitle.isEmpty ? '未命名会话' : serverTitle;
  }

  ChatThread copyWith({
    String? threadId,
    ChatScene? scene,
    String? workspaceId,
    String? title,
    ChatThreadTitleMode? titleMode,
    int? titleVersion,
    DateTime? updatedAt,
    String? firstUserMessageText,
    String? localAlias,
    bool clearLocalAlias = false,
    ChatConversationPurpose? purpose,
    String? agentProfileId,
    bool clearAgentProfileId = false,
    List<ChatActiveRun>? activeRuns,
  }) {
    return ChatThread(
      threadId: threadId ?? this.threadId,
      scene: scene ?? this.scene,
      workspaceId: workspaceId ?? this.workspaceId,
      title: title ?? this.title,
      titleMode: titleMode ?? this.titleMode,
      titleVersion: titleVersion ?? this.titleVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      firstUserMessageText: firstUserMessageText ?? this.firstUserMessageText,
      localAlias: clearLocalAlias ? null : localAlias ?? this.localAlias,
      purpose: purpose ?? this.purpose,
      agentProfileId: clearAgentProfileId
          ? null
          : agentProfileId ?? this.agentProfileId,
      activeRuns: List<ChatActiveRun>.unmodifiable(
        activeRuns ?? this.activeRuns,
      ),
    );
  }
}

final class ChatActiveRun {
  const ChatActiveRun({required this.agentRunId, required this.status});

  final String agentRunId;
  final String status;

  bool get isTerminal => const <String>{
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'orphaned',
  }.contains(status);
}

final class ChatMessage {
  const ChatMessage({
    required this.messageId,
    required this.threadId,
    required this.scene,
    required this.role,
    required this.contentType,
    required this.status,
    this.taskId,
    this.agentRunId,
    this.textPreview,
    this.transcriptText,
    this.imageAttachments = const <ChatImageAttachment>[],
    this.resourceAttachments = const <ChatResourceAttachment>[],
    this.assetReferences = const <ChatAssetReference>[],
    this.createdAt,
    this.localDelivery = ChatLocalDeliveryState.server,
    this.localFailureCanAbandon = false,
  });

  final String messageId;
  final String threadId;
  final ChatScene scene;
  final ChatMessageRole role;
  final ChatMessageContentType contentType;
  final String status;
  final String? taskId;
  final String? agentRunId;
  final String? textPreview;
  final String? transcriptText;
  final List<ChatImageAttachment> imageAttachments;
  final List<ChatResourceAttachment> resourceAttachments;
  final List<ChatAssetReference> assetReferences;
  final DateTime? createdAt;
  final ChatLocalDeliveryState localDelivery;
  final bool localFailureCanAbandon;

  String? get visibleText => textPreview ?? transcriptText;

  bool get hasVisibleContent =>
      visibleText?.trim().isNotEmpty == true ||
      imageAttachments.isNotEmpty ||
      resourceAttachments.isNotEmpty;

  ChatMessage copyWith({
    String? messageId,
    String? threadId,
    ChatScene? scene,
    ChatMessageRole? role,
    ChatMessageContentType? contentType,
    String? status,
    String? taskId,
    String? agentRunId,
    String? textPreview,
    String? transcriptText,
    List<ChatImageAttachment>? imageAttachments,
    List<ChatResourceAttachment>? resourceAttachments,
    List<ChatAssetReference>? assetReferences,
    DateTime? createdAt,
    ChatLocalDeliveryState? localDelivery,
    bool? localFailureCanAbandon,
  }) {
    return ChatMessage(
      messageId: messageId ?? this.messageId,
      threadId: threadId ?? this.threadId,
      scene: scene ?? this.scene,
      role: role ?? this.role,
      contentType: contentType ?? this.contentType,
      status: status ?? this.status,
      taskId: taskId ?? this.taskId,
      agentRunId: agentRunId ?? this.agentRunId,
      textPreview: textPreview ?? this.textPreview,
      transcriptText: transcriptText ?? this.transcriptText,
      imageAttachments: List<ChatImageAttachment>.unmodifiable(
        imageAttachments ?? this.imageAttachments,
      ),
      resourceAttachments: List<ChatResourceAttachment>.unmodifiable(
        resourceAttachments ?? this.resourceAttachments,
      ),
      assetReferences: List<ChatAssetReference>.unmodifiable(
        assetReferences ?? this.assetReferences,
      ),
      createdAt: createdAt ?? this.createdAt,
      localDelivery: localDelivery ?? this.localDelivery,
      localFailureCanAbandon:
          localFailureCanAbandon ?? this.localFailureCanAbandon,
    );
  }
}

final class ChatThreadPage {
  const ChatThreadPage({required this.items, this.nextCursor});

  final List<ChatThread> items;
  final String? nextCursor;
}

final class ChatThreadDetail {
  const ChatThreadDetail({required this.thread, required this.messages});

  final ChatThread thread;
  final List<ChatMessage> messages;
}

enum ChatNextActionType {
  none,
  openTaskPanel,
  pollTask,
  pollAgentRun,
  pollThread,
  pollAsr,
  quotaInsufficient,
  retryAsr,
}

final class ChatNextAction {
  const ChatNextAction({
    required this.type,
    this.taskId,
    this.agentRunId,
    this.asrTaskId,
    this.userMessage,
  });

  const ChatNextAction.none() : this(type: ChatNextActionType.none);

  final ChatNextActionType type;
  final String? taskId;
  final String? agentRunId;
  final String? asrTaskId;
  final String? userMessage;
}

final class ChatTextMutation {
  const ChatTextMutation({
    this.message,
    this.assistantMessage,
    this.nextAction = const ChatNextAction.none(),
    this.acceptedContext,
    this.receiptThreadId,
    this.receiptMessageId,
    this.receiptStatus,
  });

  final ChatMessage? message;
  final ChatMessage? assistantMessage;
  final ChatNextAction nextAction;
  final ChatAcceptedContext? acceptedContext;
  final String? receiptThreadId;
  final String? receiptMessageId;
  final String? receiptStatus;
}

final class ChatVoiceMutation {
  const ChatVoiceMutation({
    required this.message,
    this.assistantMessage,
    this.nextAction = const ChatNextAction.none(),
    this.acceptedContext,
  });

  final ChatMessage message;
  final ChatMessage? assistantMessage;
  final ChatNextAction nextAction;
  final ChatAcceptedContext? acceptedContext;
}

bool isSafeChatIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

bool isSafeAgentRunIdentifier(String value) {
  return RegExp(
    r'^(?:agent_run_|agent-run-)[A-Za-z0-9][A-Za-z0-9._:-]{0,239}$',
  ).hasMatch(value);
}

String? normalizeChatThreadFirstMessage(String? value) {
  final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length <= 32) return normalized;
  return '${normalized.substring(0, 32)}…';
}
