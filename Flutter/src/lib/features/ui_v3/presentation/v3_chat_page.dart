import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/di/chat_providers.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/api/api_client.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../agent/application/mobile_agent_capability_controller.dart';
import '../../chat/application/chat_assistant_note_creator.dart';
import '../../chat/application/chat_controller.dart';
import '../../chat/application/chat_file_attachment_uploader.dart';
import '../../chat/application/voice_message_controller.dart';
import '../../chat/application/resource_image_reader.dart';
import '../../chat/data/chat_thread_alias_repository.dart';
import '../../chat/domain/chat_models.dart';
import '../../chat/domain/chat_context.dart';
import '../../../core/native/native_file_port.dart';
import '../../notifications/application/pending_message_projection.dart';
import '../../onboarding/application/first_launch_device_setup_controller.dart';
import '../../notifications/application/push_navigation_controller.dart';
import '../../transcription/application/live_transcript_controller.dart';
import '../../transcription/presentation/live_transcription_failure_dialog.dart';
import '../application/deep_positioning_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../../book_work/application/masterpiece_providers.dart';
import '../domain/deep_positioning_models.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';
import 'chat/chat_entry_figma_spec.dart';
import 'chat/chat_entry_surface.dart';
import 'chat/chat_history_surfaces.dart';
import 'chat/v3_chat_conversation_timeline.dart';
import 'v3_chat_runtime_summary.dart';
import 'v3_chat_execution_process.dart';

export 'v3_chat_execution_process.dart';
export 'chat/chat_history_surfaces.dart';

const agentAssistedCreationChatEntryRouteValue = 'agent-assisted-creation';

enum V3ChatPresentation { page, noteSheet }

final class V3ChatSheetExpansion {
  const V3ChatSheetExpansion({
    required this.threadId,
    required this.agentProfileId,
    required this.draft,
    required this.includesSourceReference,
  });

  final String? threadId;
  final String? agentProfileId;
  final String draft;
  final bool includesSourceReference;
}

typedef V3ChatSheetExpandCallback =
    void Function(V3ChatSheetExpansion expansion);

enum _ChatThreadAction { rename, resetName, runtime, hide }

enum V3ChatVoiceControlPhase {
  idle,
  starting,
  recording,
  stopping;

  static V3ChatVoiceControlPhase fromState(VoiceMessageState state) {
    return switch (state.status) {
      VoiceMessageControllerStatus.checkingPermission ||
      VoiceMessageControllerStatus.starting => V3ChatVoiceControlPhase.starting,
      VoiceMessageControllerStatus.recording ||
      VoiceMessageControllerStatus.paused => V3ChatVoiceControlPhase.recording,
      VoiceMessageControllerStatus.stopping => V3ChatVoiceControlPhase.stopping,
      _ => V3ChatVoiceControlPhase.idle,
    };
  }
}

String _chatHistoryAgentMetadataLabel(ChatThread thread) {
  final profile = thread.agentProfileId?.trim();
  final agentLabel = profile == null || profile.isEmpty
      ? 'Agent 信息待同步'
      : chatAgentProfileLabel(profile);
  return thread.localAlias == null ? agentLabel : '$agentLabel · 本机名称';
}

List<ChatThread> _mergeChatHistoryThreads(
  Iterable<ChatController> controllers,
) {
  final threadsById = <String, ChatThread>{};
  for (final controller in controllers) {
    for (final original in controller.historyThreads) {
      final resolvedPurpose = resolveChatConversationPurposeForAgent(
        requestedPurpose: original.purpose,
        agentProfileId: original.agentProfileId,
      );
      final thread = resolvedPurpose == original.purpose
          ? original
          : original.copyWith(purpose: resolvedPurpose);
      final existing = threadsById[thread.threadId];
      threadsById[thread.threadId] = existing == null
          ? thread
          : _preferredChatHistoryThread(existing, thread);
    }
  }
  final merged = threadsById.values.toList()
    ..sort((left, right) {
      final updatedAtOrder = (right.updatedAt?.microsecondsSinceEpoch ?? 0)
          .compareTo(left.updatedAt?.microsecondsSinceEpoch ?? 0);
      return updatedAtOrder == 0
          ? left.threadId.compareTo(right.threadId)
          : updatedAtOrder;
    });
  return List<ChatThread>.unmodifiable(merged);
}

ChatThread _preferredChatHistoryThread(ChatThread left, ChatThread right) {
  final updatedAtOrder = (right.updatedAt?.microsecondsSinceEpoch ?? 0)
      .compareTo(left.updatedAt?.microsecondsSinceEpoch ?? 0);
  if (updatedAtOrder > 0) return right;
  if (updatedAtOrder < 0) return left;
  final metadataOrder = _chatHistoryMetadataScore(
    right,
  ).compareTo(_chatHistoryMetadataScore(left));
  if (metadataOrder > 0) return right;
  if (metadataOrder < 0) return left;
  if (left.purpose != right.purpose) {
    return right.purpose == ChatConversationPurpose.deepPositioning
        ? right
        : left;
  }
  final leftProfile = left.agentProfileId ?? '';
  final rightProfile = right.agentProfileId ?? '';
  return rightProfile.compareTo(leftProfile) < 0 ? right : left;
}

int _chatHistoryMetadataScore(ChatThread thread) =>
    (thread.agentProfileId?.trim().isNotEmpty == true ? 4 : 0) +
    (normalizeChatThreadFirstMessage(thread.firstUserMessageText) != null
        ? 2
        : 0) +
    (thread.title?.trim().isNotEmpty == true ? 1 : 0);

void _debugChatLiveVoice(
  String stage,
  VoiceMessageState state, {
  String? errorCode,
}) {
  if (!kDebugMode) return;
  debugPrint(
    '[ChatLiveVoice] stage=$stage status=${state.status.name} '
    'busy=${state.isBusy} captureActive=${state.isCaptureActive} '
    'liveStatus=${state.liveTranscriptStatus?.name ?? '-'} '
    'error=${errorCode ?? state.lastErrorCode ?? '-'}',
  );
}

String _agentUnavailableMessage(MobileAgentFeatureAccess access) {
  if (access.status == MobileAgentFeatureStatus.idle ||
      access.status == MobileAgentFeatureStatus.loading) {
    return '正在校验当前账号的 AI 能力，请稍候';
  }
  return switch (access.errorCode) {
    'AGENT_SESSION_REQUIRED' => '登录并选择工作空间后才能使用该能力',
    'AGENT_WORKSPACE_RECOVERY_REQUIRED' => '工作区正在恢复，恢复完成后即可使用聊一聊',
    'AGENT_WORKSPACE_CONTEXT_UNAVAILABLE' => '正在获取当前工作区，请稍后重试',
    'AGENT_PROFILE_NOT_SELECTABLE' => '该 Agent 尚未发布，当前不可用',
    'SKILL_SELECTION_NOT_CANDIDATE' ||
    'SKILL_INSTALLATION_REQUIRED' ||
    'SKILL_INSTALLATION_DISABLED' => '当前工作空间尚未启用该 Skill',
    'MODEL_PROFILE_NOT_SELECTABLE' => '当前选择的模型不可用',
    'PERSONA_INSERTION_SKILL_UNPUBLISHED' => '人设植入能力尚未发布',
    'AGENT_FEATURE_PROHIBITED' => '该能力已被禁止接入',
    _ => '暂时无法校验该 AI 能力，请稍后重试',
  };
}

WorkbenchPurpose? _assetAnalysisPurposeForSkill(WorkbenchChatSkill? skill) =>
    switch (skill) {
      WorkbenchChatSkill.persona => WorkbenchPurpose.persona,
      WorkbenchChatSkill.lead => WorkbenchPurpose.lead,
      _ => null,
    };

String _chatHeaderTitle(
  WorkbenchChatSkill? skill,
  String? agentProfileId, {
  required bool deepPositioning,
}) {
  final profile = agentProfileId?.trim();
  final resolvedSkill = skill ?? WorkbenchChatSkill.fromAgentProfileId(profile);
  if (deepPositioning) return '继续深度定位';
  return switch (resolvedSkill) {
    WorkbenchChatSkill.persona => '个人 IP',
    WorkbenchChatSkill.lead => '获客营销',
    WorkbenchChatSkill.visualDesign => '视觉设计',
    WorkbenchChatSkill.videoAnalysis => '视频分析',
    WorkbenchChatSkill.positioningLv1 => '基础定位',
    WorkbenchChatSkill.socialPositioning => '深度定位',
    WorkbenchChatSkill.masterpiece => '代表作',
    null when profile == 'data_body' => '数字孪生',
    null
        when profile == null ||
            profile.isEmpty ||
            profile == 'self_media_creation' ||
            profile == standardCreationChatAgentProfileId =>
      '聊一聊',
    null => chatAgentProfileLabel(profile),
  };
}

final class _ChatEntryPresentation {
  _ChatEntryPresentation({
    required this.greeting,
    required this.supportingCopy,
    required this.suggestionSets,
  }) : assert(_hasBalancedAgentSuggestionSets(suggestionSets));

  final String greeting;
  final String supportingCopy;
  final List<List<ChatEntrySuggestionSpec>> suggestionSets;
}

bool _hasBalancedAgentSuggestionSets(
  List<List<ChatEntrySuggestionSpec>> suggestionSets,
) =>
    suggestionSets.length >= 2 &&
    suggestionSets.every(
      (suggestions) =>
          suggestions.length == 3 &&
          suggestions.first.kind == ChatEntrySuggestionKind.notePicker &&
          suggestions
              .skip(1)
              .every(
                (suggestion) =>
                    suggestion.kind == ChatEntrySuggestionKind.prompt,
              ) &&
          suggestions
                  .where(
                    (suggestion) =>
                        suggestion.kind == ChatEntrySuggestionKind.notePicker,
                  )
                  .length ==
              1 &&
          suggestions
                  .where(
                    (suggestion) =>
                        suggestion.kind == ChatEntrySuggestionKind.prompt,
                  )
                  .length ==
              2,
    );

_ChatEntryPresentation _chatEntryPresentation(
  WorkbenchChatSkill? skill,
  String? agentProfileId,
) {
  final profile = knownPublicChatAgentProfileId(agentProfileId);
  if (profile == 'data_body') {
    return _ChatEntryPresentation(
      greeting: 'Hello，我是数字孪生 Agent',
      supportingCopy: '基于你的资料与表达，持续理解并完善你的数字分身。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，识别其中的经历、观点和表达特征'),
          ChatEntrySuggestionSpec.question('建立准确的数字孪生，最先需要补充哪些信息？'),
          ChatEntrySuggestionSpec.question('怎样区分稳定的个人特征和一次性的表达？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，判断它能证明哪些长期能力'),
          ChatEntrySuggestionSpec.question('怎样判断一段经历是否足以代表一个人的能力？'),
          ChatEntrySuggestionSpec.question('用哪些问题能发现自我介绍里缺失的关键信息？'),
        ],
      ],
    );
  }
  if (profile == 'self_media_creation') {
    return _ChatEntryPresentation(
      greeting: 'Hello，我是自媒体创作 Agent',
      supportingCopy: '从受众、主题和内容形式出发，推进可发布的自媒体内容。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，帮我提炼适合发布的自媒体选题'),
          ChatEntrySuggestionSpec.question('一个新账号应该先确定受众、主题还是内容形式？'),
          ChatEntrySuggestionSpec.question('怎样判断一个选题更适合短视频还是图文？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，帮我规划一条完整的发布内容'),
          ChatEntrySuggestionSpec.question('内容更新不稳定时，应该怎样建立选题流程？'),
          ChatEntrySuggestionSpec.question('怎样让同一个主题适配不同的内容平台？'),
        ],
      ],
    );
  }
  if (profile == 'faya_germination') {
    return _ChatEntryPresentation(
      greeting: 'Hello，我是深度洞察 Agent',
      supportingCopy: '从素材中挖掘冲突、洞察和可以继续展开的观点。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，帮我挖出值得展开的核心观点'),
          ChatEntrySuggestionSpec.question('普通素材怎样找到有冲突感的观点切口？'),
          ChatEntrySuggestionSpec.question('如何判断一个观点既新鲜又经得起推敲？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，帮我找到被忽略的反常识线索'),
          ChatEntrySuggestionSpec.question('一个事实可以从哪些角度发展成独立观点？'),
          ChatEntrySuggestionSpec.question('怎样把观点写得尖锐但不夸大事实？'),
        ],
      ],
    );
  }
  final resolvedSkill = skill ?? WorkbenchChatSkill.fromAgentProfileId(profile);
  return switch (resolvedSkill) {
    WorkbenchChatSkill.positioningLv1 => _ChatEntryPresentation(
      greeting: 'Hello，我是基础定位 Agent',
      supportingCopy: '从经历、能力和目标出发，建立清晰可信的基础定位。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，帮我提炼真实的能力和经历线索'),
          ChatEntrySuggestionSpec.question('做基础定位时，应该先梳理经历还是目标受众？'),
          ChatEntrySuggestionSpec.question('怎样把擅长的事情描述成清晰的个人价值？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，判断它能支撑怎样的基础定位'),
          ChatEntrySuggestionSpec.question('定位太宽泛时，可以用哪些问题逐步缩小范围？'),
          ChatEntrySuggestionSpec.question('怎样判断一个定位是否真实、具体并且可验证？'),
        ],
      ],
    ),
    WorkbenchChatSkill.socialPositioning => _ChatEntryPresentation(
      greeting: 'Hello，我是深度定位 Agent',
      supportingCopy: '沿着已有定位，梳理你的经历、受众与价值，让表达更有辨识度。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，从真实经历中提炼定位线索'),
          ChatEntrySuggestionSpec.question('还不确定服务谁时，应该怎样缩小目标人群？'),
          ChatEntrySuggestionSpec.question('定位里“我擅长”和“市场需要”应该怎样取舍？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，判断它最能证明我解决哪类问题'),
          ChatEntrySuggestionSpec.question('怎样把专业能力转成用户能感知的价值？'),
          ChatEntrySuggestionSpec.question('如何验证一个定位是否清晰、可信且可持续？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，提炼适合长期表达的核心观点'),
          ChatEntrySuggestionSpec.question('怎样选择长期内容支柱，避免定位越做越散？'),
          ChatEntrySuggestionSpec.question('定位确定前，最值得做的低成本验证有哪些？'),
        ],
      ],
    ),
    WorkbenchChatSkill.persona => _ChatEntryPresentation(
      greeting: 'Hello，我是个人 IP Agent',
      supportingCopy: '从经历、优势和表达中，找到更准确的个人定位。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，提炼能支撑个人 IP 的经历'),
          ChatEntrySuggestionSpec.question('个人 IP 定位，应先明确能力还是受众？'),
          ChatEntrySuggestionSpec.question('怎样把个人经历转成有辨识度的内容主题？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，找出最有故事感的表达线索'),
          ChatEntrySuggestionSpec.question('怎样形成稳定又不刻意的人设表达？'),
          ChatEntrySuggestionSpec.question('如何设计适合长期更新的个人栏目？'),
        ],
      ],
    ),
    WorkbenchChatSkill.lead => _ChatEntryPresentation(
      greeting: 'Hello，我是获客营销 Agent',
      supportingCopy: '把产品信息转成更有吸引力和转化力的内容。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，提炼客户最在意的问题'),
          ChatEntrySuggestionSpec.question('怎样区分客户的表面需求和真实购买动机？'),
          ChatEntrySuggestionSpec.question('获客内容怎样自然引导下一步行动？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，改造成可信的获客案例'),
          ChatEntrySuggestionSpec.question('如何用内容验证目标客户是否值得重点投入？'),
          ChatEntrySuggestionSpec.question('怎样写卖点才能具体可信而不过度承诺？'),
        ],
      ],
    ),
    WorkbenchChatSkill.visualDesign => _ChatEntryPresentation(
      greeting: 'Hello，我是视觉参考 Agent',
      supportingCopy: '把口播稿转成道具、灯光和场景建议。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，生成匹配主题的视觉参考'),
          ChatEntrySuggestionSpec.question('口播视频怎样搭配道具、灯光和拍摄场景？'),
          ChatEntrySuggestionSpec.question('怎样用构图突出人物和重要信息？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，提炼画面主题和视觉元素'),
          ChatEntrySuggestionSpec.question('不同内容主题适合怎样的色彩和字体风格？'),
          ChatEntrySuggestionSpec.question('怎样为不同平台调整画面比例和安全区域？'),
        ],
      ],
    ),
    WorkbenchChatSkill.videoAnalysis => _ChatEntryPresentation(
      greeting: 'Hello，我是视频分析 Agent',
      supportingCopy: '可以拆解具体视频的结构、画面和节奏，也可以直接讨论常见的视频问题。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份内容资产，梳理视频分析重点'),
          ChatEntrySuggestionSpec.question('判断短视频开头是否有效，通常看哪些信号？'),
          ChatEntrySuggestionSpec.question('怎样拆解视频的结构、画面和节奏？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份内容资产，提炼视频表达主线'),
          ChatEntrySuggestionSpec.question('前五秒怎样建立期待并减少用户划走？'),
          ChatEntrySuggestionSpec.question('怎样把视频观点整理成可复用的文字提纲？'),
        ],
      ],
    ),
    WorkbenchChatSkill.masterpiece => _ChatEntryPresentation(
      greeting: 'Hello，我是代表作 Agent',
      supportingCopy: '围绕你的创作主题与现有内容，推进结构、章节和表达。',
      suggestionSets: const <List<ChatEntrySuggestionSpec>>[
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，判断哪些内容适合写进代表作'),
          ChatEntrySuggestionSpec.question('一部代表作的核心主线应该如何定义和检验？'),
          ChatEntrySuggestionSpec.question('章节结构松散时，可以用什么方法重新组织？'),
        ],
        <ChatEntrySuggestionSpec>[
          ChatEntrySuggestionSpec.assetReference('引用一份资产，提炼可发展为章节的故事或观点'),
          ChatEntrySuggestionSpec.question('写作卡住时，如何判断该补材料还是改结构？'),
          ChatEntrySuggestionSpec.question('作品开头怎样快速建立问题和阅读动力？'),
        ],
      ],
    ),
    _ => _ChatEntryPresentation(
      greeting: ChatEntryFigmaSpec.greeting,
      supportingCopy: ChatEntryFigmaSpec.supportingCopy,
      suggestionSets: ChatEntryFigmaSpec.suggestionSets,
    ),
  };
}

class V3ChatPage extends ConsumerStatefulWidget {
  const V3ChatPage({
    this.contentLineId,
    this.feedItemId,
    this.threadId,
    this.windowId,
    this.workbenchContext,
    this.autoAnalyzeMaterials = false,
    this.dailyTopicTitle,
    this.initialPrompt,
    this.autoSubmitInitialPrompt = false,
    this.isAgentAssistedCreationEntry = false,
    this.ordinaryEntryPoint,
    this.showHistoryOnStart = false,
    this.startupGuide = false,
    this.launchMode = ChatLaunchMode.resumeRecent,
    this.conversationPurpose = ChatConversationPurpose.general,
    this.presentation = V3ChatPresentation.page,
    this.onSheetClose,
    this.onSheetExpand,
    super.key,
  });

  final String? contentLineId;
  final String? feedItemId;
  final String? threadId;
  final String? windowId;
  final WorkbenchChatContext? workbenchContext;
  final bool autoAnalyzeMaterials;
  final String? dailyTopicTitle;
  final String? initialPrompt;
  final bool autoSubmitInitialPrompt;
  final bool isAgentAssistedCreationEntry;
  final OrdinaryChatEntryPoint? ordinaryEntryPoint;
  final bool showHistoryOnStart;
  final bool startupGuide;
  final ChatLaunchMode launchMode;
  final ChatConversationPurpose conversationPurpose;
  final V3ChatPresentation presentation;
  final VoidCallback? onSheetClose;
  final V3ChatSheetExpandCallback? onSheetExpand;

  @override
  ConsumerState<V3ChatPage> createState() => _V3ChatPageState();
}

class _V3ChatPageState extends ConsumerState<V3ChatPage> with RouteAware {
  static int _chatWindowSequence = 0;
  static int _voiceOwnerSequence = 0;
  final _text = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  bool _hasText = false;
  int? _startupGuideAccountRevision;

  bool get _isStartupGuideRoute =>
      widget.startupGuide &&
      !widget.autoSubmitInitialPrompt &&
      !widget.isAgentAssistedCreationEntry &&
      widget.initialPrompt == null &&
      widget.launchMode == ChatLaunchMode.fresh &&
      widget.conversationPurpose == ChatConversationPurpose.general &&
      widget.presentation == V3ChatPresentation.page &&
      widget.workbenchContext == null &&
      widget.threadId == null &&
      widget.feedItemId == null &&
      widget.contentLineId == null;

  bool _hasStartupGuide(FirstLaunchDeviceSetupController journey) =>
      _isStartupGuideRoute &&
      journey.requiresChatGuide &&
      _startupGuideAccountRevision == journey.accountRevision;

  void _skipStartupGuide() {
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    if (_hasStartupGuide(journey) && !journey.skipChatGuide()) {
      showV3Snack(context, '进度暂未保存，请再试一次');
    }
  }

  Future<bool> _submitUserTextTurn(
    ChatController controller,
    Future<bool> Function() submit,
  ) async {
    final journey = _isStartupGuideRoute
        ? ref.read(firstLaunchDeviceSetupControllerProvider)
        : null;
    final profile = controller.activeAgentProfileId;
    final guideRevision =
        journey != null &&
            _hasStartupGuide(journey) &&
            (profile == null || profile == standardCreationChatAgentProfileId)
        ? _startupGuideAccountRevision
        : null;
    final accepted = await submit();
    if (accepted && journey != null && guideRevision != null) {
      _completeStartupChatGuide(journey, guideRevision);
    }
    return accepted;
  }

  void _completeStartupChatGuide(
    FirstLaunchDeviceSetupController journey,
    int accountRevision,
  ) {
    if (journey.accountRevision != accountRevision ||
        !journey.requiresChatGuide) {
      return;
    }
    final saved =
        journey.openChatGuide(expectedAccountRevision: accountRevision) &&
        journey.completeChatGuide(expectedAccountRevision: accountRevision);
    if (!saved && mounted && _hasStartupGuide(journey)) {
      showV3Snack(
        context,
        '消息已发送，引导进度暂未保存',
        actionLabel: '重试保存',
        onAction: () => _completeStartupChatGuide(journey, accountRevision),
      );
    }
  }

  double _lastKeyboardInset = 0;
  bool _keepLatestVisibleAfterSubmission = false;
  bool _followsLatest = true;
  bool _isDraggingConversation = false;
  bool _scrollToBottomScheduled = false;
  bool _pendingForcedScroll = false;
  bool _pendingImmediateScroll = false;
  int _immediateScrollGeneration = 0;
  bool _resolvingInitialConversation = true;
  bool _switchingConversation = false;
  bool _sendSubmissionInFlight = false;
  bool _sendPreflightInFlight = false;
  bool _routeFeedItemEnabled = true;
  PageRoute<dynamic>? _observedRoute;
  bool _routeVisible = true;
  bool _positioningReportSaving = false;
  bool _routeLeaveEffectsScheduled = false;
  late final bool _positioningSessionHadReport;
  late final ChatFileAttachmentUploader _fileAttachments;
  late final NativeFilePort _nativeFilePort;
  late final VoiceMessageController _voiceMessageController;
  late final String _voiceSessionOwner;
  final LiveTranscriptionFailureDialogGate _voiceFailureDialogGate =
      LiveTranscriptionFailureDialogGate();
  late final String? _initialThreadId;
  Future<void>? _initialThreadLoad;
  OrdinaryChatEntryPoint? _persistedOrdinaryEntryPoint;
  String? _persistedOrdinaryThreadId;
  String? _pendingContentLineId;
  String? _pendingContextLabel;
  List<String> _pendingMemoryNoteIds = const <String>[];
  String? _lastAppliedLiveTranscript;
  String _liveTranscriptPrefix = '';
  int? _lastObservedChatControllerId;
  int? _lastObservedChatMessageCount;
  int? _routeRecoveryScheduledForControllerId;
  String? _pendingPositioningReportThreadId;
  String? _scheduledPositioningAssistantMessageId;
  Set<String> _positioningAssistantIdsBeforeSend = const <String>{};
  bool _assetAnalysisSubmissionScheduled = false;
  bool _initialPromptSubmissionScheduled = false;
  bool _initialHistoryShown = false;
  late bool _initialConversationResolved;
  bool _showM05History = false;
  bool _historyIsRouteEntry = false;
  bool _historyChildVisitInProgress = false;
  bool _workbenchMaterialsConsumed = false;
  final Set<String> _creatingAssistantNoteIds = <String>{};
  final Set<String> _createdAssistantNoteIds = <String>{};

  @override
  void initState() {
    super.initState();
    if (_isStartupGuideRoute) {
      final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
      if (journey.requiresChatGuide) {
        _startupGuideAccountRevision = journey.accountRevision;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_hasStartupGuide(journey)) return;
          journey.openChatGuide(
            expectedAccountRevision: _startupGuideAccountRevision!,
          );
        });
      }
    }
    _showM05History = widget.showHistoryOnStart;
    _historyIsRouteEntry = widget.showHistoryOnStart;
    final requestedThreadId = widget.threadId?.trim();
    _initialThreadId =
        requestedThreadId != null && isSafeChatIdentifier(requestedThreadId)
        ? requestedThreadId
        : null;
    final initialChat = ref.read(_chatControllerProvider).state;
    _initialConversationResolved = _shouldRestoreOrdinaryEntry
        ? false
        : switch (_effectiveLaunchMode) {
            ChatLaunchMode.exactThread =>
              initialChat.activeThreadId == _safeThreadId &&
                  initialChat.messages.isNotEmpty,
            ChatLaunchMode.resumeRecent =>
              initialChat.activeThreadId != null ||
                  initialChat.messages.isNotEmpty,
            ChatLaunchMode.fresh || ChatLaunchMode.history => true,
          };
    _debugRouteRestore('init');
    // Cache recovery is synchronous and account-scoped. It must happen before
    // capability warm-up so a known historical thread never flashes an empty
    // or unavailable conversation while its remote detail is catching up.
    _voiceSessionOwner = 'chat:${++_voiceOwnerSequence}';
    _voiceMessageController = ref.read(feedAiVoiceMessageControllerProvider);
    _nativeFilePort = ref.read(nativeFilePortProvider);
    _fileAttachments = ChatFileAttachmentUploader(
      nativeFilePort: _nativeFilePort,
      apiClient: ref.read(apiClientProvider),
      workspaceId: () =>
          ref.read(sessionStoreProvider).state.workspace?.workspaceId,
    )..addListener(_onFileAttachmentsChanged);
    _positioningSessionHadReport =
        widget.conversationPurpose == ChatConversationPurpose.deepPositioning &&
        ref.read(deepPositioningControllerProvider).result != null;
    final initialPrompt = _safeInitialPrompt;
    if (initialPrompt != null) {
      _hasText = true;
      _text.value = TextEditingValue(
        text: initialPrompt,
        selection: TextSelection.collapsed(offset: initialPrompt.length),
      );
    }
    _text.addListener(() {
      final hasText = _text.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
    _composerFocus.addListener(_handleComposerFocusChanged);
    ref.listenManual<int>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.foregroundGeneration,
      ),
      (_, __) => _refreshOnForeground(),
    );
    ref.listenManual<int>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.viewMetricsRevision,
      ),
      (_, __) => _handleViewMetricsChanged(),
    );
    ref.listenManual<ChatControllerState>(
      _chatControllerProvider.select((controller) => controller.state),
      (_, next) => _schedulePositioningReportReconciliation(next),
      fireImmediately: true,
    );
    ref.listenManual<ChatController>(
      _chatControllerProvider,
      (_, next) => _debugChatControllerBinding(next),
      fireImmediately: true,
    );
    _listenToChatReactions();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _prepareCapabilityAndLoad().whenComplete(() {
          if (!mounted) return;
          _resolvingInitialConversation = false;
          if (!_initialConversationResolved) {
            setState(() => _initialConversationResolved = true);
          }
          final activeThreadId = ref
              .read(_chatControllerProvider)
              .state
              .activeThreadId;
          _publishForegroundThread(activeThreadId);
          if (activeThreadId != null) {
            _acknowledgeVisibleChatResult(activeThreadId);
          }
          _showInitialHistory();
        }),
      );
    });
  }

  void _listenToChatReactions() {
    ref.listenManual<String?>(
      _chatControllerProvider.select(
        (controller) => controller.state.activeThreadId,
      ),
      (_, next) => _publishForegroundThread(next),
      fireImmediately: true,
    );
    ref.listenManual<VoiceMessageState>(
      feedAiVoiceMessageControllerProvider.select(
        (controller) => controller.state,
      ),
      _handleVoiceStateChanged,
    );
    ref.listenManual(
      _chatControllerProvider.select(
        (controller) => (
          threadId: controller.state.activeThreadId,
          messageCount: controller.state.messages.length,
          runStatus: controller.state.agentRunStatus,
          toolActivity: Object.hashAll(
            controller.state.assistantToolTrace.map(
              (trace) => Object.hash(
                trace.invocationId,
                trace.state,
                trace.outcome,
                trace.completedAt,
                trace.outputFiles.length,
              ),
            ),
          ),
        ),
      ),
      (previous, next) {
        if (previous == next) return;
        final changedThread = previous?.threadId != next.threadId;
        _scheduleScrollToBottom(
          force: changedThread,
          immediate:
              _resolvingInitialConversation ||
              _switchingConversation ||
              changedThread,
        );
      },
    );
    ref.listenManual<
      ({
        String threadId,
        int resultFingerprint,
        String? failureCode,
        String? failedTaskId,
      })?
    >(
      _chatControllerProvider.select((controller) {
        final state = controller.state;
        final threadId = state.activeThreadId;
        if (threadId == null) return null;
        final assistantResults = state.displayMessages.where(
          (message) => message.role == ChatMessageRole.assistant,
        );
        final failureCode = state.status == ChatControllerStatus.failed
            ? state.lastErrorCode
            : null;
        final failedTaskId = failureCode == null
            ? null
            : state.turnState.agentRunId?.trim();
        if (assistantResults.isEmpty && failureCode == null) return null;
        return (
          threadId: threadId,
          resultFingerprint: Object.hashAll(
            assistantResults.map(
              (message) => Object.hash(
                message.messageId,
                message.status,
                message.agentRunId,
                message.taskId,
                message.visibleText,
                Object.hashAll(
                  message.imageAttachments.map(
                    (attachment) => attachment.resourceId,
                  ),
                ),
                Object.hashAll(
                  message.resourceAttachments.map(
                    (attachment) => attachment.resourceId,
                  ),
                ),
              ),
            ),
          ),
          failureCode: failureCode,
          failedTaskId: failedTaskId,
        );
      }),
      (previous, next) {
        if (next != null && next != previous) {
          _acknowledgeVisibleChatResult(next.threadId);
        }
      },
    );
    ref.listenManual<int>(
      chatRunTrackerProvider.select(
        (tracker) => tracker.taskLedgerDeltaSequence,
      ),
      (previous, next) {
        if (previous == next) return;
        final threadId = ref.read(_chatControllerProvider).state.activeThreadId;
        if (threadId != null) _acknowledgeVisibleChatResult(threadId);
      },
    );
    ref.listenManual<String>(
      pendingMessageProjectionProvider.select(
        (projection) => pendingMessageRemoteResultRevision(projection.items),
      ),
      (previous, next) {
        if (next.isEmpty || next == previous) return;
        final threadId = ref.read(_chatControllerProvider).state.activeThreadId;
        if (threadId != null) _acknowledgeVisibleChatResult(threadId);
      },
      fireImmediately: true,
    );
    ref.listenManual<String?>(
      _chatControllerProvider.select((controller) {
        final state = controller.state;
        final activeThreadId = state.activeThreadId;
        final activeThread = activeThreadId == null
            ? null
            : state.threads
                  .where((thread) => thread.threadId == activeThreadId)
                  .firstOrNull;
        return activeThread?.agentProfileId ?? controller.activeAgentProfileId;
      }),
      (previous, next) {
        if (previous == next) return;
        final chatState = ref.read(_chatControllerProvider).state;
        if (chatState.activeThreadId != null || chatState.threads.isNotEmpty) {
          return;
        }
        if (!_requiresCatalogPreflight(next)) return;
        final featureId = _agentFeatureIdFor(
          next == null ? widget.workbenchContext?.skill : null,
          agentProfileId: next,
        );
        final access = ref
            .read(mobileAgentCapabilityControllerProvider)
            .accessFor(featureId);
        if (access.status == MobileAgentFeatureStatus.idle) {
          unawaited(
            ref
                .read(mobileAgentCapabilityControllerProvider)
                .ensureFeature(featureId),
          );
        }
      },
    );
    ref.listenManual<int>(
      pushRuntimeControllerProvider.select(
        (controller) => controller.state.bannerId,
      ),
      (previous, next) {
        if (previous == next) return;
        final message = ref
            .read(pushRuntimeControllerProvider)
            .state
            .foregroundMessage;
        final threadId = ref.read(_chatControllerProvider).state.activeThreadId;
        if (message == null ||
            threadId == null ||
            ref.read(foregroundChatThreadIdProvider) != threadId ||
            !isPushForChatThread(message, threadId)) {
          return;
        }
        unawaited(_refreshCompletedConversation(threadId));
      },
    );
  }

  void _showInitialHistory() {
    if (!mounted || !widget.showHistoryOnStart || _initialHistoryShown) return;
    _initialHistoryShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openM05History());
    });
  }

  @override
  void dispose() {
    _routeVisible = false;
    _scheduleVoiceCaptureEnd();
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _fileAttachments
      ..removeListener(_onFileAttachmentsChanged)
      ..dispose();
    _scrollController.dispose();
    _composerFocus
      ..removeListener(_handleComposerFocusChanged)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || identical(route, _observedRoute)) {
      return;
    }
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _observedRoute = route;
    _routeVisible = route.isCurrent;
    appRouteObserver.subscribe(this, route);
  }

  Future<void> _prepareCapabilityAndLoad({bool forceRefresh = false}) async {
    await _loadInitialThreads();
    if (!mounted) return;
    if (_safeInitialPrompt == null) {
      _scheduleAssetAnalysisSubmission();
    } else {
      _scheduleInitialPromptSubmission();
    }
    final controller = ref.read(_chatControllerProvider);
    final hasEstablishedConversation =
        _safeThreadId != null ||
        controller.state.activeThreadId != null ||
        controller.state.threads.isNotEmpty;
    // A historical thread already has an opaque public Agent Profile. Loading
    // it must never wait for a best-effort catalog refresh. An explicit retry
    // remains allowed to refresh the public catalog for a new send attempt.
    if (hasEstablishedConversation && !forceRefresh) return;
    final initialAgentProfileId = controller.activeAgentProfileId;
    // A standard empty chat is submitted through the direct public facade,
    // which owns its `self_media_creation_standard` fallback. Likewise, an
    // entry that already carries an opaque published Profile has all the
    // client-side selection data it needs. Do not make an optional catalog
    // read look like a broken new conversation.
    if (!_requiresCatalogPreflight(initialAgentProfileId)) return;
    unawaited(
      ref
          .read(mobileAgentCapabilityControllerProvider)
          .ensureFeature(
            _agentFeatureIdFor(
              widget.workbenchContext?.skill,
              agentProfileId: initialAgentProfileId,
            ),
            forceRefresh: forceRefresh,
          ),
    );
  }

  void _scheduleAssetAnalysisSubmission() {
    if (!widget.autoAnalyzeMaterials || _assetAnalysisSubmissionScheduled) {
      return;
    }
    final workbenchContext = widget.workbenchContext;
    final purpose = _assetAnalysisPurposeForSkill(workbenchContext?.skill);
    if (workbenchContext == null ||
        workbenchContext.materialIds.isEmpty ||
        purpose == null) {
      return;
    }
    _assetAnalysisSubmissionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final controller = ref.read(_chatControllerProvider);
      if (controller.state.activeThreadId != null ||
          controller.state.messages.isNotEmpty ||
          controller.state.isSending) {
        return;
      }
      final prompt = purpose.assetAnalysisPrompt;
      _text.value = TextEditingValue(
        text: prompt,
        selection: TextSelection.collapsed(offset: prompt.length),
      );
      await _sendMessage();
    });
  }

  String? get _safeInitialPrompt {
    final prompt = widget.initialPrompt?.trim();
    if (prompt == null || prompt.isEmpty) return null;
    return prompt.length <= 1000 ? prompt : prompt.substring(0, 1000);
  }

  void _scheduleInitialPromptSubmission() {
    if (!widget.autoSubmitInitialPrompt || _initialPromptSubmissionScheduled) {
      return;
    }
    final prompt = _safeInitialPrompt;
    if (prompt == null) return;
    _initialPromptSubmissionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final controller = ref.read(_chatControllerProvider);
      if (controller.state.activeThreadId != null ||
          controller.state.messages.isNotEmpty ||
          controller.state.isSending) {
        return;
      }
      _text.value = TextEditingValue(
        text: prompt,
        selection: TextSelection.collapsed(offset: prompt.length),
      );
      await _sendMessage();
    });
  }

  Future<void> _loadInitialThreads() {
    final existing = _initialThreadLoad;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _loadInitialThreadsOnce().whenComplete(() {
      if (identical(_initialThreadLoad, operation)) {
        _initialThreadLoad = null;
      }
    });
    _initialThreadLoad = operation;
    return operation;
  }

  Future<void> _loadInitialThreadsOnce() async {
    final controller = ref.read(_chatControllerProvider);
    final threadId = _safeThreadId;
    _debugRouteRestore(
      'load-initial',
      activeThreadId: controller.state.activeThreadId,
    );
    if (_effectiveLaunchMode == ChatLaunchMode.exactThread &&
        threadId != null) {
      _debugRouteRestore('load-route-thread', activeThreadId: threadId);
      controller.restoreCachedConversations();
      controller.restoreHiddenThread(threadId);
      await controller.selectThread(
        threadId,
        forceRemote: _isDeepPositioning,
        allowUnassignedPurposeHydration: _isDeepPositioning,
      );
      if (!mounted ||
          !identical(controller, ref.read(_chatControllerProvider))) {
        return;
      }
      if (controller.state.status == ChatControllerStatus.ready &&
          controller.state.activeThreadId == threadId) {
        _rememberOrdinaryEntryThread(controller, threadId);
        _rememberDailyTopicContext(threadId);
        if (!_isDeepPositioning) {
          final entryPoint = _ordinaryEntryPoint;
          if (entryPoint == null) {
            unawaited(controller.revalidateThreadIfStale(threadId));
          } else {
            unawaited(
              _revalidateOrdinaryEntryThread(controller, entryPoint, threadId),
            );
          }
        }
      }
      _scheduleScrollToBottom(force: true, immediate: true);
      _acknowledgeVisibleChatResult(threadId);
      return;
    }

    final ordinaryEntryPoint = _ordinaryEntryPoint;
    if (ordinaryEntryPoint != null && _shouldRestoreOrdinaryEntry) {
      controller.restoreCachedConversations();
      final restoredThreadId = await _restoreOrdinaryEntryThread(
        controller,
        ordinaryEntryPoint,
      );
      if (!mounted ||
          !identical(controller, ref.read(_chatControllerProvider))) {
        return;
      }
      if (restoredThreadId == null) {
        controller.startNewThread();
        _scheduleScrollToEntry();
        return;
      }
      if (_routeFeedItemEnabled) {
        setState(() => _routeFeedItemEnabled = false);
      }
      _scheduleScrollToBottom(force: true, immediate: true);
      _acknowledgeVisibleChatResult(restoredThreadId);
      unawaited(
        _revalidateOrdinaryEntryThread(
          controller,
          ordinaryEntryPoint,
          restoredThreadId,
        ),
      );
      return;
    }

    if (_effectiveLaunchMode.startsFresh) {
      _debugRouteRestore(
        _effectiveLaunchMode == ChatLaunchMode.history
            ? 'load-history-browser'
            : 'load-fresh-conversation',
      );
      controller.startNewThread();
      return;
    }

    controller.restoreCachedConversations();

    final restored = await controller.restoreRecentPurposeThread();
    String? restoredThreadId;
    if (!mounted) return;
    if (restored &&
        controller.state.activeThreadId != null &&
        controller.state.messages.isNotEmpty) {
      if (!_initialConversationResolved) {
        setState(() => _initialConversationResolved = true);
      }
      _debugRouteRestore(
        'load-restored-recent',
        activeThreadId: controller.state.activeThreadId,
      );
      final activeThreadId = controller.state.activeThreadId;
      if (activeThreadId != null) {
        restoredThreadId = activeThreadId;
        _scheduleScrollToBottom(force: true, immediate: true);
        _acknowledgeVisibleChatResult(activeThreadId);
      }
    }
    if (_isDeepPositioning) {
      await controller.loadThreads(refresh: restored, selectLatest: !restored);
    } else {
      await controller.loadThreads(
        refresh: true,
        selectLatest: true,
        authoritativeLatest: true,
      );
    }
    if (!mounted) return;
    final activeThreadId = controller.state.activeThreadId;
    if (activeThreadId == null) {
      _scheduleScrollToEntry();
      return;
    }
    if (activeThreadId != restoredThreadId) {
      _scheduleScrollToBottom(force: true, immediate: true);
    }
    _acknowledgeVisibleChatResult(activeThreadId);
  }

  void _handleViewMetricsChanged() {
    if (!mounted) return;
    final keyboardInset = View.of(context).viewInsets.bottom;
    final previousKeyboardInset = _lastKeyboardInset;
    final keyboardOpened = keyboardInset > previousKeyboardInset;
    _lastKeyboardInset = keyboardInset;
    if (keyboardOpened) _scheduleScrollToBottom();
  }

  void _refreshOnForeground() {
    if (!_routeVisible || !mounted) {
      return;
    }
    final routeThreadId = _safeThreadId;
    if (routeThreadId != null) {
      _debugRouteRestore('resume-route-thread', activeThreadId: routeThreadId);
      unawaited(_restoreRouteThreadOnForeground(routeThreadId));
      return;
    }
    final controller = ref.read(_chatControllerProvider);
    final threadId = controller.state.activeThreadId;
    _debugRouteRestore('resumed', activeThreadId: threadId);
    if (threadId == null) {
      unawaited(_loadInitialThreads());
      return;
    }
    if (controller.shouldRefreshThreadOnForeground(threadId)) {
      unawaited(_refreshCompletedConversation(threadId));
    } else {
      _acknowledgeVisibleChatResult(threadId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDeepPositioning) return _buildChat(context);
    final tokens = HuahuoV3Theme.darkTokens.copyWith(
      canvas: const Color(0xFF0D0B11),
      surface: const Color(0xFF1F1D22),
      surfaceMuted: const Color(0xFF2B282F),
      ink: const Color(0xFFF4F0F8),
      text: const Color(0xFFDAD4E0),
      muted: const Color(0xFF9791A0),
      line: const Color(0xFF3A363F),
      accent: const Color(0xFFB88CFF),
      primary: const Color(0xFFB88CFF),
      onPrimary: const Color(0xFF1B1321),
    );
    final base = HuahuoV3Theme.fromTokens(
      tokens: tokens,
      brightness: Brightness.dark,
    );
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'Noto Sans SC'),
      ),
      child: Builder(builder: _buildChat),
    );
  }

  Widget _buildChat(BuildContext context) {
    final isNoteSheet = widget.presentation == V3ChatPresentation.noteSheet;
    final rebuildMetrics = ref.read(runtimeActivityMetricsProvider);
    rebuildMetrics.recordRebuild('chat_page_surface');
    final chatController = ref.watch(_chatControllerProvider);
    final chat = chatController.state;
    final activeThread = chat.activeThreadId == null
        ? null
        : chat.threads
              .where((thread) => thread.threadId == chat.activeThreadId)
              .firstOrNull;
    final activeSkill =
        activeThread?.workbenchSkill ??
        WorkbenchChatSkill.fromAgentProfileId(activeThread?.agentProfileId) ??
        (activeThread == null ? widget.workbenchContext?.skill : null);
    final activeAgentProfileId =
        activeThread?.agentProfileId ?? chatController.activeAgentProfileId;
    final entryPresentation = _chatEntryPresentation(
      activeSkill ??
          (_isDeepPositioning && activeAgentProfileId == null
              ? WorkbenchChatSkill.socialPositioning
              : null),
      activeAgentProfileId,
    );
    final headerTitle = _chatHeaderTitle(
      activeSkill,
      activeAgentProfileId,
      deepPositioning: _isDeepPositioning,
    );
    final startupJourney = _isStartupGuideRoute
        ? ref.watch(firstLaunchDeviceSetupControllerProvider)
        : null;
    final showsStartupGuide =
        startupJourney != null &&
        _hasStartupGuide(startupJourney) &&
        activeSkill == null &&
        (activeAgentProfileId == null ||
            activeAgentProfileId == standardCreationChatAgentProfileId);
    final agentFeatureId = _agentFeatureIdFor(
      activeAgentProfileId == null ? activeSkill : null,
      agentProfileId: activeAgentProfileId,
    );
    final requiresCatalogPreflight = _requiresCatalogPreflight(
      activeAgentProfileId,
    );
    final activeThreadId = chat.activeThreadId;
    final hasBackgroundTask = ref.watch(
      chatRunTrackerProvider.select(
        (tracker) =>
            activeThreadId != null &&
            tracker.taskLedger.any(
              (task) =>
                  task.kind == 'chat' &&
                  task.threadId == activeThreadId &&
                  !task.isTerminal &&
                  !agentTaskNeedsUserInput(task),
            ),
      ),
    );
    final fallbackToolRunId = chat.nextAction.agentRunId;
    final fallbackRunStatuses = <String, String?>{
      if (fallbackToolRunId != null) fallbackToolRunId: chat.agentRunStatus,
      if (activeThread != null)
        for (final run in activeThread.activeRuns)
          if (!run.isTerminal) run.agentRunId: run.status,
    };
    final agentCapabilities = ref.watch(
      mobileAgentCapabilityControllerProvider,
    );
    final featureAccess = agentCapabilities.accessFor(agentFeatureId);
    final capabilityUnavailable =
        requiresCatalogPreflight &&
        featureAccess.status == MobileAgentFeatureStatus.unavailable &&
        !chat.hasActiveThread &&
        chat.threads.isEmpty;
    final colors = HuahuoV3Theme.tokensOf(context);
    final voice = ref.watch(feedAiVoiceMessageControllerProvider).state;
    final voicePhase = V3ChatVoiceControlPhase.fromState(voice);
    final memoryLibrary = ref.watch(knowledgeLibraryControllerProvider);
    final activeMemoryNotes = _conversationMemoryNotes(memoryLibrary);
    final routeNoteId = _safeFeedItemId;
    final hasActiveRouteNote =
        routeNoteId != null &&
        activeMemoryNotes.any(
          (note) =>
              note.id == routeNoteId || note.copiedFromContentId == routeNoteId,
        );
    final entrySuggestionSets = showsStartupGuide
        ? ChatEntryFigmaSpec.startupSuggestionSets
        : hasActiveRouteNote
        ? ChatEntryFigmaSpec.noteSuggestionSets
        : entryPresentation.suggestionSets;
    final workbenchNotes = _activeWorkbenchNotes(memoryLibrary);
    final pendingWorkbenchMaterialCount = _workbenchMaterialsConsumed
        ? 0
        : widget.workbenchContext?.materialIds.length ?? 0;
    final fileAttachments = _fileAttachments.attachments;
    final resourceImageCache = ref.watch(resourceImageCacheProvider);
    final masterpieceMarkdown = activeSkill == WorkbenchChatSkill.masterpiece
        ? ref.watch(
            masterpieceControllerProvider.select(
              (controller) => controller.chatMarkdown,
            ),
          )
        : null;
    final threadActionsDisabled =
        chat.isSending ||
        chat.isLoading ||
        _sendPreflightInFlight ||
        _positioningReportSaving ||
        _fileAttachments.isUploading ||
        voice.isBusy ||
        voice.isCaptureActive;
    final newWindowDisabled =
        _sendPreflightInFlight ||
        _positioningReportSaving ||
        voice.isBusy ||
        voice.isCaptureActive;
    final contextMessage = _contextBannerMessage(
      chat,
      workbenchNotes,
      fileAttachments: fileAttachments,
      masterpieceMarkdown: masterpieceMarkdown,
      featureAccess: featureAccess,
      hasEstablishedThread: chat.hasActiveThread,
      requiresCatalogPreflight: requiresCatalogPreflight,
    );
    final hasPendingOutgoingMessage = chat.messages.any(
      (message) =>
          message.role == ChatMessageRole.user &&
          message.localDelivery == ChatLocalDeliveryState.pending,
    );
    final usesM05Chrome = ChatEntryFigmaSpec.enabled && !_isDeepPositioning;
    final usesSharedHeaderActions = usesM05Chrome || _isDeepPositioning;
    if (_showM05History) {
      final accountWideHistory = _usesAccountWideHistory(chatController);
      final deepHistoryController = accountWideHistory
          ? ref.watch(deepPositioningChatControllerProvider)
          : null;
      final historyControllers = <ChatController>[
        chatController,
        if (deepHistoryController != null) deepHistoryController,
      ];
      final historyThreads = _mergeChatHistoryThreads(historyControllers);
      final historyRefreshing = historyControllers.any(
        (controller) => controller.isRefreshingHistory,
      );
      final historyErrorCode = historyControllers
          .map((controller) => controller.historyRefreshErrorCode)
          .whereType<String>()
          .firstOrNull;
      return V3ChatHistorySurface(
        threads: historyThreads,
        loading: historyRefreshing && historyThreads.isEmpty,
        syncing: historyRefreshing,
        hasMore: historyControllers.any(
          (controller) => controller.hasMoreHistory,
        ),
        errorCode: historyErrorCode,
        onBack: _closeM05History,
        isRouteEntry: _historyIsRouteEntry,
        onNewConversation: _openNewChatWindow,
        onRetry: () => unawaited(_refreshM05History(force: true)),
        onLoadMore: () => unawaited(_refreshM05History(loadMore: true)),
        onSelect: (thread) => unawaited(_selectM05HistoryThread(thread)),
        onMore: (thread) => unawaited(_showM05ThreadActions(thread)),
      );
    }
    final showsM05Entry =
        (usesM05Chrome || _isDeepPositioning) &&
        !widget.isAgentAssistedCreationEntry &&
        _initialConversationResolved &&
        chat.lastErrorCode == null &&
        chat.messages.isEmpty &&
        !chat.hasActiveThread &&
        !chat.isLoading &&
        !chat.isSending &&
        workbenchNotes.isEmpty &&
        pendingWorkbenchMaterialCount == 0 &&
        (contextMessage == null ||
            _isDeepPositioning ||
            activeSkill == WorkbenchChatSkill.masterpiece) &&
        !capabilityUnavailable;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleChatScrollMetricsNotification,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleChatScrollNotification,
          child: LayoutBuilder(
            builder: (context, viewportConstraints) {
              final compactChatToolbar = viewportConstraints.maxWidth < 344;
              final page = V3PageScaffold(
                title: isNoteSheet ? '' : headerTitle,
                titleStyle: _isDeepPositioning
                    ? const TextStyle(
                        fontFamily: 'Noto Sans SC',
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      )
                    : null,
                topBarHeight: isNoteSheet
                    ? 60
                    : usesM05Chrome || _isDeepPositioning
                    ? 40
                    : 52,
                subtitle: isNoteSheet || usesM05Chrome || _isDeepPositioning
                    ? null
                    : _isDeepPositioning
                    ? '和 AI 对话，逐步澄清你的定位'
                    : '和 AI 对话，梳理想法与内容方向',
                inlineTitle: true,
                showBack: !isNoteSheet,
                inlineTitleLeading: null,
                onTitleTap: isNoteSheet ? null : _scrollToOldest,
                fallbackRoute: _fallbackRoute,
                backBehavior: V3BackBehavior.popThenFallback,
                trailing: isNoteSheet
                    ? null
                    : _isDeepPositioning
                    ? IconButton(
                        tooltip: '对话历史',
                        onPressed:
                            chatController.isAgentScopeResolved &&
                                !threadActionsDisabled
                            ? () => unawaited(_openM05History())
                            : null,
                        icon: Icon(
                          Icons.history_rounded,
                          size: 20,
                          color: colors.muted,
                        ),
                      )
                    : usesSharedHeaderActions
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: HuahuoSpacing.xs,
                        ),
                        child: ChatEntryHeaderActions(
                          historyEnabled:
                              chatController.isAgentScopeResolved &&
                              (!threadActionsDisabled ||
                                  (chat.isLoading && chat.messages.isEmpty)),
                          newConversationEnabled:
                              chatController.isAgentScopeResolved &&
                              !newWindowDisabled,
                          onHistory: () => unawaited(_openM05History()),
                          onNewConversation: _openNewChatWindow,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!compactChatToolbar) ...[
                            _ChatSkillBadge(
                              key: const ValueKey<String>(
                                'chat-active-agent-badge',
                              ),
                              skill: activeSkill,
                              agentProfileId: activeAgentProfileId,
                              fallbackLabel: '标准创作',
                            ),
                            const SizedBox(width: 4),
                          ],
                          IconButton(
                            tooltip: '会话列表',
                            icon: Icon(
                              LucideIcons.messagesSquare,
                              size: 21,
                              color: colors.ink,
                            ),
                            onPressed: threadActionsDisabled
                                ? null
                                : () => _showThreadList(context),
                          ),
                          IconButton(
                            tooltip: '新建会话',
                            icon: Icon(
                              LucideIcons.messageSquarePlus,
                              size: 21,
                              color: colors.ink,
                            ),
                            onPressed: newWindowDisabled
                                ? null
                                : _openNewChatWindow,
                          ),
                          IconButton(
                            tooltip: '刷新会话',
                            icon: Icon(
                              Icons.refresh_rounded,
                              size: 25,
                              color: colors.ink,
                            ),
                            onPressed: threadActionsDisabled
                                ? null
                                : () => unawaited(
                                    ref
                                        .read(_chatControllerProvider)
                                        .loadThreads(
                                          refresh: true,
                                          selectLatest: false,
                                        ),
                                  ),
                          ),
                        ],
                      ),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                bottomBarPadding: _isDeepPositioning
                    ? const EdgeInsets.fromLTRB(24, 6, 24, 16)
                    : const EdgeInsets.fromLTRB(16, 6, 16, 8),
                bottomBarUsesSafeArea: !usesM05Chrome,
                scrollController: _scrollController,
                showScrollbar: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.manual,
                bottomBar: V3ChatInputBar(
                  digitalTwinStyle: _isDeepPositioning,
                  controller: _text,
                  focusNode: _composerFocus,
                  hasText:
                      _hasText || _fileAttachments.readyAttachments.isNotEmpty,
                  isSubmissionInFlight:
                      _sendPreflightInFlight ||
                      _fileAttachments.isUploading ||
                      _positioningReportSaving,
                  isInputBusy: voice.isBusy,
                  enabled:
                      !capabilityUnavailable && !_fileAttachments.hasFailures,
                  canSubmit:
                      _initialConversationResolved &&
                      chatController.isAgentScopeResolved &&
                      chat.canSubmitUserTurn,
                  voicePhase: voicePhase,
                  voiceEnabled:
                      !capabilityUnavailable &&
                      !_sendPreflightInFlight &&
                      !_fileAttachments.isUploading &&
                      !_positioningReportSaving &&
                      _initialConversationResolved &&
                      chatController.isAgentScopeResolved &&
                      chat.canSubmitUserTurn,
                  entryMode: usesM05Chrome,
                  attachments: fileAttachments,
                  memoryNotes: activeMemoryNotes,
                  onPlus: () => _showPlusMenu(
                    context,
                    allowVideoUpload: activeAgentProfileId != null
                        ? activeAgentProfileId == 'video_analysis'
                        : activeSkill == WorkbenchChatSkill.videoAnalysis,
                  ),
                  onRemoveAttachment: _fileAttachments.remove,
                  onRetryAttachment: (attachment) =>
                      unawaited(_fileAttachments.retry(attachment.localId)),
                  onPreviewAttachment: _showLocalImagePreview,
                  onRemoveMemoryNote: (noteId) =>
                      _removeConversationAssetReference(chat, noteId),
                  onVoice: _handleVoice,
                  onSend: _sendMessage,
                ),
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasBackgroundTask) ...[
                          const V3LongRunningTaskNotice(),
                          const SizedBox(height: 12),
                        ],
                        if (contextMessage != null) ...[
                          _ConversationContextBanner(message: contextMessage),
                          const SizedBox(height: 18),
                        ],
                        if (showsM05Entry)
                          ChatEntrySurface(
                            showStartupGuide: showsStartupGuide,
                            onSkipStartupGuide: _skipStartupGuide,
                            enabled: !threadActionsDisabled,
                            greeting: entryPresentation.greeting,
                            supportingCopy: entryPresentation.supportingCopy,
                            suggestionSets: entrySuggestionSets,
                            helpLabel:
                                activeSkill == WorkbenchChatSkill.visualDesign
                                ? '什么是视觉参考？'
                                : null,
                            onHelp:
                                activeSkill == WorkbenchChatSkill.visualDesign
                                ? () => unawaited(_showVisualReferenceHelp())
                                : null,
                            emptyStateLabel: activeSkill == null
                                ? null
                                : '输入一个问题，开始一段新的对话。',
                            onSuggestion: _handleEntrySuggestion,
                          )
                        else if ((!_initialConversationResolved ||
                                chat.isLoading) &&
                            chat.messages.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 54),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      color: colors.ink,
                                      strokeWidth: 2.2,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '正在加载最近对话',
                                    style: TextStyle(
                                      color: colors.muted,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (!widget.isAgentAssistedCreationEntry &&
                            chat.messages.isEmpty)
                          _EmptyConversation(
                            hasError: chat.lastErrorCode != null,
                            errorCode: chat.lastErrorCode,
                            prompt: _isDeepPositioning
                                ? '从最近最想解决的一件事开始，和 AI 一起找到清晰定位。'
                                : capabilityUnavailable
                                ? '该能力发布后可在这里使用。'
                                : '输入一个问题，开始一段新的对话。',
                            onRetry: _retryConversation,
                          ),
                      ],
                    ),
                  ),
                  if (_initialConversationResolved &&
                      (chat.messages.isNotEmpty ||
                          (!hasPendingOutgoingMessage &&
                              chat.lastErrorCode == null)))
                    V3ChatConversationTimeline(
                      digitalTwinStyle: _isDeepPositioning,
                      threadId: activeThreadId,
                      messages: chat.displayMessages,
                      fallbackRunStatuses: fallbackRunStatuses,
                      fallbackToolRunId: fallbackToolRunId,
                      fallbackToolTrace: chat.assistantToolTrace,
                      isSending: chat.isSending,
                      isThreadPending: () => activeThread == null
                          ? false
                          : chatController.isThreadPending(activeThread),
                      assistantAnswerDrafts:
                          chatController.assistantAnswerDrafts,
                      runtimeInvocationReader: (threadId) =>
                          chatController.readRuntimeInvocationHistory(
                            threadId,
                            reportErrors: false,
                          ),
                      retryFailedMessageActionFor: (message) =>
                          chatController.canRetryFailedTextMessage(
                            message.messageId,
                          )
                          ? () => unawaited(
                              _retryFailedTextMessage(
                                chatController,
                                message.messageId,
                              ),
                            )
                          : null,
                      imageAttachmentsBuilder:
                          (context, attachments, generatedByAssistant) =>
                              V3ChatMessageImageGrid(
                                attachments: attachments,
                                resourceImageCache: resourceImageCache,
                                nativeFilePort: _nativeFilePort,
                                generatedByAssistant: generatedByAssistant,
                              ),
                      resourceAttachmentsBuilder: (context, attachments) =>
                          V3ChatMessageResourceList(attachments: attachments),
                      isCreatingNote: (message) =>
                          _creatingAssistantNoteIds.contains(message.messageId),
                      createNoteActionFor: (message) {
                        if (message.role != ChatMessageRole.assistant ||
                            message.localDelivery !=
                                ChatLocalDeliveryState.server ||
                            (message.visibleText?.trim().isNotEmpty != true &&
                                message.imageAttachments.isEmpty) ||
                            _createdAssistantNoteIds.contains(
                              message.messageId,
                            )) {
                          return null;
                        }
                        return () => _saveAssistantReplyAsNote(message);
                      },
                      onStreamingRebuild: () {
                        rebuildMetrics.recordRebuild('chat_streaming_bubble');
                        _scheduleScrollToBottom(immediate: true);
                      },
                      onRunRebuild: () {
                        rebuildMetrics.recordRebuild('chat_current_run');
                        _scheduleScrollToBottom();
                      },
                      suppressStandaloneActivity: hasPendingOutgoingMessage,
                    ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (voice.isCaptureActive &&
                            !usesM05Chrome &&
                            !_isDeepPositioning) ...[
                          _VoiceRecordingPanel(
                            state: voice,
                            onFinish: _finishVoice,
                            onCancel: _cancelVoice,
                          ),
                          const SizedBox(height: 18),
                        ],
                        if (chat.messages.isNotEmpty &&
                            chat.lastErrorCode != null) ...[
                          _ChatStatusBanner(errorCode: chat.lastErrorCode!),
                          const SizedBox(height: 18),
                        ],
                        if (_showsServerAction(chat.nextAction.type)) ...[
                          _ServerActionBanner(
                            action: chat.nextAction,
                            isBusy:
                                voice.status ==
                                VoiceMessageControllerStatus.asrPolling,
                            onAction: switch (chat.nextAction.type) {
                              ChatNextActionType.pollTask ||
                              ChatNextActionType.pollAgentRun ||
                              ChatNextActionType.pollThread => () => unawaited(
                                ref
                                    .read(_chatControllerProvider)
                                    .refreshPendingTask(),
                              ),
                              ChatNextActionType.pollAsr => _refreshVoiceAsr,
                              ChatNextActionType.retryAsr => _retryVoiceAsr,
                              _ => null,
                            },
                          ),
                          const SizedBox(height: 18),
                        ],
                        if (chat.messages.isEmpty && !chat.isLoading)
                          const SizedBox(height: 38),
                      ],
                    ),
                  ),
                ],
              );
              if (!isNoteSheet) return page;
              return Stack(
                children: <Widget>[
                  page,
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: _V3NoteChatSheetHeader(
                      onClose: _closeNoteSheet,
                      onExpand:
                          threadActionsDisabled || widget.onSheetExpand == null
                          ? null
                          : _expandNoteSheet,
                      onNewConversation:
                          threadActionsDisabled || newWindowDisabled
                          ? null
                          : _openNewChatWindow,
                      onHistory: threadActionsDisabled
                          ? null
                          : () => unawaited(_openM05History()),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    if (widget.workbenchContext?.skill == WorkbenchChatSkill.positioningLv1 ||
        ref.read(_chatControllerProvider).activeAgentProfileId ==
            'positioning_lv1') {
      await context.push(AppRoutePaths.positioningReport);
      return;
    }
    if (_sendSubmissionInFlight || !_initialConversationResolved) return;
    final controller = ref.read(_chatControllerProvider);
    if (!controller.state.canSubmitUserTurn) return;
    if (_fileAttachments.isUploading) {
      showV3Snack(context, '资料上传完成后才能发送');
      return;
    }
    if (_fileAttachments.hasFailures) {
      showV3Snack(context, '请重试或移除上传失败的资料');
      return;
    }
    final admittedThreadId = controller.state.activeThreadId;
    final draft = _text.value;
    final value = draft.text.trim();
    _sendSubmissionInFlight = true;
    setState(() => _sendPreflightInFlight = true);
    try {
      final activeThread = controller.state.activeThreadId == null
          ? null
          : controller.state.threads
                .where(
                  (thread) =>
                      thread.threadId == controller.state.activeThreadId,
                )
                .firstOrNull;
      final lockedAgentProfileId =
          activeThread?.agentProfileId ?? controller.activeAgentProfileId;
      if (_requiresCatalogPreflight(lockedAgentProfileId)) {
        final featureAccess = await ref
            .read(mobileAgentCapabilityControllerProvider)
            .ensureFeature(
              _agentFeatureIdFor(
                widget.workbenchContext?.skill,
                agentProfileId: null,
              ),
            );
        if (!mounted) return;
        if (featureAccess.status == MobileAgentFeatureStatus.unavailable) {
          showV3Snack(context, _agentUnavailableMessage(featureAccess));
          return;
        }
      }
      final chatController = controller;
      final contextLineId = _outgoingContextLineId(chatController.state);
      final library = ref.read(knowledgeLibraryControllerProvider);
      final memoryNotes = _conversationMemoryNotes(library);
      final workbenchNotes = _activeWorkbenchNotes(library);
      final pendingWorkbenchMaterialCount = _workbenchMaterialsConsumed
          ? 0
          : widget.workbenchContext?.materialIds.length ?? 0;
      if (pendingWorkbenchMaterialCount > 0 &&
          workbenchNotes.length != pendingWorkbenchMaterialCount) {
        showV3Snack(context, '所选资产正在同步，请稍后重新选择');
        return;
      }
      final selectedNotes = <V3FeedItem>[...memoryNotes, ...workbenchNotes];
      if (!await _synchronizeSelectedNotes(selectedNotes)) {
        if (mounted) {
          showV3Snack(
            context,
            selectedNotes.any((note) => note.isReadOnly)
                ? '请先沉淀到我的资产，再在聊一聊中引用'
                : '所选笔记未能同步到云端，本次消息未发送',
          );
        }
        return;
      }
      if (!mounted) return;
      final synchronizedMemoryNotes = <V3FeedItem>[
        for (final note in memoryNotes)
          if (library.noteForId(note.id) case final synchronized?) synchronized,
      ];
      final synchronizedWorkbenchNotes = <V3FeedItem>[
        for (final note in workbenchNotes)
          if (library.noteForId(note.id) case final synchronized?) synchronized,
      ];
      final routeFeedItemId = _safeFeedItemId;
      final routeConversationAssetId =
          _routeFeedItemEnabled && routeFeedItemId != null
          ? synchronizedMemoryNotes
                .where(
                  (note) =>
                      note.id == routeFeedItemId ||
                      note.copiedFromContentId == routeFeedItemId,
                )
                .firstOrNull
                ?.id
          : null;
      final workbenchContext = _effectiveWorkbenchContext(chatController.state);
      if (workbenchContext?.skill == WorkbenchChatSkill.masterpiece) {
        final masterpiece = ref.read(masterpieceControllerProvider);
        if (!await masterpiece.prepareChat()) {
          if (mounted) showV3Snack(context, '请先保存或处理代表作草稿，并确认云端内容读取成功后再发送');
          return;
        }
        if (!mounted ||
            !identical(masterpiece, ref.read(masterpieceControllerProvider))) {
          return;
        }
      }
      final masterpieceMarkdown =
          workbenchContext?.skill == WorkbenchChatSkill.masterpiece
          ? ref.read(masterpieceControllerProvider).chatMarkdown
          : null;
      final chatContext = _buildOutgoingContext(
        contentLineId: contextLineId,
        memoryNotes: synchronizedMemoryNotes,
        workbenchContext: workbenchContext,
        workbenchNotes: synchronizedWorkbenchNotes,
        masterpieceMarkdown: masterpieceMarkdown,
      );
      if (chatContext == null) {
        showV3Snack(context, '当前上下文无法安全发送，请移除后重试');
        return;
      }
      if (value.isEmpty && chatContext.references.isEmpty) {
        showV3Snack(context, '先输入一个问题或添加资料');
        return;
      }
      if (!identical(ref.read(_chatControllerProvider), chatController) ||
          chatController.state.activeThreadId != admittedThreadId ||
          !chatController.state.canSubmitUserTurn) {
        showV3Snack(context, '会话状态已变化，请重新发送');
        return;
      }
      _dismissComposer();
      final consumesWorkbenchMaterials = pendingWorkbenchMaterialCount > 0;
      final submittedMemoryNoteIds = <String>{
        for (final note in memoryNotes) note.id,
      };
      final submittedAttachments = List<ChatFileAttachment>.unmodifiable(
        _fileAttachments.readyAttachments,
      );
      final submittedResourceAttachments =
          List<ChatResourceAttachment>.unmodifiable(
            _fileAttachments.readyResourceAttachments,
          );
      if (consumesWorkbenchMaterials) {
        setState(() => _workbenchMaterialsConsumed = true);
      }
      final positioningAssistantIdsBeforeSend = _persistsDeepPositioningReport
          ? <String>{
              for (final message in chatController.state.messages)
                if (message.role == ChatMessageRole.assistant)
                  message.messageId,
            }
          : const <String>{};
      setState(() => _sendPreflightInFlight = false);
      _text.clear();
      final ordinaryEntryPointForSubmission = _ordinaryEntryPoint;
      final ordinaryEntryRepositoryForSubmission =
          ordinaryEntryPointForSubmission == null
          ? null
          : ref.read(chatThreadAliasRepositoryProvider);
      final sessionStoreForSubmission = ref.read(sessionStoreProvider);
      final sessionForSubmission = sessionStoreForSubmission.state;
      final userIdForSubmission = sessionForSubmission.user?.userId;
      final workspaceIdForSubmission =
          ordinaryEntryRepositoryForSubmission?.workspaceScope;
      final expiresAtForSubmission = sessionForSubmission.expiresAt;
      final sent = await _submitUserTextTurn(
        chatController,
        () => chatController.sendText(
          value,
          contentLineId: contextLineId,
          context: chatContext,
          resourceAttachments: submittedResourceAttachments,
          assetReferences: <ChatAssetReference>[
            for (final note in selectedNotes)
              ChatAssetReference(assetId: note.id, title: note.title),
          ],
          conversationAssetId: routeConversationAssetId,
        ),
      );
      final establishedThreadId = chatController.state.activeThreadId;
      if (establishedThreadId != null &&
          ordinaryEntryPointForSubmission != null &&
          ordinaryEntryRepositoryForSubmission != null &&
          userIdForSubmission != null &&
          workspaceIdForSubmission != null &&
          sessionStoreForSubmission.state.user?.userId == userIdForSubmission &&
          readyWorkspaceId(sessionStoreForSubmission.state) ==
              workspaceIdForSubmission &&
          sessionStoreForSubmission.state.expiresAt == expiresAtForSubmission) {
        _persistOrdinaryEntryThread(
          controller: chatController,
          repository: ordinaryEntryRepositoryForSubmission,
          entryPoint: ordinaryEntryPointForSubmission,
          threadId: establishedThreadId,
        );
      }
      if (!mounted) return;
      if (sent) {
        if (establishedThreadId != null) {
          _rememberDailyTopicContext(establishedThreadId);
        }
        if (_pendingContentLineId != null) {
          setState(() {
            _pendingContentLineId = null;
            _pendingContextLabel = null;
          });
        }
        for (final attachment in submittedAttachments) {
          _fileAttachments.remove(attachment.localId);
        }
        setState(() {
          _pendingMemoryNoteIds = List<String>.unmodifiable(
            _pendingMemoryNoteIds.where(
              (noteId) => !submittedMemoryNoteIds.contains(noteId),
            ),
          );
          _routeFeedItemEnabled = false;
        });
        _scheduleScrollToBottom();
        if (_persistsDeepPositioningReport && establishedThreadId != null) {
          _pendingPositioningReportThreadId = establishedThreadId;
          _positioningAssistantIdsBeforeSend =
              positioningAssistantIdsBeforeSend;
          _schedulePositioningReportReconciliation(chatController.state);
        }
      } else {
        if (consumesWorkbenchMaterials) {
          setState(() => _workbenchMaterialsConsumed = false);
        }
        final errorCode = chatController.state.lastErrorCode;
        if (_isExplicitAgentProfileRejection(errorCode)) {
          final capabilities = ref.read(
            mobileAgentCapabilityControllerProvider,
          );
          capabilities.invalidateCatalogCache();
          unawaited(
            capabilities.ensureFeature(
              _agentFeatureIdFor(
                activeThread?.workbenchSkill ?? widget.workbenchContext?.skill,
                agentProfileId: lockedAgentProfileId,
              ),
            ),
          );
        }
        if (_text.text.isEmpty && draft.text.isNotEmpty) _text.value = draft;
      }
    } finally {
      _sendSubmissionInFlight = false;
      if (mounted && _sendPreflightInFlight) {
        setState(() => _sendPreflightInFlight = false);
      }
    }
  }

  Future<void> _retryFailedTextMessage(
    ChatController controller,
    String messageId,
  ) async {
    final accepted = await _submitUserTextTurn(
      controller,
      () => controller.retryFailedTextMessage(messageId),
    );
    if (!accepted ||
        !mounted ||
        !identical(controller, ref.read(_chatControllerProvider)) ||
        !_routeFeedItemEnabled) {
      return;
    }
    setState(() => _routeFeedItemEnabled = false);
  }

  void _handleEntrySuggestion(ChatEntrySuggestionSpec suggestion) {
    switch (suggestion.kind) {
      case ChatEntrySuggestionKind.prompt:
        _setEntryPrompt(suggestion.label);
        unawaited(_sendMessage());
      case ChatEntrySuggestionKind.notePicker:
        unawaited(
          _showMemoryNoteReferenceSheet(
            context,
            autoSendPrompt: suggestion.label,
          ),
        );
    }
  }

  void _setEntryPrompt(String prompt) {
    _text.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
  }

  Future<void> _saveAssistantReplyAsNote(ChatMessage message) async {
    if (_creatingAssistantNoteIds.contains(message.messageId) ||
        _createdAssistantNoteIds.contains(message.messageId)) {
      return;
    }
    setState(() => _creatingAssistantNoteIds.add(message.messageId));
    final result = await ref
        .read(chatAssistantNoteCreatorProvider)
        .create(message);
    if (!mounted) return;
    setState(() {
      _creatingAssistantNoteIds.remove(message.messageId);
      if (result.isSuccess) {
        _createdAssistantNoteIds.add(message.messageId);
      }
    });
    final note = result.note;
    if (!result.isSuccess || note == null) {
      showV3Snack(context, _assistantAssetFailureMessage(result.errorCode));
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已保存到我的资产'),
          action: SnackBarAction(
            label: '去查看',
            onPressed: () =>
                context.push('/v3/feed/items/${Uri.encodeComponent(note.id)}'),
          ),
        ),
      );
  }

  ChatContextEnvelope? _buildOutgoingContext({
    required String? contentLineId,
    required List<V3FeedItem> memoryNotes,
    required WorkbenchChatContext? workbenchContext,
    required List<V3FeedItem> workbenchNotes,
    required String? masterpieceMarkdown,
  }) {
    final references = <ChatContextReference>[];
    for (final note in memoryNotes) {
      final reference = _exactHNoteChatReference(note);
      if (reference == null) return null;
      references.add(reference);
    }
    for (final note in workbenchNotes) {
      final reference = _exactHNoteChatReference(note);
      if (reference == null) return null;
      references.add(reference);
    }
    for (final attachment in _fileAttachments.readyAttachments) {
      final resourceId = attachment.resourceId;
      if (resourceId == null) return null;
      references.add(
        ChatContextReference(
          type: attachment.isImage
              ? ChatContextReferenceType.image
              : ChatContextReferenceType.file,
          id: resourceId,
        ),
      );
    }
    final skill = workbenchContext?.skill;
    final purpose = switch (skill) {
      WorkbenchChatSkill.positioningLv1 => ChatContextPurpose.deepPositioning,
      WorkbenchChatSkill.socialPositioning =>
        ChatContextPurpose.socialPositioning,
      _ when _isDeepPositioning => ChatContextPurpose.socialPositioning,
      _ => _contextPurposeForSkill(skill),
    };
    final normalizedMasterpiece = masterpieceMarkdown?.trim();
    final masterpieceSnapshot =
        skill == WorkbenchChatSkill.masterpiece &&
            normalizedMasterpiece != null &&
            normalizedMasterpiece.isNotEmpty
        ? ChatLocalDraftSnapshot.create(
            kind: 'masterpiece_markdown',
            content: normalizedMasterpiece,
            revision: 'current',
          )
        : null;
    if (skill == WorkbenchChatSkill.masterpiece &&
        normalizedMasterpiece?.isNotEmpty == true &&
        masterpieceSnapshot == null) {
      return null;
    }
    final entityId = skill?.routeValue ?? memoryNotes.firstOrNull?.id;
    return ChatContextEnvelope.create(
      purpose: purpose,
      contentLineId: contentLineId,
      entryPoint: ChatContextEntryPoint(
        surface: skill == null ? 'feed_chat' : 'workbench_chat',
        entityType: entityId == null
            ? null
            : skill == null
            ? 'memory_note'
            : 'skill',
        entityId: entityId,
      ),
      references: references,
      includeAccountProfile: true,
      localDraftSnapshot: masterpieceSnapshot,
    );
  }

  WorkbenchChatContext? _effectiveWorkbenchContext(ChatControllerState state) {
    final activeThreadId = state.activeThreadId;
    final historicalThread = activeThreadId == null
        ? null
        : state.threads
              .where((thread) => thread.threadId == activeThreadId)
              .firstOrNull;
    final historicalSkill =
        historicalThread?.workbenchSkill ??
        WorkbenchChatSkill.fromAgentProfileId(historicalThread?.agentProfileId);
    final skill =
        historicalSkill ??
        (historicalThread == null ? widget.workbenchContext?.skill : null);
    if (skill == null) return null;
    final routeContext = widget.workbenchContext;
    return WorkbenchChatContext(
      skill: skill,
      materialIds: historicalThread == null
          ? routeContext?.materialIds ?? const <String>[]
          : const <String>[],
    );
  }

  String? get _safeContentLineId {
    final value = widget.contentLineId?.trim();
    if (value == null || !isSafeChatIdentifier(value)) return null;
    return value;
  }

  String? get _safeThreadId {
    return _initialThreadId;
  }

  bool get _isExplicitNewWindow {
    final value = widget.windowId?.trim();
    return value != null && isSafeChatIdentifier(value);
  }

  bool get _hasSourceBoundEntry =>
      _safeContentLineId != null ||
      _safeFeedItemId != null ||
      widget.workbenchContext?.materialIds.isNotEmpty == true;

  OrdinaryChatEntryPoint? get _ordinaryEntryPoint {
    if (widget.conversationPurpose != ChatConversationPurpose.general ||
        widget.workbenchContext != null ||
        widget.isAgentAssistedCreationEntry) {
      return null;
    }
    return widget.ordinaryEntryPoint;
  }

  bool get _shouldRestoreOrdinaryEntry =>
      _ordinaryEntryPoint != null &&
      _safeThreadId == null &&
      !_isExplicitNewWindow &&
      !_isStartupGuideRoute &&
      widget.launchMode != ChatLaunchMode.history;

  ChatLaunchMode get _effectiveLaunchMode {
    if (_safeThreadId != null) return ChatLaunchMode.exactThread;
    if (widget.launchMode == ChatLaunchMode.history) {
      return ChatLaunchMode.history;
    }
    if (_isExplicitNewWindow ||
        _hasSourceBoundEntry ||
        widget.workbenchContext != null ||
        _isDeepPositioning) {
      return ChatLaunchMode.fresh;
    }
    return widget.launchMode;
  }

  bool _requiresCatalogPreflight(String? agentProfileId) {
    if (knownPublicChatAgentProfileId(agentProfileId) != null) return false;
    // General chat uses the direct facade's documented public fallback. Deep
    // positioning and a malformed specialist entry without a public Profile
    // have no equivalent direct binding, so retain the defensive preflight.
    return _isDeepPositioning || widget.workbenchContext != null;
  }

  bool get _isDeepPositioning =>
      widget.conversationPurpose == ChatConversationPurpose.deepPositioning;

  bool get _persistsDeepPositioningReport =>
      _isDeepPositioning &&
      widget.workbenchContext?.skill != WorkbenchChatSkill.positioningLv1;

  void _schedulePositioningReportReconciliation(ChatControllerState chat) {
    if (!_persistsDeepPositioningReport || _positioningReportSaving) return;
    final threadId = _pendingPositioningReportThreadId;
    if (threadId == null || chat.activeThreadId != threadId) return;
    ChatMessage? durableAssistant;
    for (final message in chat.messages.reversed) {
      if (message.threadId == threadId &&
          message.role == ChatMessageRole.assistant &&
          message.localDelivery == ChatLocalDeliveryState.server &&
          message.status != 'streaming' &&
          message.visibleText?.trim().isNotEmpty == true &&
          !_positioningAssistantIdsBeforeSend.contains(message.messageId)) {
        durableAssistant = message;
        break;
      }
    }
    if (durableAssistant == null ||
        _scheduledPositioningAssistantMessageId == durableAssistant.messageId) {
      return;
    }
    final assistantMessageId = durableAssistant.messageId;
    _scheduledPositioningAssistantMessageId = assistantMessageId;
    unawaited(_reconcilePositioningReport(threadId, assistantMessageId));
  }

  Future<void> _reconcilePositioningReport(
    String threadId,
    String assistantMessageId,
  ) async {
    final chat = ref.read(_chatControllerProvider).state;
    if (_pendingPositioningReportThreadId != threadId ||
        chat.activeThreadId != threadId ||
        !chat.messages.any(
          (message) =>
              message.messageId == assistantMessageId &&
              message.role == ChatMessageRole.assistant &&
              message.localDelivery == ChatLocalDeliveryState.server &&
              message.status != 'streaming',
        )) {
      _scheduledPositioningAssistantMessageId = null;
      return;
    }
    setState(() => _positioningReportSaving = true);
    final lifecycle = ref.read(positioningLifecycleCoordinatorProvider);
    if (lifecycle != null) {
      await lifecycle.continueRecovery();
      if (!mounted) return;
      setState(() => _positioningReportSaving = false);
      _pendingPositioningReportThreadId = null;
      _positioningAssistantIdsBeforeSend = const <String>{};
      _scheduledPositioningAssistantMessageId = null;
      return;
    }
    final reportSaved = await ref
        .read(deepPositioningControllerProvider)
        .saveConversation(
          _positioningEntries(chat.messages),
          further: _positioningSessionHadReport,
        );
    if (!mounted) return;
    setState(() => _positioningReportSaving = false);
    _pendingPositioningReportThreadId = null;
    _positioningAssistantIdsBeforeSend = const <String>{};
    _scheduledPositioningAssistantMessageId = null;
    if (!reportSaved) {
      showV3Snack(context, '对话已完成，定位报告暂未更新');
    }
  }

  String _agentFeatureIdFor(
    WorkbenchChatSkill? skill, {
    String? agentProfileId,
  }) {
    if (skill == WorkbenchChatSkill.positioningLv1) {
      return 'positioning.initial';
    }
    if (_isDeepPositioning) return 'deep_positioning';
    switch (knownPublicChatAgentProfileId(agentProfileId)) {
      case 'self_media_creation':
        return 'creation.free';
      case 'self_media_creation_standard':
        return 'chat.general';
      case 'renshe_content':
        return 'workbench.persona';
      case 'huoke_content':
        return 'workbench.lead_content';
      case 'visual_chat':
        return 'visual.chat';
      case 'video_analysis':
        return 'video_analysis';
      case 'positioning_lv1':
        return 'positioning.initial';
      case 'positioning_lv2':
        return 'deep_positioning';
      case 'book_writing':
        return 'book.writing';
      case 'faya_germination':
        return 'note.sprout';
      case null:
        break;
    }
    return switch (skill) {
      WorkbenchChatSkill.persona => 'workbench.persona',
      WorkbenchChatSkill.lead => 'workbench.lead_content',
      WorkbenchChatSkill.visualDesign => 'visual.chat',
      WorkbenchChatSkill.videoAnalysis => 'video_analysis',
      WorkbenchChatSkill.positioningLv1 => 'positioning.initial',
      WorkbenchChatSkill.socialPositioning => 'deep_positioning',
      WorkbenchChatSkill.masterpiece => 'book.writing',
      null => 'chat.general',
    };
  }

  String get _fallbackRoute {
    final skill = widget.workbenchContext?.skill;
    if (skill == WorkbenchChatSkill.masterpiece) return '/v3/masterpiece';
    if (_isDeepPositioning || skill != null) return '/v3/workbench';
    return '/v3/feed';
  }

  AutoDisposeChangeNotifierProvider<ChatController>
  get _chatControllerProvider => _isDeepPositioning
      ? deepPositioningChatControllerProvider
      : feedAiChatControllerProvider;

  void _retryConversation() {
    unawaited(_prepareCapabilityAndLoad(forceRefresh: true));
  }

  String? get _activeRouteContentLineId => _safeContentLineId;

  String? get _safeFeedItemId {
    final value = widget.feedItemId?.trim();
    if (value == null || !isSafeChatIdentifier(value)) return null;
    return value;
  }

  String? _outgoingContextLineId(ChatControllerState chat) {
    return _pendingContentLineId ??
        (chat.hasActiveThread ? null : _activeRouteContentLineId);
  }

  V3FeedItem? get _activeRouteFeedItem {
    final id = _routeFeedItemEnabled ? _safeFeedItemId : null;
    if (id == null) return null;
    final library = ref.read(knowledgeLibraryControllerProvider);
    return _chatReferenceableNoteForId(library, id);
  }

  List<V3FeedItem> _conversationMemoryNotes(
    KnowledgeLibraryController library,
  ) {
    if (_pendingMemoryNoteIds.isNotEmpty) {
      return <V3FeedItem>[
        for (final id in _pendingMemoryNoteIds)
          if (_chatReferenceableNoteForId(library, id) case final note?) note,
      ];
    }
    if (!_initialConversationResolved) {
      return const <V3FeedItem>[];
    }
    final routeNote = _activeRouteFeedItem;
    return routeNote == null ? const <V3FeedItem>[] : <V3FeedItem>[routeNote];
  }

  void _removeConversationAssetReference(
    ChatControllerState state,
    String noteId,
  ) {
    if (_pendingMemoryNoteIds.contains(noteId)) {
      setState(() {
        _pendingMemoryNoteIds = <String>[
          for (final id in _pendingMemoryNoteIds)
            if (id != noteId) id,
        ];
      });
      return;
    }
    final threadId = state.activeThreadId;
    if (threadId != null) {
      ref
          .read(chatThreadAliasRepositoryProvider)
          .removeThreadAssetReference(scene: state.scene, threadId: threadId);
    }
    setState(() {
      _routeFeedItemEnabled = false;
    });
  }

  List<V3FeedItem> _activeWorkbenchNotes(KnowledgeLibraryController library) {
    if (_workbenchMaterialsConsumed) return const <V3FeedItem>[];
    final context = widget.workbenchContext;
    if (context == null) return const <V3FeedItem>[];
    return <V3FeedItem>[
      for (final id in context.materialIds)
        if (_chatReferenceableNoteForId(library, id) case final note?) note,
    ];
  }

  V3FeedItem? _chatReferenceableNoteForId(
    KnowledgeLibraryController library,
    String id,
  ) {
    final note = library.noteForId(id);
    if (note == null || !note.isReadOnly) return note;

    V3FeedItem? depositedCopy;
    for (final candidate in library.mineNotes) {
      if (candidate.copiedFromContentId != note.id) continue;
      depositedCopy ??= candidate;
      if (_exactHNoteChatReference(candidate) != null) return candidate;
    }
    return depositedCopy ?? note;
  }

  Future<bool> _synchronizeSelectedNotes(Iterable<V3FeedItem> notes) async {
    final library = ref.read(knowledgeLibraryControllerProvider);
    final noteIds = <String>{};
    final selected = <V3FeedItem>[];
    var needsRemoteReconciliation = false;
    for (final note in notes) {
      if (!noteIds.add(note.id)) {
        continue;
      }
      selected.add(note);
      needsRemoteReconciliation =
          needsRemoteReconciliation || _exactHNoteChatReference(note) == null;
    }
    if (needsRemoteReconciliation) {
      await library.reconcileRemoteNotesForChatReference();
    }
    for (final selectedNote in selected) {
      final current = library.noteForId(selectedNote.id);
      if (current == null) return false;
      if (_exactHNoteChatReference(current) != null) continue;
      if (current.isReadOnly) return false;
      await library.syncNote(current.id);
      final synchronized = library.noteForId(current.id);
      if (synchronized == null ||
          _exactHNoteChatReference(synchronized) == null) {
        return false;
      }
    }
    return true;
  }

  ChatContextReference? _exactHNoteChatReference(V3FeedItem note) {
    final noteId = note.remoteNoteId?.trim();
    final revisionId = note.rawPartRevisionId?.trim();
    if (note.syncState != NoteSyncState.synced ||
        noteId == null ||
        revisionId == null ||
        !isSafeChatIdentifier(noteId) ||
        !isSafeChatIdentifier(revisionId)) {
      return null;
    }
    return ChatContextReference(
      type: ChatContextReferenceType.material,
      id: noteId,
      revision: revisionId,
    );
  }

  String? _contextBannerMessage(
    ChatControllerState chat,
    List<V3FeedItem> workbenchNotes, {
    required List<ChatFileAttachment> fileAttachments,
    required String? masterpieceMarkdown,
    required MobileAgentFeatureAccess featureAccess,
    required bool hasEstablishedThread,
    required bool requiresCatalogPreflight,
  }) {
    if (fileAttachments.any(
      (attachment) => attachment.status == ChatFileAttachmentStatus.uploading,
    )) {
      return '正在上传资料，完成后会作为本次对话上下文发送。';
    }
    if (fileAttachments.any(
      (attachment) => attachment.status == ChatFileAttachmentStatus.failed,
    )) {
      return '有资料上传失败，请重试或移除后再发送。';
    }
    if (workbenchNotes.isNotEmpty) {
      final exactCount = workbenchNotes
          .where((note) => _exactHNoteChatReference(note) != null)
          .length;
      if (exactCount != workbenchNotes.length) {
        return '所选笔记尚未完成同步，当前不会发送正文或本地路径。';
      }
      return null;
    }
    if (masterpieceMarkdown?.trim().isNotEmpty == true) {
      return '已带入当前代表作正文，将与本条消息一起分析。';
    }
    if (_isDeepPositioning) {
      return '定位对话已开启。AI 会根据你的回答逐步追问经历、优势、服务对象与目标。';
    }
    final pending = _pendingContextLabel;
    if (pending != null) {
      return '已选择$pending上下文；尚未同步，本次仅发送你输入的文字。';
    }
    if (_activeRouteContentLineId != null && !chat.hasActiveThread) {
      return '已带入本次转写上下文，首条消息会创建关联会话。';
    }
    if (widget.workbenchContext != null) {
      if (requiresCatalogPreflight &&
          !featureAccess.isAvailable &&
          !hasEstablishedThread) {
        return _agentUnavailableMessage(featureAccess);
      }
      return null;
    }
    if (requiresCatalogPreflight &&
        !featureAccess.isAvailable &&
        !hasEstablishedThread) {
      return _agentUnavailableMessage(featureAccess);
    }
    return null;
  }

  void _scheduleScrollToEntry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    });
  }

  void _scheduleScrollToBottom({bool force = false, bool immediate = false}) {
    if (_isDraggingConversation || (!force && !_followsLatest)) return;
    _pendingForcedScroll = _pendingForcedScroll || force;
    _pendingImmediateScroll = _pendingImmediateScroll || immediate;
    if (_scrollToBottomScheduled) return;
    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final forced = _pendingForcedScroll;
      final useImmediateScroll = _pendingImmediateScroll;
      _scrollToBottomScheduled = false;
      _pendingForcedScroll = false;
      _pendingImmediateScroll = false;
      if (!mounted ||
          !_scrollController.hasClients ||
          _isDraggingConversation ||
          (!forced && !_followsLatest)) {
        return;
      }
      if (useImmediateScroll) {
        final generation = ++_immediateScrollGeneration;
        _jumpToBottomWithoutAnimation(force: forced, generation: generation);
        return;
      }
      final target = _scrollController.position.maxScrollExtent;
      if ((target - _scrollController.position.pixels).abs() < 0.5) return;
      _scrollController.animateTo(
        target,
        duration: V3MotionTokens.emphasized,
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _jumpToBottomWithoutAnimation({
    required bool force,
    required int generation,
    int remainingLayoutPasses = 4,
  }) {
    if (generation != _immediateScrollGeneration ||
        !mounted ||
        !_scrollController.hasClients ||
        _isDraggingConversation ||
        (!force && !_followsLatest)) {
      return;
    }
    final target = _scrollController.position.maxScrollExtent;
    if ((target - _scrollController.position.pixels).abs() >= 0.5) {
      _scrollController.jumpTo(target);
    }
    if (remainingLayoutPasses <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottomWithoutAnimation(
        force: force,
        generation: generation,
        remainingLayoutPasses: remainingLayoutPasses - 1,
      );
    });
  }

  void _scrollToOldest() {
    FocusManager.instance.primaryFocus?.unfocus();
    _followsLatest = false;
    _keepLatestVisibleAfterSubmission = false;
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: V3MotionTokens.deliberate,
      curve: Curves.easeOutCubic,
    );
  }

  void _handleComposerFocusChanged() {
    if (_composerFocus.hasFocus) _scheduleScrollToBottom();
  }

  bool _handleChatScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _immediateScrollGeneration += 1;
      _isDraggingConversation = true;
      _keepLatestVisibleAfterSubmission = false;
      _followsLatest = false;
    }
    if (notification is ScrollEndNotification && _isDraggingConversation) {
      _isDraggingConversation = false;
      _followsLatest = notification.metrics.extentAfter <= 24;
    }
    return false;
  }

  bool _handleChatScrollMetricsNotification(
    ScrollMetricsNotification notification,
  ) {
    if (_keepLatestVisibleAfterSubmission) {
      _scheduleScrollToBottom(immediate: true);
    }
    return false;
  }

  void _dismissComposer() {
    if (!_composerFocus.hasFocus) return;
    _keepLatestVisibleAfterSubmission = true;
    _followsLatest = true;
    _composerFocus.unfocus();
  }

  Future<void> _refreshCompletedConversation(String threadId) async {
    final controller = ref.read(_chatControllerProvider);
    if (controller.state.activeThreadId != threadId) return;
    await controller.selectThread(threadId, forceRemote: true);
    if (!mounted) return;
    _scheduleScrollToBottom();
    _acknowledgeVisibleChatResult(threadId);
  }

  Future<void> _restoreRouteThreadOnForeground(String threadId) async {
    final controller = ref.read(_chatControllerProvider);
    await controller.selectThread(
      threadId,
      forceRemote:
          _isDeepPositioning ||
          controller.shouldRefreshThreadOnForeground(threadId),
      allowUnassignedPurposeHydration: _isDeepPositioning,
    );
    if (!mounted || controller.state.activeThreadId != threadId) return;
    _scheduleScrollToBottom(force: true, immediate: true);
    _acknowledgeVisibleChatResult(threadId);
  }

  void _acknowledgeVisibleChatResult(String threadId) {
    if (!_initialConversationResolved || _showM05History) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_routeVisible ||
          !_initialConversationResolved ||
          _showM05History ||
          !ref.read(appActivityCoordinatorProvider).state.isForeground) {
        return;
      }
      final state = ref.read(_chatControllerProvider).state;
      if (state.activeThreadId != threadId) return;
      final showsRetryableFailure =
          state.status == ChatControllerStatus.failed &&
          state.lastErrorCode != null;
      final failedTaskId = showsRetryableFailure
          ? state.turnState.agentRunId?.trim()
          : null;
      final evidence = pendingMessageChatResultEvidence(
        threadId: threadId,
        messages: state.displayMessages,
        taskLedger: ref.read(chatRunTrackerProvider).taskLedger,
        pendingMessages: ref.read(pendingMessageProjectionProvider).items,
        visibleFailedTaskId: failedTaskId,
      );
      if (evidence.matchingTaskIds.isEmpty) return;
      unawaited(
        ref
            .read(pendingMessageActionsProvider)
            .acknowledgeResultShown(
              targetType: 'thread',
              targetId: threadId,
              matchingTaskIds: evidence.matchingTaskIds,
              durableSucceededTaskIds: evidence.durableSucceededTaskIds,
            ),
      );
    });
  }

  void _publishForegroundThread(String? threadId) {
    if (!_routeVisible) return;
    scheduleMicrotask(() {
      if (mounted && _routeVisible) {
        final safeThreadId =
            _initialConversationResolved &&
                !_showM05History &&
                threadId != null &&
                isSafeChatIdentifier(threadId)
            ? threadId
            : null;
        if (ref.read(foregroundChatThreadIdProvider) != safeThreadId) {
          ref.read(foregroundChatThreadIdProvider.notifier).state =
              safeThreadId;
        }
      }
    });
  }

  void _scheduleRouteLeaveEffects() {
    if (_routeLeaveEffectsScheduled) return;
    _routeLeaveEffectsScheduled = true;
    final activeThreadId = ref
        .read(_chatControllerProvider)
        .state
        .activeThreadId;
    final foreground = ref.read(foregroundChatThreadIdProvider.notifier);
    // RouteAware callbacks run while Navigator holds its route lock. Defer every
    // provider mutation until the transition has reached a stable frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_routeVisible) return;
      if (activeThreadId != null && foreground.state == activeThreadId) {
        foreground.state = null;
      }
      unawaited(
        _voiceMessageController.endCaptureForLeave(owner: _voiceSessionOwner),
      );
    });
  }

  void _scheduleVoiceCaptureEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_routeVisible) return;
      unawaited(
        _voiceMessageController.endCaptureForLeave(owner: _voiceSessionOwner),
      );
    });
  }

  void _rememberDailyTopicContext(String threadId) {
    final title = widget.dailyTopicTitle?.trim();
    if (title == null || title.isEmpty) return;
    try {
      ref
          .read(chatThreadAliasRepositoryProvider)
          .saveDailyTopicContext(
            scene: ChatScene.feedAi,
            threadId: threadId,
            title: title,
          );
    } on Object {
      // Route display metadata is optional and cannot block the server thread.
    }
  }

  Future<String?> _restoreOrdinaryEntryThread(
    ChatController controller,
    OrdinaryChatEntryPoint entryPoint,
  ) async {
    final repository = ref.read(chatThreadAliasRepositoryProvider);
    final bindings = repository.ordinaryThreadBindingsFor(
      scene: ChatScene.feedAi,
      entryPoint: entryPoint,
    );
    for (final binding in bindings) {
      if (repository.isThreadHidden(
        scene: ChatScene.feedAi,
        threadId: binding.threadId,
      )) {
        continue;
      }
      await controller.selectThread(
        binding.threadId,
        silentRemoteFailure: true,
      );
      if (!mounted ||
          !identical(controller, ref.read(_chatControllerProvider))) {
        return null;
      }
      final state = controller.state;
      final isStandardThread = _isStandardOrdinaryThread(
        controller,
        binding.threadId,
      );
      final hasWorkspaceMismatch = _hasOrdinaryEntryWorkspaceMismatch(
        controller,
        repository,
        binding.threadId,
      );
      if (state.status != ChatControllerStatus.ready ||
          state.activeThreadId != binding.threadId ||
          !isStandardThread ||
          hasWorkspaceMismatch) {
        if (_isPermanentOrdinaryBindingFailure(state.lastErrorCode) ||
            hasWorkspaceMismatch ||
            (state.status == ChatControllerStatus.ready &&
                state.activeThreadId == binding.threadId &&
                !isStandardThread)) {
          _removeOrdinaryEntryThreadBinding(
            repository,
            entryPoint,
            binding.threadId,
          );
        }
        continue;
      }
      _rememberOrdinaryEntryThread(
        controller,
        binding.threadId,
        hasExistingWorkspaceBinding: true,
      );
      return binding.threadId;
    }
    return null;
  }

  Future<void> _revalidateOrdinaryEntryThread(
    ChatController controller,
    OrdinaryChatEntryPoint entryPoint,
    String threadId,
  ) async {
    await controller.revalidateThreadIfStale(threadId);
    if (!mounted ||
        !identical(controller, ref.read(_chatControllerProvider)) ||
        _ordinaryEntryPoint != entryPoint) {
      return;
    }
    final failureCode = controller.lastRemoteFailureCodeForThreadSelection(
      threadId,
    );
    final repository = ref.read(chatThreadAliasRepositoryProvider);
    final hasWorkspaceMismatch = _hasOrdinaryEntryWorkspaceMismatch(
      controller,
      repository,
      threadId,
    );
    if (!_isPermanentOrdinaryBindingFailure(failureCode) &&
        !hasWorkspaceMismatch) {
      return;
    }
    _removeOrdinaryEntryThreadBinding(repository, entryPoint, threadId);
    if (hasWorkspaceMismatch && controller.state.activeThreadId == threadId) {
      setState(() => _routeFeedItemEnabled = true);
      controller.startNewThread();
      _scheduleScrollToEntry();
    }
  }

  void _removeOrdinaryEntryThreadBinding(
    ChatThreadAliasRepository repository,
    OrdinaryChatEntryPoint entryPoint,
    String threadId,
  ) {
    try {
      repository.removeOrdinaryThreadBinding(
        scene: ChatScene.feedAi,
        entryPoint: entryPoint,
        threadId: threadId,
      );
    } on Object {
      // Entry recovery is an optional local shortcut.
    }
  }

  bool _hasOrdinaryEntryWorkspaceMismatch(
    ChatController controller,
    ChatThreadAliasRepository repository,
    String threadId,
  ) {
    final workspaceId = controller.state.threads
        .where((thread) => thread.threadId == threadId)
        .firstOrNull
        ?.workspaceId;
    final repositoryWorkspace = repository.workspaceScope;
    return workspaceId != null &&
        repositoryWorkspace != null &&
        workspaceId != repositoryWorkspace;
  }

  bool _isStandardOrdinaryThread(ChatController controller, String threadId) {
    final matchingThread = controller.state.threads
        .where((thread) => thread.threadId == threadId)
        .firstOrNull;
    if (matchingThread == null) return false;
    final profileId = matchingThread.agentProfileId?.trim().isNotEmpty == true
        ? matchingThread.agentProfileId!.trim()
        : controller.activeAgentProfileId?.trim();
    return profileId == standardCreationChatAgentProfileId;
  }

  bool _isPermanentOrdinaryBindingFailure(String? errorCode) =>
      switch (errorCode) {
        'NOT_FOUND' ||
        'THREAD_NOT_FOUND' ||
        'CHAT_THREAD_ID_INVALID' ||
        'CHAT_THREAD_PURPOSE_MISMATCH' ||
        'CHAT_THREAD_SCENE_MISMATCH' ||
        'CHAT_THREAD_AGENT_PROFILE_MISMATCH' => true,
        _ => false,
      };

  void _rememberOrdinaryEntryThread(
    ChatController controller,
    String threadId, {
    bool hasExistingWorkspaceBinding = false,
  }) {
    if (!mounted || !identical(controller, ref.read(_chatControllerProvider))) {
      return;
    }
    final entryPoint = _ordinaryEntryPoint;
    if (entryPoint == null) return;
    _persistOrdinaryEntryThread(
      controller: controller,
      repository: ref.read(chatThreadAliasRepositoryProvider),
      entryPoint: entryPoint,
      threadId: threadId,
      hasExistingWorkspaceBinding: hasExistingWorkspaceBinding,
    );
  }

  void _persistOrdinaryEntryThread({
    required ChatController controller,
    required ChatThreadAliasRepository repository,
    required OrdinaryChatEntryPoint entryPoint,
    required String threadId,
    bool hasExistingWorkspaceBinding = false,
  }) {
    if (_persistedOrdinaryEntryPoint == entryPoint &&
        _persistedOrdinaryThreadId == threadId) {
      return;
    }
    if (!isSafeChatIdentifier(threadId) ||
        !_isStandardOrdinaryThread(controller, threadId)) {
      return;
    }
    final repositoryWorkspace = repository.workspaceScope;
    if (repositoryWorkspace == null) return;
    final thread = controller.state.threads
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    if (thread == null) return;
    final threadWorkspace = thread.workspaceId;
    if (threadWorkspace != repositoryWorkspace &&
        (!hasExistingWorkspaceBinding || threadWorkspace != null)) {
      return;
    }
    try {
      repository.markOrdinaryThreadOpened(
        scene: ChatScene.feedAi,
        entryPoint: entryPoint,
        threadId: threadId,
        agentProfileId: standardCreationChatAgentProfileId,
      );
      _persistedOrdinaryEntryPoint = entryPoint;
      _persistedOrdinaryThreadId = threadId;
    } on Object {
      // Entry recovery is an optional local shortcut, never a send boundary.
    }
  }

  Map<String, String> get _ordinaryEntryRouteParameters {
    final entryPoint = _ordinaryEntryPoint;
    if (entryPoint == null) return const <String, String>{};
    return <String, String>{
      'ordinaryEntryKind': entryPoint.kind.storageValue,
      'ordinaryEntryId': entryPoint.entryId,
    };
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _scheduleRouteLeaveEffects();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _routeLeaveEffectsScheduled = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeVisible) return;
      _applyLiveTranscript(
        ref.read(feedAiVoiceMessageControllerProvider).state,
      );
      final controller = ref.read(_chatControllerProvider);
      final threadId = controller.state.activeThreadId;
      _publishForegroundThread(threadId);
      if (threadId != null &&
          controller.shouldRefreshThreadOnForeground(threadId)) {
        unawaited(_refreshCompletedConversation(threadId));
      } else if (threadId != null) {
        _acknowledgeVisibleChatResult(threadId);
      }
    });
  }

  @override
  void didPop() {
    _routeVisible = false;
    _scheduleRouteLeaveEffects();
  }

  Future<void> _handleVoice() async {
    final controller = ref.read(feedAiVoiceMessageControllerProvider);
    final state = controller.state;
    _debugChatLiveVoice('tap', state);
    if (state.isBusy) {
      _debugChatLiveVoice('blocked_busy', state);
      return;
    }
    if (state.isCaptureActive) {
      if (!state.belongsToLiveTranscript(_voiceSessionOwner)) {
        _voiceFailureDialogGate.beginAttempt();
        await _presentVoiceFailure(
          'CHAT_LIVE_TRANSCRIPT_SESSION_BUSY',
          attemptId: state.liveTranscriptAttemptId,
        );
        return;
      }
      await _finishVoice();
      return;
    }
    _lastAppliedLiveTranscript = null;
    _liveTranscriptPrefix = '';
    _voiceFailureDialogGate.beginAttempt();
    _debugChatLiveVoice('start_requested', state);
    final started = await controller.startLiveTranscription(
      owner: _voiceSessionOwner,
    );
    final resultState = controller.state;
    _debugChatLiveVoice(
      started ? 'start_succeeded' : 'start_failed',
      resultState,
    );
    if (!mounted || started || resultState.lastErrorCode != null) return;
    await _presentVoiceFailure(
      'CHAT_LIVE_TRANSCRIPT_UNAVAILABLE',
      attemptId: resultState.liveTranscriptAttemptId,
    );
  }

  Future<void> _finishVoice() async {
    final controller = ref.read(feedAiVoiceMessageControllerProvider);
    if (!controller.state.isCaptureActive || controller.state.isBusy) return;
    _debugChatLiveVoice('stop_requested', controller.state);
    final transcribed = await controller.stopAndTranscribe(
      owner: _voiceSessionOwner,
    );
    if (!mounted) return;
    if (transcribed) {
      _debugChatLiveVoice('stop_succeeded', controller.state);
      _applyLiveTranscript(controller.state);
      return;
    }
    _debugChatLiveVoice('stop_failed', controller.state);
    final errorCode = controller.state.lastErrorCode;
    if (errorCode == null) {
      await _presentVoiceFailure(
        'VOICE_TRANSCRIPTION_FAILED',
        wasTranscribing: true,
        attemptId: controller.state.liveTranscriptAttemptId,
      );
    }
  }

  bool get _isNoteSheet => widget.presentation == V3ChatPresentation.noteSheet;

  void _closeNoteSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    final callback = widget.onSheetClose;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.maybeOf(context)?.maybePop();
  }

  void _expandNoteSheet() {
    final callback = widget.onSheetExpand;
    if (!_isNoteSheet || callback == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final controller = ref.read(_chatControllerProvider);
    final routeSourceId = _safeFeedItemId;
    final sourceIncluded =
        routeSourceId != null &&
        _conversationMemoryNotes(
          ref.read(knowledgeLibraryControllerProvider),
        ).any(
          (note) =>
              note.id == routeSourceId ||
              note.copiedFromContentId == routeSourceId,
        );
    callback(
      V3ChatSheetExpansion(
        threadId: controller.state.activeThreadId,
        agentProfileId: knownPublicChatAgentProfileId(
          controller.activeAgentProfileId,
        ),
        draft: _text.text,
        includesSourceReference: sourceIncluded,
      ),
    );
  }

  void _startNewNoteSheetConversation() {
    FocusManager.instance.primaryFocus?.unfocus();
    final controller = ref.read(_chatControllerProvider);
    controller.startNewThread();
    _fileAttachments.clearAll();
    _text.clear();
    setState(() {
      _showM05History = false;
      _routeFeedItemEnabled = true;
      _pendingMemoryNoteIds = const <String>[];
      _pendingContentLineId = null;
      _pendingContextLabel = null;
      _workbenchMaterialsConsumed = false;
      _followsLatest = true;
      _keepLatestVisibleAfterSubmission = false;
    });
    _publishForegroundThread(null);
  }

  void _openNewChatWindow() {
    if (_isNoteSheet) {
      _startNewNoteSheetConversation();
      return;
    }
    _chatWindowSequence += 1;
    final windowId =
        '${DateTime.now().microsecondsSinceEpoch}-$_chatWindowSequence';
    final agentProfileId = _newConversationAgentProfileId();
    final location = Uri(
      path: '/v3/feed/chat',
      queryParameters: <String, String>{
        'window': windowId,
        ..._ordinaryEntryRouteParameters,
        if (_isDeepPositioning)
          'purpose': ChatConversationPurpose.deepPositioning.routeValue,
        if (agentProfileId != null) 'agentProfileId': agentProfileId,
      },
    ).toString();
    if (_showM05History) {
      unawaited(_pushHistoryChild(location));
    } else {
      context.replace(location);
    }
  }

  String _historicalThreadLocation(ChatThread thread) {
    final agentProfileId = knownPublicChatAgentProfileId(thread.agentProfileId);
    return Uri(
      path: '/v3/feed/chat',
      queryParameters: <String, String>{
        'threadId': thread.threadId,
        'purpose': thread.purpose.routeValue,
        ..._ordinaryEntryRouteParameters,
        if (agentProfileId != null) 'agentProfileId': agentProfileId,
      },
    ).toString();
  }

  Future<void> _pushHistoryChild(String location) async {
    if (!mounted || _historyChildVisitInProgress) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    _historyChildVisitInProgress = true;
    try {
      await visitChildRoute(router, location);
    } finally {
      _historyChildVisitInProgress = false;
    }
  }

  void _replaceWithHistoricalThread(ChatThread thread) {
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      debugPrint(
        '[ChatRoute] history route unavailable thread=${thread.threadId}',
      );
      return;
    }
    _debugRouteRestore('history-canonicalize', activeThreadId: thread.threadId);
    router.replace(_historicalThreadLocation(thread));
  }

  void _debugRouteRestore(String stage, {String? activeThreadId}) {
    if (!kDebugMode) return;
    debugPrint(
      '[ChatRouteRestore] stage=$stage '
      'routeThread=${_safeThreadId ?? '-'} '
      'activeThread=${activeThreadId ?? '-'} '
      'launch=${_effectiveLaunchMode.name} '
      'window=$_isExplicitNewWindow '
      'source=$_hasSourceBoundEntry '
      'contentLine=${_safeContentLineId ?? '-'} '
      'item=${_safeFeedItemId ?? '-'} '
      'materials=${widget.workbenchContext?.materialIds.length ?? 0} '
      'purpose=${widget.conversationPurpose.routeValue}',
    );
  }

  void _debugChatControllerBinding(ChatController controller) {
    final controllerId = identityHashCode(controller);
    final messageCount = controller.state.messages.length;
    final previousControllerId = _lastObservedChatControllerId;
    if (_lastObservedChatControllerId == controllerId &&
        _lastObservedChatMessageCount == messageCount) {
      return;
    }
    _lastObservedChatControllerId = controllerId;
    _lastObservedChatMessageCount = messageCount;
    if (kDebugMode) {
      debugPrint(
        '[ChatRouteRestore] stage=controller-binding '
        'controller=$controllerId '
        'routeThread=${_safeThreadId ?? '-'} '
        'activeThread=${controller.state.activeThreadId ?? '-'} '
        'messages=$messageCount',
      );
    }
    if (previousControllerId != null &&
        previousControllerId != controllerId &&
        _safeThreadId != null) {
      _scheduleRouteThreadRecoveryForReplacement(controllerId);
    }
  }

  void _scheduleRouteThreadRecoveryForReplacement(int controllerId) {
    if (_routeRecoveryScheduledForControllerId == controllerId) return;
    _routeRecoveryScheduledForControllerId = controllerId;
    final threadId = _safeThreadId;
    if (threadId == null) return;
    scheduleMicrotask(() {
      if (!mounted || _safeThreadId != threadId) return;
      final controller = ref.read(_chatControllerProvider);
      if (identityHashCode(controller) != controllerId) return;
      if (controller.state.activeThreadId == threadId &&
          controller.state.messages.isNotEmpty) {
        return;
      }
      _debugRouteRestore(
        'controller-replaced-route-thread',
        activeThreadId: controller.state.activeThreadId,
      );
      unawaited(_restoreRouteThreadOnForeground(threadId));
    });
  }

  String? _newConversationAgentProfileId() {
    final profile = knownPublicChatAgentProfileId(
      ref.read(_chatControllerProvider).activeAgentProfileId,
    );
    if (profile == null) return null;
    if (!_isDeepPositioning) return profile;
    return profile == 'positioning_lv1' || profile == 'positioning_lv2'
        ? profile
        : null;
  }

  Future<void> _cancelVoice() async {
    final controller = ref.read(feedAiVoiceMessageControllerProvider);
    final clearTranscript = controller.state.isLiveTranscription;
    final cancelled = await controller.cancel(
      liveTranscriptOwner: _voiceSessionOwner,
    );
    if (!mounted || !cancelled || !clearTranscript) return;
    _lastAppliedLiveTranscript = null;
    _text.clear();
  }

  Future<void> _showVisualReferenceHelp() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .28),
      elevation: 0,
      showDragHandle: false,
      builder: (sheetContext) => _VisualReferenceHelpSheet(
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<void> _openVoicePermissionSettings() async {
    await ref
        .read(platformPermissionsPortProvider)
        .openAppSettings(
          PlatformPermissionKind.microphone,
          impactAcknowledged: true,
        );
  }

  void _applyLiveTranscript(VoiceMessageState state) {
    if (!state.isLiveTranscription ||
        !state.belongsToLiveTranscript(_voiceSessionOwner)) {
      return;
    }
    final transcript = state.liveTranscriptText.trim();
    if (transcript.isEmpty || transcript == _lastAppliedLiveTranscript) return;
    _lastAppliedLiveTranscript = transcript;
    final composed = '$_liveTranscriptPrefix$transcript';
    _text.value = TextEditingValue(
      text: composed,
      selection: TextSelection.collapsed(offset: composed.length),
    );
  }

  void _handleVoiceStateChanged(
    VoiceMessageState? previous,
    VoiceMessageState next,
  ) {
    if (!mounted ||
        !_routeVisible ||
        !next.belongsToLiveTranscript(_voiceSessionOwner)) {
      return;
    }
    _applyLiveTranscript(next);
    final errorCode = next.lastErrorCode;
    if (errorCode == null) return;
    _debugChatLiveVoice('terminal_failure', next, errorCode: errorCode);
    final wasListening =
        previous?.liveTranscriptStatus == LiveTranscriptStatus.transcribing;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeVisible) return;
      unawaited(
        _presentVoiceFailure(
          errorCode,
          wasTranscribing: wasListening,
          attemptId: next.liveTranscriptAttemptId,
        ),
      );
    });
  }

  Future<void> _presentVoiceFailure(
    String errorCode, {
    bool wasTranscribing = false,
    int? attemptId,
  }) async {
    if (!mounted ||
        !_routeVisible ||
        !_voiceFailureDialogGate.claim(
          owner: _voiceSessionOwner,
          attemptId: attemptId,
        )) {
      return;
    }
    late final LiveTranscriptionFailureDialogAction action;
    try {
      action = await showLiveTranscriptionFailureDialog(
        context: context,
        errorCode: errorCode,
        wasTranscribing: wasTranscribing,
      );
    } finally {
      _voiceFailureDialogGate.release();
    }
    if (!mounted || !_routeVisible) return;
    switch (action) {
      case LiveTranscriptionFailureDialogAction.openSettings:
        await _openVoicePermissionSettings();
        break;
      case LiveTranscriptionFailureDialogAction.retry:
        _liveTranscriptPrefix = _text.text;
        _lastAppliedLiveTranscript = null;
        _voiceFailureDialogGate.beginAttempt();
        await ref
            .read(feedAiVoiceMessageControllerProvider)
            .startLiveTranscription(owner: _voiceSessionOwner);
        break;
      case LiveTranscriptionFailureDialogAction.dismiss:
        break;
    }
  }

  Future<void> _refreshVoiceAsr() async {
    await ref.read(feedAiVoiceMessageControllerProvider).refreshAsr();
  }

  Future<void> _retryVoiceAsr() async {
    await ref.read(feedAiVoiceMessageControllerProvider).retryAsr();
  }

  Future<void> _openM05History() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted && !_showM05History) {
      setState(() {
        _historyIsRouteEntry = false;
        _showM05History = true;
      });
      _publishForegroundThread(null);
    }
    final controllers = _readM05HistoryControllers();
    for (final controller in controllers) {
      controller.restoreCachedConversations();
    }
    unawaited(
      Future.wait<void>(
        controllers.map((controller) => controller.refreshCompleteHistory()),
      ),
    );
  }

  bool _usesAccountWideHistory(ChatController primaryController) =>
      widget.showHistoryOnStart &&
      _effectiveLaunchMode == ChatLaunchMode.history &&
      !_isDeepPositioning &&
      widget.workbenchContext == null &&
      primaryController.activeAgentProfileId == null;

  List<ChatController> _readM05HistoryControllers() {
    final primary = ref.read(_chatControllerProvider);
    return <ChatController>[
      primary,
      if (_usesAccountWideHistory(primary))
        ref.read(deepPositioningChatControllerProvider),
    ];
  }

  Future<void> _refreshM05History({
    bool loadMore = false,
    bool force = false,
  }) => Future.wait<void>(
    _readM05HistoryControllers().map(
      (controller) =>
          controller.refreshCompleteHistory(loadMore: loadMore, force: force),
    ),
  );

  ChatController _historyControllerForThread(ChatThread thread) {
    final primary = ref.read(_chatControllerProvider);
    if (!_usesAccountWideHistory(primary)) return primary;
    final deep = ref.read(deepPositioningChatControllerProvider);
    final deepOwnsThread = deep.historyThreads.any(
      (candidate) => candidate.threadId == thread.threadId,
    );
    if (!deepOwnsThread) return primary;
    final primaryOwnsThread = primary.historyThreads.any(
      (candidate) => candidate.threadId == thread.threadId,
    );
    return !primaryOwnsThread ||
            thread.purpose == ChatConversationPurpose.deepPositioning
        ? deep
        : primary;
  }

  void _closeM05History() {
    if (!mounted || !_showM05History) return;
    if (_historyIsRouteEntry) {
      unawaited(
        returnFromV3LongRunningTask(
          context,
          fallbackRoute: '/v3/profile/account',
        ),
      );
      return;
    }
    setState(() => _showM05History = false);
    final threadId = ref.read(_chatControllerProvider).state.activeThreadId;
    _publishForegroundThread(threadId);
    if (threadId != null) _acknowledgeVisibleChatResult(threadId);
  }

  Future<void> _selectM05HistoryThread(ChatThread thread) async {
    final controller = ref.read(_chatControllerProvider);
    if (!_isNoteSheet && GoRouter.maybeOf(context) != null) {
      await _pushHistoryChild(_historicalThreadLocation(thread));
      return;
    }
    _switchingConversation = true;
    try {
      await controller.selectThread(thread.threadId);
    } finally {
      _switchingConversation = false;
    }
    if (!mounted || !identical(controller, ref.read(_chatControllerProvider))) {
      return;
    }
    final state = controller.state;
    if (state.activeThreadId != thread.threadId) {
      if (state.lastErrorCode case final error?) {
        showV3Snack(context, '加载会话失败：$error');
      }
      return;
    }
    setState(() => _showM05History = false);
    _publishForegroundThread(thread.threadId);
    _followsLatest = true;
    _scheduleScrollToBottom(force: true, immediate: true);
    _acknowledgeVisibleChatResult(thread.threadId);
    if (_isNoteSheet) {
      _rememberOrdinaryEntryThread(controller, thread.threadId);
      setState(() {
        _routeFeedItemEnabled = false;
        _pendingMemoryNoteIds = const <String>[];
      });
    }
  }

  Future<void> _showM05ThreadActions(ChatThread thread) async {
    final action = await showV3ActionSheet<_ChatThreadAction>(
      context: context,
      title: '对话操作',
      cancelLabel: '取消',
      items: const [
        V3ActionSheetItem<_ChatThreadAction>(
          key: ValueKey('chat-history-action-rename'),
          value: _ChatThreadAction.rename,
          icon: Icons.edit_outlined,
          label: '重命名对话',
        ),
        V3ActionSheetItem<_ChatThreadAction>(
          key: ValueKey('chat-history-action-delete'),
          value: _ChatThreadAction.hide,
          icon: Icons.delete_outline_rounded,
          label: '删除对话',
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;
    final controller = _historyControllerForThread(thread);
    if (action == _ChatThreadAction.rename) {
      final alias = await showV3TextInputDialog(
        context: context,
        title: '重命名会话',
        initialValue: thread.localAlias ?? thread.defaultDisplayTitle,
        label: '会话名称',
        maxLength: 60,
        inputKey: const ValueKey('chat-thread-name-input'),
        validator: controller.threadAliasError,
      );
      if (alias == null || !mounted) return;
      final renamedRemotely = await controller.renameThreadRemote(
        thread.threadId,
        alias,
      );
      if (!mounted) return;
      if (renamedRemotely || controller.renameThread(thread.threadId, alias)) {
        showV3Snack(context, renamedRemotely ? '会话名称已同步' : '会话名称仅保存在本机');
      } else {
        showV3Snack(context, '会话名称同步失败，请稍后重试');
      }
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '从本机历史中删除？',
        message: '该会话只会在当前账号的本机历史中隐藏，云端记录和正在运行的任务不会受到影响。',
        primaryLabel: '删除',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (confirmed == true && mounted) {
      if (controller.hideThread(thread.threadId)) {
        showV3Snack(context, '已从本机历史中删除');
      } else {
        showV3Snack(context, '删除失败，请稍后重试');
      }
    }
  }

  Future<void> _showThreadList(BuildContext pageContext) async {
    final controller = ref.read(_chatControllerProvider);
    controller.restoreCachedConversations();
    unawaited(controller.refreshCompleteHistory());
    final selectedThread = await showV3GlassBottomSheet<ChatThread>(
      context: pageContext,
      isScrollControlled: true,
      builder: (sheetContext) => V3SheetScaffold(
        title: '会话',
        message: '会话名称与运行详情由服务端同步。',
        showClose: true,
        child: Flexible(
          child: SizedBox(
            height: 360,
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final chat = controller.state;
                final historyThreads = controller.historyThreads;
                if (historyThreads.isEmpty) {
                  return Center(
                    child: Text(
                      '暂无服务端会话',
                      style: TextStyle(
                        color: HuahuoV3Theme.tokensOf(context).muted,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: historyThreads.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (itemContext, index) {
                    final thread = historyThreads[index];
                    final selected = thread.threadId == chat.activeThreadId;
                    return Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => Navigator.of(sheetContext).pop(thread),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
                          child: Row(
                            children: [
                              Icon(
                                selected
                                    ? Icons.chat_bubble_rounded
                                    : Icons.chat_bubble_outline_rounded,
                                size: 21,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      thread.displayTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        _chatHistoryAgentMetadataLabel(thread),
                                        key: ValueKey<String>(
                                          'chat-history-agent-${thread.threadId}',
                                        ),
                                        style: TextStyle(
                                          color: HuahuoV3Theme.tokensOf(
                                            context,
                                          ).muted,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (controller.isThreadPending(thread))
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: SizedBox.square(
                                    dimension: 17,
                                    child: CircularProgressIndicator.adaptive(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              else if (selected)
                                const Icon(Icons.check_rounded, size: 19),
                              IconButton(
                                key: ValueKey(
                                  'chat-thread-more-${thread.threadId}',
                                ),
                                tooltip: '会话操作',
                                onPressed: () =>
                                    unawaited(_showThreadActions(thread)),
                                icon: const Icon(Icons.more_horiz_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    if (selectedThread == null || !mounted || !pageContext.mounted) return;

    _switchingConversation = true;
    try {
      await controller.selectThread(selectedThread.threadId);
    } finally {
      _switchingConversation = false;
    }
    if (!mounted ||
        !pageContext.mounted ||
        !identical(controller, ref.read(_chatControllerProvider))) {
      return;
    }
    final state = controller.state;
    if (state.activeThreadId == selectedThread.threadId) {
      final threadForRoute =
          state.threads
              .where((thread) => thread.threadId == selectedThread.threadId)
              .firstOrNull ??
          selectedThread;
      _followsLatest = true;
      _scheduleScrollToBottom(force: true, immediate: true);
      _acknowledgeVisibleChatResult(selectedThread.threadId);
      _replaceWithHistoricalThread(threadForRoute);
      return;
    }
    if (state.lastErrorCode case final error?) {
      showV3Snack(pageContext, '加载会话失败：$error');
    }
  }

  Future<void> _showThreadActions(ChatThread thread) async {
    final pageContext = context;
    final action = await showV3ActionSheet<_ChatThreadAction>(
      context: pageContext,
      title: thread.displayTitle,
      items: [
        const V3ActionSheetItem(
          value: _ChatThreadAction.rename,
          icon: Icons.edit_outlined,
          label: '重命名',
        ),
        V3ActionSheetItem(
          value: _ChatThreadAction.resetName,
          icon: Icons.restore_rounded,
          label: '恢复原名称',
          subtitle: thread.defaultDisplayTitle,
          enabled:
              thread.titleMode == ChatThreadTitleMode.custom ||
              thread.localAlias != null,
        ),
        const V3ActionSheetItem(
          value: _ChatThreadAction.runtime,
          icon: Icons.analytics_outlined,
          label: '运行详情',
        ),
        const V3ActionSheetItem(
          value: _ChatThreadAction.hide,
          icon: Icons.delete_outline_rounded,
          label: '从本机历史中删除',
          subtitle: '不会删除云端会话或取消正在运行的任务',
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted || !pageContext.mounted) return;
    final controller = ref.read(_chatControllerProvider);
    switch (action) {
      case _ChatThreadAction.rename:
        final alias = await showV3TextInputDialog(
          context: pageContext,
          title: '重命名会话',
          initialValue: thread.localAlias ?? thread.defaultDisplayTitle,
          label: '会话名称',
          maxLength: 60,
          inputKey: const ValueKey('chat-thread-name-input'),
          validator: controller.threadAliasError,
        );
        if (alias == null || !mounted || !pageContext.mounted) return;
        final renamedRemotely = await controller.renameThreadRemote(
          thread.threadId,
          alias,
        );
        if (!mounted || !pageContext.mounted) return;
        if (renamedRemotely ||
            controller.renameThread(thread.threadId, alias)) {
          showV3Snack(pageContext, renamedRemotely ? '会话名称已同步' : '会话名称仅保存在本机');
        } else {
          showV3Snack(
            pageContext,
            controller.state.lastErrorCode == 'THREAD_TITLE_VERSION_CONFLICT'
                ? '名称已被其他端修改，已刷新当前会话'
                : '会话名称同步失败，请稍后重试',
          );
        }
        return;
      case _ChatThreadAction.resetName:
        final resetRemotely = await controller.resetThreadNameRemote(
          thread.threadId,
        );
        if (!mounted || !pageContext.mounted) return;
        if (resetRemotely || controller.resetThreadName(thread.threadId)) {
          showV3Snack(pageContext, resetRemotely ? '已恢复原名称' : '已恢复本机原名称');
        } else {
          showV3Snack(
            pageContext,
            controller.state.lastErrorCode == 'THREAD_TITLE_VERSION_CONFLICT'
                ? '名称已被其他端修改，已刷新当前会话'
                : '恢复名称失败，请稍后重试',
          );
        }
        return;
      case _ChatThreadAction.runtime:
        await _showThreadRuntime(pageContext, thread);
        return;
      case _ChatThreadAction.hide:
        final confirmed = await showDialog<bool>(
          context: pageContext,
          builder: (dialogContext) => V3GlassDialog(
            title: '从本机历史中删除？',
            message: '该会话只会在当前账号的本机历史中隐藏，云端记录和正在运行的任务不会受到影响。',
            primaryLabel: '删除',
            onPrimary: () => Navigator.of(dialogContext).pop(true),
            onCancel: () => Navigator.of(dialogContext).pop(false),
          ),
        );
        if (confirmed != true || !mounted || !pageContext.mounted) return;
        if (controller.hideThread(thread.threadId)) {
          showV3Snack(
            pageContext,
            '已从本机历史中删除',
            actionLabel: '撤销',
            onAction: () {
              if (controller.restoreHiddenThread(thread.threadId)) {
                unawaited(
                  controller.loadThreads(refresh: true, selectLatest: false),
                );
              }
            },
          );
        }
        return;
    }
  }

  Future<void> _showThreadRuntime(
    BuildContext context,
    ChatThread thread,
  ) async {
    final controller = ref.read(_chatControllerProvider);
    final refresh = controller.readRuntimeInvocation(thread.threadId);
    final cached = controller.cachedRuntimeInvocation(thread.threadId);
    await showV3GlassBottomSheet<void>(
      context: this.context,
      isScrollControlled: true,
      builder: (sheetContext) => V3SheetScaffold(
        title: '运行详情',
        message: '仅展示已脱敏的服务端运行摘要。',
        showClose: true,
        child: Flexible(
          child: FutureBuilder<SharedThreadRuntimeInvocation?>(
            future: refresh,
            initialData: cached,
            builder: (context, snapshot) {
              final invocation = snapshot.data;
              if (invocation != null) {
                return ThreadRuntimeSummary(invocation: invocation);
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return const SizedBox(
                height: 88,
                child: Center(child: Text('尚无可查看的运行记录。')),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showPlusMenu(BuildContext context, {required bool allowVideoUpload}) {
    showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => V3ChatAttachmentSheet(
        onClose: () => Navigator.pop(sheetContext),
        onNote: () {
          Navigator.pop(sheetContext);
          _showMemoryNoteReferenceSheet(context);
        },
        onCamera: () {
          Navigator.pop(sheetContext);
          unawaited(_pickAndUploadCameraImage());
        },
        onImages: () {
          Navigator.pop(sheetContext);
          unawaited(_pickAndUploadImages());
        },
        onVideo: allowVideoUpload
            ? () {
                Navigator.pop(sheetContext);
                unawaited(_pickAndUploadVideo());
              }
            : null,
      ),
    );
  }

  Future<void> _pickAndUploadVideo() async {
    final source = await showV3ActionSheet<NativeMediaSource>(
      context: context,
      title: '上传视频',
      cancelLabel: '取消',
      items: const <V3ActionSheetItem<NativeMediaSource>>[
        V3ActionSheetItem(
          value: NativeMediaSource.gallery,
          icon: LucideIcons.video,
          label: '从相册选择',
        ),
        V3ActionSheetItem(
          value: NativeMediaSource.files,
          icon: LucideIcons.folderOpen,
          label: '从文件选择',
        ),
      ],
    );
    if (!mounted || source == null) return;
    final failure = source == NativeMediaSource.files
        ? await _fileAttachments.pickAndUploadVideoFiles()
        : await _fileAttachments.pickAndUploadVideos();
    if (!mounted || failure == null) return;
    showV3Snack(context, '视频选择或上传失败，请重试');
  }

  Future<void> _showMemoryNoteReferenceSheet(
    BuildContext context, {
    String? autoSendPrompt,
  }) async {
    final library = ref.read(knowledgeLibraryControllerProvider);
    final notes = library.mineNotes;
    if (notes.isEmpty) {
      showV3Snack(context, '我的资产暂时没有可引用的内容');
      return;
    }
    final selected = await showV3GlassBottomSheet<V3FeedItem>(
      context: context,
      isScrollControlled: true,
      builder: (_) => V3ChatNotePickerSheet(notes: notes),
    );
    if (selected == null || !mounted) return;
    final selectedForReference = _chatReferenceableNoteForId(
      library,
      selected.id,
    );
    if (selectedForReference == null ||
        !await _synchronizeSelectedNotes(<V3FeedItem>[selectedForReference])) {
      if (mounted) {
        showV3Snack(this.context, '所选笔记未能同步到云端，暂时无法引用');
      }
      return;
    }
    if (!mounted) return;
    final synchronized = _chatReferenceableNoteForId(library, selected.id);
    if (synchronized == null ||
        _exactHNoteChatReference(synchronized) == null) {
      showV3Snack(this.context, '所选笔记缺少正式版本，暂时无法引用');
      return;
    }
    final currentIds = <String>{
      for (final note in _conversationMemoryNotes(library)) note.id,
    }..add(synchronized.id);
    setState(() {
      _pendingMemoryNoteIds = List<String>.unmodifiable(currentIds);
      _routeFeedItemEnabled = false;
    });
    final prompt = autoSendPrompt?.trim();
    if (prompt != null && prompt.isNotEmpty) {
      _setEntryPrompt(prompt);
      await _sendMessage();
      return;
    }
    showV3Snack(this.context, '已引用已同步笔记：${synchronized.title}');
  }

  Future<void> _pickAndUploadCameraImage() async {
    final failure = await _fileAttachments.pickAndUploadCameraImage();
    if (!mounted || failure == null) return;
    if (failure.code == 'MEDIA_PICKER_CANCELLED' ||
        failure.code == 'CHAT_IMAGE_PICK_EMPTY') {
      return;
    }
    showV3Snack(context, '拍照或上传失败，请重试');
  }

  Future<void> _pickAndUploadImages() async {
    final failure = await _fileAttachments.pickAndUploadImages();
    if (!mounted || failure == null) return;
    if (failure.code == 'MEDIA_PICKER_CANCELLED' ||
        failure.code == 'CHAT_IMAGE_PICK_EMPTY') {
      return;
    }
    showV3Snack(context, '图片选择或上传失败，请重试');
  }

  void _showLocalImagePreview(ChatFileAttachment attachment) {
    if (!attachment.isImage) return;
    final path = attachment.localPreviewPath?.trim();
    if (path == null || path.isEmpty) return;
    final file = File(path);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => _ChatLocalImageViewer(
          file: file,
          displayName: attachment.displayName,
          mimeType: attachment.mimeType,
          nativeFilePort: _nativeFilePort,
        ),
      ),
    );
  }

  void _onFileAttachmentsChanged() {
    if (mounted) setState(() {});
  }
}

class _V3NoteChatSheetHeader extends StatelessWidget {
  const _V3NoteChatSheetHeader({
    required this.onClose,
    required this.onExpand,
    required this.onNewConversation,
    required this.onHistory,
  });

  final VoidCallback onClose;
  final VoidCallback? onExpand;
  final VoidCallback? onNewConversation;
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final leading = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          key: const ValueKey<String>('note-chat-close'),
          tooltip: '关闭',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded, size: 22),
        ),
        IconButton(
          key: const ValueKey<String>('note-chat-expand'),
          tooltip: '展开聊天',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          onPressed: onExpand,
          icon: const Icon(Icons.open_in_full_rounded, size: 19),
        ),
        IconButton(
          key: const ValueKey<String>('note-chat-new-conversation'),
          tooltip: '新建对话',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          onPressed: onNewConversation,
          icon: const Icon(Icons.add_comment_outlined, size: 19),
        ),
      ],
    );
    const title = Text(
      '聊一聊',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    );
    final history = TextButton.icon(
      key: const ValueKey<String>('note-chat-history'),
      onPressed: onHistory,
      icon: const Icon(Icons.history_rounded, size: 19),
      label: const Text('历史'),
      style: TextButton.styleFrom(
        foregroundColor: colors.muted,
        padding: EdgeInsets.zero,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 320) {
            return Row(
              children: <Widget>[
                leading,
                const Expanded(child: Center(child: title)),
                history,
              ],
            );
          }
          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Align(alignment: Alignment.centerLeft, child: leading),
              title,
              Align(alignment: Alignment.centerRight, child: history),
            ],
          );
        },
      ),
    );
  }
}

class V3ChatFileAttachmentStrip extends StatelessWidget {
  const V3ChatFileAttachmentStrip({
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
    required this.onPreview,
    this.onContinueAdding,
    super.key,
  });

  final List<ChatFileAttachment> attachments;
  final ValueChanged<String> onRemove;
  final ValueChanged<ChatFileAttachment> onRetry;
  final ValueChanged<ChatFileAttachment> onPreview;
  final VoidCallback? onContinueAdding;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      key: const ValueKey('chat-composer-attachment-tray'),
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length + (onContinueAdding == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          if (index == attachments.length) {
            return _ChatContinueAddingTile(onPressed: onContinueAdding!);
          }
          final attachment = attachments[index];
          return _ChatFileAttachmentChip(
            attachment: attachment,
            onRemove: () => onRemove(attachment.localId),
            onRetry: attachment.status == ChatFileAttachmentStatus.failed
                ? () => onRetry(attachment)
                : null,
            onPreview: attachment.isImage ? () => onPreview(attachment) : null,
            colors: colors,
          );
        },
      ),
    );
  }
}

class _ChatContinueAddingTile extends StatelessWidget {
  const _ChatContinueAddingTile({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      key: const ValueKey('chat-attachment-continue'),
      color: colors.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: 88,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 24, color: colors.ink),
              const SizedBox(height: 6),
              Text(
                '继续添加',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatFileAttachmentChip extends StatelessWidget {
  const _ChatFileAttachmentChip({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
    required this.onPreview,
    required this.colors,
  });

  final ChatFileAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;
  final VoidCallback? onPreview;
  final HuahuoV3ThemeTokens colors;

  @override
  Widget build(BuildContext context) {
    final isUploading = attachment.status == ChatFileAttachmentStatus.uploading;
    final isFailed = attachment.status == ChatFileAttachmentStatus.failed;
    final accent = isFailed ? colors.danger : colors.ink;
    if (attachment.isImage) {
      return _ChatLocalImageThumbnail(
        attachment: attachment,
        onRemove: onRemove,
        onRetry: onRetry,
        onPreview: onPreview,
        colors: colors,
      );
    }
    return Material(
      color: colors.surfaceMuted,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 220,
        height: 88,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          border: Border.all(color: isFailed ? colors.danger : colors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isUploading)
              const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              )
            else
              Icon(
                isFailed ? Icons.error_outline_rounded : Icons.attach_file,
                size: 18,
                color: accent,
              ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                isUploading
                    ? '${attachment.displayName} 上传中'
                    : isFailed
                    ? '${attachment.displayName} 上传失败'
                    : attachment.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: accent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: const Text('重试'),
              ),
            IconButton(
              tooltip: '移除资料',
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, size: 17),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatLocalImageThumbnail extends StatelessWidget {
  const _ChatLocalImageThumbnail({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
    required this.onPreview,
    required this.colors,
  });

  final ChatFileAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;
  final VoidCallback? onPreview;
  final HuahuoV3ThemeTokens colors;

  @override
  Widget build(BuildContext context) {
    final path = attachment.localPreviewPath?.trim();
    final isUploading = attachment.status == ChatFileAttachmentStatus.uploading;
    final isFailed = attachment.status == ChatFileAttachmentStatus.failed;
    final cacheExtent = _chatImageCacheExtent(context, 88);
    return SizedBox(
      width: 88,
      height: 88,
      child: Material(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path != null && path.isNotEmpty)
              Image(
                image: ResizeImage.resizeIfNeeded(
                  cacheExtent,
                  cacheExtent,
                  FileImage(File(path)),
                ),
                fit: BoxFit.cover,
              )
            else
              Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: colors.muted,
                ),
              ),
            if (path != null && path.isNotEmpty)
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: onPreview),
                ),
              ),
            if (isUploading || isFailed)
              ColoredBox(
                color: Colors.black.withValues(alpha: .48),
                child: Center(
                  child: isUploading
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2.4,
                          ),
                        )
                      : IconButton(
                          tooltip: '重试上传图片',
                          icon: const Icon(
                            Icons.refresh_rounded,
                            color: Colors.white,
                          ),
                          onPressed: onRetry,
                        ),
                ),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: colors.surface.withValues(alpha: .94),
                elevation: 1,
                shadowColor: colors.ink.withValues(alpha: .12),
                shape: CircleBorder(side: BorderSide(color: colors.line)),
                child: IconButton(
                  tooltip: '移除图片',
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: colors.muted,
                  ),
                  onPressed: onRemove,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatLocalImageViewer extends StatefulWidget {
  const _ChatLocalImageViewer({
    required this.file,
    required this.displayName,
    required this.mimeType,
    required this.nativeFilePort,
  });

  final File file;
  final String displayName;
  final String mimeType;
  final NativeFilePort nativeFilePort;

  @override
  State<_ChatLocalImageViewer> createState() => _ChatLocalImageViewerState();
}

class _ChatLocalImageViewerState extends State<_ChatLocalImageViewer> {
  var _isSaving = false;

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final bytes = await widget.file.readAsBytes();
      final saved = await widget.nativeFilePort.saveImageToGallery(
        bytes: bytes,
        displayName: widget.displayName,
        mimeType: widget.mimeType,
      );
      if (!mounted) return;
      showV3Snack(
        context,
        saved.ok && saved.value == true ? '图片已保存到相册' : '保存图片失败，请重试',
      );
    } catch (_) {
      if (mounted) showV3Snack(context, '保存图片失败，请重试');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final qualityWidth = _chatImageCacheExtent(context, size.width * 2);
    final qualityHeight = _chatImageCacheExtent(context, size.height * 2);
    return _ChatImageViewerSurface(
      image: Image.file(
        widget.file,
        fit: BoxFit.contain,
        cacheWidth: qualityWidth,
        cacheHeight: qualityHeight,
      ),
      isSaving: _isSaving,
      onSave: _save,
    );
  }
}

class _ChatImageViewerSurface extends StatelessWidget {
  const _ChatImageViewerSurface({
    required this.image,
    required this.isSaving,
    required this.onSave,
  });

  final Widget image;
  final bool isSaving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: size.width - 24,
        height: size.height - 88,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(child: image),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    tooltip: '保存到相册',
                    onPressed: isSaving ? null : onSave,
                    icon: isSaving
                        ? const SizedBox.square(
                            dimension: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.download_rounded,
                            color: Colors.white,
                          ),
                  ),
                  IconButton(
                    tooltip: '关闭图片预览',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationContextBanner extends StatelessWidget {
  const _ConversationContextBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      color: colors.surfaceMuted,
      child: Row(
        children: [
          const V3ChatMark(key: ValueKey('chat-context-chat-mark'), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryNoteContextChip extends StatelessWidget {
  const _MemoryNoteContextChip({required this.note, required this.onRemove});

  final V3FeedItem note;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      key: ValueKey<String>('chat-memory-note-context-${note.id}'),
      color: colors.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 18, color: colors.ink),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '已引用资产「${note.title}」',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: '移除引用资产',
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryNoteContextStrip extends StatelessWidget {
  const _MemoryNoteContextStrip({
    required this.notes,
    required this.onRemove,
    required this.onContinueAdding,
  });

  final List<V3FeedItem> notes;
  final ValueChanged<String> onRemove;
  final VoidCallback onContinueAdding;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      key: const ValueKey('chat-memory-note-context-strip'),
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: notes.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index < notes.length) {
            final note = notes[index];
            return SizedBox(
              width: 228,
              child: _MemoryNoteContextChip(
                note: note,
                onRemove: () => onRemove(note.id),
              ),
            );
          }
          return Tooltip(
            message: '继续添加资料',
            child: Material(
              key: const ValueKey('chat-memory-note-continue-adding'),
              color: colors.surfaceMuted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onContinueAdding,
                child: const SizedBox(
                  width: 48,
                  child: Icon(Icons.add_rounded, size: 24),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChatSkillBadge extends StatelessWidget {
  const _ChatSkillBadge({
    super.key,
    this.skill,
    this.agentProfileId,
    this.fallbackLabel = '聊一聊',
  });

  final WorkbenchChatSkill? skill;
  final String? agentProfileId;
  final String fallbackLabel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 92, minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Text(
        agentProfileId == null
            ? skill?.label ?? fallbackLabel
            : chatAgentProfileLabel(agentProfileId),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.ink,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class V3ChatNotePickerSheet extends StatefulWidget {
  const V3ChatNotePickerSheet({required this.notes, super.key});

  final List<V3FeedItem> notes;

  @override
  State<V3ChatNotePickerSheet> createState() => _V3ChatNotePickerSheetState();
}

class _V3ChatNotePickerSheetState extends State<V3ChatNotePickerSheet> {
  final _queryController = TextEditingController();
  final _scrollController = ScrollController();
  String _query = '';
  String? _selectedId;

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final normalizedQuery = _query.trim().toLowerCase();
    final visibleNotes = widget.notes
        .where((note) {
          if (normalizedQuery.isEmpty) return true;
          return _memoryNoteSearchText(note).contains(normalizedQuery);
        })
        .toList(growable: false);
    final selectedNote = visibleNotes
        .where((note) => note.id == _selectedId)
        .firstOrNull;
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final preferredHeight = (mediaQuery.size.height * .815).clamp(0.0, 712.0);
    final availableHeight =
        mediaQuery.size.height - keyboardInset - mediaQuery.viewPadding.top;
    final height = preferredHeight.clamp(
      0.0,
      availableHeight.clamp(0.0, mediaQuery.size.height),
    );
    final compactKeyboard = keyboardInset > 0 && height < 260;
    final closeButton = SizedBox.square(
      dimension: compactKeyboard ? 44 : 40,
      child: IconButton(
        key: const ValueKey('chat-note-picker-close'),
        tooltip: '关闭',
        style: IconButton.styleFrom(
          backgroundColor: colors.surfaceMuted,
          shape: const CircleBorder(),
        ),
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded, size: 21),
      ),
    );
    final searchField = TextField(
      key: const ValueKey('chat-note-picker-search'),
      controller: _queryController,
      contextMenuBuilder: V3TextEditing.buildContextMenu,
      onChanged: (value) => setState(() => _query = value),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: '搜索标题、正文或来源',
        isDense: compactKeyboard,
        constraints: compactKeyboard
            ? const BoxConstraints.tightFor(height: 44)
            : null,
        filled: true,
        fillColor: colors.surfaceMuted,
        contentPadding: EdgeInsets.symmetric(
          vertical: compactKeyboard ? 8 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.line),
        ),
      ),
    );
    final confirmButton = SizedBox(
      height: compactKeyboard ? 44 : 48,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onPrimary,
          disabledBackgroundColor: colors.surfaceMuted,
          disabledForegroundColor: colors.muted,
        ),
        onPressed: selectedNote == null
            ? null
            : () => Navigator.pop(context, selectedNote),
        child: const Text('引用这篇笔记'),
      ),
    );
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (compactKeyboard)
                  Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: 4),
                      closeButton,
                    ],
                  )
                else ...[
                  SizedBox(
                    height: 54,
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '选择引用笔记',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        closeButton,
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  searchField,
                  const SizedBox(height: 18),
                  Text(
                    normalizedQuery.isEmpty
                        ? '最近更新'
                        : '搜索结果 · ${visibleNotes.length} 篇',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                ],
                if (compactKeyboard) const SizedBox(height: 4),
                Expanded(
                  child: visibleNotes.isEmpty
                      ? Center(
                          child: Text(
                            '没有匹配的笔记',
                            style: TextStyle(color: colors.muted),
                          ),
                        )
                      : V3InteractiveScrollbar(
                          controller: _scrollController,
                          child: ListView.separated(
                            controller: _scrollController,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: EdgeInsets.zero,
                            itemCount: visibleNotes.length,
                            separatorBuilder: (_, __) =>
                                SizedBox(height: compactKeyboard ? 4 : 12),
                            itemBuilder: (itemContext, index) {
                              final note = visibleNotes[index];
                              final selected = note.id == _selectedId;
                              return Material(
                                key: ValueKey('chat-note-picker-${note.id}'),
                                color: colors.canvas,
                                borderRadius: BorderRadius.circular(10),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () =>
                                      setState(() => _selectedId = note.id),
                                  child: Container(
                                    constraints: BoxConstraints(
                                      minHeight: compactKeyboard ? 52 : 82,
                                    ),
                                    padding: EdgeInsets.fromLTRB(
                                      compactKeyboard ? 10 : 12,
                                      compactKeyboard ? 6 : 10,
                                      compactKeyboard ? 6 : 8,
                                      compactKeyboard ? 6 : 8,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: selected
                                            ? colors.accent
                                            : colors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.description_outlined,
                                          color: colors.accent,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              minHeight: compactKeyboard
                                                  ? 40
                                                  : 64,
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      note.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      height: compactKeyboard
                                                          ? 2
                                                          : 3,
                                                    ),
                                                    Text(
                                                      _memoryNotePreview(note),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: colors.muted,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                if (!compactKeyboard)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 3,
                                                        ),
                                                    child: Text(
                                                      _memoryNoteUpdatedLabel(
                                                        note,
                                                      ),
                                                      style: TextStyle(
                                                        color: colors.muted,
                                                        fontSize: 11.5,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: selected
                                                  ? colors.accent
                                                  : colors.line,
                                            ),
                                            color: selected
                                                ? colors.accent
                                                : Colors.transparent,
                                          ),
                                          alignment: Alignment.center,
                                          child: selected
                                              ? Icon(
                                                  Icons.check_rounded,
                                                  size: 18,
                                                  color: colors.onPrimary,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
                Divider(height: 1, color: colors.line),
                SizedBox(height: compactKeyboard ? 4 : 14),
                if (compactKeyboard)
                  SizedBox(width: double.infinity, child: confirmButton)
                else
                  Row(
                    children: [
                      SizedBox(
                        width: 112,
                        height: 48,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: confirmButton),
                    ],
                  ),
                SizedBox(height: compactKeyboard ? 4 : 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _memoryNoteSearchText(V3FeedItem note) {
  return '${note.title}\n${note.rawBody}\n${note.summaryBody ?? ''}'
      .toLowerCase();
}

String _memoryNotePreview(V3FeedItem note) {
  final raw = note.rawBody.trim();
  if (raw.isNotEmpty) return raw;
  return note.summaryBody?.trim().isNotEmpty == true
      ? note.summaryBody!.trim()
      : '暂无可展示内容';
}

String _memoryNoteUpdatedLabel(V3FeedItem note) {
  final updatedAt = note.updatedAt.toLocal();
  final now = DateTime.now();
  final valueDay = DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
  final today = DateTime(now.year, now.month, now.day);
  final time =
      '${updatedAt.hour.toString().padLeft(2, '0')}:'
      '${updatedAt.minute.toString().padLeft(2, '0')}';
  if (valueDay == today) return '今天 $time 更新';
  if (valueDay == today.subtract(const Duration(days: 1))) {
    return '昨天 $time 更新';
  }
  return '${updatedAt.month} 月 ${updatedAt.day} 日更新';
}

ChatContextPurpose _contextPurposeForSkill(WorkbenchChatSkill? skill) =>
    switch (skill) {
      WorkbenchChatSkill.persona => ChatContextPurpose.persona,
      WorkbenchChatSkill.lead => ChatContextPurpose.lead,
      WorkbenchChatSkill.visualDesign => ChatContextPurpose.visualDesign,
      WorkbenchChatSkill.videoAnalysis => ChatContextPurpose.videoAnalysis,
      WorkbenchChatSkill.positioningLv1 => ChatContextPurpose.deepPositioning,
      WorkbenchChatSkill.socialPositioning =>
        ChatContextPurpose.socialPositioning,
      WorkbenchChatSkill.masterpiece => ChatContextPurpose.masterpiece,
      null => ChatContextPurpose.general,
    };

List<DeepPositioningConversationEntry> _positioningEntries(
  List<ChatMessage> messages,
) => <DeepPositioningConversationEntry>[
  for (final message in messages)
    if (message.localDelivery != ChatLocalDeliveryState.failed &&
        (message.role == ChatMessageRole.user ||
            message.role == ChatMessageRole.assistant) &&
        message.visibleText?.trim().isNotEmpty == true)
      DeepPositioningConversationEntry(
        text: message.visibleText!.trim(),
        isAssistant: message.role == ChatMessageRole.assistant,
      ),
];

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({
    required this.hasError,
    required this.errorCode,
    required this.prompt,
    required this.onRetry,
  });

  final bool hasError;
  final String? errorCode;
  final String prompt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (hasError) {
      return _ChatStatusBanner(errorCode: errorCode!, onRetry: onRetry);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const V3ChatMark(size: 42),
            const SizedBox(height: 14),
            Text(
              prompt,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                height: 1.5,
                color: HuahuoV3Theme.tokensOf(context).muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceRecordingPanel extends StatelessWidget {
  const _VoiceRecordingPanel({
    required this.state,
    required this.onFinish,
    required this.onCancel,
  });

  final VoiceMessageState state;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final paused = state.status == VoiceMessageControllerStatus.paused;
    final presentation = _chatLiveTranscriptPresentation(
      state.liveTranscriptStatus,
      paused: paused,
      colors: colors,
    );
    return V3Card(
      radius: 8,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      color: colors.surfaceMuted,
      child: Row(
        children: [
          Icon(presentation.icon, size: 28, color: presentation.color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  presentation.label,
                  style: TextStyle(
                    color: presentation.color,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _voiceDurationLabel(state.elapsedSeconds),
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '结束转写并编辑',
            onPressed: onFinish,
            icon: const Icon(Icons.check_circle_outline_rounded),
          ),
          IconButton(
            tooltip: '取消录制',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

final class _ChatLiveTranscriptPresentation {
  const _ChatLiveTranscriptPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

_ChatLiveTranscriptPresentation _chatLiveTranscriptPresentation(
  LiveTranscriptStatus? status, {
  required bool paused,
  required HuahuoV3ThemeTokens colors,
}) {
  if (paused) {
    return _ChatLiveTranscriptPresentation(
      label: '实时转写已暂停',
      icon: Icons.pause_circle_outline,
      color: colors.muted,
    );
  }
  return switch (status) {
    LiveTranscriptStatus.transcribing => _ChatLiveTranscriptPresentation(
      label: '正在实时转写',
      icon: Icons.graphic_eq_rounded,
      color: colors.success,
    ),
    LiveTranscriptStatus.stopping => _ChatLiveTranscriptPresentation(
      label: '正在整理转写内容',
      icon: Icons.more_time_rounded,
      color: colors.primary,
    ),
    LiveTranscriptStatus.failed => _ChatLiveTranscriptPresentation(
      label: '实时转写暂不可用',
      icon: Icons.info_outline_rounded,
      color: colors.danger,
    ),
    LiveTranscriptStatus.starting || null => _ChatLiveTranscriptPresentation(
      label: '正在连接实时转写',
      icon: Icons.sync_rounded,
      color: colors.primary,
    ),
    LiveTranscriptStatus.idle => _ChatLiveTranscriptPresentation(
      label: '实时转写已完成',
      icon: Icons.check_circle_outline_rounded,
      color: colors.success,
    ),
  };
}

class _ChatStatusBanner extends StatelessWidget {
  const _ChatStatusBanner({required this.errorCode, this.onRetry});

  final String errorCode;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      color: HuahuoV3Theme.semanticSurface(colors.danger, colors.surface),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              chatFailureMessage(errorCode),
              style: TextStyle(color: colors.ink, fontWeight: FontWeight.w700),
            ),
          ),
          if (onRetry != null)
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }
}

String chatFailureMessage(String code) => switch (code) {
  'CHAT_THREAD_LIST_FAILED' ||
  'CHAT_THREAD_DETAIL_FAILED' ||
  'CHAT_THREAD_METADATA_LOAD_FAILED' ||
  'CHAT_THREAD_LOCAL_METADATA_LOAD_FAILED' ||
  'CHAT_THREAD_PURPOSE_LOAD_FAILED' => '加载最近对话失败，请重试。',
  'META_WORKSPACE_UNAVAILABLE' ||
  'AGENT_PROFILE_UNAVAILABLE' ||
  'AGENT_RELEASE_UNAVAILABLE' => '普通聊天服务尚未准备好，请稍后再试。',
  'SERVICE_BUSY' => '聊天服务暂时繁忙，请稍后再试。',
  'ACCOUNT_UNCOVERED_CREDIT_BLOCKED' => '当前账号有尚未补足的历史算力额度，聊天暂不可用。',
  'CREDIT_RESERVATION_INSUFFICIENT' => '当前账号额度不足，暂时无法发起新的 AI 处理。',
  'UNAUTHORIZED' => '登录状态已失效，请重新登录。',
  'NETWORK_REQUEST_FAILED' ||
  'REQUEST_TIMEOUT' ||
  'TIMEOUT' => '网络连接异常，请检查网络后重试。',
  'CHAT_LIVE_TRANSCRIPT_EMPTY' => '没有识别到清晰语音，请再试一次。',
  'CHAT_LIVE_TRANSCRIPT_SESSION_BUSY' => '上一段语音转写正在结束，请稍后再试。',
  'CHAT_LIVE_TRANSCRIPT_UNAVAILABLE' ||
  'CHAT_LIVE_TRANSCRIPT_START_FAILED' ||
  'CHAT_LIVE_TRANSCRIPT_FAILED' ||
  'LIVE_ASR_BACKEND_NOT_READY' ||
  'LIVE_ASR_SESSION_NETWORK_FAILED' ||
  'REALTIME_ASR_SESSION_UNAVAILABLE' ||
  'TENCENT_LIVE_ASR_SDK_UNAVAILABLE' => '实时转写暂不可用，请稍后再试。',
  'CHAT_AGENT_ROUTE_UNAVAILABLE' => '当前聊天能力尚未开放。',
  'CHAT_AGENT_CATALOG_UNAVAILABLE' => '聊天能力目录暂时不可用，请稍后再试。',
  'AGENT_PROFILE_NOT_SELECTABLE' => '当前聊天助手尚未发布，请稍后再试。',
  'SKILL_SELECTION_NOT_CANDIDATE' ||
  'SKILL_INSTALLATION_REQUIRED' ||
  'SKILL_INSTALLATION_DISABLED' => '当前聊天能力尚未为该账号启用。',
  'CHAT_AGENT_RUN_PENDING' => 'AI 仍在处理中，可稍后刷新结果。',
  'CHAT_THREAD_TURN_IN_PROGRESS' => '这段对话的上一轮仍在处理中，请等待回复完成。',
  'CHAT_THREAD_RESULT_SYNC_FAILED' => '上一轮已结束，但结果同步失败。请稍后再次发送，系统会先重试同步，不会重复提交。',
  'CHAT_AGENT_RUN_REPLY_NOT_PERSISTED' => 'AI 已完成处理，但回复尚未同步，请稍后刷新。',
  'CHAT_AGENT_RUN_DEGRADED' => 'AI 本次未能完整处理，请重新发送或稍后再试。',
  'CHAT_AGENT_RUN_SYSTEM_FALLBACK' => 'AI 服务本次执行失败，请稍后重新发送。',
  'CHAT_AGENT_RUN_CANCELLED' => '本次 AI 处理已取消。',
  'CHAT_AGENT_RUN_TIMEOUT' => '本次 AI 处理超时，请重新发送。',
  'CHAT_REPLY_TIMEOUT' => 'AI 长时间未返回，请重新发送。',
  'CHAT_AGENT_RUN_ORPHANED' => '本次 AI 处理已中断，请重新发送。',
  'CHAT_AGENT_RUN_FAILED' => 'AI 未能完成本次处理，请重新发送。',
  'RUNTIME_EVENT_GAP' => 'AI 本次运行事件不完整，请稍后重新发送。',
  'AGENT_PLAN_EXPIRED' => 'AI 执行计划已失效，请稍后重新发送。',
  'USER_TIMEZONE_UNAVAILABLE' => '当前账号的时区信息不可用，请稍后再试。',
  'CHAT_AGENT_RUN_BINDING_INVALID' ||
  'CHAT_AGENT_RUN_RESULT_INVALID' => '服务器返回的聊天结果无法验证，请稍后再试。',
  'CHAT_AGENT_RUN_STATUS_UNAVAILABLE' ||
  'CHAT_AGENT_RUN_POLL_FAILED' => '暂时无法确认 AI 处理状态，请稍后刷新。',
  _ => '消息发送失败，请稍后再试。',
};

String _assistantAssetFailureMessage(String? code) => switch (code) {
  'WORKSPACE_CONTEXT_UNAVAILABLE' => '当前工作区尚未就绪，暂不能创建资产。',
  'RESOURCE_REFERENCE_FORBIDDEN' => '生成图片资源尚未就绪，暂不能创建资产。',
  'CHAT_ASSISTANT_IMAGE_REFERENCE_INVALID' => '回复中的图片资源无效，暂不能创建资产。',
  'CHAT_ASSISTANT_NOTE_READBACK_FAILED' => '资产已创建，正在同步显示，请稍后刷新资产列表。',
  'UNAUTHORIZED' => '登录状态已失效，请重新登录后创建资产。',
  'NETWORK_REQUEST_FAILED' ||
  'REQUEST_TIMEOUT' ||
  'TIMEOUT' => '网络连接异常，暂不能创建资产。',
  _ => '创建资产失败，请重试。',
};

bool _isExplicitAgentProfileRejection(String? code) => switch (code) {
  'AGENT_PROFILE_NOT_SELECTABLE' ||
  'AGENT_PROFILE_UNAVAILABLE' ||
  'AGENT_RELEASE_UNAVAILABLE' => true,
  _ => false,
};

String _voiceDurationLabel(int seconds) {
  final value = seconds < 0 ? 0 : seconds;
  final minutes = value ~/ 60;
  final remainder = value % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
}

class _ServerActionBanner extends StatelessWidget {
  const _ServerActionBanner({
    required this.action,
    this.onAction,
    this.isBusy = false,
  });

  final ChatNextAction action;
  final VoidCallback? onAction;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final text = switch (action.type) {
      ChatNextActionType.openTaskPanel => 'AI 已请求打开任务面板。',
      ChatNextActionType.pollTask => 'AI 正在处理任务。',
      ChatNextActionType.pollAgentRun ||
      ChatNextActionType.pollThread => 'AI 正在生成回复。',
      ChatNextActionType.pollAsr => 'AI 正在处理语音转写。',
      ChatNextActionType.quotaInsufficient =>
        action.userMessage ?? '额度不足，请稍后重试。',
      ChatNextActionType.retryAsr => '语音转写需要重试。',
      ChatNextActionType.none => '',
    };
    return V3Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
      child: Row(
        children: [
          Icon(Icons.info_outline, color: HuahuoV3Theme.tokensOf(context).ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: HuahuoV3Theme.tokensOf(context).ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (onAction != null)
            IconButton(
              tooltip: switch (action.type) {
                ChatNextActionType.retryAsr => '重试转写',
                ChatNextActionType.pollAsr => '刷新转写',
                _ => '刷新回复',
              },
              onPressed: isBusy ? null : onAction,
              icon: isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      action.type == ChatNextActionType.retryAsr
                          ? Icons.restart_alt_rounded
                          : Icons.refresh_rounded,
                    ),
            ),
        ],
      ),
    );
  }
}

class V3ChatInputBar extends StatelessWidget {
  const V3ChatInputBar({
    required this.controller,
    required this.focusNode,
    required this.hasText,
    required this.isSubmissionInFlight,
    required this.isInputBusy,
    required this.enabled,
    required this.canSubmit,
    required this.voicePhase,
    required this.voiceEnabled,
    required this.entryMode,
    required this.attachments,
    required this.memoryNotes,
    required this.onPlus,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onPreviewAttachment,
    required this.onRemoveMemoryNote,
    required this.onVoice,
    required this.onSend,
    this.digitalTwinStyle = false,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasText;
  final bool isSubmissionInFlight;
  final bool isInputBusy;
  final bool enabled;
  final bool canSubmit;
  final V3ChatVoiceControlPhase voicePhase;
  final bool voiceEnabled;
  final bool entryMode;
  final List<ChatFileAttachment> attachments;
  final List<V3FeedItem> memoryNotes;
  final VoidCallback onPlus;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<ChatFileAttachment> onRetryAttachment;
  final ValueChanged<ChatFileAttachment> onPreviewAttachment;
  final ValueChanged<String> onRemoveMemoryNote;
  final VoidCallback onVoice;
  final VoidCallback onSend;
  final bool digitalTwinStyle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final voiceEngaged = voicePhase != V3ChatVoiceControlPhase.idle;
    final sendForeground =
        ThemeData.estimateBrightnessForColor(colors.accent) == Brightness.dark
        ? Colors.white
        : colors.canvas;
    final hasContext = attachments.isNotEmpty || memoryNotes.isNotEmpty;
    final composer = V3ChatComposerShell(
      surfaceKey: ValueKey<String>(
        entryMode ? 'chat-entry-composer' : 'chat-composer-shell',
      ),
      embedded: hasContext,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Tooltip(
            message: '添加资料',
            child: Material(
              key: ValueKey<String>(
                entryMode ? 'chat-entry-add' : 'chat-composer-add',
              ),
              color: colors.surfaceMuted,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: !enabled || isSubmissionInFlight || voiceEngaged
                    ? null
                    : onPlus,
                child: const SizedBox.square(
                  dimension: V3ChatComposerMetrics.actionSize,
                  child: Icon(
                    Icons.add,
                    size: V3ChatComposerMetrics.actionIconSize,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: V3CenteredInput(
              key: const ValueKey('chat-composer-input-target'),
              minHeight: V3ChatComposerMetrics.actionSize,
              focusNode: focusNode,
              enabled: enabled && !isInputBusy,
              builder: (inputFocus) => TextField(
                key: const ValueKey<String>('chat-composer'),
                controller: controller,
                focusNode: inputFocus,
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                enabled: enabled && !isInputBusy,
                readOnly: voiceEngaged || isSubmissionInFlight,
                minLines: 1,
                maxLines: V3ChatComposerMetrics.maxVisibleLines,
                scrollPhysics: const ClampingScrollPhysics(),
                textAlignVertical: TextAlignVertical.center,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (enabled &&
                      canSubmit &&
                      !isSubmissionInFlight &&
                      !isInputBusy &&
                      !voiceEngaged) {
                    onSend();
                  }
                },
                style: TextStyle(
                  color: colors.text,
                  fontFamily: digitalTwinStyle ? 'Noto Sans SC' : null,
                  fontSize: digitalTwinStyle ? 12 : 14,
                  fontWeight: FontWeight.w400,
                ),
                decoration: V3TextEditing.inlineDecoration.copyWith(
                  hintText: voiceEngaged
                      ? '正在转写，可继续说…'
                      : digitalTwinStyle
                      ? '告诉我你想强化的方向…'
                      : ChatEntryFigmaSpec.composerHint,
                  hintStyle: TextStyle(
                    fontSize: digitalTwinStyle ? 12 : 14,
                    fontWeight: FontWeight.w400,
                    color: colors.muted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            key: ValueKey<String>(
              entryMode ? 'chat-entry-voice' : 'chat-composer-voice',
            ),
            child: _LiveTranscriptionVoiceButton(
              phase: voicePhase,
              enabled: switch (voicePhase) {
                V3ChatVoiceControlPhase.idle => enabled && voiceEnabled,
                V3ChatVoiceControlPhase.recording => true,
                V3ChatVoiceControlPhase.starting ||
                V3ChatVoiceControlPhase.stopping => false,
              },
              color: colors.surfaceMuted,
              activeColor: colors.accent,
              foreground: colors.ink,
              dimension: V3ChatComposerMetrics.actionSize,
              coreDimension: 36,
              compactEntryStyle: true,
              onPressed: onVoice,
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: '发送',
            child: Material(
              key: ValueKey<String>(
                entryMode ? 'chat-entry-send' : 'chat-composer-send',
              ),
              color: colors.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap:
                    !enabled ||
                        !canSubmit ||
                        isSubmissionInFlight ||
                        isInputBusy ||
                        voiceEngaged ||
                        !hasText
                    ? null
                    : onSend,
                child: SizedBox.square(
                  dimension: V3ChatComposerMetrics.actionSize,
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    color:
                        enabled &&
                            canSubmit &&
                            !isSubmissionInFlight &&
                            !isInputBusy &&
                            !voiceEngaged &&
                            hasText
                        ? sendForeground
                        : sendForeground.withValues(alpha: .42),
                    size: 25,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final disclaimer = Text(
      ChatEntryFigmaSpec.disclaimer,
      key: const ValueKey<String>('chat-entry-disclaimer'),
      style: TextStyle(
        color: colors.muted,
        fontSize: 11,
        fontWeight: FontWeight.w400,
      ),
    );
    if (hasContext) {
      return Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: V3ChatComposerMetrics.maximumWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                key: const ValueKey('chat-composer-context-panel'),
                color: colors.surface,
                elevation: 3,
                shadowColor: colors.ink.withValues(alpha: .08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(color: colors.line),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Semantics(
                        enabled: !isSubmissionInFlight,
                        child: IgnorePointer(
                          ignoring: isSubmissionInFlight,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 120),
                            opacity: isSubmissionInFlight ? .56 : 1,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (memoryNotes.isNotEmpty)
                                  _MemoryNoteContextStrip(
                                    notes: memoryNotes,
                                    onRemove: onRemoveMemoryNote,
                                    onContinueAdding: onPlus,
                                  ),
                                if (memoryNotes.isNotEmpty &&
                                    attachments.isNotEmpty)
                                  const SizedBox(height: 12),
                                if (attachments.isNotEmpty)
                                  V3ChatFileAttachmentStrip(
                                    attachments: attachments,
                                    onRemove: onRemoveAttachment,
                                    onRetry: onRetryAttachment,
                                    onPreview: onPreviewAttachment,
                                    onContinueAdding: onPlus,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, thickness: 1, color: colors.line),
                    composer,
                  ],
                ),
              ),
              if (entryMode) ...[const SizedBox(height: 4), disclaimer],
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: V3ChatComposerMetrics.maximumWidth,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            composer,
            if (entryMode) ...[const SizedBox(height: 4), disclaimer],
          ],
        ),
      ),
    );
  }
}

class _LiveTranscriptionVoiceButton extends StatefulWidget {
  const _LiveTranscriptionVoiceButton({
    required this.phase,
    required this.enabled,
    required this.color,
    required this.foreground,
    required this.onPressed,
    this.activeColor,
    this.dimension = 52,
    this.coreDimension = 36,
    this.compactEntryStyle = false,
  });

  final V3ChatVoiceControlPhase phase;
  final bool enabled;
  final Color color;
  final Color? activeColor;
  final Color foreground;
  final VoidCallback onPressed;
  final double dimension;
  final double coreDimension;
  final bool compactEntryStyle;

  @override
  State<_LiveTranscriptionVoiceButton> createState() =>
      _LiveTranscriptionVoiceButtonState();
}

class _LiveTranscriptionVoiceButtonState
    extends State<_LiveTranscriptionVoiceButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  final _tickerMetrics = RuntimeTickerMetricsLease('chat_voice_pulse');

  bool get _showPulse => widget.phase != V3ChatVoiceControlPhase.idle;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: V3MotionTokens.activityPulse,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _LiveTranscriptionVoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final shouldPulse =
        _showPulse &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop(canceled: false);
    }
    _tickerMetrics.sync(context, active: shouldPulse);
  }

  @override
  void dispose() {
    _tickerMetrics.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (widget.phase) {
      V3ChatVoiceControlPhase.idle => '开始实时转写',
      V3ChatVoiceControlPhase.starting => '正在启动实时转写',
      V3ChatVoiceControlPhase.recording => '结束实时转写',
      V3ChatVoiceControlPhase.stopping => '正在结束实时转写',
    };
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final recordingColor = widget.compactEntryStyle
            ? widget.activeColor ?? widget.color
            : const Color(0xFFDC3C51);
        final controlColor = _showPulse
            ? widget.compactEntryStyle
                  ? Theme.of(context).colorScheme.surface
                  : const Color(0xFFFFE7EB)
            : widget.color;
        final controlForeground = _showPulse
            ? recordingColor
            : widget.foreground;
        final phase = _showPulse ? _pulse.value : 0.0;
        final outerWaveOpacity = _showPulse ? (.46 * (1 - phase)) : 0.0;
        final innerWaveOpacity = _showPulse
            ? (.34 * (1 - ((phase + .48) % 1)))
            : 0.0;
        return Tooltip(
          message: tooltip,
          child: SizedBox.square(
            dimension: widget.dimension,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_showPulse)
                  Transform.scale(
                    key: const ValueKey<String>(
                      'chat-live-transcription-wave-outer',
                    ),
                    scale: .72 + (phase * .28),
                    child: Opacity(
                      opacity: outerWaveOpacity,
                      child: Container(
                        width: widget.dimension - 4,
                        height: widget.dimension - 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: recordingColor, width: 2),
                        ),
                      ),
                    ),
                  ),
                if (_showPulse)
                  Transform.scale(
                    scale: .58 + (((phase + .48) % 1) * .32),
                    child: Opacity(
                      opacity: innerWaveOpacity,
                      child: Container(
                        width: widget.dimension - 4,
                        height: widget.dimension - 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: recordingColor, width: 2),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: DecoratedBox(
                    key: const ValueKey<String>(
                      'chat-live-transcription-voice',
                    ),
                    decoration: BoxDecoration(
                      color: widget.compactEntryStyle
                          ? Theme.of(context).colorScheme.surface
                          : _showPulse
                          ? recordingColor.withValues(alpha: .20)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _showPulse
                            ? recordingColor.withValues(alpha: .90)
                            : Colors.transparent,
                        width: widget.compactEntryStyle ? 1.2 : 2.5,
                      ),
                      boxShadow: _showPulse
                          ? <BoxShadow>[
                              BoxShadow(
                                color: recordingColor.withValues(
                                  alpha: widget.compactEntryStyle ? .12 : .40,
                                ),
                                blurRadius: widget.compactEntryStyle ? 8 : 14,
                                spreadRadius: widget.compactEntryStyle ? 0 : 1,
                              ),
                            ]
                          : const <BoxShadow>[],
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: widget.coreDimension,
                  child: Material(
                    key: const ValueKey<String>('chat-live-transcription-core'),
                    color: controlColor,
                    shape: const CircleBorder(),
                    child: Center(
                      child: switch (widget.phase) {
                        V3ChatVoiceControlPhase.starting ||
                        V3ChatVoiceControlPhase.stopping => SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            key: const ValueKey<String>(
                              'chat-live-transcription-progress',
                            ),
                            color: controlForeground,
                            strokeWidth: 2.5,
                          ),
                        ),
                        V3ChatVoiceControlPhase.recording => Icon(
                          widget.compactEntryStyle
                              ? Icons.mic_rounded
                              : Icons.stop_rounded,
                          color: controlForeground,
                          size: 25,
                        ),
                        V3ChatVoiceControlPhase.idle => Icon(
                          Icons.mic_rounded,
                          color: controlForeground,
                          size: 25,
                        ),
                      },
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: widget.enabled ? widget.onPressed : null,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class V3ChatReceivedActivityCard extends StatelessWidget {
  const V3ChatReceivedActivityCard({this.noteAware = false, super.key});

  final bool noteAware;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey<String>('chat-assistant-thinking-bubble'),
      constraints: const BoxConstraints(maxWidth: 354),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: tokens.canvas,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: tokens.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: V3AgentRunGlyph(
              key: const ValueKey<String>('chat-assistant-thinking-progress'),
              color: tokens.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '聊一聊 Agent',
                  style: TextStyle(
                    color: tokens.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  noteAware
                      ? '已收到，正在进行分析中，正在思考要调用的工具…'
                      : '已收到，正在进行分析\n正在思考需要调用的工具…',
                  style: TextStyle(
                    color: tokens.muted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 50,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  decoration: BoxDecoration(
                    color: tokens.surfaceMuted,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const _V3ChatActivitySkeleton(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _V3ChatActivitySkeleton extends StatelessWidget {
  const _V3ChatActivitySkeleton();

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    Widget line(double width) => Container(
      width: width,
      height: 4,
      decoration: BoxDecoration(
        color: tokens.line,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(216),
        const SizedBox(height: 7),
        line(176),
        const SizedBox(height: 7),
        line(128),
      ],
    );
  }
}

class V3ChatMessageResourceList extends StatelessWidget {
  const V3ChatMessageResourceList({required this.attachments, super.key});

  final List<ChatResourceAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < attachments.length; index += 1) ...[
          _ChatResourceRow(attachment: attachments[index]),
          if (index != attachments.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ChatResourceRow extends StatelessWidget {
  const _ChatResourceRow({required this.attachment});

  final ChatResourceAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final metadata = <String>[
      if (attachment.mimeType case final mimeType?) mimeType,
      if (_chatResourceSizeLabel(attachment.sizeBytes) case final size?) size,
    ].join(' · ');
    return Container(
      key: ValueKey<String>('chat-resource-${attachment.resourceId}'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          Icon(
            switch (attachment.kind) {
              ChatResourceAttachmentKind.image => Icons.image_outlined,
              ChatResourceAttachmentKind.video => Icons.videocam_outlined,
              ChatResourceAttachmentKind.audio => Icons.audiotrack_outlined,
              ChatResourceAttachmentKind.file =>
                Icons.insert_drive_file_outlined,
            },
            color: colors.accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.displayName ??
                      switch (attachment.kind) {
                        ChatResourceAttachmentKind.image => '图片',
                        ChatResourceAttachmentKind.video => '视频',
                        ChatResourceAttachmentKind.audio => '音频',
                        ChatResourceAttachmentKind.file => '文件',
                      },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _chatResourceSizeLabel(int? value) {
  if (value == null || value <= 0) return null;
  if (value < 1024) return '$value B';
  final kibibytes = value / 1024;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} KB';
  final mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) return '${mebibytes.toStringAsFixed(1)} MB';
  return '${(mebibytes / 1024).toStringAsFixed(1)} GB';
}

class V3ChatMessageImageGrid extends StatelessWidget {
  const V3ChatMessageImageGrid({
    required this.attachments,
    required this.resourceImageCache,
    required this.nativeFilePort,
    this.generatedByAssistant = false,
    super.key,
  });

  final List<ChatImageAttachment> attachments;
  final ResourceImageReader resourceImageCache;
  final NativeFilePort nativeFilePort;
  final bool generatedByAssistant;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 152.0;
        final columns = generatedByAssistant
            ? 1
            : availableWidth >= 232
            ? 2
            : 1;
        final tileExtent = generatedByAssistant
            ? availableWidth.clamp(0.0, 520.0).toDouble()
            : ((availableWidth - spacing * (columns - 1)) / columns)
                  .clamp(0.0, 176.0)
                  .toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (generatedByAssistant) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 15,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'AI 生成图片',
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final attachment in attachments)
                  _ChatRemoteImageThumbnail(
                    attachment: attachment,
                    resourceImageCache: resourceImageCache,
                    nativeFilePort: nativeFilePort,
                    dimension: tileExtent,
                    height: generatedByAssistant
                        ? (tileExtent * .92).clamp(220.0, 520.0).toDouble()
                        : null,
                    semanticLabel: generatedByAssistant ? '查看 AI 生成图片' : '查看图片',
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

int _chatImageCacheExtent(BuildContext context, double logicalExtent) {
  final pixels = logicalExtent * MediaQuery.devicePixelRatioOf(context);
  return pixels.ceil().clamp(1, 4096).toInt();
}

class _ChatRemoteImageThumbnail extends StatefulWidget {
  const _ChatRemoteImageThumbnail({
    required this.attachment,
    required this.resourceImageCache,
    required this.nativeFilePort,
    required this.dimension,
    this.height,
    required this.semanticLabel,
  });

  final ChatImageAttachment attachment;
  final ResourceImageReader resourceImageCache;
  final NativeFilePort nativeFilePort;
  final double dimension;
  final double? height;
  final String semanticLabel;

  @override
  State<_ChatRemoteImageThumbnail> createState() =>
      _ChatRemoteImageThumbnailState();
}

class _ChatRemoteImageThumbnailState extends State<_ChatRemoteImageThumbnail> {
  late Future<CachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.resourceImageCache.load(widget.attachment.resourceId);
  }

  @override
  void didUpdateWidget(covariant _ChatRemoteImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.resourceId != widget.attachment.resourceId) {
      _image = widget.resourceImageCache.load(widget.attachment.resourceId);
    }
  }

  void _retry() {
    setState(() {
      _image = widget.resourceImageCache.load(widget.attachment.resourceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: widget.dimension,
      height: widget.height ?? widget.dimension,
      child: FutureBuilder<CachedResourceImage>(
        future: _image,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image != null) {
            final logicalHeight = widget.height ?? widget.dimension;
            final cacheWidth = _chatImageCacheExtent(context, widget.dimension);
            final cacheHeight = _chatImageCacheExtent(context, logicalHeight);
            return Material(
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              color: colors.surfaceMuted,
              child: Semantics(
                key: ValueKey<String>(
                  'chat-image-${widget.attachment.resourceId}',
                ),
                button: true,
                label: widget.semanticLabel,
                child: InkWell(
                  excludeFromSemantics: true,
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _ChatRemoteImageViewer(
                      resourceId: image.resourceId,
                      displayName: widget.attachment.displayName,
                      resourceImageCache: widget.resourceImageCache,
                      nativeFilePort: widget.nativeFilePort,
                      thumbnailBytes: image.bytes,
                      thumbnailCacheWidth: cacheWidth,
                      thumbnailCacheHeight: cacheHeight,
                    ),
                  ),
                  child: Image.memory(
                    image.bytes,
                    fit: BoxFit.cover,
                    cacheWidth: cacheWidth,
                    cacheHeight: cacheHeight,
                    errorBuilder: (_, _, _) => Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: colors.muted,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
              ),
            );
          }
          return Semantics(
            button: true,
            label: '重新加载图片',
            onTap: _retry,
            child: ExcludeSemantics(
              child: Tooltip(
                message: '重新加载图片',
                child: Material(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: _retry,
                    borderRadius: BorderRadius.circular(8),
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: colors.muted,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChatRemoteImageViewer extends StatefulWidget {
  const _ChatRemoteImageViewer({
    required this.resourceId,
    required this.resourceImageCache,
    required this.nativeFilePort,
    required this.thumbnailBytes,
    required this.thumbnailCacheWidth,
    required this.thumbnailCacheHeight,
    this.displayName,
  });

  final String resourceId;
  final ResourceImageReader resourceImageCache;
  final NativeFilePort nativeFilePort;
  final Uint8List thumbnailBytes;
  final int thumbnailCacheWidth;
  final int thumbnailCacheHeight;
  final String? displayName;

  @override
  State<_ChatRemoteImageViewer> createState() => _ChatRemoteImageViewerState();
}

class _ChatRemoteImageViewerState extends State<_ChatRemoteImageViewer> {
  var _isSaving = false;
  late Future<CachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.resourceImageCache.load(widget.resourceId);
  }

  void _reload() {
    setState(() {
      _image = widget.resourceImageCache.load(widget.resourceId);
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final image = await widget.resourceImageCache.load(widget.resourceId);
      final saved = await widget.nativeFilePort.saveImageToGallery(
        bytes: image.bytes,
        displayName: widget.displayName ?? 'AI-图片',
        mimeType: image.mimeType,
      );
      if (!mounted) return;
      showV3Snack(
        context,
        saved.ok && saved.value == true ? '图片已保存到相册' : '保存图片失败，请重试',
      );
    } catch (_) {
      if (mounted) showV3Snack(context, '保存图片失败，请重试');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CachedResourceImage>(
      future: _image,
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image != null) {
          final viewport = MediaQuery.sizeOf(context);
          final cacheWidth = _chatImageCacheExtent(context, viewport.width * 2);
          final cacheHeight = _chatImageCacheExtent(
            context,
            viewport.height * 2,
          );
          return _ChatImageViewerSurface(
            image: Image.memory(
              image.bytes,
              fit: BoxFit.contain,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              frameBuilder: (context, child, frame, synchronous) {
                if (synchronous || frame != null) return child;
                return Image.memory(
                  widget.thumbnailBytes,
                  fit: BoxFit.contain,
                  cacheWidth: widget.thumbnailCacheWidth,
                  cacheHeight: widget.thumbnailCacheHeight,
                );
              },
              errorBuilder: (_, _, _) =>
                  _ChatImageViewerFailure(onRetry: _reload),
            ),
            isSaving: _isSaving,
            onSave: _save,
          );
        }
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(12),
          child: SizedBox(
            width: MediaQuery.sizeOf(context).width - 24,
            height: MediaQuery.sizeOf(context).height - 88,
            child: snapshot.connectionState != ConnectionState.done
                ? const Center(
                    child: CircularProgressIndicator.adaptive(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : _ChatImageViewerFailure(onRetry: _reload),
          ),
        );
      },
    );
  }
}

class _ChatImageViewerFailure extends StatelessWidget {
  const _ChatImageViewerFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IconButton(
        tooltip: '重新加载图片',
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 30),
      ),
    );
  }
}

bool _showsServerAction(ChatNextActionType type) => switch (type) {
  ChatNextActionType.none ||
  ChatNextActionType.pollTask ||
  ChatNextActionType.pollAgentRun ||
  ChatNextActionType.pollThread => false,
  _ => true,
};

class _VisualReferenceHelpSheet extends StatelessWidget {
  const _VisualReferenceHelpSheet({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey<String>('visual-reference-help-sheet'),
      height: 418,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .12),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 26),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.ink.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const SizedBox(width: 36, height: 4),
                ),
              ),
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    colors.accent.withValues(alpha: .14),
                    colors.surface,
                  ),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 40,
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: colors.accent,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '什么是视觉参考？',
                key: const ValueKey<String>('visual-reference-help-title'),
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 18,
                  height: 26 / 18,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '视觉参考会根据你的口播稿生成一张示意图，提前呈现这条视频需要准备的道具、灯光布局和拍摄场景。',
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          height: 22 / 14,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '它不是最终成片，而是一张帮助你准备拍摄的视觉清单。',
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          height: 22 / 14,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  key: const ValueKey<String>('visual-reference-help-confirm'),
                  onPressed: onClose,
                  style: FilledButton.styleFrom(
                    foregroundColor: colors.onPrimary,
                    backgroundColor: colors.accent,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class V3ChatAttachmentSheet extends StatelessWidget {
  const V3ChatAttachmentSheet({
    required this.onClose,
    required this.onNote,
    required this.onCamera,
    required this.onImages,
    this.onVideo,
    super.key,
  });

  final VoidCallback onClose;
  final VoidCallback onNote;
  final VoidCallback onCamera;
  final VoidCallback onImages;
  final VoidCallback? onVideo;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: HuahuoSpacing.compact),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const ValueKey('chat-attachment-close'),
                  tooltip: '关闭',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 22),
                ),
              ),
            ),
            _PlusMenuTile(
              icon: LucideIcons.notebookText,
              title: '引用笔记',
              onTap: onNote,
            ),
            const SizedBox(height: 4),
            _PlusMenuTile(
              icon: LucideIcons.camera,
              title: '拍照',
              onTap: onCamera,
            ),
            const SizedBox(height: 4),
            _PlusMenuTile(
              icon: LucideIcons.image,
              title: '图片',
              onTap: onImages,
            ),
            if (onVideo != null) ...[
              const SizedBox(height: 4),
              _PlusMenuTile(
                icon: LucideIcons.video,
                title: '上传视频',
                onTap: onVideo!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlusMenuTile extends StatelessWidget {
  const _PlusMenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surfaceMuted.withValues(alpha: .64),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 54,
              height: 56,
              child: Icon(icon, size: 21, color: colors.ink),
            ),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: colors.muted, size: 20),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}
